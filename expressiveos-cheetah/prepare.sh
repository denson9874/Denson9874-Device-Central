#!/usr/bin/env bash
# Get the ExpressiveOS tree ready for a phone's build (idempotent; EOS_DEVICE, cheetah unless
# set): every Git LFS file of its EOS_LFS_PROJECTS present, the kit's tree patches
# (apply.sh), then the firmware its EOS_FIRMWARE_MODE says (devices/<device>.conf):
#   cache   the newest cached Google firmware into its vendor repo unless that already ships
#           newer (cheetah). The cache, ~/android-dt/firmware/<device>, is the one
#           evolution-cheetah/fetch-firmware.sh fills; it's only read here;
#   blobs   the vendor repo's own (husky: TheMuppets' blobs carry the factory firmware);
#   images  vendor/google/<device>-images made by the device tree's extract-images.sh from the
#           newest ~/android-dt/firmware/image-<device>-*.zip, again only when that zip
#           changed (the Pixel 11s: stock vendor, boot, dtbo and firmware images). Their
#           vendor blobs, vendor/google/<device>, aren't in ExpressiveOS's manifest (Google's
#           files, never pushed anywhere): the first build copies the build server's own repo
#           of them, ~/evolution's, which is only read, and a later one moves to its newer
#           commits; eos-images.sh records the commit in sources.txt.
# eos-images.sh runs this before the KernelSU Next, ViPER4Android, boot animation and
# wallpaper kits.
#
#   prepare.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "PREPARE=FAIL"' EXIT
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"
[[ $# -le 1 ]] || fail "usage: prepare.sh [top]"
eos_top "${1:-}"
vendor="$top/$EOS_VENDOR_DIR"

if [[ $EOS_FIRMWARE_MODE = images ]]; then
    # Google's blobs for this phone, from the server's own repo of them (read, never written)
    src=${evo:+$evo/$EOS_VENDOR_DIR}
    in_top "$vendor"
    if [[ ! -e $vendor ]]; then
        [[ -n $src && -d $src/.git ]] || fail "$EOS_VENDOR_DIR isn't in this tree, and there's no ~/evolution/$EOS_VENDOR_DIR to copy it from"
        echo "$EOS_VENDOR_DIR: copying the build server's repo (~/evolution/$EOS_VENDOR_DIR, $(git -C "$src" rev-parse --short HEAD))"
        git clone -q --no-hardlinks --no-checkout -- "$src" "$vendor" || fail "can't copy ~/evolution/$EOS_VENDOR_DIR"
        git -C "$vendor" remote rename origin server || fail "can't name $EOS_VENDOR_DIR's remote"
        git -C "$vendor" checkout -q --detach "$(git -C "$src" rev-parse HEAD)" || fail "can't check out $EOS_VENDOR_DIR"
    fi
    project_ok "$vendor"
    [[ -z "$(git -C "$vendor" status --porcelain)" ]] || fail "$EOS_VENDOR_DIR has changes that aren't committed (git -C $vendor status)"
    if [[ -n $src && -d $src/.git ]]; then
        sh=$(git -C "$src" rev-parse HEAD)
        if [[ $(git -C "$vendor" rev-parse HEAD) != "$sh" ]]; then
            git -C "$vendor" fetch -q server "+HEAD:refs/remotes/server/HEAD" || fail "can't read ~/evolution/$EOS_VENDOR_DIR"
            if git -C "$vendor" merge-base --is-ancestor HEAD "$sh"; then
                git -C "$vendor" checkout -q --detach "$sh" || fail "can't move $EOS_VENDOR_DIR to ${sh:0:12}"
                echo "$EOS_VENDOR_DIR: moved to the server repo's ${sh:0:12}"
            else
                echo "WARNING: $EOS_VENDOR_DIR is at $(git -C "$vendor" rev-parse --short HEAD), which the server repo's ${sh:0:12} doesn't build on: kept as it is"
            fi
        fi
    fi
    echo "OK: $EOS_VENDOR_DIR at $(git -C "$vendor" log -1 --format='%h %s' | cut -c1-90)"
fi

# Git LFS: without it the radio images and some GMS APKs are 130-byte pointer files and
# the build ships garbage. git lfs ls-files marks a file that's only a pointer with '-'.
git lfs version >/dev/null 2>&1 || fail "git-lfs isn't installed"
pointers() { git -C "$1" lfs ls-files | awk '$2 == "-"' | wc -l; }
for p in $EOS_LFS_PROJECTS; do
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

fwsrc=
case $EOS_FIRMWARE_MODE in
cache)
    # Release date of a build id such as cp3a.261005.005 -> 261005
    date_of() { cut -d. -f2 <<<"${1,,}"; }
    fw=~/android-dt/firmware/$EOS_DEVICE
    cached=$(cat "$fw/CURRENT" 2>/dev/null || true)
    # What the vendor repo ships when we don't touch it: its BuildFingerprint build id
    shipped=$(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null ||
              grep -oE "$EOS_DEVICE:17/[A-Z0-9]{4}\.[0-9]{6}\.[0-9]{3}" "$top/$EOS_DEVICE_TREE/lineage_$EOS_DEVICE.mk" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]' ||
              true)   # neither: unknown, said below
    if [[ -z "$cached" ]]; then
        echo "WARNING: no cached factory firmware in $fw (run evolution-cheetah/fetch-firmware.sh); shipping the vendor repo's ${shipped:-unknown}"
    elif [[ -n "$shipped" && "$(date_of "$cached")" < "$(date_of "$shipped")" ]]; then
        echo "WARNING: cached firmware $cached is older than the vendor repo's $shipped; keeping the vendor repo's (run fetch-firmware.sh)"
    else
        bl=$(find "$fw" -maxdepth 1 -name "bootloader-$EOS_DEVICE-*.img" | sort | tail -1)
        rd=$(find "$fw" -maxdepth 1 -name "radio-$EOS_DEVICE-*.img" | sort | tail -1)
        [[ -n "$bl" && -n "$rd" ]] || fail "$fw/CURRENT says $cached, but its bootloader or radio image is missing"
        "$kit/update-firmware.sh" "$top" "$bl" "$rd" "$cached"
    fi
    fwsrc=$(cat "$vendor/FIRMWARE_SOURCE" 2>/dev/null || echo "${shipped:-unknown} (vendor repo)")
    ;;
