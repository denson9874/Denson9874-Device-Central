#!/bin/bash
# Images + signed A/B OTA build for cheetah (Pixel 7 Pro): Evolution X's own trees,
# our patches and the newest cached Google firmware (~/evolution-cheetah/prepare.sh),
# built twice: the second pass ships the first pass's init_boot patched with
# KernelSU Next (cheetah-ksu.sh), so the images and the OTA are rooted.
# The kernel is built from LineageOS's gs201 kernel source by build_kernel (the first
# run syncs it into out-kernel/, later runs are incremental).
#   KERNEL_ONLY=1 cheetah-images.sh   # stop after build_kernel
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
~/evolution-cheetah/prepare.sh ~/evolution || { echo "prepare.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
source build/envsetup.sh
lunch lineage_cheetah-cp2a-user || { echo "BUILD_EXIT=1"; exit 1; }
# The build's AB_OTA_PARTITIONS, for p11-ota.sh's payload check
po=$(get_build_var PRODUCT_OUT); mkdir -p "$po"
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$po/ab_partitions.txt"
build_kernel || { echo "build_kernel failed"; echo "BUILD_EXIT=1"; exit 1; }
if [ "${KERNEL_ONLY:-0}" = 1 ]; then echo "BUILD_EXIT=0"; exit 0; fi
# Both passes must stamp the same build date and number, or pass 2 rebuilds every
# partition whose build.prop changed
export BUILD_DATETIME=${BUILD_DATETIME:-$(date +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-eng.$(whoami).$(date -d @$BUILD_DATETIME +%Y%m%d.%H%M%S)}
# Pass 1: images and OTA with a stock init_boot, which cheetah-ksu.sh patches
unset CHEETAH_KSU_INIT_BOOT
m -j"$(nproc)" evolution || { echo "BUILD_EXIT=1"; exit 1; }
~/evolution-cheetah/tools/cheetah-ksu.sh || { echo "cheetah-ksu.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
# Pass 2: the same build with the KernelSU Next init_boot (device/google/pantah 0011);
# only init_boot, target-files and the signed A/B OTA package (p11-ota.sh) are redone
export CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img
m -j"$(nproc)" evolution || { echo "BUILD_EXIT=1"; exit 1; }
echo "BUILD_EXIT=0"
