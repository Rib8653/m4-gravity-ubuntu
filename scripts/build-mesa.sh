#!/bin/bash
# Build Gravity's Mesa (with the M4 / Apple9 Asahi driver) using Ubuntu's own
# mesa packaging, so the result replaces Ubuntu's Mesa packages one for one.
#
# Ubuntu's debian/rules already enables the asahi Gallium and Vulkan drivers on
# arm64. This script only swaps in Gravity's upstream source and a newer version.
#
# Run this natively on arm64, or in an arm64 container under qemu-user (slow).
# You need deb-src entries for $UBUNTU_SUITE (docker/Dockerfile sets them up).
#
# Ubuntu's packaging targets Mesa 26.0, and Gravity tracks 26.3-devel. If a
# Debian patch no longer applies, it is dropped and named in the log. Missing
# or new install files fail the build in dh_install/dh_missing. Fix those in
# mesa/debian-overrides/ rather than editing the generated tree by hand.
. "$(dirname "$0")/lib.sh"
need apt-get dpkg-buildpackage dch quilt git xz

[[ "$(dpkg --print-architecture)" == arm64 ]] || die "build Mesa on arm64 (native or an arm64 container)"

"$TOP/scripts/fetch-sources.sh" mesa
BUILD="$WORK/build/mesa"
VERSION="${MESA_UPSTREAM_VERSION}-${MESA_DEB_REVISION}"
UPVER="${MESA_UPSTREAM_VERSION}"
# Packaging fixes for Ubuntu's 26.0 packaging on Mesa 26.3, applied to debian/rules
# (idempotent):
# - dh_missing: Mesa 26.3 installs files that Ubuntu's .install lists do not
#   cover (for example new tools). List them in mesa-not-installed.txt instead of failing.
# - dh_makeshlibs -c4 fails when a library exports new symbols, which a newer
#   Mesa does. Report them instead (-c1).
patch_rules() {
    sed -i 's/dh_makeshlibs -a -- -c4/dh_makeshlibs -a -- -c1/' debian/rules
    if ! grep -q '^override_dh_missing:' debian/rules; then
        printf '\noverride_dh_missing:\n\tdh_missing --list-missing 2>&1 | tee ../mesa-not-installed.txt\n' >>debian/rules
    fi
}

finish() {
    mkdir -p "$DEBS"
    mv ../*.deb "$DEBS/"
    [[ -s ../mesa-not-installed.txt ]] && cp ../mesa-not-installed.txt "$OUT/" &&
        warn "some Mesa files were not packaged; see $OUT/mesa-not-installed.txt"
    log "Mesa packages are in $DEBS"
}

# MESA_RESUME=1: reuse the compiled tree from the last run and only redo packaging.
if [[ "${MESA_RESUME:-0}" == 1 && -f "$BUILD/mesa-$UPVER/debian/rules" ]]; then
    cd "$BUILD/mesa-$UPVER"
    patch_rules
    log "Resuming the Mesa packaging in $PWD (no recompile)"
    rm -f ../*.deb
    DEB_BUILD_OPTIONS="nocheck parallel=$JOBS ${DEB_BUILD_OPTIONS:-}" dpkg-buildpackage -b -uc -us -nc
    finish
    exit 0
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# apt-get source needs deb-src entries and fresh package lists (the Docker
# image deletes its lists to save space).
if ! grep -rqsE '^(Types:.*deb-src|deb-src )' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    log "Enabling deb-src package sources"
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
    fi
    if grep -qs '^deb ' /etc/apt/sources.list; then
        sed -n 's/^deb /deb-src /p' /etc/apt/sources.list >/etc/apt/sources.list.d/gravity-deb-src.list
    fi
    grep -rqsE '^(Types:.*deb-src|deb-src )' /etc/apt/sources.list /etc/apt/sources.list.d/ ||
        die "could not enable deb-src entries; add them for $UBUNTU_SUITE by hand"
fi
apt-get update

log "Fetching Ubuntu's mesa packaging ($UBUNTU_SUITE)"
apt-get source --only-source --download-only "mesa/$UBUNTU_SUITE" ||
    apt-get source --only-source --download-only mesa
debtar=$(ls mesa_*.debian.tar.* | head -1)
[[ -n "$debtar" ]] || die "could not download Ubuntu's mesa source package"

log "Creating the orig tarball from Gravity Mesa ${MESA_REF:0:12}"
git -C "$SRC/mesa" archive --format=tar --prefix="mesa-$UPVER/" HEAD | xz -T0 >"mesa_$UPVER.orig.tar.xz"
tar -xf "mesa_$UPVER.orig.tar.xz"
tar -xf "$debtar" -C "mesa-$UPVER"

# Ubuntu's packaging forbids meson downloads (--wrap-mode=nodownload), but
# Mesa 26.3 needs venus-protocol as a subproject. Bundle Gravity's pinned
# snapshot the way its mesa.spec does.
wrap="mesa-$UPVER/subprojects/venus-protocol.wrap"
if [[ -f "$wrap" ]]; then
    grep -qx "revision = $VENUS_PROTOCOL_COMMIT" "$wrap" ||
        die "venus-protocol.wrap no longer matches VENUS_PROTOCOL_COMMIT; update config/sources.env"
    vdir="$(sed -n 's/^directory = //p' "$wrap")"
    # Fetched by commit (verified by fetch_git), like meson's own [wrap-git].
    fetch_git "$(sed -n 's/^url = //p' "$wrap")" "$VENUS_PROTOCOL_COMMIT" "$SRC/venus-protocol"
    mkdir -p "mesa-$UPVER/subprojects/$vdir"
    git -C "$SRC/venus-protocol" archive HEAD | tar -x -C "mesa-$UPVER/subprojects/$vdir"
fi

# provide_wrap_file NAME: unpack a [wrap-file] subproject from its pinned
# source_url and source_hash (both taken from Mesa's own .wrap), and apply its
# patch_directory overlay, so meson finds it without downloading anything.
provide_wrap_file() {
    local w="mesa-$UPVER/subprojects/$1.wrap" dir url file hash patchdir
    [[ -f "$w" ]] || return 0
    dir="$(sed -n 's/^directory *= *//p' "$w")"
    url="$(sed -n 's/^source_url *= *//p' "$w")"
    file="$(sed -n 's/^source_filename *= *//p' "$w")"
    hash="$(sed -n 's/^source_hash *= *//p' "$w")"
    patchdir="$(sed -n 's/^patch_directory *= *//p' "$w")"
    [[ -n "$dir" && -n "$url" && -n "$hash" ]] || die "$1.wrap is not a [wrap-file] with a pinned hash"
    fetch_file "$url" "$hash" "$SRC/dl/$file" || die "could not download $url"
    mkdir -p "mesa-$UPVER/subprojects/$dir"
    tar -xf "$SRC/dl/$file" -C "mesa-$UPVER/subprojects/$dir" --strip-components=1
    if [[ -n "$patchdir" ]]; then
        cp -a "mesa-$UPVER/subprojects/packagefiles/$patchdir/." "mesa-$UPVER/subprojects/$dir/"
    fi
    log "Bundled subproject $1 ($dir)"
}
# Crates that Mesa 26.3 needs in newer versions than Ubuntu 26.04 packages:
#   xml-rs: the panfrost kraid compiler needs xml >= 1.2.1 (Ubuntu has 1.2.0).
for w in ${MESA_BUNDLED_WRAPS:-xml-rs}; do
    provide_wrap_file "$w"
