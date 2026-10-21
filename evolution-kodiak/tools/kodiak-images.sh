#!/bin/bash
# Images-only build with the current configuration (user, dexpreopt on).
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
# Test builds carry the maintainer's private extras (device/google/kodiak-personal).
export KODIAK_PERSONAL=true
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m -j"$(nproc)"
echo "BUILD_EXIT=$?"
