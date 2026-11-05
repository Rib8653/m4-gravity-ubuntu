#!/bin/bash
# Runs inside the arm64 image chroot (mmdebstrap customize hook).
# It reads /gravity-image.env (FLAVOR, BOOT_UUID, ROOT_UUID, ESP_FSUUID,
# GRAVITY_APT_URL, UBUNTU_*) and turns a minimal Ubuntu into an M4 Mac mini image.
set -euxo pipefail
. /gravity-image.env
export DEBIAN_FRONTEND=noninteractive GRAVITY_IMAGE_BUILD=1 LC_ALL=C.UTF-8

# Do not start services inside the chroot.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

# ------------------------------------------------------------------ APT setup
rm -f /etc/apt/sources.list
cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $UBUNTU_MIRROR
Suites: $UBUNTU_SUITE $UBUNTU_SUITE-updates $UBUNTU_SUITE-backports
Components: $UBUNTU_COMPONENTS
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $UBUNTU_MIRROR
Suites: $UBUNTU_SUITE-security
Components: $UBUNTU_COMPONENTS
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
# The packages built from Gravity's sources, used only while building.
echo "deb [trusted=yes] file:/var/cache/gravity-repo ./" >/etc/apt/sources.list.d/gravity-build.list

# Gravity's packages (kernel, Mesa, bootloader) always win over Ubuntu's.
# Ubuntu's generic kernels and flash-kernel must never be installed: they
# would boot without M4 support, and flash-kernel writes /boot/dtb, which
# GRUB would load in place of m1n1's device tree.
cat >/etc/apt/preferences.d/gravity-ubuntu.pref <<'EOF'
Package: *
Pin: release o=Gravity Ubuntu
Pin-Priority: 1001

Package: linux-generic* linux-image-generic* linux-headers-generic* linux-image-*-generic linux-modules-*-generic linux-image-virtual* flash-kernel
Pin: version *
Pin-Priority: -1
EOF

cat >>/var/cache/debconf/gravity.seed <<'EOF'
grub-efi-arm64 grub2/update_nvram boolean false
grub-efi-arm64 grub2/force_efi_extra_removable boolean true
grub-efi-arm64-signed grub2/update_nvram boolean false
EOF
debconf-set-selections /var/cache/debconf/gravity.seed
rm -f /var/cache/debconf/gravity.seed

# update-m1n1 binds /boot/efi when this marker exists, instead of looking for the
# system ESP's PARTUUID in the device tree.
mkdir -p /boot/efi/m1n1
touch /boot/efi/.builder

apt-get update

# --------------------------------------------------------------- packages
case "$FLAVOR" in
    ubuntu)  flavor_pkgs=(ubuntu-desktop-minimal) ;;
    kubuntu) flavor_pkgs=(kubuntu-desktop) ;;
    server)  flavor_pkgs=(ubuntu-server openssh-server) ;;
    *) echo "unknown FLAVOR $FLAVOR" >&2; exit 1 ;;
esac

apt-get install -y --no-install-recommends \
    linux-image-gravity-16k gravity-ubuntu-platform gravity-bootloader u-boot-gravity-apple \
    gravity-firmware-tools gravity-sleep-policy alsa-ucm-conf-asahi \
    grub-efi-arm64 grub-efi-arm64-signed grub-efi-arm64-bin shim-signed \
    dracut zstd e2fsprogs dosfstools locales sudo ca-certificates
apt-get install -y "${flavor_pkgs[@]}" \
    pipewire pipewire-pulse wireplumber network-manager wpasupplicant bluez \
    language-pack-en

# Gravity's Mesa must have replaced Ubuntu's when it was built.
if ls /var/cache/gravity-repo/libgl1-mesa-dri_*.deb >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' libgl1-mesa-dri | grep -q gravity ||
        { echo "Ubuntu's Mesa was installed instead of Gravity's" >&2; exit 1; }
else
    echo "WARNING: no Gravity Mesa packages; Ubuntu's Mesa may not support the M4 GPU" >&2
fi
for pkg in linux-image-generic linux-image-virtual flash-kernel; do
    if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        echo "$pkg must not be installed" >&2
        exit 1
    fi
done

