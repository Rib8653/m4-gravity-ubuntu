#!/bin/sh
# SPDX-License-Identifier: MIT
# First-boot swap setup: a swap file on the root filesystem with zswap in front
# of it. Ubuntu port of Gravity's setup-swap.sh (ext4 root, so no btrfs
# subvolume, no SELinux labels and no zram to turn off).
set -e

size=8G
swapfile=/var/swap/swapfile

if [ "$(id -u)" != 0 ]; then
    echo "Script must be run as root" >&2
    exit 1
fi

if [ "${1:-}" = "--recreate" ]; then
    shift
    swapoff "$swapfile" 2>/dev/null || true
    rm -f "$swapfile"
elif [ -e "$swapfile" ]; then
    echo "$swapfile already exists, use --recreate to recreate it" >&2
    exit 1
fi
[ -n "${1:-}" ] && size="$1"

mkdir -p /var/swap
chmod 0700 /var/swap
free_bytes=$(( $(stat -f --format="%a*%S" /var/swap) ))
size_bytes=$(numfmt --from=iec "$size")
if [ "$free_bytes" -lt $((2 * size_bytes)) ]; then
    echo "Not enough free disk space to allocate $size of swap" >&2
    exit 1
fi

fallocate -l "$size" "$swapfile"
chmod 0600 "$swapfile"
mkswap "$swapfile"
swapon "$swapfile"
grep -q "^$swapfile " /etc/fstab || echo "$swapfile none swap sw 0 0" >> /etc/fstab

ln -sf /usr/share/gravity-ubuntu/gravity-enable-zswap.conf /etc/tmpfiles.d/gravity-enable-zswap.conf
systemd-tmpfiles --create /etc/tmpfiles.d/gravity-enable-zswap.conf || true

systemctl disable gravity-setup-swap-firstboot.service
