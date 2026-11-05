#!/bin/bash
# Build the architecture-independent Gravity-on-Ubuntu packages:
#
#   gravity-ubuntu-platform  update-m1n1, gravity-fwupdate, gravity-diagnose,
#                            Gravity's dracut modules (Ubuntu's default) and
#                            equivalent initramfs-tools hooks, kernel hooks, GRUB defaults,
#                            first-boot swap/extras, hwdb (replaces Fedora's
#                            gravity-scripts, dracut-gravity, update-m1n1,
#                            linux-firmware-vendor and gravity-remix-scripts)
#   gravity-firmware-tools   python3 gravity_firmware + gravity-fwextract
#   gravity-sleep-policy     Gravity's temporary "no suspend on M4" policy
#   alsa-ucm-conf-asahi      Asahi ALSA UCM profiles (Fedora: alsa-ucm-asahi)
#   linux-image-gravity-16k  metapackage that follows the current Gravity kernel
. "$(dirname "$0")/lib.sh"
need make dpkg-deb python3

"$TOP/scripts/fetch-sources.sh" scripts installer ucm
PKG="$SRC/gravity-packages"
P="$TOP/platform"
STAGE="$WORK/build/deb"
MAINT="Gravity Ubuntu builders <noreply@gravitylinux.org>"
mkdir -p "$STAGE"

control() { # control DIR NAME ARCH [extra lines...]
    local dir=$1 name=$2 arch=$3
    shift 3
    mkdir -p "$dir/DEBIAN"
    {
        echo "Package: $name"
        echo "Version: $PLATFORM_VERSION"
        echo "Architecture: $arch"
        echo "Maintainer: $MAINT"
        printf '%s\n' "$@"
    } >"$dir/DEBIAN/control"
}

# ------------------------------------------------------ gravity-ubuntu-platform
s="$STAGE/gravity-ubuntu-platform"
rm -rf "$s"
make -C "$SRC/scripts" clean >/dev/null
# Gravity's dracut modules are used as they are: Ubuntu 26.04 defaults to dracut.
make -C "$SRC/scripts" DESTDIR="$s" PREFIX=/usr BIN_DIR=/usr/sbin CONFIG_DIR=/etc/default \
    install install-dracut install-udev-hwdb >/dev/null
install -Dm0644 "$P/default/update-m1n1"            "$s/etc/default/update-m1n1"
install -Dm0755 "$P/sbin/gravity-update-boot"       "$s/usr/sbin/gravity-update-boot"
install -Dm0755 "$P/kernel/zz-update-m1n1"          "$s/etc/kernel/postinst.d/zz-update-m1n1"
install -Dm0755 "$P/kernel/zz-update-m1n1"          "$s/etc/kernel/postrm.d/zz-update-m1n1"
install -Dm0755 "$P/initramfs-tools/hooks/gravity"  "$s/usr/share/initramfs-tools/hooks/gravity"
install -Dm0755 "$P/initramfs-tools/scripts/init-top/gravity-firmware" \
                "$s/usr/share/initramfs-tools/scripts/init-top/gravity-firmware"
install -Dm0755 "$P/initramfs-tools/scripts/init-bottom/gravity-firmware" \
                "$s/usr/share/initramfs-tools/scripts/init-bottom/gravity-firmware"