done

cd "mesa-$UPVER"

if [[ -d "$TOP/mesa/debian-overrides" ]]; then
    log "Applying debian-overrides"
    cp -a "$TOP/mesa/debian-overrides/." debian/
fi

# Leave out the AMD drivers (radeonsi, RADV). A Mac mini has no AMD GPU (Gravity
# also removes amdgpu from its kernel), and in Mesa 26.3 they need libdrm >= 2.4.133,
# newer than Ubuntu 26.04's.
if [[ "${MESA_KEEP_AMD:-0}" != 1 ]]; then
    sed -i -e 's/^\(\s*GALLIUM_DRIVERS += \)radeonsi /\1/' \
           -e 's/^\(\s*VULKAN_DRIVERS += \)amd /\1/' debian/rules
    if grep -qE '^\s*(GALLIUM_DRIVERS \+= .*\bradeonsi\b|VULKAN_DRIVERS \+= .*\bamd\b)' debian/rules; then
        die "could not remove the AMD drivers from debian/rules; update build-mesa.sh"
    fi
    sed -i '/00-radv-defaults\.conf/d' debian/mesa-vulkan-drivers.install
    log "Left out the AMD drivers (radeonsi, RADV)"
fi

# Drop the Debian/Ubuntu patches that no longer apply to the newer source.
export QUILT_PATCHES=debian/patches
if [[ -s debian/patches/series ]]; then
    # Apply cumulatively, since later patches can depend on earlier ones, then
    # revert so that dpkg-source can apply the remaining series itself.
    : >debian/patches/series.new
    kept=()
    while read -r p _; do
        [[ -z "$p" || "$p" == \#* ]] && continue
        if patch -p1 --dry-run -s -f <"debian/patches/$p" >/dev/null 2>&1; then
            patch -p1 -s -f --no-backup-if-mismatch <"debian/patches/$p"
            kept+=("$p")
            echo "$p" >>debian/patches/series.new
        else
            warn "dropping Debian patch that no longer applies: $p"
        fi
    done <debian/patches/series
    for ((i = ${#kept[@]} - 1; i >= 0; i--)); do
        patch -p1 -R -s -f --no-backup-if-mismatch <"debian/patches/${kept[i]}"
    done
    mv debian/patches/series.new debian/patches/series
fi

DEBFULLNAME="Gravity Ubuntu builders" DEBEMAIL="noreply@gravitylinux.org" \
    dch --newversion "$VERSION" --distribution "$UBUNTU_SUITE" --force-distribution \
    "Rebuild from Gravity Linux Mesa ${MESA_REF} for the Apple M4 (AGX G16) GPU."

grep -q "asahi" debian/rules || die "debian/rules does not enable the asahi driver"

patch_rules

log "Installing build dependencies"
apt-get build-dep -y ./
# Build dependencies that Mesa 26.3 adds over Ubuntu's 26.0 packaging:
#   libegl-dev, libgles-dev  Gravity's Apple9 (M4) drm-shim test runner
#   librust-bitflags-dev     panfrost kraid compiler (bitflags >= 2.9.1)
# Ubuntu's get-wraps-from-cargo-registry.py maps installed crates into subprojects/.
apt-get install -y --no-install-recommends libegl-dev libgles-dev librust-bitflags-dev

log "Building Mesa packages"
DEB_BUILD_OPTIONS="nocheck parallel=$JOBS ${DEB_BUILD_OPTIONS:-}" dpkg-buildpackage -b -uc -us

finish
