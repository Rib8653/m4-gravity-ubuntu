# shellcheck shell=bash
# Shared helpers for the build scripts. Source this file; do not execute it.

set -euo pipefail
umask 022

TOP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/sources.env
. "$TOP/config/sources.env"

: "${WORK:=$TOP/work}"
: "${OUT:=$TOP/out}"
SRC="$WORK/src"
DEBS="$OUT/debs"
: "${JOBS:=$(nproc)}"

export DEBIAN_FRONTEND=noninteractive
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || date +%s)}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (see docker/Dockerfile)"
}

host_arch() { dpkg --print-architecture 2>/dev/null || uname -m; }
is_native_arm64() { [[ "$(uname -m)" == aarch64 ]]; }

# Cross-compiler prefix for kernel, U-Boot and m1n1 builds on non-arm64 hosts.
cross_prefix() {
    if is_native_arm64; then echo ""; else echo "aarch64-linux-gnu-"; fi
}

# fetch_git URL REF DIR: shallow-fetch one pinned commit (or tag) and verify it.
fetch_git() {
    local url=$1 ref=$2 dir=$3
    # A shallow fetch stores no tag, so remember which ref the checkout came from.
    if [[ -d "$dir/.git" ]]; then
        local head
        head="$(git -C "$dir" rev-parse -q --verify 'HEAD^{commit}' || true)"
        if [[ "$head" == "$ref" ]] || [[ "$(cat "$dir/.git/gravity-ref" 2>/dev/null)" == "$ref $head" ]]; then
            log "Using existing $(basename "$dir") at ${ref:0:12}"
            return
        fi
    fi
    log "Fetching $url @ ${ref:0:12}"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    local i
    for i in 1 2 3 4; do
        git -C "$dir" fetch -q --depth 1 origin "$ref" && break
        ((i < 4)) || die "could not fetch $url $ref"
        sleep $((2 ** i))
    done
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        [[ "$(git -C "$dir" rev-parse HEAD)" == "$ref" ]] || die "$url: fetched commit does not match $ref"
    fi
    echo "$ref $(git -C "$dir" rev-parse HEAD)" >"$dir/.git/gravity-ref"
}

# fetch_file URL SHA256 DEST: download once and verify the checksum.
fetch_file() {
    local url=$1 sum=$2 dest=$3
    if [[ -f "$dest" ]] && echo "$sum  $dest" | sha256sum -c --status; then
        return 0
    fi
    log "Downloading $url"
    mkdir -p "$(dirname "$dest")"
    curl -fL --retry 4 --retry-delay 2 -o "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }
    echo "$sum  $dest.part" | sha256sum -c --status || { rm -f "$dest.part"; die "checksum mismatch: $url"; }
    mv "$dest.part" "$dest"
}

# Apply a patch exactly (no fuzz) and record it in $dir/.gravity-patches, so
# re-running a build does not apply it twice. A reverse dry run cannot tell
# whether a patch is applied: a deletion-only patch reverses cleanly either way.
apply_patch() {
    local dir=$1 patch=$2 name stamp
    name="$(basename "$patch") $(sha256sum <"$patch" | cut -c1-16)"
    stamp="$dir/.gravity-patches"
    if [[ -f "$stamp" ]] && grep -qxF "$name" "$stamp"; then
        log "  already applied: $(basename "$patch")"
        return
    fi
    log "  applying: $(basename "$patch")"
    patch -d "$dir" -p1 -s -f --fuzz=0 --no-backup-if-mismatch <"$patch" ||
        die "$(basename "$patch") does not apply to $dir"
    echo "$name" >>"$stamp"
}

# make_deb STAGING_DIR: build a binary .deb from a staged tree that contains
# DEBIAN/control. Output goes to $DEBS.
make_deb() {
    local staging=$1
    mkdir -p "$DEBS"
    find "$staging" -path "$staging/DEBIAN" -prune -o -type d -exec chmod 0755 {} +
    if [[ -d "$staging/etc" ]]; then
        (cd "$staging" && find etc -type f -printf '/%p\n' | sort) >"$staging/DEBIAN/conffiles"
        [[ -s "$staging/DEBIAN/conffiles" ]] || rm -f "$staging/DEBIAN/conffiles"
    fi
    local size
    size=$(du -sk --exclude=DEBIAN "$staging" | cut -f1)
    sed -i "/^Installed-Size:/d" "$staging/DEBIAN/control"
    echo "Installed-Size: $size" >>"$staging/DEBIAN/control"
    dpkg-deb --root-owner-group -Zxz --build "$staging" "$DEBS" >&2
}