install -Dm0644 "$P/grub/90-gravity.cfg"            "$s/etc/default/grub.d/90-gravity.cfg"
for f in "$P"/libexec/*.sh; do
    install -Dm0755 "$f" "$s/usr/libexec/gravity-ubuntu/$(basename "$f")"
done
install -Dm0644 "$PKG/gravity-remix-scripts/gravity-enable-zswap.conf" \
                "$s/usr/share/gravity-ubuntu/gravity-enable-zswap.conf"
# The image builder enables the first-boot units that suit each flavour.
for u in "$P"/systemd/*.service; do
    install -Dm0644 "$u" "$s/usr/lib/systemd/system/$(basename "$u")"
done
install -Dm0644 "$SRC/scripts/LICENSE" "$s/usr/share/doc/gravity-ubuntu-platform/LICENSE"
install -d "$s/usr/lib/firmware/vendor"
control "$s" gravity-ubuntu-platform all \
    "Section: admin" "Priority: optional" \
    "Depends: dracut | initramfs-tools, bash, passwd, cpio, util-linux, kmod, linux-base, gzip, python3, gravity-firmware-tools (= $PLATFORM_VERSION), gravity-bootloader, u-boot-gravity-apple, grub-efi-arm64 | grub-efi-arm64-signed" \
    "Recommends: gravity-sleep-policy, alsa-ucm-conf-asahi, linux-image-gravity-16k" \
    "Conflicts: flash-kernel" \
    "Homepage: https://github.com/GravityLinux/scripts" \
    "Description: Apple M4 Mac mini integration for Ubuntu (Gravity Linux port)" \
    " Boot and firmware glue for running Ubuntu on the M4 Mac mini with Gravity" \
    " Linux's kernel and bootloader: update-m1n1, vendor firmware updates," \
    " initramfs-tools hooks, kernel hooks and first-boot setup."
cat >"$s/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    if [ -d /run/systemd/system ] || [ -n "$GRAVITY_IMAGE_BUILD" ]; then
        systemctl enable gravity-setup-swap-firstboot.service gravity-extras-firstboot.service >/dev/null 2>&1 || true
    fi
    command -v systemd-hwdb >/dev/null && systemd-hwdb update >/dev/null 2>&1 || true
    if [ -z "$GRAVITY_IMAGE_BUILD" ]; then
        if command -v update-initramfs >/dev/null; then
            update-initramfs -u -k all >/dev/null 2>&1 || true
        elif command -v dracut >/dev/null; then
            dracut --force --regenerate-all >/dev/null 2>&1 || true
        fi
        /usr/sbin/gravity-update-boot || true
    fi
fi
EOF
cat >"$s/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ]; then
    systemctl disable gravity-setup-swap-firstboot.service gravity-extras-firstboot.service >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$s/DEBIAN/postinst" "$s/DEBIAN/prerm"
make_deb "$s"

# ------------------------------------------------------- gravity-firmware-tools
s="$STAGE/gravity-firmware-tools"
rm -rf "$s"
pydir="$s/usr/lib/python3/dist-packages/gravity_firmware"
install -d "$pydir"
git -C "$SRC/installer" archive HEAD gravity_firmware | tar -x -C "$s/usr/lib/python3/dist-packages"
rm -rf "$pydir/__pycache__"
install -d "$s/usr/bin"
cat >"$s/usr/bin/gravity-fwextract" <<'EOF'
#!/usr/bin/python3
import sys
from gravity_firmware.update import main
sys.exit(main())
EOF
chmod 0755 "$s/usr/bin/gravity-fwextract"
install -Dm0644 "$SRC/installer/LICENSE" "$s/usr/share/doc/gravity-firmware-tools/LICENSE"
control "$s" gravity-firmware-tools all \
    "Section: admin" "Priority: optional" \
    "Depends: python3" \
    "Homepage: https://github.com/GravityLinux/installer" \
    "Description: Apple vendor firmware extraction tools (Gravity Linux)" \
    " Rebuilds the vendor firmware package (Wi-Fi, Bluetooth, ...) on the ESP" \
    " from the firmware archive that the Gravity installer collected from macOS."
cat >"$s/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -z "$GRAVITY_IMAGE_BUILD" ] && [ -x /usr/sbin/gravity-fwupdate ]; then
    /usr/sbin/gravity-fwupdate || echo "gravity-firmware-tools: gravity-fwupdate failed; run it manually" >&2
fi
EOF
chmod 0755 "$s/DEBIAN/postinst"
make_deb "$s"

# --------------------------------------------------------- gravity-sleep-policy
s="$STAGE/gravity-sleep-policy"
rm -rf "$s"
r="$PKG/gravity-remix-scripts"
install -Dm0644 "$r/90-gravity-no-sleep.conf"        "$s/usr/lib/systemd/sleep.conf.d/90-gravity-no-sleep.conf"
install -Dm0644 "$r/90-gravity-no-sleep-logind.conf" "$s/usr/lib/systemd/logind.conf.d/90-gravity-no-sleep.conf"
for unit in suspend hibernate hybrid-sleep suspend-then-hibernate; do
    install -Dm0644 "$r/90-gravity-block-sleep-service.conf" \
        "$s/usr/lib/systemd/system/systemd-$unit.service.d/90-gravity-no-sleep.conf"
done
install -Dm0644 "$r/SLEEP-POLICY.md" "$s/usr/share/doc/gravity-sleep-policy/SLEEP-POLICY.md"
control "$s" gravity-sleep-policy all \
    "Section: admin" "Priority: optional" \
    "Depends: systemd" \
    "Description: Temporary policy that disables system sleep on the M4 Mac mini" \
    " Suspend and hibernation do not work on the M4 yet. This package turns them" \
    " off and makes logind ignore sleep keys and idle sleep. Remove it once sleep" \
    " is supported."
cat >"$s/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
[ -d /run/systemd/system ] && systemctl daemon-reload || true
EOF
cp "$s/DEBIAN/postinst" "$s/DEBIAN/postrm"
chmod 0755 "$s/DEBIAN/postinst" "$s/DEBIAN/postrm"
make_deb "$s"

# ----------------------------------------------------------- alsa-ucm-conf-asahi
s="$STAGE/alsa-ucm-conf-asahi"
rm -rf "$s"
install -d "$s/usr/share/alsa"
cp -r "$SRC/alsa-ucm-conf-asahi/ucm2" "$s/usr/share/alsa/"
install -d "$s/usr/share/doc/alsa-ucm-conf-asahi"
find "$SRC/alsa-ucm-conf-asahi" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'README*' \) \
    -exec install -m0644 -t "$s/usr/share/doc/alsa-ucm-conf-asahi/" {} +
control "$s" alsa-ucm-conf-asahi all \
    "Section: sound" "Priority: optional" \
    "Depends: alsa-ucm-conf" \
    "Homepage: https://github.com/AsahiLinux/alsa-ucm-conf-asahi" \
    "Description: ALSA Use Case Manager profiles for Apple silicon Macs" \
    " UCM profiles for Apple silicon audio devices. The M4 Mac mini speaker is" \
    " protected by the kernel driver, so no userspace DSP daemon is needed."
sed -i "s/^Version: .*/Version: $ALSA_UCM_ASAHI_VERSION/" "$s/DEBIAN/control"
make_deb "$s"

# ------------------------------------------------------- linux-image-gravity-16k
krel="${LINUX_VERSION}${KERNEL_LOCALVERSION}"
s="$STAGE/linux-image-gravity-16k"
rm -rf "$s"
install -d "$s/usr/share/doc/linux-image-gravity-16k"
echo "Metapackage for the Gravity Linux M4 kernel." >"$s/usr/share/doc/linux-image-gravity-16k/README"
control "$s" linux-image-gravity-16k arm64 \
    "Section: kernel" "Priority: optional" \
    "Depends: linux-image-$krel (>= ${LINUX_VERSION}-${KERNEL_DEB_REVISION}), gravity-ubuntu-platform" \
    "Recommends: linux-headers-$krel" \
    "Description: Gravity Linux kernel for the Apple M4 Mac mini (metapackage)" \
    " Always depends on the current Gravity 16K-page kernel ($krel)."
sed -i "s/^Version: .*/Version: ${LINUX_VERSION}-${KERNEL_DEB_REVISION}/" "$s/DEBIAN/control"
make_deb "$s"

log "Platform packages are in $DEBS"
