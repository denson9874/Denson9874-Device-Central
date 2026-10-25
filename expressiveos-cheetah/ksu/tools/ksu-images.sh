#!/bin/bash
# The make part of an ExpressiveOS cheetah build with KernelSU Next, after the
# tree's prepare step and apply-ksu.sh: lunch, build_kernel, then two passes.
# Pass 1 builds everything with a stock init_boot; cheetah-ksu.sh patches it;
# pass 2 rebuilds with CHEETAH_KSU_INIT_BOOT (patches/device_google_pantah/0002),
# so only init_boot, target-files and the signed OTA are redone. Prints
# BUILD_EXIT=0|1 as the last line, like the other images scripts.
#
#   ksu-images.sh <lunch target> [top]     # e.g. lineage_cheetah-cp2a-user
#   KERNEL_ONLY=1 ksu-images.sh ...        # stop after build_kernel
here="$(cd "$(dirname "$0")" && pwd)"
target=${1:?usage: ksu-images.sh <lunch target> [top]}
top=${2:-$HOME/expressiveos}
cd "$top" || { echo "BUILD_EXIT=1"; exit 1; }
[ "$(pwd -P)" != "$(cd ~/evolution 2>/dev/null && pwd -P)" ] || { echo "the Evolution X tree isn't rooted"; echo "BUILD_EXIT=1"; exit 1; }
source build/envsetup.sh
lunch "$target" || { echo "BUILD_EXIT=1"; exit 1; }
# The build's AB_OTA_PARTITIONS, for the OTA script's payload check
po=$(get_build_var PRODUCT_OUT); mkdir -p "$po"
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$po/ab_partitions.txt"
build_kernel || { echo "build_kernel failed"; echo "BUILD_EXIT=1"; exit 1; }
if [ "${KERNEL_ONLY:-0}" = 1 ]; then echo "BUILD_EXIT=0"; exit 0; fi
# Both passes must stamp the same build date and number, or pass 2 rebuilds every
# partition whose build.prop changed (and a date read with $(shell date) can roll over)
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -d @$BUILD_DATETIME +%Y%m%d.%H%M%S)}
unset CHEETAH_KSU_INIT_BOOT
m -j"$(nproc)" evolution || { echo "BUILD_EXIT=1"; exit 1; }
"$here/cheetah-ksu.sh" "$top" || { echo "cheetah-ksu.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
export CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img
m -j"$(nproc)" evolution || { echo "BUILD_EXIT=1"; exit 1; }
echo "BUILD_EXIT=0"
