#!/usr/bin/env bash
# Get the ExpressiveOS cheetah tree ready for a build (idempotent): every Git LFS file
# present, the kit's tree patches (apply.sh), and the newest cached Google firmware in
# vendor/google/cheetah unless the vendor repo already ships newer. The firmware cache,
# ~/android-dt/firmware/cheetah, is the one evolution-cheetah/fetch-firmware.sh fills;
# it's only read here. eos-images.sh runs this before the KernelSU Next, ViPER4Android,
# boot animation and wallpaper kits.
#
#   prepare.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "PREPARE=FAIL"' EXIT
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"
[[ $# -le 1 ]] || fail "usage: prepare.sh [top]"
eos_top "${1:-}"
vendor="$top/vendor/google/cheetah"

# Git LFS: without it the radio images and some GMS APKs are 130-byte pointer files and
# the build ships garbage. git lfs ls-files marks a file that's only a pointer with '-'.
git lfs version >/dev/null 2>&1 || fail "git-lfs isn't installed"
pointers() { git -C "$1" lfs ls-files | awk '$2 == "-"' | wc -l; }
for p in vendor/google/cheetah vendor/gms; do
    project_ok "$top/$p"
    n=$(pointers "$top/$p")
    if (( n > 0 )); then
        echo "$p: $n Git LFS files are pointers only; fetching them"
        git -C "$top/$p" lfs pull || fail "git lfs pull failed in $p"
        n=$(pointers "$top/$p")
        (( n == 0 )) || fail "$p still has $n Git LFS pointer files"
    fi
    echo "OK: $p: all $(git -C "$top/$p" lfs ls-files | wc -l) Git LFS files present"
done

"$kit/apply.sh" "$top" || fail "apply.sh failed"

# Release date of a build id such as cp3a.261005.005 -> 261005
date_of() { cut -d. -f2 <<<"${1,,}"; }
fw=~/android-dt/firmware/cheetah
cached=$(cat "$fw/CURRENT" 2>/dev/null || true)
# What the vendor repo ships when we don't touch it: its BuildFingerprint build id
shipped=$(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null ||
          grep -oE 'cheetah:17/[A-Z0-9]{4}\.[0-9]{6}\.[0-9]{3}' "$top/device/google/pantah/lineage_cheetah.mk" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]' ||
          true)   # neither: unknown, said below
if [[ -z "$cached" ]]; then
    echo "WARNING: no cached factory firmware in $fw (run evolution-cheetah/fetch-firmware.sh); shipping the vendor repo's ${shipped:-unknown}"
elif [[ -n "$shipped" && "$(date_of "$cached")" < "$(date_of "$shipped")" ]]; then
    echo "WARNING: cached firmware $cached is older than the vendor repo's $shipped; keeping the vendor repo's (run fetch-firmware.sh)"
else
    bl=$(find "$fw" -maxdepth 1 -name 'bootloader-cheetah-*.img' | sort | tail -1)
    rd=$(find "$fw" -maxdepth 1 -name 'radio-cheetah-*.img' | sort | tail -1)
    [[ -n "$bl" && -n "$rd" ]] || fail "$fw/CURRENT says $cached, but its bootloader or radio image is missing"
    "$kit/update-firmware.sh" "$top" "$bl" "$rd" "$cached"
fi
done=1
echo "PREPARE_OK firmware $(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null || echo "${shipped:-unknown} (vendor repo)")"
