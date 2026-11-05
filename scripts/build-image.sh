#!/bin/bash
# Build an Ubuntu image for the M4 Mac mini from the packages in out/debs.
#
#   FLAVOR=ubuntu|kubuntu|server scripts/build-image.sh
#
# Output, in out/image-$FLAVOR/:
#   esp/      contents of the EFI system partition (m1n1/boot.bin, GRUB, shim)
#   boot.img  ext4 /boot partition image
#   root.img  ext4 root partition image (the installer grows the partition,
#             and x-systemd.growfs grows the filesystem on first boot)
#   image.json  UUIDs and sizes, read by package-installer.sh
#
# Needs root (mmdebstrap and chroot). On x86_64 it also needs qemu-user binfmt
# support for aarch64. No loop devices or privileged mounts are used.
. "$(dirname "$0")/lib.sh"
need mmdebstrap mke2fs resize2fs e2fsck dumpe2fs dpkg-scanpackages apt-ftparchive uuidgen python3

FLAVOR="${FLAVOR:-ubuntu}"
case "$FLAVOR" in ubuntu|kubuntu|server) ;; *) die "FLAVOR must be ubuntu, kubuntu or server" ;; esac
[[ $EUID == 0 ]] || die "run as root (mmdebstrap/chroot)"
if ! is_native_arm64; then
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] ||
        die "aarch64 binfmt is not registered (install qemu-user-binfmt)"
fi

IMG="$WORK/image-$FLAVOR"
DEST="$OUT/image-$FLAVOR"
ROOT="$IMG/rootfs"
REPO="$IMG/repo"
rm -rf "$IMG" "$DEST"
mkdir -p "$REPO" "$DEST"

