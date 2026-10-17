#!/bin/bash
# Images + signed A/B OTA build for cheetah (Pixel 7 Pro): Evolution X's own trees,
# our two patches and the newest cached Google firmware (~/evolution-cheetah/prepare.sh).
# The kernel is built from LineageOS's gs201 kernel source by build_kernel (the first
# run syncs it into out-kernel/, later runs are incremental).
#   KERNEL_ONLY=1 cheetah-images.sh   # stop after build_kernel
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
~/evolution-cheetah/prepare.sh ~/evolution || { echo "prepare.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
source build/envsetup.sh
lunch lineage_cheetah-cp2a-user || { echo "BUILD_EXIT=1"; exit 1; }
build_kernel || { echo "build_kernel failed"; echo "BUILD_EXIT=1"; exit 1; }
if [ "${KERNEL_ONLY:-0}" = 1 ]; then echo "BUILD_EXIT=0"; exit 0; fi
m -j"$(nproc)" evolution   # images plus the signed A/B OTA package (p11-ota.sh)
echo "BUILD_EXIT=$?"
