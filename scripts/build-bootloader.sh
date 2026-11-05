#!/bin/bash
# Build Gravity's M4 m1n1 bootloader as the gravity-bootloader .deb.
#
# Build flags follow GravityLinux/packages gravity-bootloader.spec:
# RELEASE=1 LOGO=gravity, the M4 no-display patch, and two builds: stage 1
# (CHAINLOADING=1, used by the macOS-side installer) and stage 2 (packed into
# boot.bin with the device trees and U-Boot by update-m1n1).
. "$(dirname "$0")/lib.sh"
# Prefer a rustup toolchain (it has the bare-metal target); Ubuntu's rustc does not.
if [[ -n "${M1N1_CARGO:-}" ]]; then
    PATH="$(dirname "$M1N1_CARGO"):$PATH"
    export PATH
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
need make cargo rustc python3 dpkg-deb

"$TOP/scripts/fetch-sources.sh" bootloader
PKG="$SRC/gravity-packages"
M1N1="$SRC/bootloader"
VERSION="${BOOTLOADER_VERSION}-${BOOTLOADER_DEB_REVISION}"

rustup_target=aarch64-unknown-none-softfloat
libdir="$(rustc --print target-libdir --target "$rustup_target" 2>/dev/null || true)"
if [[ -z "$libdir" || ! -d "$libdir" ]]; then
    command -v rustup >/dev/null || die "the Rust $rustup_target target is required (rustup target add $rustup_target)"
    rustup target add "$rustup_target"
fi

log "Applying Gravity bootloader patch"
apply_patch "$M1N1" "$PKG/gravity-bootloader/m1n1-no-display.patch"

# Gravity's boot logo, from the same artwork revision as gravity-logos.
install -m0644 "$SRC/artwork/logos/png_128/GravityLinux_logomark.png" "$M1N1/data/gravity_128.png"
install -m0644 "$SRC/artwork/logos/png_256/GravityLinux_logomark.png" "$M1N1/data/gravity_256.png"

# The m1n1 Makefile calls ImageMagick 7's `magick`. Provide it on IM6 systems.
shim="$WORK/build/bin"
mkdir -p "$shim"
if ! command -v magick >/dev/null; then
    need convert
    printf '#!/bin/sh\nexec convert "$@"\n' >"$shim/magick"
    chmod +x "$shim/magick"
fi
export PATH="$shim:$PATH"

# Gravity's spec deletes Cargo.lock because it vendors crates for an offline
# RPM build. Here cargo downloads them, and the upstream Cargo.lock pins them.
flags=(RELEASE=1 LOGO=gravity ARCH="$(cross_prefix)")
log "Building m1n1 stage 1 (chainloading)"
make -C "$M1N1" clean >/dev/null
make -C "$M1N1" -j"$JOBS" "${flags[@]}" CHAINLOADING=1
rm -rf "$M1N1/build-stage1"
mv "$M1N1/build" "$M1N1/build-stage1"

log "Building m1n1 stage 2"
make -C "$M1N1" -j"$JOBS" "${flags[@]}"

# ---------------------------------------------------------------- package
stage="$WORK/build/deb/gravity-bootloader"
rm -rf "$stage"
install -Dm0644 "$M1N1/build/m1n1.bin"              "$stage/usr/lib/gravity-boot/m1n1.bin"
install -Dm0644 "$M1N1/build/m1n1.macho"            "$stage/usr/lib/gravity-boot/m1n1.macho"
install -Dm0644 "$M1N1/build-stage1/m1n1.bin"       "$stage/usr/lib/gravity-boot/stage1/m1n1.bin"
install -Dm0644 "$M1N1/build-stage1/m1n1.macho"     "$stage/usr/lib/gravity-boot/stage1/m1n1.macho"
install -Dm0644 "$M1N1/m1n1.conf.example"           "$stage/etc/m1n1.conf"
install -Dm0644 "$M1N1/udev/80-m1n1.rules"          "$stage/usr/lib/udev/rules.d/80-m1n1.rules"
install -Dm0644 "$M1N1/LICENSE.GPL2"                "$stage/usr/share/doc/gravity-bootloader/LICENSE.GPL2"
install -Dm0644 "$M1N1/LICENSE.MIT"                 "$stage/usr/share/doc/gravity-bootloader/LICENSE.MIT"
cp -r "$M1N1/3rdparty_licenses"                     "$stage/usr/share/doc/gravity-bootloader/"
for f in LICENSE README.md TRADEMARKS.md; do
    [[ -f "$SRC/artwork/$f" ]] && install -Dm0644 "$SRC/artwork/$f" "$stage/usr/share/doc/gravity-bootloader/artwork/$f"
done
# Same path as the Fedora package, for tools that hard-code it.
mkdir -p "$stage/usr/lib64/m1n1"
ln -s ../../lib/gravity-boot/m1n1.bin "$stage/usr/lib64/m1n1/m1n1.bin"

mkdir -p "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<EOF
Package: gravity-bootloader
Version: $VERSION
Architecture: arm64
Maintainer: Gravity Ubuntu builders <noreply@gravitylinux.org>
Section: admin
Priority: optional
Recommends: gravity-ubuntu-platform
Homepage: https://github.com/GravityLinux/bootloader
Description: m1n1 bootloader for the Apple M4 Mac mini (Gravity Linux fork)
 m1n1 bridges the Apple (XNU) boot chain to the Linux boot chain. This is
 Gravity Linux's M4 fork (source ${BOOTLOADER_REF:0:12}). update-m1n1 combines
 stage 2 with the device trees and U-Boot into the ESP's m1n1/boot.bin.
EOF
cat >"$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -x /usr/sbin/update-m1n1 ]; then
    /usr/sbin/update-m1n1 || echo "gravity-bootloader: update-m1n1 failed; run it manually" >&2
fi
EOF
chmod 0755 "$stage/DEBIAN/postinst"
make_deb "$stage"
