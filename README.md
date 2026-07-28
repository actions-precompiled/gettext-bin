# gettext prebuilt binaries

Relocatable [GNU gettext](https://www.gnu.org/software/gettext/) builds for
Linux, published as tarballs you can unpack and use with [mise](https://mise.jdx.dev/),
asdf, or a plain `PATH` entry.

Each package includes the gettext tools (`msgfmt`, `xgettext`, `msgmerge`, …)
built as a static-lean tree (wrappers + RPATH for relocatability).

## Why not Dagger / buildenv?

This repo used to be a Dagger pipeline. It now matches the rest of
actions-precompiled: **Docker + `create_releases`**, same shape as
[tesseract-bin](https://github.com/actions-precompiled/tesseract-bin) and
[quickshell](https://github.com/actions-precompiled/quickshell).

The generic [buildenv](https://github.com/actions-precompiled/buildenv) image is
aimed at small C/C++ CMake cross builds. Here we want a native multi-arch image
and a full GNU autotools configure of gettext.

## Supported targets

| Target | Builder | Notes |
|--------|---------|--------|
| `linux-amd64` | `ubuntu-latest` | Native build on Ubuntu 24.04 |
| `linux-aarch64` | `ubuntu-24.04-arm` | Native build (no QEMU) |

Native builds only. GitHub’s free arm64 runners are for **public** repos; private
repos need paid arm runners or self-hosted.

## Artifact layout

```text
gettext-0.26-linux-amd64.tar.gz
└── gettext/
    ├── bin/
    │   ├── msgfmt          (wrapper → msgfmt.bin when shared deps need LD path)
    │   ├── gettext
    │   ├── xgettext
    │   └── …
    ├── lib/                (any non-core shared libs that still linked)
    ├── share/
    └── BUILDINFO.txt
```

Install example:

```bash
mkdir -p ~/.local/gettext
tar -xzf gettext-0.26-linux-amd64.tar.gz -C ~/.local/gettext --strip-components=1
export PATH="$HOME/.local/gettext/bin:$PATH"
msgfmt --version
xgettext --version
```

## Building

### Prerequisites

- Docker
- Network (downloads the GNU tarball + pulls base image)
- GitHub CLI (`gh`) only if you use `--publish`

### Commands

```bash
# Build one version locally (default — no GitHub release)
./create_releases 0.26

# Auto-detect GNU releases not published here yet, still local-only
./create_releases

# See what would be built
./create_releases --dry-run
# or: DRY_RUN=1 ./create_releases

# Explicit target(s)
TARGETS=linux-amd64 ./create_releases 0.26
TARGETS="linux-amd64 linux-aarch64" ./create_releases 0.26

# Optional: also create a GitHub Release
./create_releases --publish 0.26
```

`create_releases` is a uv script (`#!/usr/bin/env -S uv run --script`, stdlib deps only).
Install tools with `mise install` (see `mise.toml`). Default `TARGETS` matches the
host (`linux-amd64` or `linux-aarch64`). **Publish is off by default** so local
builds are safe.

| Flag / env | Meaning |
|------------|---------|
| `--publish` / `PUBLISH=1` | Create GitHub releases and upload tarballs |
| `--dry-run` / `DRY_RUN=1` | List versions, do not build |
| `--skip-smoke` / `SKIP_SMOKE=1` | Skip post-build smoke test |
| `--smoke-only` | Only smoke-test existing `target/` tarballs (no build) |
| `TARGETS` | Space-separated targets (default: host arch) |
| `BUILD_OUTPUT_DIR` | Output root (default `$PWD/target`) |
| `SKIP_IMAGE_BUILD` | Reuse an already-built `gettext-buildenv:local` |
| `IMAGE_NAME` / `IMAGE_TAG` | Override image name |
| `GETTEXT_MIRROR` | Base URL for tarballs (default `https://ftp.gnu.org/gnu/gettext`) |
| `SKIP_GPG` | Set `1` to skip signature verify (not recommended) |

Smoke tests extract the tarball, run `--version` on core tools, and compile a tiny `.po`.

### What the container does

1. Downloads `gettext-<version>.tar.gz` (+ `.sig`) from the GNU mirror  
2. Verifies the GPG signature (Bruno Haible keys)  
3. Configures with `--disable-shared --enable-static`  
4. Installs into a staging prefix and packages `gettext/`  
5. Emits `gettext-<version>-linux-amd64.tar.gz` under `target/<target>/`

## CI

Two workflows:

| Workflow | Trigger | What |
|----------|---------|------|
| **Build** (`build.yml`) | **push** / PR → latest GNU version; **`workflow_dispatch`** → one version | Arch matrix (`linux-amd64`, `linux-aarch64`); upload artifacts; optional **GitHub Release** if `publish=true` |
| **Dispatch Missing** (`dispatch-missing.yml`) | **`workflow_dispatch` only** | Computes missing versions (or takes a list) and **dispatches one Build run per version** |

### Releases are mutable (re-issueable)

| Mode | Behavior |
|------|----------|
| `publish=true` | Create release if missing; `gh release upload --clobber` replaces same-named assets |
| `publish=true` + `recreate=true` | `gh release delete … --yes --cleanup-tag`, then create + upload |

### Typical flows

```text
# Smoke / PR / push
push → Build(latest) → artifacts only

# One version, maybe release
Actions → Build → version=0.26, publish=true

# Fan-out missing (safe start: cap + no publish)
Actions → Dispatch Missing → max=3, publish=false
```

Orchestration is `create_releases` (uv script, stdlib + `curl`/`docker`/`gh`).

## Versioning

Release tags track **GNU** gettext versions (`0.26`, `0.25.1`, …). The tarball
name uses the bare version (`gettext-0.26-linux-amd64.tar.gz`).

## Notes / limitations

- glibc is from Ubuntu 24.04 — older distros may not run the binary.
- Java/C#/D/Modula-2/Emacs bindings are disabled in this packaging.
- Windows packaging is out of scope for this turn.

## License

Upstream gettext is GPL / LGPL (see the source tree). This packaging glue is
provided under the same terms as other actions-precompiled repos unless noted
otherwise.
