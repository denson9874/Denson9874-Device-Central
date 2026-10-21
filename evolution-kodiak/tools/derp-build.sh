#!/bin/bash
# Build DerpFest for kodiak in ~/derpfest, pack the fastboot zip, and copy the release files to Google Drive
# (gdrive:DerpFest/kodiak, through ~/upload-to-drive.sh).
#
#   derp-build.sh [--no-upload] [--check-only]
#
#   --no-upload   build and pack, but copy nothing to Drive (test builds: the release notes point users there)
#   --check-only  only run check_extras on the existing out/; no lunch, no build
#
# check_extras makes sure the vendor/extra apps (BCR, see DERP_BCR_PLAN.md) are in the image and unmodified.
# If they aren't, nothing is packed or uploaded and the exit status is 3 (4: no OTA zip after the build). The
# fastboot zip and the upload use the date in this build's OTA zip name. The last line of a build is
# "=== DerpFest Build Finished: <date> (EXIT=<n>) ===".
set -uo pipefail

NOUPLOAD=0; CHECKONLY=0
while [ $# -gt 0 ]; do
    case $1 in
        --no-upload) NOUPLOAD=1 ;;
        --check-only) CHECKONLY=1 ;;
        *) echo "usage: derp-build.sh [--no-upload] [--check-only]" >&2; exit 2 ;;
    esac
    shift
done

TREE=$HOME/derpfest
O=$TREE/out/target/product/kodiak
BCR=$TREE/vendor/extra/bcr

# BCR must be installed exactly as bcr-fetch.sh checked it (presigned: any change would break its signature).
# Taking BCR out of vendor/extra/product.mk (a deliberate rollback) turns the check off; a missing vendor/extra doesn't.
check_extras() {
    local mk=$TREE/vendor/extra/product.mk
    local apk=$O/system_ext/priv-app/BCR/BCR.apk
    local xml=$O/system_ext/etc/permissions/privapp-permissions-com.chiller3.bcr.xml
    [ -f "$mk" ] || { echo "BCR_CHECK=MISSING $mk (vendor/extra isn't set up)"; return 3; }
    grep -v '^[[:space:]]*#' "$mk" | grep -qw BCR || { echo "BCR_CHECK=SKIPPED (BCR isn't in $mk)"; return 0; }
    [ -f "$BCR/BCR.apk.sha256" ] || { echo "BCR_CHECK=MISSING $BCR/BCR.apk.sha256 (vendor/extra isn't set up)"; return 3; }
    [ -f "$apk" ] || { echo "BCR_CHECK=MISSING $apk"; return 3; }
    [ -f "$xml" ] || { echo "BCR_CHECK=MISSING $xml"; return 3; }
    [ "$(sha256sum < "$apk" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$BCR/BCR.apk.sha256")" ] \
        || { echo "BCR_CHECK=MISSING the unmodified BCR.apk ($apk differs from $BCR/BCR.apk.sha256)"; return 3; }
    echo "BCR_CHECK=OK version=$(cat "$BCR/VERSION")"
}

if [ "$CHECKONLY" = 1 ]; then
    check_extras
    exit $?
fi

finish() {
    echo "=== DerpFest Build Finished: $(date) (EXIT=$1) ==="
    exit "$1"
}

cd "$TREE" || finish 1
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
[ "$BUILD_EXIT" -eq 0 ] || finish "$BUILD_EXIT"

check_extras || finish 3

ota=$(ls -t "$O"/DerpFest-v17-*-kodiak-Unofficial-Stable.zip 2>/dev/null | head -1)
DATE=$(basename "${ota:-none}" | sed -n 's/^DerpFest-v17-\([0-9]\{8\}\)-kodiak-.*/\1/p')
[ -n "$DATE" ] || { echo "no DerpFest-v17-<date>-kodiak-Unofficial-Stable.zip in $O"; finish 4; }

echo "=== Packaging Fastboot Update ZIP ==="
KODIAK_ROOT=none ~/kodiak-imgzip.sh "$O" ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip \
    "$O/DerpFest-v17-$DATE-kodiak-Unofficial-fastboot.zip" || true

if [ "$NOUPLOAD" = 1 ]; then
    echo "UPLOAD=SKIPPED (--no-upload)"
else
    echo "=== Uploading build to Google Drive: DerpFest/kodiak ==="
    ~/upload-to-drive.sh DerpFest kodiak "$O"/DerpFest-v17-"$DATE"-* "$O/kodiak.json" || true
fi

finish 0
