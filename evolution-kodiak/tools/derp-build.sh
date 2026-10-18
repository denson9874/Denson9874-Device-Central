#!/bin/bash
set -uo pipefail

cd ~/derpfest
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export DERPFEST_BUILD_TYPE=Unofficial
export BUILD_USERNAME=android-build
export BUILD_HOSTNAME=voltage-build

source build/envsetup.sh
lunch lineage_kodiak-cp2a-user

echo "=== DerpFest Build Started: $(date) ==="
m -j$(nproc) derp 2>&1 | tee ~/derp-build.log
BUILD_EXIT=${PIPESTATUS[0]}
echo "=== DerpFest Build Finished: $(date) (EXIT=$BUILD_EXIT) ==="

if [ "$BUILD_EXIT" -eq 0 ]; then
    echo "=== Packaging Fastboot Update ZIP ==="
    KODIAK_ROOT=none ~/kodiak-imgzip.sh /home/build/derpfest/out/target/product/kodiak \
        ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip \
        /home/build/derpfest/out/target/product/kodiak/DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip || true

    echo "=== Uploading build to Google Drive: DerpFest/kodiak ==="
    ~/upload-to-drive.sh DerpFest kodiak \
        /home/build/derpfest/out/target/product/kodiak/DerpFest-v17*.zip \
        /home/build/derpfest/out/target/product/kodiak/DerpFest-v17*.sha* \
        /home/build/derpfest/out/target/product/kodiak/kodiak.json || true
fi

exit $BUILD_EXIT
