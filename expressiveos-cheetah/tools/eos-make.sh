#!/usr/bin/env bash
# The make part of an ExpressiveOS 2.0 build of a phone (EOS_DEVICE, cheetah unless set;
# devices/<device>.conf). All six EOS 2.0 phones use prebuilt stock factory kernel images
# (EOS_KERNEL=prebuilt). With root (EOS_KSU=wild): the tree's prebuilt boot image
# (BOARD_PREBUILT_BOOTIMAGE) with Wild Kernels' BakaSU kernel in place of its own
# (ksu/tools/wild-boot.sh build), which the make takes as its boot image through EOS_WILD_BOOT,
# one pass; it must ship that boot and the stock init_boot (ksu-check.sh images), and
# wild-boot.sh stock then signs the stock boot as the build signed boot.img, for users who
# want no root. Without root (EOS_KSU=none): the build's own boot and init_boot. Either way
# one make pass, and the build keeps its target-files zip (tf_zip in lib.sh). Every phone gets
# EOS_PRODUCT_OUT's ab_partitions.txt. A quick build (EOS_QUICK=1, lib.sh) runs m droid where
# a full one runs m eos: the same images, and no OTA package or target-files zip. The last
# line is MAKE_EXIT=0 or MAKE_EXIT=1.
#
#   eos-make.sh [top]                    # default ~/expressiveos; lunch target EOS_LUNCH (devices/<device>.conf)
#   EOS_INSTALLCLEAN=1 eos-make.sh       # start with m installclean
#   EOS_QUICK=1 eos-make.sh              # images only: m droid, no OTA package or target-files
#
# Not -e or -u: envsetup.sh and its functions rely on neither; every step is checked
set -o pipefail
done=0
# Quiet while run_locked's marker is there: the run waiting for the locks prints it then
trap '[[ $done = 1 || -e "${EOS_STARTED:-}" ]] || echo "MAKE_EXIT=1"' EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
[[ $# -le 1 ]] || fail "usage: eos-make.sh [top]"
eos_top "${1:-}"
# Run alone, this runs again under eos_lock (the locks eos-images.sh holds) and exits with it
run_locked MAKE_EXIT=1 "$0" "$top"
# A TOP or OUT exported for another tree would send envsetup, lunch and m there
clean_env
cd "$top" || fail "can't cd to $top"
PATH=$HOME/bin:$PATH
O=$EOS_PRODUCT_OUT
K=$EOS_KSU_OUT

# The Wild piece apply-ksu.sh puts in: the phone's device tree patch (cheetah's in ksu/patches/,
# another phone's in devices/<device>/ksu-patches/)
if [[ $EOS_KSU = wild ]]; then
    if [[ $EOS_DEVICE = cheetah ]]; then
        kdirs=("$kit"/ksu/patches/device_google_pantah/)
    else
        kdirs=("$kit/devices/$EOS_DEVICE"/ksu-patches/*/)
    fi
    n=0
    for dir in "${kdirs[@]}"; do
        [[ -d $dir ]] || continue
        kp=$(patch_project "$dir")
        for p in "$dir"*.patch; do
            [[ -e $p ]] || continue
            s=$(subject_of "$p")
            has_subject "$top/$kp" "$s" || fail "$kp lacks '$s' (run apply-ksu.sh)"
            n=$((n + 1))
        done
    done
    (( n > 0 )) || fail "no Wild device tree patch for $EOS_DEVICE (devices/$EOS_DEVICE/ksu-patches/)"
    # The SukiSU kit's manager and first-boot setup: apply-ksu.sh removes them, nothing ships them now
    [[ ! -e vendor/extra/ksu ]] || fail "vendor/extra/ksu is still in the tree (the SukiSU kit's; run apply-ksu.sh)"
fi

if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    echo "KERNEL_ONLY=1: $EOS_DEVICE builds no kernel (EOS_KERNEL=$EOS_KERNEL: prebuilt stock factory kernel images): nothing to build"
    done=1; echo "MAKE_EXIT=0"; exit 0
fi
eos_step make
export EXPRESSIVE_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
if command -v ccache >/dev/null; then export USE_CCACHE=1 CCACHE_EXEC; CCACHE_EXEC=$(command -v ccache); fi
# shellcheck source=/dev/null
source build/envsetup.sh >/dev/null || fail "build/envsetup.sh failed"
lunch "$EOS_LUNCH" || fail "lunch $EOS_LUNCH failed"
[[ "$(cd "$(gettop)" && pwd -P)" = "$top" ]] || fail "lunch picked the tree $(gettop), not $top"
[[ "$(get_build_var PRODUCT_OUT)" = "$O" ]] || fail "PRODUCT_OUT is $(get_build_var PRODUCT_OUT), not $O"
ic=$EOS_STATE/installclean
if [[ "${EOS_INSTALLCLEAN:-0}" = 1 || -e $ic ]]; then
    if [[ -e $ic ]]; then why="a modules= compile check installed into $O since the last build"; else why="EOS_INSTALLCLEAN=1"; fi
    echo "== m installclean ($why)"
    m installclean || fail "m installclean failed"
    rm -f -- "$ic" || fail "can't remove $ic"
fi
mkdir -p -- "$O" "$EOS_STATE"
# The build's AB_OTA_PARTITIONS, for the OTA script's payload check
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$O/ab_partitions.txt" \
    || fail "get_build_var AB_OTA_PARTITIONS failed"
grep -qx init_boot "$O/ab_partitions.txt" || fail "AB_OTA_PARTITIONS doesn't list init_boot: $(tr '\n' ' ' < "$O/ab_partitions.txt")"
# Record prebuilt kernel provenance (no kernel built from source in EOS 2.0)
pb=$(get_build_var BOARD_PREBUILT_BOOTIMAGE)
pbsha=
[[ -n $pb && -f $pb ]] && pbsha=$(sha256sum -- "$pb" | cut -d' ' -f1)
echo "<manifest><!-- $EOS_DEVICE: no kernel built from source (EOS_KERNEL=$EOS_KERNEL). The kernel is the tree's prebuilt boot image${pb:+ $pb}${pbsha:+ (sha256 $pbsha)}, Google's stock $EOS_KMI GKI. --></manifest>" \
    > "$EOS_STATE/kernel-manifest.xml" || fail "can't write $EOS_STATE/kernel-manifest.xml"
echo "OK: $EOS_DEVICE's kernel is its tree's prebuilt boot image${pb:+ ($pb)}"

# One date and number for the whole build (and the zip's name)
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -ud "@$BUILD_DATETIME" +%Y%m%d.%H%M%S)}
# Older builds' packages out of the way: after this run, out/ holds only this build's,
# and the target-files zip a full build keeps (vendor/expressiveos/build/tasks/eos.mk) is this build's.
# A quick build leaves none: nothing in out/ can pass for its package
tf=$(tf_zip)
# m eos is m droid (the images) plus the OTA package and its target-files zip
# (vendor/expressiveos/build/tasks/eos.mk)
goal=droid
if [[ $EOS_QUICK != 1 ]]; then
    goal=$(make_goal)
fi
in_top "$top/${tf%/*}"
pkgs() { rm -f -- "$O"/ExpressiveOS-*.zip "$O"/ExpressiveOS-*.zip.sha256sum "$O/$EOS_DEVICE.json" "$tf"; }
pkgs
# The phone whose make ran in this tree before this one, for the make's TIME line (prev=, lib.sh's
# eos_step): a change of phone redoes the steps that depend on the product (API stubs, SystemUI's
# ksp, and SystemUI and Settings when the other side of the HiLight split built last). Written
# before m: a make that stops part way has switched the tree all the same. A modules= compile
# check doesn't write it
lastmake=${EOS_LAST_MAKE:-$HOME/.expressiveos-last-make}
EOS_PREV_DEVICE=$(head -c 32 -- "$lastmake" 2>/dev/null | tr -cd 'a-z0-9-' || true)
EOS_PREV_DEVICE=${EOS_PREV_DEVICE:--}
printf '%s\n' "$EOS_DEVICE" > "$lastmake" 2>/dev/null || true
echo "note: the make before this one in the tree was ${EOS_PREV_DEVICE/#-/unknown}'s"
unset EOS_WILD_BOOT
if [[ $EOS_KSU = wild ]]; then
    # The tree's own boot image (BOARD_PREBUILT_BOOTIMAGE without EOS_WILD_BOOT): Google's GKI,
    # or on cheetah and husky the one build_kernel just made
    sb=$(get_build_var BOARD_PREBUILT_BOOTIMAGE)
    [[ -n $sb && -f $sb ]] || fail "BOARD_PREBUILT_BOOTIMAGE is '$sb', not a file: no stock boot image to build Wild's from"
    "$kit/ksu/tools/wild-boot.sh" build "$sb" "$top" || fail "wild-boot.sh build failed"
    export EOS_WILD_BOOT=$K/boot-wild.img
    [[ "$(get_build_var BOARD_PREBUILT_BOOTIMAGE)" = "$EOS_WILD_BOOT" ]] \
        || fail "the device tree doesn't take EOS_WILD_BOOT as its boot image (run apply-ksu.sh: ksu-patches 0101)"
    echo "== make (Wild boot, stock init_boot): m $goal, BUILD_DATETIME $BUILD_DATETIME"
else
    # No root (EOS_KSU=none): the build's own boot and init_boot ship
    echo "== make (stock boot and init_boot, no root: EOS_KSU=none): m $goal, BUILD_DATETIME $BUILD_DATETIME"
fi
m -j"$(nproc)" "$goal" || fail "make failed"
pass="the build"
zips=()
for z in "$O"/ExpressiveOS-*.zip; do if [[ -f $z ]]; then zips+=("$z"); fi; done
if [[ $EOS_QUICK = 1 ]]; then
    # m droid packages nothing; a package or target-files zip here isn't this build's
    (( ${#zips[@]} == 0 )) || fail "$pass (quick: m droid) left ${zips[*]##*/} in $O, which isn't this build's"
    [[ ! -e $tf ]] || fail "$pass (quick: m droid) left a target-files zip ($tf), which isn't this build's"
else
    [[ ${#zips[@]} = 1 ]] || fail "$pass made no ExpressiveOS package in $O, or more than one"
    # vendor/expressiveos/config/version.mk names it after BUILD_DATETIME's day (UTC)
    want="ExpressiveOS-*-$(date -ud "@$BUILD_DATETIME" +%Y%m%d)-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE.zip"
    # shellcheck disable=SC2053
    [[ ${zips[0]##*/} == $want ]] || fail "$pass made ${zips[0]##*/}, want $want"
    [[ -f $tf ]] || fail "$pass kept no target-files zip ($tf): check vendor/expressiveos/build/tasks/eos.mk"
fi
if [[ $EOS_KSU = wild ]]; then
    "$kit/ksu/tools/ksu-check.sh" images "$top/$O" "$top" || fail "the build didn't ship Wild's boot and the stock init_boot"
    EOS_AVB_BOOT_KEY=$(get_build_var BOARD_AVB_BOOT_KEY_PATH) "$kit/ksu/tools/wild-boot.sh" stock "$top" \
        || fail "wild-boot.sh stock failed"
else
    # The init_boot it ships is the stock one: init, and no kernelsu.ko (an init_boot a KernelSU
    # build left in out/ would show here). Only those two files: its device nodes need root
    (
        t=$(mktemp -d "${TMPDIR:-/tmp}/eos-make.XXXXXX") || fail "can't make a temporary folder"
        trap 'rm -rf -- "$t"' EXIT
        H=out/host/linux-x86/bin
        if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" --boot_img "$O/init_boot.img" --out "$t/ib" >/dev/null
        else python3 -I system/tools/mkbootimg/unpack_bootimg.py --boot_img "$O/init_boot.img" --out "$t/ib" >/dev/null
        fi || fail "can't unpack $O/init_boot.img"
        mkdir -- "$t/r"
        (cd "$t/r" && { lz4 -dc "$t/ib/ramdisk" 2>/dev/null || gzip -dc "$t/ib/ramdisk"; } \
            | cpio -id --quiet --no-absolute-filenames init kernelsu.ko) || fail "can't unpack $O/init_boot.img's ramdisk"
        [[ -e $t/r/init && ! -e $t/r/kernelsu.ko ]] || fail "$O/init_boot.img isn't the stock one (no init, or kernelsu.ko in it), but $EOS_DEVICE has EOS_KSU=none"
    ) || fail "the build didn't ship a stock init_boot"
    echo "OK: $O/init_boot.img is the stock one (no KernelSU: EOS_KSU=none)"
fi
eos_step end
done=1
if [[ $EOS_QUICK = 1 ]]; then
    echo "OK: the images, quick (m droid): no OTA package or target-files zip"
else
    echo "OK: ${zips[0]##*/}"
fi
echo "MAKE_EXIT=0"
