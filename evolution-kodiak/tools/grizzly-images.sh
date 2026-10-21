#!/bin/bash
# Images build for grizzly (Pixel 11 Pro): user variant, unrooted, no extras.
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
source build/envsetup.sh
lunch lineage_grizzly-cp2a-user
m -j"$(nproc)" evolution   # images plus the signed A/B OTA package (p11-ota.sh)
echo "BUILD_EXIT=$?"
