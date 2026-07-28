# Build environment for relocatable gettext binaries (static-lean tools).
# Native multi-arch: build this image on amd64 or arm64 runners (no QEMU cross).
FROM ubuntu:24.04

ARG TARGETARCH=

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        file \
        gnupg \
        gperf \
        libtool \
        m4 \
        make \
        patchelf \
        pkg-config \
        tar \
        xz-utils \
        zlib1g-dev \
        libxml2-dev \
        libncurses-dev \
        bison \
        flex \
        gettext \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY scripts/build_and_package.sh /usr/local/bin/build_and_package.sh
RUN chmod +x /usr/local/bin/build_and_package.sh

ENTRYPOINT ["/usr/local/bin/build_and_package.sh"]
