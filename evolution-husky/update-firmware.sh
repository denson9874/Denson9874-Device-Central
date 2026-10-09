#!/usr/bin/env bash
# Replace the husky firmware that the OTA ships (bootloader + radio partitions)
# with a Google factory release, so updates never carry firmware older than the
# phone's (Pixels refuse bootloader downgrades). LineageOS's husky blobs carry
# the firmware of the release they were extracted from.
#
#   update-firmware.sh <evolution-top> <bootloader-husky-*.img> <radio-husky-*.img>
#
# Uses the tree's lineage/scripts/fbpacktool; rewrites the sha1s in
# vendor/google/husky/Android.mk (a local change; rerun after `repo sync`).
set -euo pipefail
top="$(cd "$1" && pwd)"; bootloader="$2"; radio="$3"
vendor="$top/vendor/google/husky"
fbpacktool="$top/lineage/scripts/fbpacktool/fbpacktool.py"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
python3 "$fbpacktool" unpack -o "$work" "$bootloader" >/dev/null
python3 "$fbpacktool" unpack -o "$work" "$radio" >/dev/null

images=$(grep -oE 'radio/[a-z0-9_]+\.img' "$vendor/Android.mk" | sed 's|radio/||')
for img in $images; do
    [[ -f "$work/$img" ]] || { echo "missing $img in factory images" >&2; exit 1; }
done
for img in $images; do
    cp "$work/$img" "$vendor/radio/$img"
    sha="$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)"
    sed -i -E "s|(radio/${img//./\\.},)[0-9a-f]{40}|\1$sha|" "$vendor/Android.mk"
    echo "$img $sha"
done
echo "$(basename "$bootloader") + $(basename "$radio")" > "$vendor/radio/SOURCE"
