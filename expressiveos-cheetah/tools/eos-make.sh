#!/usr/bin/env bash
# The make part of an ExpressiveOS build of a phone (EOS_DEVICE, cheetah unless set;
# devices/<device>.conf). tools/eos-images.sh runs it after prepare.sh, the key checks and
# the kits; run alone, it builds what the tree already has: lunch, build_kernel on a phone
# that builds its kernel (EOS_KERNEL=gs-6.1: cheetah, husky), then one make pass, which must
# ship the stock init_boot (no root: ExpressiveOS ships none) and keep its target-files zip
# (tf_zip in lib.sh). Every phone gets EOS_PRODUCT_OUT's ab_partitions.txt. A quick build
# (EOS_QUICK=1, lib.sh) runs m droid where a full one runs m bacon: the same images, and
# no OTA package or target-files zip, which it then must not leave in out/ either. The last
# line is MAKE_EXIT=0 or MAKE_EXIT=1.
#
#   eos-make.sh [top]                    # default ~/expressiveos; lunch target EOS_LUNCH (devices/<device>.conf)
#   KERNEL_ONLY=1 eos-make.sh [top]      # stop after build_kernel (nothing to
#                                        # build for a phone with a prebuilt kernel)
#   EOS_INSTALLCLEAN=1 eos-make.sh       # start with m installclean (a modules= compile check
#                                        # asks the next build that makes images, full or
#                                        # quick, for it itself)
#   EOS_QUICK=1 eos-make.sh              # images only: m droid, no OTA package or target-files
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

# eos_step (lib.sh): with EOS_KERNEL=gs-6.1 the kernel step is the kernel source's sync and
# check, lunch, build_kernel (and an m installclean); then the make, lunch's on the other phones
if [[ $EOS_KERNEL = gs-6.1 ]]; then
    eos_step kernel
    # Before lunch, which runs build_kernel
    kernel_pinned
elif [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    echo "KERNEL_ONLY=1: $EOS_DEVICE builds no kernel (EOS_KERNEL=$EOS_KERNEL: its tree's prebuilt boot image): nothing to build"
    done=1; echo "MAKE_EXIT=0"; exit 0
else
    eos_step make
fi
# The build type under its 1.1 name, and its old one, which a tree from before 1.1 reads
# (vendor/lineage's version.mk takes EVO_BUILD_TYPE when only it is set, through 1.1)
export EXPRESSIVE_BUILD_TYPE=$EOS_BUILD_TYPE EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
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
# marker for the next build that makes images (full or quick)
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
    for b in "$top"/device/google/*-kernels/*/boot.img; do
        [[ -f $b ]] || continue
        t=$(mktemp -d "${TMPDIR:-/tmp}/boot_patch.XXXXXX")
        if python3 "$top/system/tools/mkbootimg/unpack_bootimg.py" --boot_img "$b" --out "$t" >/dev/null 2>&1; then
            out=$(python3 "$top/system/tools/mkbootimg/unpack_bootimg.py" --boot_img "$b" --out "$t")
            if echo "$out" | grep -q 'os patch level: None'; then
                echo "Patching boot.img header os_patch_level for ${b#"$top"/}"
                python3 "$top/system/tools/mkbootimg/mkbootimg.py" \
                    --header_version 4 \
                    --kernel "$t/kernel" \
                    --os_version 14.0.0 \
                    --os_patch_level 2026-10 \
                    -o "$b" || echo "WARNING: failed to repack $b"
            fi
        fi
        rm -rf -- "$t"
    done
else
    # No kernel source to name: the record says what the kernel is instead, so the records
    # are the same set for every phone
    pb=$(get_build_var BOARD_PREBUILT_BOOTIMAGE)
    pbsha=
    [[ -n $pb && -f $pb ]] && pbsha=$(sha256sum -- "$pb" | cut -d' ' -f1)
    echo "<manifest><!-- $EOS_DEVICE: no kernel built from source (EOS_KERNEL=$EOS_KERNEL). The kernel is the tree's prebuilt boot image${pb:+ $pb}${pbsha:+ (sha256 $pbsha)}, Google's stock $EOS_KMI GKI. --></manifest>" \
        > "$EOS_STATE/kernel-manifest.xml" || fail "can't write $EOS_STATE/kernel-manifest.xml"
    echo "OK: $EOS_DEVICE's kernel is its tree's prebuilt boot image${pb:+ ($pb)}; nothing kernel-related to build"
fi
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then eos_step end; done=1; echo "MAKE_EXIT=0"; exit 0; fi

eos_step make
# One build date and number for the whole build: the zip's name and every build.prop take them
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -ud "@$BUILD_DATETIME" +%Y%m%d.%H%M%S)}
# Older builds' packages out of the way: after this run, out/ holds only this build's,
# and the target-files zip a full build keeps (patches/vendor_lineage/0003) is this build's.
# A quick build leaves none: nothing in out/ can pass for its package
tf=$(tf_zip)
# m bacon is m droid (the images) plus the OTA package and its target-files zip
# (vendor/lineage's build/tasks/bacon.mk: bacon: <package> $(DEFAULT_GOAL)). A tree from
# before 1.1 has the same goal as evolution only (lib.sh's make_goal)
goal=droid
if [[ $EOS_QUICK != 1 ]]; then
    goal=$(make_goal)
    [[ $goal = bacon ]] || echo "note: vendor/lineage has no bacon goal (a tree from before 1.1): building the package with m $goal, its old name"
fi
in_top "$top/${tf%/*}"
pkgs() { rm -f -- "$O"/ExpressiveOS-*.zip "$O"/ExpressiveOS-*.zip.sha256sum "$O/$EOS_DEVICE.json" "$tf"; }
pkgs
echo "== make: m $goal, BUILD_DATETIME $BUILD_DATETIME"
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
    # patches/vendor_lineage/0001 names it after BUILD_DATETIME's day (UTC)
    want="ExpressiveOS-*-$(date -ud "@$BUILD_DATETIME" +%Y%m%d)-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE.zip"
    # shellcheck disable=SC2053
    [[ ${zips[0]##*/} == $want ]] || fail "$pass made ${zips[0]##*/}, want $want"
    [[ -f $tf ]] || fail "$pass kept no target-files zip ($tf): is patches/vendor_lineage/0003 in vendor/lineage?"
fi
# The init_boot it ships is the stock one: init, and no kernelsu.ko (an init_boot an older
# rooted build left in out/ would show here). Only those two files: its device nodes need root
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
    [[ -e $t/r/init && ! -e $t/r/kernelsu.ko ]] || fail "$O/init_boot.img isn't the stock one (no init, or kernelsu.ko in it): ExpressiveOS ships no root"
) || fail "the build didn't ship a stock init_boot"
echo "OK: $O/init_boot.img is the stock one (no root)"
eos_step end
done=1
if [[ $EOS_QUICK = 1 ]]; then
    echo "OK: the images, quick (m droid): no OTA package or target-files zip"
else
    echo "OK: ${zips[0]##*/}"
fi
echo "MAKE_EXIT=0"
