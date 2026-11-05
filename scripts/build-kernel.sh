#!/bin/bash
# Build Gravity's M4 kernel as Ubuntu .deb packages (linux-image, linux-headers).
#
# Steps:
#   1. Take the Asahi Fedora 16K config that Gravity uses as its base, from the
#      pinned SRPM (or from KERNEL_BASE_CONFIG=/path/to/config).
#   2. Apply Gravity's fragments, then kernel/ubuntu.config.
#   3. Apply Gravity's arm64 symbol-export patches, which the modular DRM driver needs.
#   4. make bindeb-pkg.
#
# Environment: KERNEL_BASE_CONFIG, KERNEL_CONFIG_ONLY=1 (stop after the
# config step), JOBS.
. "$(dirname "$0")/lib.sh"
need make gcc bc bison flex python3 rsync dpkg-deb

"$TOP/scripts/fetch-sources.sh" linux
PKG="$SRC/gravity-packages"
LINUX="$SRC/linux"
BUILD="$WORK/build/kernel"
mkdir -p "$BUILD" "$DEBS"

# -------------------------------------------------------------- base config
base_config="${KERNEL_BASE_CONFIG:-}"
if [[ -z "$base_config" ]]; then
    srpm="$SRC/dl/$(basename "$KERNEL_BASE_SRPM_URL")"
    if fetch_file "$KERNEL_BASE_SRPM_URL" "$KERNEL_BASE_SRPM_SHA256" "$srpm"; then
        need bsdtar
        base_config="$BUILD/$KERNEL_BASE_CONFIG_NAME"
        bsdtar -xOf "$srpm" "$KERNEL_BASE_CONFIG_NAME" >"$base_config"
    else
        warn "Gravity's base SRPM is unavailable; using Asahi Linux's pinned 16K config instead"
        base_config="$SRC/dl/asahi-linux-16k.config"
        fetch_file "$KERNEL_FALLBACK_CONFIG_URL" "$KERNEL_FALLBACK_CONFIG_SHA256" "$base_config" ||
            die "no base config could be downloaded; pass KERNEL_BASE_CONFIG=/path/to/$KERNEL_BASE_CONFIG_NAME"
    fi
fi
[[ -s "$base_config" ]] || die "base config $base_config is empty"

# ------------------------------------------------------------------ patches
log "Applying Gravity kernel patches"
for p in "$PKG"/kernel/0*.patch; do
    apply_patch "$LINUX" "$p"
done

# ------------------------------------------------------------------- config
export ARCH=arm64
CROSS_COMPILE="$(cross_prefix)"
export CROSS_COMPILE
[[ -z "$CROSS_COMPILE" ]] || need "${CROSS_COMPILE}gcc"
make_k() { make -C "$LINUX" O="$BUILD/obj" -j"$JOBS" "$@"; }

log "Generating kernel config"
mkdir -p "$BUILD/obj"
python3 "$TOP/kernel/overlay-config.py" "$base_config" "$BUILD/obj/.config" \
    "$PKG/kernel/gravity-aarch64.config" \
    "$PKG/kernel/gravity.config" \
    "$PKG/kernel/gravity-trim.config" \
    "$TOP/kernel/ubuntu.config"
make_k olddefconfig >/dev/null

missing=0
while read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! grep -qxF "$line" "$BUILD/obj/.config"; then
        warn "kernel config lacks: $line (got: $(grep -E "^(# )?${line%%=*}[= ]" "$BUILD/obj/.config" || echo unset))"
        missing=1
    fi
done <"$TOP/kernel/required.config"
if ((missing)); then
    # CONFIG_RUST is quietly turned off when rustc/bindgen are missing or too old.
    make_k rustavailable || true
    die "kernel config is missing required M4 options"
fi
# Report fragment settings that Kconfig dropped because of unmet dependencies.
python3 "$TOP/kernel/overlay-config.py" /dev/null "$BUILD/wanted.config" \
    "$PKG/kernel/gravity-aarch64.config" "$PKG/kernel/gravity.config" \
    "$PKG/kernel/gravity-trim.config" "$TOP/kernel/ubuntu.config"
while read -r line; do
    case "$line" in
        CONFIG_*)
            grep -qxF "$line" "$BUILD/obj/.config" || warn "Kconfig did not keep: $line" ;;
        "# CONFIG_"*" is not set")
            # Options hidden by their dependencies are already off; that is fine.
            key="${line#\# }"; key="${key%% *}"
            if grep -q "^$key=" "$BUILD/obj/.config"; then warn "Kconfig re-enabled: $key"; fi ;;
    esac
done <"$BUILD/wanted.config"
mkdir -p "$OUT"
cp "$BUILD/obj/.config" "$OUT/kernel-${LINUX_VERSION}${KERNEL_LOCALVERSION}.config"
[[ "${KERNEL_CONFIG_ONLY:-0}" == 1 ]] && { log "Config written to $OUT"; exit 0; }

# -------------------------------------------------------------------- build
log "Building kernel packages (this takes a while)"
make_k \
    LOCALVERSION="$KERNEL_LOCALVERSION" \
    KDEB_PKGVERSION="${LINUX_VERSION}-${KERNEL_DEB_REVISION}" \
    KDEB_SOURCENAME="linux-gravity" \
    KDEB_COMPRESS=xz \
    KBUILD_BUILD_USER=gravity-ubuntu KBUILD_BUILD_HOST=builder \
    DPKG_FLAGS="-d" \
    bindeb-pkg

# bindeb-pkg writes the packages next to the build tree.
shopt -s nullglob
debs=("$BUILD"/*.deb)
((${#debs[@]})) || die "bindeb-pkg produced no packages"
mv "${debs[@]}" "$DEBS/"
rm -f "$BUILD"/*.buildinfo "$BUILD"/*.changes

# linux-libc-dev from this tree would replace Ubuntu's; it is never installed.
log "Kernel packages:"
ls -1 "$DEBS"/linux-*"${LINUX_VERSION}${KERNEL_LOCALVERSION}"* "$DEBS"/linux-libc-dev_* 2>/dev/null >&2 || true
