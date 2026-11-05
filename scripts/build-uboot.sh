#!/bin/bash
# Build U-Boot (apple_m1 board) with Gravity's full patch stack, packaged as
# u-boot-gravity-apple.
#
# The patches are applied in the order of the Patch: tags in
# GravityLinux/packages uboot-tools.spec, just as %autosetup -p1 would apply them.
. "$(dirname "$0")/lib.sh"
need make gcc bison flex python3 dpkg-deb

"$TOP/scripts/fetch-sources.sh" uboot
PKG="$SRC/gravity-packages/uboot-tools"
UBOOT="$SRC/u-boot"
VERSION="${UBOOT_VERSION}-${UBOOT_DEB_REVISION}"

log "Applying the U-Boot patch stack from uboot-tools.spec"
# "Patch123: https://.../commit/abc.patch#/asahi-abc.patch" -> asahi-abc.patch
mapfile -t patches < <(
    grep -E '^Patch[0-9]+:' "$PKG/uboot-tools.spec" |
    sed -E 's/^Patch([0-9]+):[[:space:]]*/\1 /' | sort -n -k1,1 |
    awk '{ n = split($2, a, "/"); print a[n] }'
)
((${#patches[@]} > 0)) || die "no patches found in uboot-tools.spec"
for p in "${patches[@]}"; do
    [[ -f "$PKG/$p" ]] || die "patch listed in the spec is missing: $p"
    apply_patch "$UBOOT" "$PKG/$p"
done

out="$WORK/build/u-boot"
rm -rf "$out"
mkdir -p "$out"
log "Building U-Boot apple_m1"
make -C "$UBOOT" O="$out" CROSS_COMPILE="$(cross_prefix)" apple_m1_defconfig
make -C "$UBOOT" O="$out" CROSS_COMPILE="$(cross_prefix)" -j"$JOBS"
[[ -s "$out/u-boot-nodtb.bin" ]] || die "u-boot-nodtb.bin was not built"

stage="$WORK/build/deb/u-boot-gravity-apple"
rm -rf "$stage"
install -Dm0644 "$out/u-boot-nodtb.bin" "$stage/usr/lib/gravity-boot/u-boot-nodtb.bin"
install -Dm0644 "$UBOOT/Licenses/gpl-2.0.txt" "$stage/usr/share/doc/u-boot-gravity-apple/gpl-2.0.txt"
# Same path as Fedora's uboot-images-armv8.
mkdir -p "$stage/usr/share/uboot/apple_m1"
ln -s ../../../lib/gravity-boot/u-boot-nodtb.bin "$stage/usr/share/uboot/apple_m1/u-boot-nodtb.bin"
mkdir -p "$stage/DEBIAN"
cat >"$stage/DEBIAN/control" <<EOF
Package: u-boot-gravity-apple
Version: $VERSION
Architecture: arm64
Maintainer: Gravity Ubuntu builders <noreply@gravitylinux.org>
Section: admin
Priority: optional
Recommends: gravity-ubuntu-platform
Homepage: https://github.com/GravityLinux/packages/tree/main/uboot-tools
Description: U-Boot for Apple silicon, with Gravity Linux's M4 patches
 U-Boot ${UBOOT_VERSION} for the apple_m1 board, with the Asahi and Gravity patch
 stack. It provides the UEFI environment that GRUB runs in. m1n1 loads it
 from the ESP's m1n1/boot.bin.
EOF
cat >"$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -x /usr/sbin/update-m1n1 ]; then
    /usr/sbin/update-m1n1 || echo "u-boot-gravity-apple: update-m1n1 failed; run it manually" >&2
fi
EOF
chmod 0755 "$stage/DEBIAN/postinst"
make_deb "$stage"
