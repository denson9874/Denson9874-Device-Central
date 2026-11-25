#!/usr/bin/env bash
# Wild Kernels' boot.img for ExpressiveOS on a phone with EOS_KSU=wild (EOS_DEVICE, cheetah unless
# set). Two steps around the make (eos-make.sh):
#
#   wild-boot.sh build <stock boot.img> [top]
#       before the make: the tree's prebuilt boot.img (BOARD_PREBUILT_BOOTIMAGE: Google's stock GKI)
#       with its kernel swapped for Wild's
#       Image for the phone's KMI (fetch-ksu.sh), packed again with the same header, OS version,
#       patch level and cmdline, the kernel compressed as the stock one is. Writes
#       EOS_KSU_OUT/boot-wild.img, which the make takes as BOARD_PREBUILT_BOOTIMAGE (EOS_WILD_BOOT,
#       each phone's ksu-patches) and signs with the tree's boot AVB key like any prebuilt boot,
#       and keeps the stock one as EOS_KSU_OUT/boot-stock.src.img.
#   EOS_AVB_BOOT_KEY=<key> wild-boot.sh stock [top]
#       after the make: EOS_KSU_OUT/boot-stock.img, the stock boot signed exactly as the build
#       signed boot.img (the tree's boot key; algorithm, rollback index and props from its
#       footer), for users who want no root. eos-pack.sh publishes it beside the fastboot zip.
#
# The last line is KSU_EXIT=0 or KSU_EXIT=1.
set -euo pipefail
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    # Quiet while run_locked's marker is there: the run waiting for the locks prints it then
    [[ $done = 1 || -e "${EOS_STARTED:-}" ]] || echo "KSU_EXIT=1"
    exit $rc
}
trap cleanup EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../../lib.sh
source "$here/../lib.sh"
usage="usage: wild-boot.sh build <stock boot.img> [top] | stock [top]"
mode=${1:-}
case $mode in
build) [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"; src=$2; eos_top "${3:-}" ;;
stock) [[ $# -le 2 ]] || fail "$usage"; eos_top "${2:-}" ;;
*) fail "$usage" ;;
esac
[[ $EOS_KSU = wild ]] || fail "Wild is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): its build ships the stock boot, there's nothing to do"
cd "$top"
for c in lz4 strings od python3; do command -v "$c" >/dev/null || fail "$c isn't installed"; done
H=out/host/linux-x86/bin
K=$EOS_KSU_OUT
in_top "$top/$K"
mkdir -p -- "$K"
T=$(mktemp -d "${TMPDIR:-/tmp}/wild-boot.XXXXXX")
unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
mkboot() { if [[ -x $H/mkbootimg ]]; then "$H/mkbootimg" "$@"; else python3 -I system/tools/mkbootimg/mkbootimg.py "$@"; fi; }
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
uname_of() {   # uname_of <boot.img>: its kernel's Linux version (6.1.162-android14-Wild)
    unpack --boot_img "$1" --out "$T/u" >/dev/null || fail "can't unpack $1"
    local k=$T/u/kernel
    [[ "$(head -c4 "$k" | od -An -tx1 | tr -d ' ')" != 02214c18 ]] || { lz4 -dc "$k" > "$T/u/Image"; k=$T/u/Image; }
    # awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
    strings "$k" | awk '/^Linux version / && !f { print $3; f = 1 }'
    rm -rf -- "$T/u"
}
kmi=$EOS_KMI
want=$(get "uname_$kmi")
[[ -n $want ]] || fail "ksu.conf has no uname_$kmi: no Wild kernel for $EOS_DEVICE's $kmi"

if [[ $mode = build ]]; then
    image=$HOME/android-dt/wild/$(get version)/$kmi/Image
    [[ -s $image ]] || fail "no $image (run $here/fetch-ksu.sh)"
    [[ -f $src ]] || fail "no $src (the tree's BOARD_PREBUILT_BOOTIMAGE)"
    rm -f -- "$K/boot-wild.img" "$K/boot-stock.src.img" "$K/boot-stock.img"
    have=$(uname_of "$src")
    [[ -n $have ]] || fail "no Linux version string in $src's kernel"
    [[ $have != *-Wild ]] || fail "$src is already a Wild kernel ($have): the input must be the tree's stock boot"
    # Wild's kernel only fits the vendor modules of the same KMI (android14-6.1...)
    [[ "${have%%-*}" == "${kmi#*-}".* && "$have" == *"-${kmi%%-*}"* ]] || fail "$src is Linux $have, not $kmi"
    unpack --boot_img "$src" --out "$T/st" --format=mkbootimg > "$T/args" || fail "can't unpack $src"
    [[ ! -s $T/st/ramdisk ]] || fail "$src has a ramdisk: a GKI boot.img (header v4) has none, init_boot carries it"
    cp -- "$src" "$K/boot-stock.src.img"
    if [[ "$(head -c4 "$T/st/kernel" | od -An -tx1 | tr -d ' ')" = 02214c18 ]]; then
        lz4 -l -12 -f -q "$image" "$T/Image.lz4" || fail "lz4 failed"
        kernel=$T/Image.lz4; how="lz4 (legacy), as the stock one"
    else
        kernel=$image; how="uncompressed, as the stock one"
    fi
    # The stock image's own mkbootimg arguments, with Wild's kernel in place of its kernel
    eval "args=($(cat "$T/args"))" || fail "can't read $src's mkbootimg arguments"
    for i in "${!args[@]}"; do [[ ${args[$i]} != "$T/st/kernel" ]] || args[i]=$kernel; done
    mkboot "${args[@]}" --output "$K/boot-wild.img" || fail "mkbootimg failed"
    # Same header as the stock one but for the kernel
    unpack --boot_img "$K/boot-wild.img" --out "$T/w" --format=mkbootimg > "$T/wargs" || fail "can't unpack boot-wild.img"
    sed "s#$T/st/##g" "$T/args" | sed "s#--kernel kernel##" > "$T/a1"
    sed "s#$T/w/##g" "$T/wargs" | sed "s#--kernel kernel##" > "$T/a2"
    cmp -s "$T/a1" "$T/a2" || fail "boot-wild.img's header isn't the stock one's: $(cat "$T/a2") vs $(cat "$T/a1")"
    rm -rf -- "$T/w"
    got=$(uname_of "$K/boot-wild.img")
    [[ $got = "$want" ]] || fail "boot-wild.img's kernel is Linux $got, ksu.conf says $want"
    echo "OK: $K/boot-wild.img (Wild $(get version), Linux $got; stock was $have; kernel $how)"
else
    O=$EOS_PRODUCT_OUT
    s=$K/boot-stock.src.img
    [[ -f $s ]] || fail "no $s (wild-boot.sh build runs before the make)"
    [[ -f $O/boot.img ]] || fail "no $O/boot.img (run the make first)"
    got=$(uname_of "$O/boot.img")
    [[ $got = "$want" ]] || fail "$O/boot.img's kernel is Linux $got, not Wild's $want: the make didn't take boot-wild.img (EOS_WILD_BOOT, ksu-patches)"
    "$H/avbtool" info_image --image "$O/boot.img" > "$T/info" || fail "avbtool can't read $O/boot.img"
    alg=$(sed -n 's/^Algorithm: *//p' "$T/info")
    ri=$(sed -n 's/^Rollback Index: *//p' "$T/info")
    size=$(sed -n 's/^Image size: *//p' "$T/info" | awk '{print $1}')
    [[ -n $alg && $alg != NONE && -n $ri && -n $size ]] || fail "$O/boot.img has no signed AVB footer"
    # eos-make.sh passes the tree's get_build_var BOARD_AVB_BOOT_KEY_PATH
    key=${EOS_AVB_BOOT_KEY:-}
    [[ -n $key && -f $key ]] || fail "no boot AVB key: set EOS_AVB_BOOT_KEY to the tree's BOARD_AVB_BOOT_KEY_PATH (eos-make.sh does)"
    props=()
    while IFS= read -r l; do
        [[ $l =~ ^\ +Prop:\ ([^ ]+)\ -\>\ \'(.*)\'$ ]] && props+=(--prop "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}")
    done < "$T/info"
    cp -- "$s" "$K/boot-stock.img"
    "$H/avbtool" erase_footer --image "$K/boot-stock.img" 2>/dev/null || true
    "$H/avbtool" add_hash_footer --image "$K/boot-stock.img" --partition_name boot --partition_size "$size" \
        --algorithm "$alg" --key "$key" --rollback_index "$ri" "${props[@]}" || fail "avbtool add_hash_footer failed"
    got=$(uname_of "$K/boot-stock.img")
    [[ $got != *-Wild ]] || fail "$K/boot-stock.img is a Wild kernel"
    echo "OK: $K/boot-stock.img (Linux $got, signed as $O/boot.img: $alg, rollback index $ri)"
fi
done=1
echo "KSU_EXIT=0"
