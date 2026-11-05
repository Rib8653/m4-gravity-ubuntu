#!/bin/bash
# Fetch every pinned source input into work/src.
#   fetch-sources.sh [all|packages|linux|mesa|bootloader|uboot|scripts|installer|ucm]
. "$(dirname "$0")/lib.sh"
need git curl sha256sum

want() { [[ " ${TARGETS[*]} " == *" all "* || " ${TARGETS[*]} " == *" $1 "* ]]; }
TARGETS=("${@:-all}")
mkdir -p "$SRC"

# The packaging repo is needed by almost every build, so always fetch it.
fetch_git "$GRAVITY_PACKAGES_URL" "$GRAVITY_PACKAGES_REF" "$SRC/gravity-packages"

want linux      && fetch_git "$LINUX_URL" "$LINUX_REF" "$SRC/linux"
want mesa       && fetch_git "$MESA_URL" "$MESA_REF" "$SRC/mesa"
if want bootloader; then
    fetch_git "$BOOTLOADER_URL" "$BOOTLOADER_REF" "$SRC/bootloader"
    fetch_git "$ARTWORK_URL" "$ARTWORK_REF" "$SRC/artwork"
fi
want scripts    && fetch_git "$SCRIPTS_URL" "$SCRIPTS_REF" "$SRC/scripts"
want installer  && fetch_git "$INSTALLER_URL" "$INSTALLER_REF" "$SRC/installer"
want ucm        && fetch_git "$ALSA_UCM_ASAHI_URL" "$ALSA_UCM_ASAHI_REF" "$SRC/alsa-ucm-conf-asahi"

if want uboot; then
    tarball="$SRC/dl/u-boot-$UBOOT_VERSION.tar.bz2"
    if fetch_file "$UBOOT_TARBALL_URL" "$UBOOT_TARBALL_SHA256" "$tarball"; then
        if [[ ! -f "$SRC/u-boot/.from-tarball" ]]; then
            rm -rf "$SRC/u-boot"
            mkdir -p "$SRC/u-boot"
            tar -xjf "$tarball" -C "$SRC/u-boot" --strip-components=1
            touch "$SRC/u-boot/.from-tarball"
        fi
    else
        warn "U-Boot tarball unavailable; falling back to the git tag $UBOOT_GIT_REF"
        fetch_git "$UBOOT_GIT_URL" "$UBOOT_GIT_REF" "$SRC/u-boot"
    fi
fi

log "Sources are in $SRC"