# ----------------------------------------------------- local package repo
shopt -s nullglob
required=(gravity-ubuntu-platform gravity-firmware-tools gravity-bootloader u-boot-gravity-apple linux-image-gravity-16k)
for p in "${required[@]}"; do
    debs=("$DEBS/${p}_"*.deb)
    ((${#debs[@]})) || die "missing $p in $DEBS (run make debs first)"
done
kimages=("$DEBS"/linux-image-[0-9]*gravity*_*.deb)
((${#kimages[@]})) || die "no Gravity kernel package in $DEBS (run make kernel)"
mesa=("$DEBS"/libgl1-mesa-dri_*.deb)
((${#mesa[@]})) || warn "no Gravity Mesa packages in $DEBS: Ubuntu's Mesa will be used, which may not support the M4 GPU"

log "Creating the build repository"
for f in "$DEBS"/*.deb; do
    case "$(basename "$f")" in
        linux-libc-dev_*|*-dbg_*|*-dbgsym_*) continue ;;  # never installed
    esac
    ln -f "$f" "$REPO/" 2>/dev/null || cp "$f" "$REPO/"
done
(cd "$REPO" && dpkg-scanpackages --multiversion . /dev/null >Packages 2>/dev/null && gzip -9k Packages)
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Gravity Ubuntu" \
    -o APT::FTPArchive::Release::Label="Gravity Ubuntu" \
    -o APT::FTPArchive::Release::Suite="$UBUNTU_SUITE" \
    -o APT::FTPArchive::Release::Codename="$UBUNTU_SUITE" \
    release "$REPO" >"$REPO/Release"

# ---------------------------------------------------- filesystem identities
BOOT_UUID="$(uuidgen)"
ROOT_UUID="$(uuidgen)"
# The installer formats the ESP itself, with this FAT volume ID.
esp_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
ESP_VOLUME_ID="0x$esp_id"
ESP_FSUUID="$(echo "$esp_id" | tr 'a-f' 'A-F' | sed -E 's/^(....)(....)$/\1-\2/')"

cat >"$IMG/gravity-image.env" <<EOF
FLAVOR=$FLAVOR
BOOT_UUID=$BOOT_UUID
ROOT_UUID=$ROOT_UUID
ESP_FSUUID=$ESP_FSUUID
GRAVITY_APT_URL=${GRAVITY_APT_URL:-}
UBUNTU_SUITE=$UBUNTU_SUITE
UBUNTU_RELEASE=$UBUNTU_RELEASE
UBUNTU_MIRROR=$UBUNTU_MIRROR
UBUNTU_COMPONENTS="$UBUNTU_COMPONENTS"
EOF

# -------------------------------------------------------------- rootfs
log "Bootstrapping Ubuntu $UBUNTU_RELEASE ($UBUNTU_SUITE, $FLAVOR) for arm64"
mmdebstrap \
    --mode=root --architectures=arm64 --variant=minbase \
    --components="${UBUNTU_COMPONENTS// /,}" \
    --include=ubuntu-minimal,ubuntu-standard,ca-certificates \
    --customize-hook="mkdir -p \"\$1/var/cache/gravity-repo\"" \
    --customize-hook="sync-in $REPO /var/cache/gravity-repo" \
    --customize-hook="copy-in $IMG/gravity-image.env /" \
    --customize-hook="copy-in $TOP/image/configure.sh /tmp" \
    --customize-hook="chroot \"\$1\" /bin/bash /tmp/configure.sh" \
    --customize-hook="rm -f \"\$1/tmp/configure.sh\"" \
    "$UBUNTU_SUITE" "$ROOT" \
    "deb $UBUNTU_MIRROR $UBUNTU_SUITE $UBUNTU_COMPONENTS" \
    "deb $UBUNTU_MIRROR $UBUNTU_SUITE-updates $UBUNTU_COMPONENTS" \
    "deb $UBUNTU_MIRROR $UBUNTU_SUITE-security $UBUNTU_COMPONENTS"

[[ -s "$ROOT/boot/efi/m1n1/boot.bin" ]] || die "boot.bin was not generated"

# ----------------------------------------------------- split partitions
log "Splitting ESP, /boot and / trees"
mkdir -p "$IMG/boot" "$DEST/esp"
cp -a "$ROOT/boot/efi/." "$DEST/esp/"
rm -rf "${ROOT:?}/boot/efi"
cp -a "$ROOT/boot/." "$IMG/boot/"
find "$ROOT/boot" -mindepth 1 -delete
mkdir -p "$IMG/boot/efi"      # /boot/efi mount point lives on the boot fs

# mkfs_tree DIR IMAGE LABEL UUID: an ext4 image shrunk to its minimum size
# plus HEADROOM_MB, with a size that is a multiple of 4 KiB.
mkfs_tree() {
    local dir=$1 img=$2 label=$3 uuid=$4 headroom_mb=$5 min_mb=${6:-0}
    local used_mb
    used_mb=$(( $(du -s --block-size=1M "$dir" | cut -f1) ))
    local size_mb=$(( used_mb * 13 / 10 + 256 ))
    rm -f "$img"
    mke2fs -q -t ext4 -b 4096 -L "$label" -U "$uuid" -E root_owner=0:0 -d "$dir" "$img" "${size_mb}M"
    e2fsck -fy "$img" >/dev/null || [[ $? -le 1 ]]
    resize2fs -M "$img" >/dev/null 2>&1
    local blocks
    blocks=$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/^Block count/ { gsub(/ /, "", $2); print $2 }')
    local target=$(( blocks * 4096 + headroom_mb * 1024 * 1024 ))
    (( target >= min_mb * 1024 * 1024 )) || target=$(( min_mb * 1024 * 1024 ))
    truncate -s "$target" "$img"
    resize2fs "$img" >/dev/null 2>&1
    e2fsck -fy "$img" >/dev/null || [[ $? -le 1 ]]
    (( $(stat -c %s "$img") % 4096 == 0 )) || die "$img size is not a multiple of 4 KiB"
}

log "Creating boot.img"
mkfs_tree "$IMG/boot" "$DEST/boot.img" ubuntu-boot "$BOOT_UUID" 0 1024
log "Creating root.img"
mkfs_tree "$ROOT" "$DEST/root.img" ubuntu-root "$ROOT_UUID" 512

kver="$(ls "$IMG/boot" | sed -n 's/^vmlinuz-//p' | sort -V | tail -1)"
python3 - "$DEST/image.json" <<EOF
import json, os, sys
dest = os.path.dirname(sys.argv[1])
json.dump({
    "flavor": "$FLAVOR",
    "ubuntu_release": "$UBUNTU_RELEASE",
    "ubuntu_suite": "$UBUNTU_SUITE",
    "kernel": "$kver",
    "boot_uuid": "$BOOT_UUID",
    "root_uuid": "$ROOT_UUID",
    "esp_volume_id": "$ESP_VOLUME_ID",
    "esp_fsuuid": "$ESP_FSUUID",
    "boot_size": os.path.getsize(os.path.join(dest, "boot.img")),
    "root_size": os.path.getsize(os.path.join(dest, "root.img")),
    "linux_ref": "$LINUX_REF",
    "mesa_ref": "$MESA_REF",
    "bootloader_ref": "$BOOTLOADER_REF",
}, open(sys.argv[1], "w"), indent=2)
EOF
log "Image ready in $DEST"
cat "$DEST/image.json" >&2
