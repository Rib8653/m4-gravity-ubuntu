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

log "Installing build dependencies"
apt-get build-dep -y ./

log "Building Mesa packages"
DEB_BUILD_OPTIONS="nocheck parallel=$JOBS ${DEB_BUILD_OPTIONS:-}" dpkg-buildpackage -b -uc -us

mkdir -p "$DEBS"
mv ../*.deb "$DEBS/"
log "Mesa packages are in $DEBS"
