#!/bin/bash
# Images + signed A/B OTA build for husky (Pixel 8 Pro): LineageOS's trees, TheMuppets' blobs
# and our patches (~/evolution-husky/apply.sh). The kernel is built from LineageOS's zuma kernel
# source by build_kernel (the first run syncs it into out-kernel/, later runs are incremental).
# The routine (p11-routine.sh husky) takes the tree lock and applies the shared patches first.
#   KERNEL_ONLY=1 husky-images.sh   # stop after build_kernel
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
~/evolution-husky/apply.sh ~/evolution || { echo "apply.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
source build/envsetup.sh
lunch lineage_husky-cp2a-user || { echo "BUILD_EXIT=1"; exit 1; }
# The build's AB_OTA_PARTITIONS, for p11-ota.sh's payload check
po=$(get_build_var PRODUCT_OUT); mkdir -p "$po"
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$po/ab_partitions.txt"
build_kernel || { echo "build_kernel failed"; echo "BUILD_EXIT=1"; exit 1; }
if [ "${KERNEL_ONLY:-0}" = 1 ]; then echo "BUILD_EXIT=0"; exit 0; fi
m -j"$(nproc)" evolution   # images plus the signed A/B OTA package (p11-ota.sh)
echo "BUILD_EXIT=$?"
