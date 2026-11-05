#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs once on the Mac. Installs GRUB onto the ESP (no EFI NVRAM changes) so
# that later grub package upgrades keep it updated, and regenerates grub.cfg.
# The image ships a hand-written grub.cfg because grub-mkconfig cannot probe
# devices in the build chroot.
set -e
if mountpoint -q /boot/efi; then
    grub-install --target=arm64-efi --efi-directory=/boot/efi \
        --uefi-secure-boot --force-extra-removable --no-nvram --bootloader-id=ubuntu
fi
update-grub
systemctl disable gravity-firstboot-grub.service
