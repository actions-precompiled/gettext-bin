#!/usr/bin/env bash
# Build GNU gettext from upstream tarball and produce a relocatable package.
set -euo pipefail

GETTEXT_VERSION="${GETTEXT_VERSION:?GETTEXT_VERSION is required}"
BUILD_TARGET="${BUILD_TARGET:-linux-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/out}"
# Prefer a public mirror; override with GETTEXT_MIRROR if needed.
GETTEXT_MIRROR="${GETTEXT_MIRROR:-https://ftp.gnu.org/gnu/gettext}"
JOBS="${JOBS:-$(nproc)}"
KEEP_SYMBOLS="${KEEP_SYMBOLS:-0}"
# Optional: skip GPG verify (not recommended)
SKIP_GPG="${SKIP_GPG:-0}"
# Bruno Haible signing keys (same set the old Dagger pipeline used)
GPG_KEYS="${GPG_KEYS:-B6301D9E1BBEAC08 F5BE8B267C6A406D 4F494A942E4616C2}"

RAW_VERSION="${GETTEXT_VERSION}"
if [[ "$RAW_VERSION" =~ ^v ]]; then
  TAG="${RAW_VERSION#v}"
else
  TAG="$RAW_VERSION"
fi

case "$BUILD_TARGET" in
  linux-amd64|linux-x86_64) ARCHIVE_SUFFIX="linux-amd64" ;;
  linux-aarch64|linux-arm64) ARCHIVE_SUFFIX="linux-aarch64" ;;
  *)
    echo "Unsupported BUILD_TARGET: $BUILD_TARGET (linux-amd64, linux-aarch64)" >&2
    exit 1
    ;;
esac

WORKDIR="${WORKDIR:-/tmp/gettext-build}"
SRC_DIR="${WORKDIR}/src"
STAGE_DIR="${WORKDIR}/stage"
PREFIX_DIR="${STAGE_DIR}/gettext"
TARBALL="${WORKDIR}/gettext-${TAG}.tar.gz"
SIGFILE="${WORKDIR}/gettext-${TAG}.tar.gz.sig"

rm -rf "$WORKDIR"
mkdir -p "$SRC_DIR" "$PREFIX_DIR" "$OUTPUT_DIR"

echo "========================================="
echo "Building gettext ${GETTEXT_VERSION}"
echo "  BUILD_TARGET:  ${BUILD_TARGET}"
echo "  ARCHIVE:       gettext-${TAG}-${ARCHIVE_SUFFIX}.tar.gz"
echo "  Mirror:        ${GETTEXT_MIRROR}"
echo "========================================="

# --- fetch source ---
TARBALL_URL="${GETTEXT_MIRROR}/gettext-${TAG}.tar.gz"
SIG_URL="${GETTEXT_MIRROR}/gettext-${TAG}.tar.gz.sig"

echo "Downloading ${TARBALL_URL}..."
curl --fail --silent --show-error --location --retry 3 -o "$TARBALL" "$TARBALL_URL"

if [[ "$SKIP_GPG" != "1" ]]; then
  echo "Downloading signature and verifying..."
  curl --fail --silent --show-error --location --retry 3 -o "$SIGFILE" "$SIG_URL" || {
    echo "Signature file missing; set SKIP_GPG=1 to proceed without verify" >&2
    exit 1
  }
  export GNUPGHOME="${GNUPGHOME:-${WORKDIR}/gnupg}"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  # shellcheck disable=SC2086
  gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys ${GPG_KEYS} \
    || gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys ${GPG_KEYS} \
    || gpg --batch --keyserver keyserver.ubuntu.com --recv-keys ${GPG_KEYS}
  gpg --batch --verify "$SIGFILE" "$TARBALL"
fi

echo "Extracting..."
tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1

# --- configure & build (static tools, relocatable install) ---
# Disable language bindings we do not ship; keep C/C++ tools lean.
cd "$SRC_DIR"
./configure \
  --prefix=/usr \
  --disable-shared \
  --enable-static \
  --enable-relocatable \
  --disable-java \
  --disable-native-java \
  --disable-csharp \
  --disable-d \
  --disable-modula2 \
  --without-emacs \
  --disable-openmp \
  --disable-dependency-tracking

make -j"$JOBS"
# DESTDIR layout → PREFIX_DIR/usr/...
DESTDIR="$PREFIX_DIR" make install

