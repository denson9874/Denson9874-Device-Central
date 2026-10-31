#!/usr/bin/env bash
# The make part of an ExpressiveOS build of a phone (EOS_DEVICE, cheetah unless set;
# devices/<device>.conf). tools/eos-images.sh runs it after prepare.sh, the key checks and
# the kits; run alone, it builds what the tree already has. With KernelSU Next (EOS_KSU=lkm:
# every phone): lunch, build_kernel (a phone with Google's prebuilt kernel has none to build),
# our kernelsu.ko (ksu-module.sh), then two passes:
# pass 1 builds only the images cheetah-ksu.sh reads (boot, init_boot and
# vendor_kernel_boot, whose ramdisk holds the first-stage modules; on a phone with a prebuilt
# kernel that's the factory image's, a radio file copied into the product out) with the stock
# init_boot, cheetah-ksu.sh patches that init_boot, and pass 2 builds everything with
# CHEETAH_KSU_INIT_BOOT (patches/device_google_pantah/0102; EOS_KSU_INIT_BOOT on the other
# phones, their devices/<device>/ksu-patches/ 0102). Pass 2 must ship the patched init_boot
# (ksu-check.sh images) and keep its target-files zip (tf_zip in lib.sh). Without KernelSU
# Next (EOS_KSU=none): lunch and one make pass, which must ship the stock
# init_boot and keep its target-files zip too. Every phone gets EOS_PRODUCT_OUT's
# ab_partitions.txt. The last line is MAKE_EXIT=0 or MAKE_EXIT=1.
#
#   ksu-images.sh [top]                  # default ~/expressiveos; lunch target EOS_LUNCH (devices/<device>.conf)
#   KERNEL_ONLY=1 ksu-images.sh [top]    # stop after build_kernel and kernelsu.ko (only
#                                        # kernelsu.ko for a phone with a prebuilt kernel)
#   EOS_INSTALLCLEAN=1 ksu-images.sh     # start with m installclean (a modules= compile check
#                                        # asks the next full build for it itself)
#
# The kernel (EOS_KERNEL=gs-6.1) source is pins/kernel.xml's (kernel_pinned in lib.sh): synced
# to those commits when out-kernel/ has none yet or EOS_KERNEL_SYNC=1, checked against them
# otherwise, and build_kernel (lunch runs it too) never syncs it itself (SKIP_KERNEL_SYNC=1).
# Saves the kernel tree's repo manifest -r to EOS_STATE/kernel-manifest.xml (GPL source;
# out/eos/ for cheetah). A phone with EOS_KERNEL=prebuilt builds no kernel: its
# kernel-manifest.xml only says the kernel is its tree's prebuilt boot image.
# Not -e or -u: envsetup.sh and its functions rely on neither; every step is checked
set -o pipefail
done=0
# Quiet while run_locked's marker is there: the run waiting for the locks prints it then
trap '[[ $done = 1 || -e "${EOS_STARTED:-}" ]] || echo "MAKE_EXIT=1"' EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../../lib.sh
source "$here/../lib.sh"
[[ $# -le 1 ]] || fail "usage: ksu-images.sh [top]"
eos_top "${1:-}"
# Run alone, this runs again under eos_lock (the locks eos-images.sh holds) and exits with it
run_locked MAKE_EXIT=1 "$0" "$top"
# A TOP or OUT exported for another tree would send envsetup, lunch and m there
clean_env
cd "$top" || fail "can't cd to $top"
PATH=$HOME/bin:$PATH
O=$EOS_PRODUCT_OUT
K=$EOS_KSU_OUT

# The KernelSU Next pieces apply-ksu.sh puts in: the phone's device tree patches (cheetah's in
# ../patches/, another phone's in devices/<device>/ksu-patches/) and vendor/extra/ksu
if [[ $EOS_KSU = lkm ]]; then
    if [[ $EOS_DEVICE = cheetah ]]; then
        kdirs=("$here"/patches/device_google_pantah/)
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
    (( n > 0 )) || fail "no KernelSU Next device tree patches for $EOS_DEVICE (devices/$EOS_DEVICE/ksu-patches/)"
    [[ -f vendor/extra/ksu/Android.mk ]] || fail "no vendor/extra/ksu/Android.mk (run apply-ksu.sh)"
fi

if [[ $EOS_KERNEL = gs-6.1 ]]; then
    # Before lunch, which runs build_kernel
    kernel_pinned
elif [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    # No kernel to build (EOS_KERNEL=prebuilt), and kernelsu.ko builds with the DDK, without lunch
    if [[ $EOS_KSU = lkm ]]; then
        "$here/tools/ksu-module.sh" "$top" || fail "ksu-module.sh failed"
        echo "KERNEL_ONLY=1: $EOS_DEVICE builds no kernel (EOS_KERNEL=$EOS_KERNEL: its tree's prebuilt boot image), only kernelsu.ko"
    else
        echo "KERNEL_ONLY=1: $EOS_DEVICE builds no kernel (EOS_KERNEL=$EOS_KERNEL: its tree's prebuilt boot image) and no kernelsu.ko (EOS_KSU=$EOS_KSU): nothing to build"
    fi
    done=1; echo "MAKE_EXIT=0"; exit 0
fi
export EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
if command -v ccache >/dev/null; then export USE_CCACHE=1 CCACHE_EXEC; CCACHE_EXEC=$(command -v ccache); fi
# shellcheck source=/dev/null
source build/envsetup.sh >/dev/null || fail "build/envsetup.sh failed"
lunch "$EOS_LUNCH" || fail "lunch $EOS_LUNCH failed"
[[ "$(cd "$(gettop)" && pwd -P)" = "$top" ]] || fail "lunch picked the tree $(gettop), not $top"
[[ "$(get_build_var PRODUCT_OUT)" = "$O" ]] || fail "PRODUCT_OUT is $(get_build_var PRODUCT_OUT), not $O"
# m never takes away what the product doesn't install: a modules= compile check (the runner's
# build-modules.sh) can leave a module the product overrides in the product out (Settings,
# beside SettingsGoogle). The partition images take only the product's own file list, but
# eos-verify.sh reads the product out and the target-files zip copies all of it. So
# build-modules.sh writes <EOS_STATE>/installclean, and then (or with EOS_INSTALLCLEAN=1) the
# build starts from m installclean: the product out's partitions, images and packaging go, the
# intermediates stay. Before this script writes anything to $O; a kernel-only run leaves the
# marker for the next full build
ic=$EOS_STATE/installclean
if [[ "${KERNEL_ONLY:-0}" != 1 && ( "${EOS_INSTALLCLEAN:-0}" = 1 || -e $ic ) ]]; then
    if [[ -e $ic ]]; then why="a modules= compile check installed into $O since the last build"; else why="EOS_INSTALLCLEAN=1"; fi
    echo "== m installclean ($why)"
    m installclean || fail "m installclean failed"
    rm -f -- "$ic" || fail "can't remove $ic"
fi
kt=out-kernel/google/gs-6.1
mkdir -p -- "$O" "$EOS_STATE"
# The build's AB_OTA_PARTITIONS, for the OTA script's payload check
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$O/ab_partitions.txt" \
    || fail "get_build_var AB_OTA_PARTITIONS failed"
grep -qx init_boot "$O/ab_partitions.txt" || fail "AB_OTA_PARTITIONS doesn't list init_boot: $(tr '\n' ' ' < "$O/ab_partitions.txt")"
if [[ $EOS_KERNEL = gs-6.1 ]]; then
    build_kernel || fail "build_kernel failed"
    [[ -d $kt/.repo ]] || fail "no $kt/.repo: build_kernel didn't sync the kernel source there"
    (cd "$kt" && repo manifest -r -o "$top/$EOS_STATE/kernel-manifest.xml") || fail "can't save the kernel source's manifest"
else
    # No kernel source to name: the record says what the kernel is instead, so the records
    # are the same set for every phone
    pb=$(get_build_var BOARD_PREBUILT_BOOTIMAGE)
    pbsha=
    [[ -n $pb && -f $pb ]] && pbsha=$(sha256sum -- "$pb" | cut -d' ' -f1)
    echo "<manifest><!-- $EOS_DEVICE: no kernel built from source (EOS_KERNEL=$EOS_KERNEL). The kernel is the tree's prebuilt boot image${pb:+ $pb}${pbsha:+ (sha256 $pbsha)}, Google's stock $EOS_KMI GKI. --></manifest>" \
        > "$EOS_STATE/kernel-manifest.xml" || fail "can't write $EOS_STATE/kernel-manifest.xml"
    echo "OK: $EOS_DEVICE's kernel is its tree's prebuilt boot image${pb:+ ($pb)}: no kernel to build"
fi
if [[ $EOS_KSU = lkm ]]; then
    "$here/tools/ksu-module.sh" "$top" || fail "ksu-module.sh failed"
fi
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then done=1; echo "MAKE_EXIT=0"; exit 0; fi

# Both passes must stamp the same build date and number, or pass 2 rebuilds every
# partition whose build.prop changed (and names another zip after midnight)
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -ud "@$BUILD_DATETIME" +%Y%m%d.%H%M%S)}
# Older builds' packages out of the way: after this run, out/ holds only this build's,
# and the target-files zip m evolution keeps (patches/vendor_lineage/0003) is this build's
tf=$(tf_zip)
in_top "$top/${tf%/*}"
pkgs() { rm -f -- "$O"/ExpressiveOS-*.zip "$O"/ExpressiveOS-*.zip.sha256sum "$O/$EOS_DEVICE.json" "$tf"; }
pkgs
# Both names: the one the device tree's 0102 reads is EOS_KSU_INIT_BOOT_VAR (lib.sh)
unset CHEETAH_KSU_INIT_BOOT EOS_KSU_INIT_BOOT
if [[ $EOS_KSU = lkm ]]; then
    rm -f -- "$K/init_boot-ksu.img" "$K/init_boot-stock.img"
    echo "== make pass 1 (stock init_boot), BUILD_DATETIME $BUILD_DATETIME"
    # Only what cheetah-ksu.sh reads, not all of evolution: CHEETAH_KSU_INIT_BOOT changes the
    # board config, so pass 2 runs Soong and Kati again and packages everything anyway. A full
    # pass 1 only added a second packaging run and an OTA zip (about 5 minutes) to throw away.
    # A prebuilt kernel's vendor_kernel_boot is a radio file (its tree's -images Android.mk),
    # which no image goal copies in: asked for by its path, it is, and is the current one
    vkb=()
    [[ $EOS_KERNEL != prebuilt ]] || vkb=("$O/vendor_kernel_boot.img")
    m -j"$(nproc)" bootimage initbootimage vendorkernelbootimage "${vkb[@]}" || fail "make pass 1 failed"
    "$here/tools/cheetah-ksu.sh" "$top" || fail "cheetah-ksu.sh failed"
    export "$EOS_KSU_INIT_BOOT_VAR=$K/init_boot-ksu.img"
    echo "== make pass 2 (KernelSU Next init_boot)"
    m -j"$(nproc)" evolution || fail "make pass 2 failed"
    pass="pass 2"
else
    # No KernelSU Next (EOS_KSU=none): one pass, the build's own init_boot ships
    echo "== make (stock init_boot, no KernelSU: EOS_KSU=none), BUILD_DATETIME $BUILD_DATETIME"
    m -j"$(nproc)" evolution || fail "make failed"
    pass="the build"
fi
zips=("$O"/ExpressiveOS-*.zip)
[[ ${#zips[@]} = 1 && -f ${zips[0]} ]] || fail "$pass made no ExpressiveOS package in $O, or more than one"
# patches/vendor_lineage/0001 names it after BUILD_DATETIME's day (UTC)
want="ExpressiveOS-*-$(date -ud "@$BUILD_DATETIME" +%Y%m%d)-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE.zip"
# shellcheck disable=SC2053
[[ ${zips[0]##*/} == $want ]] || fail "$pass made ${zips[0]##*/}, want $want"
[[ -f $tf ]] || fail "$pass kept no target-files zip ($tf): is patches/vendor_lineage/0003 in vendor/lineage?"
if [[ $EOS_KSU = lkm ]]; then
    "$here/tools/ksu-check.sh" images "$top/$O" "$top" || fail "pass 2 didn't ship the KernelSU Next init_boot"
else
    # The init_boot it ships is the stock one: init, and no kernelsu.ko (an init_boot a KernelSU
    # build left in out/ would show here). Only those two files: its device nodes need root
    (
        t=$(mktemp -d "${TMPDIR:-/tmp}/ksu-images.XXXXXX") || fail "can't make a temporary folder"
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
done=1
echo "OK: ${zips[0]##*/}"
echo "MAKE_EXIT=0"