# ------------------------------------------------- initramfs and boot.bin
# Like Gravity's KIWI recipe: a generic (no-hostonly) initramfs, because the
# build machine is not the target Mac. Later kernel updates on the Mac use
# Ubuntu's dracut defaults.
mapfile -t kernels < <(linux-version list)
[[ ${#kernels[@]} -ge 1 ]] || { echo "no kernel installed" >&2; exit 1; }
for v in "${kernels[@]}"; do
    [[ "$v" == *gravity* ]] || { echo "unexpected kernel $v" >&2; exit 1; }
    dracut --force --no-hostonly --kver "$v" "/boot/initrd.img-$v"
done
KVER="$(linux-version list | linux-version sort --reverse | head -1)"
lsinitrd "/boot/initrd.img-$KVER" >/tmp/initrd.list
grep -q 'load-gravity-firmware.sh' /tmp/initrd.list
grep -q 'nvme-apple\|nvme_apple' /tmp/initrd.list
rm -f /tmp/initrd.list

/usr/sbin/gravity-update-boot /boot/efi/m1n1/boot.bin
test -s /boot/efi/m1n1/boot.bin
test -s "/usr/lib/linux-image-$KVER/apple/t8132-j773g.dtb"

# ---------------------------------------------------------------- GRUB
# grub-mkconfig cannot probe devices in a chroot. Install GRUB's signed EFI
# binaries by hand, with the same layout that grub-install --uefi-secure-boot
# --force-extra-removable produces, and write a first grub.cfg. On first boot,
# gravity-firstboot-grub runs the real grub-install --no-nvram and update-grub.
pick() { for f in "$@"; do [[ -e "$f" ]] && { echo "$f"; return; }; done; echo "missing: $*" >&2; exit 1; }
shim="$(pick /usr/lib/shim/shimaa64.efi.signed.latest /usr/lib/shim/shimaa64.efi.signed /usr/lib/shim/shimaa64.efi)"
mm="$(pick /usr/lib/shim/mmaa64.efi.signed /usr/lib/shim/mmaa64.efi)"
grub="$(pick /usr/lib/grub/arm64-efi-signed/grubaa64.efi.signed)"
stub="search.fs_uuid $BOOT_UUID root
set prefix=(\$root)'/grub'
configfile \$prefix/grub.cfg"
for dir in /boot/efi/EFI/ubuntu /boot/efi/EFI/BOOT; do
    mkdir -p "$dir"
    install -m0644 "$grub" "$dir/grubaa64.efi"
    install -m0644 "$mm" "$dir/mmaa64.efi"
    echo "$stub" >"$dir/grub.cfg"
done
install -m0644 "$shim" /boot/efi/EFI/ubuntu/shimaa64.efi
install -m0644 "$shim" /boot/efi/EFI/BOOT/BOOTAA64.EFI
# No fbaa64.efi: shim's fallback would try to write EFI boot entries.

. /etc/default/grub
for f in /etc/default/grub.d/*.cfg; do . "$f"; done
cmdline="root=UUID=$ROOT_UUID ro ${GRUB_CMDLINE_LINUX_DEFAULT:-quiet splash} ${GRUB_CMDLINE_LINUX}"
mkdir -p /boot/grub
{
    echo "# Written by the image build. Replaced by update-grub on first boot."
    echo "set default=0"
    echo "set timeout_style=hidden"
    echo "set timeout=3"
    echo "search --no-floppy --fs-uuid --set=root $BOOT_UUID"
    for v in $(linux-version list | linux-version sort --reverse); do
        echo "menuentry 'Ubuntu $UBUNTU_RELEASE, Gravity kernel $v' --class ubuntu {"
        echo "    linux /vmlinuz-$v $cmdline"
        echo "    initrd /initrd.img-$v"
        echo "}"
    done
} >/boot/grub/grub.cfg

# ---------------------------------------------------------------- fstab
cat >/etc/fstab <<EOF
# <file system>        <mount point> <type> <options>                                   <dump> <pass>
UUID=$ROOT_UUID  /             ext4   defaults,x-systemd.growfs,errors=remount-ro      0      1
UUID=$BOOT_UUID  /boot         ext4   defaults                                         0      2
UUID=$ESP_FSUUID                       /boot/efi     vfat   umask=0077,shortname=winnt                       0      2
EOF

# --------------------------------------------------------- system setup
echo "ubuntu-m4" >/etc/hostname
cat >/etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	ubuntu-m4
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

passwd -l root

systemctl enable gravity-setup-swap-firstboot.service gravity-extras-firstboot.service gravity-firstboot-grub.service
case "$FLAVOR" in
    ubuntu)
        # GDM runs gnome-initial-setup when no user account exists.
        systemctl set-default graphical.target ;;
    kubuntu)
        systemctl enable gravity-firstboot-user.service
        systemctl set-default graphical.target ;;
    server)
        systemctl enable gravity-firstboot-user.service
        systemctl set-default multi-user.target ;;
esac
# ubuntu-desktop-minimal and ubuntu-server pull in cloud-init. A Mac has no
# cloud datasource, so don't wait for one at boot.
if [[ -d /etc/cloud ]]; then touch /etc/cloud/cloud-init.disabled; fi
if [[ -x /usr/sbin/sshd ]]; then
    # Each machine generates its own host keys on first boot.
    rm -f /etc/ssh/ssh_host_*
    mkdir -p /etc/systemd/system/ssh.service.d
    printf '[Service]\nExecStartPre=/usr/bin/ssh-keygen -A\n' >/etc/systemd/system/ssh.service.d/gravity-hostkeys.conf
fi

# Without a hosted Gravity repository, hold the forked packages so that an
# Ubuntu update cannot swap in a Mesa without M4 support.
rm -f /etc/apt/sources.list.d/gravity-build.list
if [[ -n "${GRAVITY_APT_URL:-}" ]]; then
    echo "deb [trusted=yes] $GRAVITY_APT_URL ./" >/etc/apt/sources.list.d/gravity-ubuntu.list
else
    mapfile -t forked < <(dpkg-query -W -f='${Package} ${Version}\n' | awk '$2 ~ /gravity/ { print $1 }')
    if ((${#forked[@]})); then apt-mark hold "${forked[@]}"; fi
fi

# ------------------------------------------------------------- cleanup
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/gravity-repo
echo uninitialized >/etc/machine-id
rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed
rm -f /boot/efi/.builder /usr/sbin/policy-rc.d /gravity-image.env
for f in /boot/dtb /boot/dtb-*; do
    [[ -e "$f" ]] && { echo "$f must not exist (GRUB would load it)" >&2; exit 1; }
done
exit 0
