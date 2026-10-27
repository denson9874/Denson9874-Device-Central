#!/bin/bash
# Images + signed A/B OTA build for husky (Pixel 8 Pro): LineageOS's trees, TheMuppets' blobs
# and our patches (~/evolution-husky/apply.sh). The kernel is built from LineageOS's zuma kernel
# source by build_kernel, which lunch runs: it syncs the source into out-kernel/ (once per build)
# and builds it incrementally.
# The routine (p11-routine.sh husky) takes the tree lock and applies the shared patches first.
#   KERNEL_ONLY=1 husky-images.sh   # stop after build_kernel
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
~/evolution-husky/apply.sh ~/evolution || { echo "apply.sh failed"; echo "BUILD_EXIT=1"; exit 1; }
source build/envsetup.sh
# lunch runs build_kernel itself and ignores its result: keep that one (it reads lunch's cached
# build variables) and check it, rather than syncing and building the kernel again after lunch.
declare -F build_kernel >/dev/null || { echo "envsetup.sh defines no build_kernel"; echo "BUILD_EXIT=1"; exit 1; }
eval "$(declare -f build_kernel | sed '1s/^build_kernel /evo_build_kernel /')"
KERNEL_RC=none
build_kernel() { evo_build_kernel "$@"; KERNEL_RC=$?; return $KERNEL_RC; }
lunch lineage_husky-cp2a-user || { echo "BUILD_EXIT=1"; exit 1; }
# The build's AB_OTA_PARTITIONS, for p11-ota.sh's payload check
po=$(get_build_var PRODUCT_OUT); mkdir -p "$po"
get_build_var AB_OTA_PARTITIONS | tr ' ' '\n' | sed '/^$/d' > "$po/ab_partitions.txt"
# A lunch that didn't build the kernel (it only does for a TARGET_KERNEL_PLATFORM_SOURCE) leaves it to us
[ "$KERNEL_RC" != none ] || build_kernel
[ "$KERNEL_RC" = 0 ] || { echo "build_kernel failed"; echo "BUILD_EXIT=1"; exit 1; }
if [ "${KERNEL_ONLY:-0}" = 1 ]; then echo "BUILD_EXIT=0"; exit 0; fi
m -j"$(nproc)" evolution   # images plus the signed A/B OTA package (p11-ota.sh)
echo "BUILD_EXIT=$?"
