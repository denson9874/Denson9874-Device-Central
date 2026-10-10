#!/bin/bash
# Fast test build for kodiak: images only (no OTA zip) and no dexpreopt.
# The first boot after flashing is slower (apps compile on the device).
# Release builds use `m evolution` with dexpreopt on.
#
#   kodiak-test-build.sh [evolution-top]   (defaults to ~/evolution)
cd "${1:-$HOME/evolution}" || exit 1
export EVO_BUILD_TYPE=Unofficial USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
export WITH_DEXPREOPT=false
source build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m -j"$(nproc)"
echo "BUILD_EXIT=$?"
