#!/usr/bin/env bash
# Replace the husky firmware that the OTA ships (bootloader + radio partitions)
# with a Google factory release, so updates never carry firmware older than the
# phone's (Pixels refuse bootloader downgrades). LineageOS's husky blobs carry
# the firmware of the release they were extracted from.
#
#   update-firmware.sh <tree-top> <bootloader-husky-*.img> <radio-husky-*.img>
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
# Verify every image, so a partial run (e.g. output piped into `head` killing the
# script mid-loop under pipefail) can never leave mixed firmware behind.
for img in $images; do
    want="$(sha1sum "$work/$img" | cut -d' ' -f1)"
    [[ "$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)" == "$want" ]] &&
        grep -q "radio/$img,$want" "$vendor/Android.mk" ||
        { echo "verify failed: $img" >&2; exit 1; }
done
echo "$(basename "$bootloader") + $(basename "$radio")" > "$vendor/radio/SOURCE"
echo "verified: all $(echo $images | wc -w) firmware images match the factory release"
