#!/bin/bash
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m evolution -j16
echo "BUILD_EXIT=$?"
