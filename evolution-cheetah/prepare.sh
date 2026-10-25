#!/usr/bin/env bash
# Get an Evolution X tree ready for a cheetah build (idempotent): our patches on
# Evolution's pantah tree, and the newest cached Google firmware (fetch-firmware.sh)
# in vendor/google/cheetah, unless the vendor repo already ships newer firmware.
#
#   prepare.sh [evolution-top]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
top="$(cd "${1:-$HOME/evolution}" && pwd)"
vendor="$top/vendor/google/cheetah"

# Git LFS: without it the radio images are 130-byte pointer files and the build
# ships garbage firmware.
for img in "$vendor"/radio/*.img; do
    if head -c 40 "$img" | grep -q "git-lfs"; then
        echo "$img is a Git LFS pointer; fetching LFS objects"
        git lfs version >/dev/null 2>&1 || { echo "FAIL: git-lfs isn't installed on this machine" >&2; exit 1; }
        git -C "$vendor" lfs pull
        break
    fi
done
for img in "$vendor"/radio/*.img; do
    head -c 40 "$img" | grep -q "git-lfs" && { echo "FAIL: $img is still an LFS pointer" >&2; exit 1; }
done

"$here/apply.sh" "$top"

# KernelSU Next manager for device/google/pantah 0010 (fetch-ksu.sh, pinned in ksu.conf)
ksu_version=$(sed -n 's/^version=//p' "$here/ksu.conf")
ksu_apk=~/android-dt/ksu/$ksu_version/KernelSUNext.apk
[[ -s "$ksu_apk" ]] || { echo "FAIL: no $ksu_apk (run fetch-ksu.sh)" >&2; exit 1; }
cp "$ksu_apk" "$top/device/google/pantah/ksu/KernelSUNext.apk"

# Release date of a build id such as cp3a.261005.005 -> 261005
date_of() { cut -d. -f2 <<<"${1,,}"; }
fw=~/android-dt/firmware/cheetah
cached=$(cat "$fw/CURRENT" 2>/dev/null || true)
# What the vendor repo ships when we don't touch it: its BuildFingerprint build id
shipped=$(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null ||
          grep -oE 'cheetah:17/[A-Z0-9]{4}\.[0-9]{6}\.[0-9]{3}' "$top/device/google/pantah/lineage_cheetah.mk" | cut -d/ -f2 | tr A-Z a-z)
if [[ -z "$cached" ]]; then
    echo "WARNING: no cached factory firmware in $fw (run fetch-firmware.sh); shipping the vendor repo's ${shipped:-unknown}"
elif [[ -n "$shipped" && "$(date_of "$cached")" < "$(date_of "$shipped")" ]]; then
    echo "WARNING: cached firmware $cached is older than the vendor repo's $shipped; keeping the vendor repo's (run fetch-firmware.sh)"
else
    "$here/update-firmware.sh" "$top" "$(ls "$fw"/bootloader-cheetah-*.img | tail -1)" "$(ls "$fw"/radio-cheetah-*.img | tail -1)" "$cached"
fi
echo "PREPARE_OK firmware $(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null || echo "${shipped:-unknown} (vendor repo)"), KernelSU Next $ksu_version"
