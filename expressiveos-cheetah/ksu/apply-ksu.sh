#!/usr/bin/env bash
# Put ExpressiveOS's Wild Kernels pieces into its tree for a phone (EOS_DEVICE, cheetah unless
# set; idempotent: a second run changes nothing): the phone's device tree patch as a local
# commit (cheetah's patches/device_google_pantah/, another phone's
# ../devices/<device>/ksu-patches/<project>/), which makes BOARD_PREBUILT_BOOTIMAGE
# EOS_WILD_BOOT when it's set (tools/wild-boot.sh's boot-wild.img, eos-make.sh). It sits on the
# tree's own device tree patches (../apply.sh, run by ../prepare.sh), which must be in first.
# vendor/extra/ksu, where the SukiSU kit staged its manager and first-boot setup, goes: with Wild
# no manager ships (users install BakaSU's APK).
# Run it on every build (repo sync drops local commits). A phone without root (EOS_KSU=none)
# has nothing here: eos-images.sh doesn't run it, and run anyway it says so and changes nothing.
#
#   apply-ksu.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "APPLY_KSU=FAIL"' EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
[[ $# -le 1 ]] || fail "usage: apply-ksu.sh [top]"
if [[ $EOS_KSU = none ]]; then
    echo "Root is off for $EOS_DEVICE (EOS_KSU=none, devices/$EOS_DEVICE.conf): nothing to apply"
    done=1
    echo "APPLY_KSU_OK skipped for this device"
    exit 0
fi
eos_top "${1:-}"
dt="$top/$EOS_DEVICE_TREE"
if [[ $EOS_DEVICE = cheetah ]]; then
    kdirs=("$here"/patches/device_google_pantah/)
else
    kdirs=("$kit/devices/$EOS_DEVICE"/ksu-patches/*/)
fi
version=$(sed -n 's/^version=//p' "$here/ksu.conf" | head -1)
echo "== Wild $version -> $top"
project_ok "$dt"
if [[ $EOS_DEVICE = cheetah ]]; then
    want=$(subject_of "$(echo "$kit"/patches/device_google_pantah/0002-*.patch)")
else
    # apply.sh checks the same feed commit in the device tree
    want="$EOS_DEVICE: get updates from denson9874/expressiveos_ota"
fi
has_subject "$dt" "$want" || fail "$EOS_DEVICE_TREE lacks the tree's own patches ('$want'); run prepare.sh first"
n=0
for dir in "${kdirs[@]}"; do
    [[ -d $dir ]] || continue
    patches=("$dir"*.patch)
    [[ -e "${patches[0]}" ]] || continue
    p=$(patch_project "$dir")              # e.g. device/google/pantah
    am_patches "$top/$p" "$(basename "$dir")" "${patches[@]}"
    n=$((n + ${#patches[@]}))
done
(( n > 0 )) || fail "no Wild device tree patch for $EOS_DEVICE (devices/$EOS_DEVICE/ksu-patches/): a phone with EOS_KSU=wild needs its device tree to take EOS_WILD_BOOT as its boot image"
# The SukiSU kit's staging folder: nothing in it ships any more
in_top "$top/vendor/extra/ksu"
if [[ -e $top/vendor/extra/ksu ]]; then
    rm -rf -- "${top:?}/vendor/extra/ksu"
    echo "removed: vendor/extra/ksu (the SukiSU kit's manager and first-boot setup)"
fi
done=1
echo "APPLY_KSU_OK Wild $version"
