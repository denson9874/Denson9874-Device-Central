#!/usr/bin/env bash
# The make part of an ExpressiveOS cheetah build with KernelSU Next. tools/eos-images.sh
# runs it after prepare.sh, the key checks and the kits; run alone, it builds what the
# tree already has. lunch, build_kernel, our kernelsu.ko (ksu-module.sh), then two passes:
# pass 1 builds only the images cheetah-ksu.sh reads (boot, init_boot and
# vendor_kernel_boot, whose ramdisk holds the first-stage modules) with the stock
# init_boot, cheetah-ksu.sh patches that init_boot, and pass 2 builds everything with
# CHEETAH_KSU_INIT_BOOT (patches/device_google_pantah/0102). Pass 2 must ship the
# patched init_boot (ksu-check.sh images) and keep its target-files zip (tf_zip in lib.sh).
# The last line is MAKE_EXIT=0 or MAKE_EXIT=1.
#
#   ksu-images.sh [top]                  # default ~/expressiveos; lunch target EOS_LUNCH (eos.conf)
#   KERNEL_ONLY=1 ksu-images.sh [top]    # stop after build_kernel and kernelsu.ko
#
# The kernel source is pins/kernel.xml's (kernel_pinned in lib.sh): synced to those commits
# when out-kernel/ has none yet or EOS_KERNEL_SYNC=1, checked against them otherwise, and
# build_kernel (lunch runs it too) never syncs it itself (SKIP_KERNEL_SYNC=1).
# Saves the kernel tree's repo manifest -r to out/eos/kernel-manifest.xml (GPL source).
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
O=out/target/product/cheetah

# The KernelSU Next pieces apply-ksu.sh puts in
pantah=$top/device/google/pantah
for p in "$here"/patches/device_google_pantah/*.patch; do
    s=$(subject_of "$p")
    has_subject "$pantah" "$s" || fail "device/google/pantah lacks '$s' (run apply-ksu.sh)"
done
[[ -f vendor/extra/ksu/Android.mk ]] || fail "no vendor/extra/ksu/Android.mk (run apply-ksu.sh)"

# Before lunch, which runs build_kernel
kernel_pinned
export EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
if command -v ccache >/dev/null; then export USE_CCACHE=1 CCACHE_EXEC; CCACHE_EXEC=$(command -v ccache); fi
# shellcheck source=/dev/null
source build/envsetup.sh >/dev/null || fail "build/envsetup.sh failed"
lunch "$EOS_LUNCH" || fail "lunch $EOS_LUNCH failed"
[[ "$(cd "$(gettop)" && pwd -P)" = "$top" ]] || fail "lunch picked the tree $(gettop), not $top"
[[ "$(get_build_var PRODUCT_OUT)" = "$O" ]] || fail "PRODUCT_OUT is $(get_build_var PRODUCT_OUT), not $O"
kt=out-kernel/google/gs-6.1
mkdir -p -- "$O" out/eos
# The build's AB_OTA_PARTITIONS, for the OTA script's payload check
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$O/ab_partitions.txt" \
    || fail "get_build_var AB_OTA_PARTITIONS failed"
grep -qx init_boot "$O/ab_partitions.txt" || fail "AB_OTA_PARTITIONS doesn't list init_boot: $(tr '\n' ' ' < "$O/ab_partitions.txt")"
build_kernel || fail "build_kernel failed"
[[ -d $kt/.repo ]] || fail "no $kt/.repo: build_kernel didn't sync the kernel source there"
(cd "$kt" && repo manifest -r -o "$top/out/eos/kernel-manifest.xml") || fail "can't save the kernel source's manifest"
"$here/tools/ksu-module.sh" "$top" || fail "ksu-module.sh failed"
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then done=1; echo "MAKE_EXIT=0"; exit 0; fi

# Both passes must stamp the same build date and number, or pass 2 rebuilds every
# partition whose build.prop changed (and names another zip after midnight)
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -ud "@$BUILD_DATETIME" +%Y%m%d.%H%M%S)}
# Older builds' packages out of the way: after this run, out/ holds only this build's,
# and the target-files zip m evolution keeps (patches/vendor_lineage/0003) is this build's
tf=$(tf_zip)
in_top "$top/${tf%/*}"
pkgs() { rm -f -- "$O"/ExpressiveOS-*.zip "$O"/ExpressiveOS-*.zip.sha256sum "$O/cheetah.json" "$tf"; }
pkgs
rm -f -- out/ksu/init_boot-ksu.img out/ksu/init_boot-stock.img
unset CHEETAH_KSU_INIT_BOOT
echo "== make pass 1 (stock init_boot), BUILD_DATETIME $BUILD_DATETIME"
# Only what cheetah-ksu.sh reads, not all of evolution: CHEETAH_KSU_INIT_BOOT changes the
# board config, so pass 2 runs Soong and Kati again and packages everything anyway. A full
# pass 1 only added a second packaging run and an OTA zip (about 5 minutes) to throw away.
m -j"$(nproc)" bootimage initbootimage vendorkernelbootimage || fail "make pass 1 failed"
"$here/tools/cheetah-ksu.sh" "$top" || fail "cheetah-ksu.sh failed"
export CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img
echo "== make pass 2 (KernelSU Next init_boot)"
m -j"$(nproc)" evolution || fail "make pass 2 failed"
zips=("$O"/ExpressiveOS-*.zip)
[[ ${#zips[@]} = 1 && -f ${zips[0]} ]] || fail "pass 2 made no ExpressiveOS package in $O, or more than one"
# patches/vendor_lineage/0001 names it after BUILD_DATETIME's day (UTC)
want="ExpressiveOS-*-$(date -ud "@$BUILD_DATETIME" +%Y%m%d)-cheetah-$EOS_VERSION-$EOS_BUILD_TYPE.zip"
# shellcheck disable=SC2053
[[ ${zips[0]##*/} == $want ]] || fail "pass 2 made ${zips[0]##*/}, want $want"
[[ -f $tf ]] || fail "pass 2 kept no target-files zip ($tf): is patches/vendor_lineage/0003 in vendor/lineage?"
"$here/tools/ksu-check.sh" images "$top/$O" "$top" || fail "pass 2 didn't ship the KernelSU Next init_boot"
done=1
echo "OK: ${zips[0]##*/}"
echo "MAKE_EXIT=0"
