#!/usr/bin/env bash
# Replace the firmware the ExpressiveOS cheetah OTA ships (bootloader + radio partitions)
# with a Google factory release, so updates never carry firmware older than the phone's
# (Pixels refuse bootloader downgrades). Evolution X's vendor_google_cheetah carries the
# firmware of the release its blobs were extracted from. The same steps as
# evolution-cheetah/update-firmware.sh, for the ExpressiveOS tree only.
#
#   update-firmware.sh <top> <bootloader-cheetah-*.img> <radio-cheetah-*.img> <build-id>
#
# Uses the tree's lineage/scripts/fbpacktool, rewrites the sha1s in
# vendor/google/cheetah/Android.mk and commits the result locally (repo sync discards
# local commits cleanly; prepare.sh reapplies them). Idempotent.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"
[[ $# -eq 4 ]] || fail "usage: update-firmware.sh <top> <bootloader img> <radio img> <build-id>"
eos_top "$1"; bootloader="$2"; radio="$3"; build="$4"
[[ "$build" =~ ^[a-z0-9]{4}\.[0-9]{6}\.[0-9]{3}(\.[a-z0-9]+)?$ ]] || fail "'$build' isn't a build id like cp3a.261005.005"
vendor="$top/vendor/google/cheetah"
project_ok "$vendor"
for p in radio Android.mk FIRMWARE_SOURCE; do in_top "$vendor/$p"; done
fbpacktool="$top/lineage/scripts/fbpacktool/fbpacktool.py"
[[ -f "$fbpacktool" ]] || fail "no $fbpacktool"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
python3 "$fbpacktool" unpack -o "$work" "$bootloader" >/dev/null
python3 "$fbpacktool" unpack -o "$work" "$radio" >/dev/null

images=$(grep -oE 'radio/[a-z0-9_]+\.img' "$vendor/Android.mk" | sed 's|radio/||')
[[ -n "$images" ]] || fail "no radio images listed in $vendor/Android.mk"
for img in $images; do
    [[ -f "$work/$img" ]] || fail "missing $img in the factory images"
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
# A new file each (cp to a temporary name, then mv), never a write into the old one: a
# radio image hard-linked with another tree's copy would change there too
for img in $images; do
    cp -- "$work/$img" "$vendor/radio/.$img.new"
    mv -f -- "$vendor/radio/.$img.new" "$vendor/radio/$img"
    sha="$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)"
    sed -i -E "s|(radio/${img//./\\.},)[0-9a-f]{40}|\1$sha|" "$vendor/Android.mk"
done
# Verify every image, so a partial run can never leave mixed firmware behind
for img in $images; do
    want="$(sha1sum "$work/$img" | cut -d' ' -f1)"
    { [[ "$(sha1sum "$vendor/radio/$img" | cut -d' ' -f1)" == "$want" ]] && grep -q "radio/$img,$want" "$vendor/Android.mk"; } \
        || fail "verify failed: $img"
done
echo "$build" > "$vendor/.FIRMWARE_SOURCE.new"
mv -f -- "$vendor/.FIRMWARE_SOURCE.new" "$vendor/FIRMWARE_SOURCE"
git -C "$vendor" add -A radio Android.mk FIRMWARE_SOURCE
git -C "$vendor" commit -q -m "cheetah: firmware from $build" -m "$(basename "$bootloader") + $(basename "$radio")"
echo "applied: firmware $build ($(wc -w <<<"$images") images verified)"
