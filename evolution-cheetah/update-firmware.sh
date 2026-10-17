#!/usr/bin/env bash
# Replace the firmware the cheetah OTA ships (bootloader + radio partitions) with
# a Google factory release, so updates never carry firmware older than the phone's
# (Pixels refuse bootloader downgrades). Evolution's vendor_google_cheetah carries
# the firmware of the release its blobs were extracted from.
#
#   update-firmware.sh <evolution-top> <bootloader-cheetah-*.img> <radio-cheetah-*.img> <build-id>
#
# Uses the tree's lineage/scripts/fbpacktool, rewrites the sha1s in
# vendor/google/cheetah/Android.mk and commits the result locally (repo sync
# discards local commits cleanly; prepare.sh reapplies them). Idempotent.
set -euo pipefail
top="$(cd "$1" && pwd)"; bootloader="$2"; radio="$3"; build="$4"
vendor="$top/vendor/google/cheetah"
fbpacktool="$top/lineage/scripts/fbpacktool/fbpacktool.py"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
python3 "$fbpacktool" unpack -o "$work" "$bootloader" >/dev/null
python3 "$fbpacktool" unpack -o "$work" "$radio" >/dev/null

images=$(grep -oE 'radio/[a-z0-9_]+\.img' "$vendor/Android.mk" | sed 's|radio/||')
[[ -n "$images" ]] || { echo "no radio images listed in $vendor/Android.mk" >&2; exit 1; }
for img in $images; do
    [[ -f "$work/$img" ]] || { echo "missing $img in the factory images" >&2; exit 1; }
done
applied() {
    [[ "$(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null)" == "$build" ]] || return 1
    local img
    for img in $images; do
        grep -q "radio/$img,$(sha1sum "$work/$img" | cut -d' ' -f1)" "$vendor/Android.mk" || return 1
        cmp -s "$work/$img" "$vendor/radio/$img" || return 1
    done
}
if applied; then
    echo "already applied: firmware $build"; exit 0
fi
for img in $images; do
    cp "$work/$img" "$vendor/radio/$img"
    sha="$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)"
    sed -i -E "s|(radio/${img//./\\.},)[0-9a-f]{40}|\1$sha|" "$vendor/Android.mk"
done
# Verify every image, so a partial run can never leave mixed firmware behind.
for img in $images; do
    want="$(sha1sum "$work/$img" | cut -d' ' -f1)"
    [[ "$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)" == "$want" ]] &&
        grep -q "radio/$img,$want" "$vendor/Android.mk" ||
        { echo "verify failed: $img" >&2; exit 1; }
done
echo "$build" > "$vendor/FIRMWARE_SOURCE"
git -C "$vendor" add -A radio Android.mk FIRMWARE_SOURCE
git -C "$vendor" commit -q -m "cheetah: firmware from $build" -m "$(basename "$bootloader") + $(basename "$radio")"
echo "applied: firmware $build ($(echo $images | wc -w) images verified)"
