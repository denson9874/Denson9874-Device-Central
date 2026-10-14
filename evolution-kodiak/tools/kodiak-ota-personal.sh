#!/bin/bash
# Personal test build plus the signed A/B OTA package (m evolution): out/.../EvolutionX-*.zip and kodiak.json.
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
export KODIAK_PERSONAL=true
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m -j"$(nproc)" evolution
echo "BUILD_EXIT=$?"
