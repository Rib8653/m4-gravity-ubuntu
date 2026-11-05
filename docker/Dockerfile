# Build environment for Gravity Linux on Ubuntu 26.04.
#
# Best on arm64 (an Ubuntu arm64 VM on the Mac itself, an arm64 server or a
# GitHub ubuntu-24.04-arm runner). It also works on x86_64: the kernel, U-Boot
# and m1n1 cross-compile, while Mesa and the image use qemu-user (much slower).
#
#   docker build -t gravity-ubuntu-builder docker/
#   docker run --rm -it --privileged -v "$PWD:/src" -w /src gravity-ubuntu-builder make all
#
# --privileged is needed for mmdebstrap's chroot mounts and binfmt (image step only).
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential bc bison flex git curl ca-certificates rsync cpio kmod \
      libssl-dev libelf-dev libncurses-dev dwarves pahole python3 python3-setuptools \
      debhelper devscripts dpkg-dev fakeroot quilt libarchive-tools xz-utils zstd zip unzip \
      rustc rust-src bindgen libclang-dev clang lld llvm \
      device-tree-compiler swig python3-dev libgnutls28-dev uuid-dev \
      imagemagick fontconfig \
      mmdebstrap ubuntu-keyring e2fsprogs dosfstools mtools apt-utils uuid-runtime \
      qemu-user-binfmt binfmt-support \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
      shellcheck \
 && rm -rf /var/lib/apt/lists/*

# m1n1 needs the bare-metal aarch64-unknown-none-softfloat Rust target, which
# Ubuntu does not package, so it comes from rustup. The kernel uses Ubuntu's
# rustc and bindgen above (needs rustc >= 1.85 and bindgen >= 0.71.1).
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl -fsSL https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init -o /tmp/rustup-init \
 && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain stable \
      --target aarch64-unknown-none-softfloat \
 && rm /tmp/rustup-init \
 && ln -s /opt/cargo/bin/rustup /usr/local/bin/rustup
# Keep Ubuntu's rustc/cargo first on PATH for the kernel. build-bootloader.sh
# selects the rustup toolchain for m1n1.
ENV M1N1_CARGO=/opt/cargo/bin/cargo M1N1_RUSTC=/opt/cargo/bin/rustc