# Flatten DESTDIR/usr → package root
if [[ -d "$PREFIX_DIR/usr" ]]; then
  shopt -s dotglob nullglob
  for entry in "$PREFIX_DIR"/usr/*; do
    base="$(basename "$entry")"
    if [[ -e "$PREFIX_DIR/$base" ]]; then
      cp -a "$entry"/. "$PREFIX_DIR/$base"/ 2>/dev/null || mv "$entry"/* "$PREFIX_DIR/$base"/
    else
      mv "$entry" "$PREFIX_DIR/$base"
    fi
  done
  shopt -u dotglob nullglob
  rm -rf "$PREFIX_DIR/usr"
fi

# Drop dev / static archive clutter (we ship tools, not a full SDK)
rm -rf \
  "$PREFIX_DIR/include" \
  "$PREFIX_DIR/lib/pkgconfig" \
  "$PREFIX_DIR/lib"/*.a \
  "$PREFIX_DIR/lib"/*.la \
  "$PREFIX_DIR/share/doc" \
  "$PREFIX_DIR/share/info" \
  "$PREFIX_DIR/share/man/man3" \
  2>/dev/null || true

# Collapse multi-arch lib dirs into lib/
for archdir in "$PREFIX_DIR"/lib/*-linux-gnu; do
  [[ -d "$archdir" ]] || continue
  shopt -s nullglob
  for entry in "$archdir"/*; do
    base="$(basename "$entry")"
    if [[ -e "$PREFIX_DIR/lib/$base" ]]; then
      rm -rf "$entry"
    else
      mkdir -p "$PREFIX_DIR/lib"
      mv "$entry" "$PREFIX_DIR/lib/"
    fi
  done
  shopt -u nullglob
  rm -rf "$archdir"
done

if [[ ! -x "$PREFIX_DIR/bin/msgfmt" && ! -x "$PREFIX_DIR/bin/gettext" ]]; then
  echo "Install did not produce expected tools under bin/" >&2
  find "$PREFIX_DIR" -type f | head -80 >&2
  exit 1
fi

mkdir -p "$PREFIX_DIR/lib" "$PREFIX_DIR/bin"

# Static-lean build still may link a few shared system libs; bundle non-core ones.
is_system_lib() {
  local base
  base="$(basename "$1")"
  case "$base" in
    libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libresolv.so*|libutil.so*|libcrypt.so*|libnsl.so*|libanl.so*|ld-linux*.so*|ld-*.so|libstdc++.so*|libgcc_s.so*|libgomp.so*|linux-vdso.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

declare -A SEEN_LIBS=()

copy_lib() {
  local src="$1"
  [[ -z "$src" || ! -e "$src" ]] && return 0
  local real
  real="$(readlink -f "$src")"
  [[ -z "$real" || ! -f "$real" ]] && return 0
  if [[ -n "${SEEN_LIBS[$real]+x}" ]]; then
    return 0
  fi
  SEEN_LIBS[$real]=1

  if is_system_lib "$real"; then
    return 0
  fi

  local base dest
  base="$(basename "$real")"
  dest="$PREFIX_DIR/lib/$base"
  case "$base" in
    ld-linux*.so*|ld-*.so) return 0 ;;
  esac

  if [[ ! -e "$dest" ]]; then
    echo "  bundling $real"
    cp -a "$real" "$dest"
  elif [[ "$(readlink -f "$dest")" != "$real" ]]; then
    echo "  bundling $real (replace existing $base)"
    cp -a "$real" "$dest"
  fi

  local soname srcbase
  soname="$(patchelf --print-soname "$dest" 2>/dev/null || true)"
  if [[ -n "$soname" && "$soname" != "$base" && ! -e "$PREFIX_DIR/lib/$soname" ]]; then
    ln -sfn "$base" "$PREFIX_DIR/lib/$soname"
  fi
  srcbase="$(basename "$src")"
  if [[ "$srcbase" != "$base" && ! -e "$PREFIX_DIR/lib/$srcbase" ]]; then
    ln -sfn "$base" "$PREFIX_DIR/lib/$srcbase"
  fi

  local dep
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    copy_lib "$dep"
  done < <(ldd "$real" 2>/dev/null | awk '/=> \// { print $3 }' || true)
}

echo "Collecting shared library dependencies..."
mapfile -d '' ELF_FILES < <(find "$PREFIX_DIR/bin" -type f -print0 2>/dev/null)

for bin in "${ELF_FILES[@]}"; do
  file "$bin" | grep -q 'ELF' || continue
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    copy_lib "$dep"
  done < <(ldd "$bin" 2>/dev/null | awk '/=> \// { print $3 }' || true)
done

# Wrappers: set LD_LIBRARY_PATH for any bundled libs (static binaries are no-ops).
# Skip scripts (e.g. gettext.sh) and already-wrapped names.
echo "Writing relocatable wrappers for ELF tools..."
for path in "$PREFIX_DIR"/bin/*; do
  [[ -f "$path" ]] || continue
  name="$(basename "$path")"
  case "$name" in
    *.bin|*.sh) continue ;;
  esac
  if head -n1 "$path" 2>/dev/null | grep -q '^#!'; then
    continue
  fi
  file "$path" | grep -q 'ELF' || continue
  mv "$path" "$PREFIX_DIR/bin/${name}.bin"
  cat > "$path" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
ROOT="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")/.." && pwd)"
export LD_LIBRARY_PATH="\${ROOT}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "\${ROOT}/bin/${name}.bin" "\$@"
WRAP
  chmod +x "$path"
done

echo "Setting RPATH on ELF files..."
while IFS= read -r -d '' elf; do
  file "$elf" | grep -q 'ELF' || continue
  case "$elf" in
    */bin/*)
      patchelf --set-rpath '$ORIGIN/../lib' "$elf" 2>/dev/null || true
      ;;
    */lib/*)
      patchelf --set-rpath '$ORIGIN' "$elf" 2>/dev/null || true
      ;;
  esac
done < <(find "$PREFIX_DIR" -type f -print0)

if [[ "$KEEP_SYMBOLS" != "1" ]]; then
  echo "Stripping binaries..."
  while IFS= read -r -d '' elf; do
    file "$elf" | grep -q 'ELF' || continue
    strip --strip-unneeded "$elf" 2>/dev/null || true
  done < <(find "$PREFIX_DIR" -type f -print0)
fi

cat > "$PREFIX_DIR/BUILDINFO.txt" <<META
package=gettext
version=${TAG}
upstream_version=${TAG}
build_target=${BUILD_TARGET}
mirror=${GETTEXT_MIRROR}
configure=--disable-shared --enable-static --enable-relocatable
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META

echo "Smoke check (dynamic linker)..."
SMOKE_BIN=""
for candidate in msgfmt.bin gettext.bin msgfmt gettext; do
  if [[ -x "$PREFIX_DIR/bin/$candidate" ]]; then
    SMOKE_BIN="$PREFIX_DIR/bin/$candidate"
    break
  fi
done
if [[ -z "$SMOKE_BIN" ]]; then
  echo "No smoke binary found" >&2
  exit 1
fi

if file "$SMOKE_BIN" | grep -q 'ELF'; then
  if ! LD_LIBRARY_PATH="$PREFIX_DIR/lib" ldd "$SMOKE_BIN" | tee /tmp/gettext-ldd.txt | grep -q 'not found'; then
    echo "All linked libraries resolved."
  else
    echo "Unresolved libraries:" >&2
    grep 'not found' /tmp/gettext-ldd.txt >&2 || true
    exit 1
  fi
  set +e
  LD_LIBRARY_PATH="$PREFIX_DIR/lib" "$SMOKE_BIN" --version >/tmp/gettext-ver.txt 2>&1
  set -e
  if grep -qi 'error while loading shared libraries\|cannot open shared object' /tmp/gettext-ver.txt; then
    cat /tmp/gettext-ver.txt >&2
    exit 1
  fi
  cat /tmp/gettext-ver.txt || true
fi

ARCHIVE_NAME="gettext-${TAG}-${ARCHIVE_SUFFIX}.tar.gz"
echo "Creating ${ARCHIVE_NAME}..."
tar -czf "${OUTPUT_DIR}/${ARCHIVE_NAME}" -C "$STAGE_DIR" gettext

echo "========================================="
echo "Done: ${OUTPUT_DIR}/${ARCHIVE_NAME}"
ls -lh "${OUTPUT_DIR}/${ARCHIVE_NAME}"
echo "Contents (top):"
tar -tzf "${OUTPUT_DIR}/${ARCHIVE_NAME}" | head -n 40 || true
echo "========================================="
