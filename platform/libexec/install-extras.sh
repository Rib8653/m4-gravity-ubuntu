#!/bin/sh
# SPDX-License-Identifier: MIT
# Install extra .deb packages that the installer placed on the ESP
# (/boot/efi/gravity/extras), without network access.
set -e
dpkg -i /boot/efi/gravity/extras/*.deb
systemctl disable gravity-extras-firstboot.service
