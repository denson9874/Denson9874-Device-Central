#!/bin/bash
# Images build for cubs (Pixel 11): user variant, unrooted, no extras.
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
unset KODIAK_PERSONAL
source build/envsetup.sh
lunch lineage_cubs-cp2a-user
m -j"$(nproc)"
echo "BUILD_EXIT=$?"