blobs)
    fwsrc="the vendor repo's own ($EOS_VENDOR_DIR at $(git -C "$vendor" rev-parse --short HEAD))"
    ;;
images)
    # The newest factory image zip for this phone, by its build id (image-<device>-<id>.zip)
    zip=$(find ~/android-dt/firmware -maxdepth 1 -name "image-$EOS_DEVICE-*.zip" | sort | tail -1)
    [[ -n $zip ]] || fail "no ~/android-dt/firmware/image-$EOS_DEVICE-*.zip to make vendor/google/$EOS_DEVICE-images from"
    imgs=$top/vendor/google/$EOS_DEVICE-images
    ex=$top/$EOS_DEVICE_TREE/extract-images.sh
    [[ -f $ex ]] || fail "$EOS_DEVICE_TREE has no extract-images.sh"
    in_top "$imgs"
    # Name, size and time stand for the zip (hashing 15 GB on every build would add minutes)
    stamp="${zip##*/} $(stat -c '%s %Y' -- "$zip")"
    if [[ "$(cat "$imgs/.eos-source" 2>/dev/null)" = "$stamp" && -f $imgs/Android.mk ]]; then
        echo "unchanged: vendor/google/$EOS_DEVICE-images (from ${zip##*/})"
    else
        echo "== vendor/google/$EOS_DEVICE-images from ${zip##*/}"
        rm -f -- "$imgs/.eos-source"
        mkdir -p -- "$top/out/.eos-extract"
        TMPDIR=$top/out/.eos-extract bash "$ex" "$zip" || fail "$EOS_DEVICE_TREE/extract-images.sh failed"
        [[ -f $imgs/Android.mk ]] || fail "extract-images.sh made no vendor/google/$EOS_DEVICE-images/Android.mk"
        printf '%s\n' "$stamp" > "$imgs/.eos-source"
    fi
    fwsrc="${zip##*/} (vendor/google/$EOS_DEVICE-images)"
    ;;
esac
done=1
echo "PREPARE_OK firmware $fwsrc"
