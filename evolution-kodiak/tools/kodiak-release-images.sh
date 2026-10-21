#!/bin/bash
# Images build for PUBLIC releases: the official tree only. No personal
# extras (KODIAK_PERSONAL), and pack with KODIAK_ROOT=none so it isn't rooted.
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m -j"$(nproc)" evolution   # images plus the signed A/B OTA package (p11-ota.sh)
echo "BUILD_EXIT=$?"
