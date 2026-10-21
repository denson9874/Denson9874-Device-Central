#!/bin/bash
# Rebuild only vbmeta.img with the current configuration (user, same as kodiak-images.sh).
cd ~/evolution
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m -j"$(nproc)" vbmetaimage
echo "BUILD_EXIT=$?"
