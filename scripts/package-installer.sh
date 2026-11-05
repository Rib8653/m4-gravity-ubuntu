#!/bin/bash
# Package images built by build-image.sh into what Gravity's macOS installer reads:
#
#   out/installer/os/<name>.zip            esp/, boot.img, root.img
#   out/installer/installer_data.json      one os_list entry per flavour
#   out/installer/bootstrap-ubuntu.sh      `curl ... | sh` entry point
#
# Gravity's installer (GravityLinux/installer, at 6420623 or later) runs as-is.
# It only reads installer_data.json and the OS package.
#
#   FLAVORS="ubuntu kubuntu" BASE_URL=https://example.org/gravity-ubuntu \
#       scripts/package-installer.sh
#
# BASE_URL is where you will upload out/installer/: installer_data.json and
# os/ are fetched from there. The installer program itself still comes from
# Gravity's CDN (INSTALLER_BASE), unless you override it.
. "$(dirname "$0")/lib.sh"
need python3 zip

FLAVORS="${FLAVORS:-ubuntu}"
BASE_URL="${BASE_URL:-http://localhost:5000}"
INSTALLER_BASE="${INSTALLER_BASE:-https://cdn.gravitylinux.org/installer}"
SUPPORTED_FW="${SUPPORTED_FW:-26.6.2}"
DEST="$OUT/installer"
mkdir -p "$DEST/os"
date_tag="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d)"

entries=()
for flavor in $FLAVORS; do
    img="$OUT/image-$flavor"
    [[ -f "$img/image.json" ]] || die "no image for $flavor; run FLAVOR=$flavor make image"
    name="ubuntu-${UBUNTU_RELEASE}-${flavor}-gravity-m4-${date_tag}"
    zipfile="$DEST/os/$name.zip"
    log "Packaging $zipfile"
    rm -f "$zipfile"
    # Store the images uncompressed: the installer streams them straight to disk.
    (cd "$img" && zip -q -0 "$zipfile" boot.img root.img && zip -q -r -9 "$zipfile" esp)
    entries+=("$flavor:$name.zip")
done

python3 - "$DEST/installer_data.json" "$OUT" "$SUPPORTED_FW" "${entries[@]}" <<'EOF'
import json, sys, os

out_json, out_dir, fw, *entries = sys.argv[1:]
names = {
    "ubuntu":  "Ubuntu {rel} LTS (GNOME desktop)",
    "kubuntu": "Kubuntu {rel} LTS (KDE Plasma desktop)",
    "server":  "Ubuntu Server {rel} LTS",
}
os_list = []
for entry in entries:
    flavor, package = entry.split(":", 1)
    meta = json.load(open(os.path.join(out_dir, f"image-{flavor}", "image.json")))
    rel = meta["ubuntu_release"]
    os_list.append({
        "name": names[flavor].format(rel=rel) + " - Gravity M4 port (unofficial)",
        "default_os_name": "Kubuntu" if flavor == "kubuntu" else "Ubuntu",
        "boot_object": "m1n1.bin",
        "next_object": "m1n1/boot.bin",
        "package": package,
        "supported_fw": fw.split(),
        "partitions": [
            {
                "name": "EFI",
                "type": "EFI",
                "size": "500MB",
                "format": "fat",
                "volume_id": meta["esp_volume_id"],
                "copy_firmware": True,
                "copy_installer_data": True,
                "source": "esp",
            },
            {
                "name": "Boot",
                "type": "Linux",
                "size": f"{meta['boot_size']}B",
                "image": "boot.img",
            },
            {
                "name": "Root",
                "type": "Linux",
                "size": f"{meta['root_size']}B",
                "expand": True,
                "image": "root.img",
            },
        ],
    })
json.dump({"os_list": os_list}, open(out_json, "w"), indent=4)
EOF

sed -e "s|@BASE_URL@|$BASE_URL|g" -e "s|@INSTALLER_BASE@|$INSTALLER_BASE|g" \
    "$TOP/installer/bootstrap-ubuntu.sh.in" >"$DEST/bootstrap-ubuntu.sh"
chmod 0755 "$DEST/bootstrap-ubuntu.sh"
(cd "$DEST" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
log "Installer data is in $DEST. Upload it to $BASE_URL, then on the Mac run:"
log "  curl -fsSL $BASE_URL/bootstrap-ubuntu.sh | sh"
