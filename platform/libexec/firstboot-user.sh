#!/bin/bash
# SPDX-License-Identifier: MIT
# Console first-boot account setup, for flavours with no graphical first-boot
# wizard (Kubuntu, server). Ubuntu's GNOME flavour uses gnome-initial-setup instead.
set -u

if getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { found=1 } END { exit !found }'; then
    systemctl disable gravity-firstboot-user.service
    exit 0
fi

clear
cat <<'BANNER'

  Welcome to Ubuntu on the Apple M4 Mac mini (Gravity Linux port)

  Create the first user account. It gets administrator (sudo) rights.

BANNER

while :; do
    read -r -p "  Full name: " fullname
    read -r -p "  Username: " username
    if [[ ! "$username" =~ ^[a-z][-a-z0-9_]{0,31}$ ]]; then
        echo "  Use lower-case letters, digits, '-' or '_', starting with a letter."
        continue
    fi
    if getent passwd "$username" >/dev/null; then
        echo "  That name is already taken."
        continue
    fi
    break
done

useradd -m -s /bin/bash -c "$fullname" -G sudo,adm,audio,video,plugdev,netdev,render,lpadmin "$username" 2>/dev/null ||
    useradd -m -s /bin/bash -c "$fullname" -G sudo "$username"
until passwd "$username"; do
    echo "  Try again."
done

read -r -p "  Hostname [ubuntu-m4]: " host
host="${host:-ubuntu-m4}"
if [[ "$host" =~ ^[A-Za-z0-9][-A-Za-z0-9]{0,62}$ ]]; then
    hostnamectl set-hostname "$host" 2>/dev/null || echo "$host" >/etc/hostname
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$host/" /etc/hosts
fi

systemctl disable gravity-firstboot-user.service
echo
echo "  Done. Starting the system..."
sleep 2
