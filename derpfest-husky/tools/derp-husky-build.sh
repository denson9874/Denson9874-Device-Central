#!/bin/bash
# Build DerpFest 17 for the Pixel 8 Pro (husky) in ~/derpfest, check the result offline and stage the release
# files in ~/releases/derpfest-husky. Nothing is uploaded here.
#
#   derp-husky-build.sh [--check-only]
#
#   --check-only  only run the offline checks on the existing out/; no lunch, no build
#
# There is no phone to test on (see README.md), so the gate is a clean build plus these checks. Exit status:
# the build's on failure, 3 if a check fails, 4 if there's no OTA zip. The last line of a build is
# "=== DerpFest husky Build Finished: <date> (EXIT=<n>) ===".
set -uo pipefail

CHECKONLY=0
case ${1:-} in
    --check-only) CHECKONLY=1 ;;
    "") ;;
    *) echo "usage: derp-husky-build.sh [--check-only]" >&2; exit 2 ;;
esac

TREE=$HOME/derpfest
O=$TREE/out/target/product/husky
DEST=$HOME/releases/derpfest-husky

finish() {
    echo "=== DerpFest husky Build Finished: $(date) (EXIT=$1) ==="
    exit "$1"
}

checks() {
    local bad=0
    no() { echo "CHECK_FAIL: $*"; bad=1; }
    grep -q '^ro.build.type=user$' "$O/system/build.prop" || no "not a user build"
    grep -q '^ro.product.vendor.device=husky$' "$O/vendor/build.prop" || no "vendor/build.prop isn't husky's"
    [ -e "$O/vendor/bin/gpuflag" ] && no "gpuflag installed (vendor 0001 not applied)"
    [ -f "$O/product/etc/default-permissions/default-permissions-zuma.xml" ] || no "default-permissions-zuma.xml missing (zuma 0001 not applied)"
    ls "$O"/product/priv-app/TurboAdapter_NoBatt* >/dev/null 2>&1 && no "TurboAdapter_NoBatt installed (husky has the Google battery HAL)"
    # Face unlock is DerpFest's ParanoidSense alone (README): LineageOS's Pixel face unlock commits aren't in the pins
    find "$O/system_ext" "$O/system" "$O/product" -maxdepth 3 -name 'ParanoidSense*.apk' | grep -q . || no "ParanoidSense missing"
    grep -q 'config_face_enroll_hal_owns_camera' "$TREE/device/google/zuma/overlay/SettingsOverlayZuma/res/values/lineage_config.xml" \
        && no "zuma has LineageOS's Pixel face unlock commits (two face unlock providers)"
    # Firmware in the OTA must be the CP3A set update-firmware.sh installed (never older than the phone's):
    # extract it from the payload and compare byte for byte
    local zip w p fwbad=0
    zip=$(ls -t "$O"/DerpFest-v17-*-husky-Unofficial-*.zip 2>/dev/null | head -1)
    if [ -z "$zip" ]; then
        no "no OTA zip to check the firmware in"
    else
        w=$(mktemp -d)
        unzip -q "$zip" payload.bin -d "$w"
        local parts=()
        for p in "$TREE"/vendor/google/husky/radio/*.img; do parts+=("$(basename "$p" .img)"); done
        TREE=$TREE python3 "$HOME/derpfest-husky/tools/payload_extract.py" "$w/payload.bin" "$w" "${parts[@]}" >/dev/null \
            || no "can't extract the firmware from $zip"
        for p in "${parts[@]}"; do
            cmp -s "$w/$p.img" "$TREE/vendor/google/husky/radio/$p.img" || { no "firmware $p in the OTA differs from vendor/google/husky/radio"; fwbad=1; }
        done
        rm -rf "$w"
        [ "$fwbad" = 0 ] && echo "FIRMWARE=OK ${#parts[@]} images, $(cat "$TREE/vendor/google/husky/radio/SOURCE")"
    fi
    # BCR from vendor/extra, as in the kodiak DerpFest build: presigned, so it must be byte-identical
    local bcr=$TREE/vendor/extra/bcr
    if grep -v '^[[:space:]]*#' "$TREE/vendor/extra/product.mk" 2>/dev/null | grep -qw BCR; then
        [ "$(sha256sum < "$O/system_ext/priv-app/BCR/BCR.apk" 2>/dev/null | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$bcr/BCR.apk.sha256")" ] \
            && echo "BCR_CHECK=OK version=$(cat "$bcr/VERSION")" || no "BCR.apk missing or modified"
    else
        echo "BCR_CHECK=SKIPPED"
    fi
    [ "$bad" = 0 ] && echo "CHECKS=OK"
    return $(( bad ? 3 : 0 ))
}

if [ "$CHECKONLY" = 1 ]; then
    checks
    exit $?
fi

# One big build at a time on this server
for i in $(seq 1 480); do
    pgrep -x soong_ui >/dev/null || pgrep -x ninja >/dev/null || break
    [ "$i" = 1 ] && echo "== waiting for the running build to finish..."
    sleep 30
done

cd "$TREE" || finish 1
"$HOME/derpfest-husky/apply.sh" "$TREE" || finish 1
# The Muppets blobs are git-lfs, and this tree wasn't repo-init'd with --git-lfs: without a pull, big APKs
# stay pointer files and the build fails much later ("Improper zip alignment" in check_prebuilt_presigned_apk)
git -C "$TREE/vendor/google/husky" lfs pull || finish 1
if grep -rlq 'git-lfs.github.com/spec/v1' "$TREE/vendor/google/husky/proprietary" "$TREE/vendor/google/husky/radio"; then
    echo "git-lfs pointer files left in vendor/google/husky"; finish 1
fi
# Kernel: the one Evolution X husky ships (built by build_kernel in ~/evolution from LineageOS's gs-6.1
# manifest, lineage-24.0). lunch would otherwise sync and build the whole kernel source again here.
cp -a "$HOME/evolution/device/google/shusky-kernels/6.1/." "$TREE/device/google/shusky-kernels/6.1/" || finish 1
export SKIP_KERNEL_BUILD=1
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export DERPFEST_BUILD_TYPE=Unofficial
export BUILD_USERNAME=android-build
export BUILD_HOSTNAME=voltage-build

source build/envsetup.sh
lunch lineage_husky-cp2a-user || finish 1

echo "=== DerpFest husky Build Started: $(date) ==="
m -j"$(nproc)" derp 2>&1 | tee ~/derp-husky-build.log
BUILD_EXIT=${PIPESTATUS[0]}
[ "$BUILD_EXIT" -eq 0 ] || finish "$BUILD_EXIT"

checks || finish 3

ZIP=$(ls -t "$O"/DerpFest-v17-*-husky-Unofficial-*.zip 2>/dev/null | head -1)
[ -n "$ZIP" ] || { echo "no DerpFest-v17-<date>-husky-Unofficial-*.zip in $O"; finish 4; }
NAME=$(basename "$ZIP")
DATE=$(sed -n 's/^DerpFest-v17-\([0-9]\{8\}\)-husky-.*/\1/p' <<<"$NAME")

# The OTA zip plus boot/vendor_boot for clean installs (recovery lives in vendor_boot), as for Evolution X husky
mkdir -p "$DEST"
cp "$ZIP" "$DEST/"
cp "$O/boot.img" "$DEST/boot-$DATE.img"
cp "$O/vendor_boot.img" "$DEST/vendor_boot-$DATE.img"
cp "$O/husky.json" "$DEST/husky-$DATE.json" 2>/dev/null || true
( cd "$DEST" && sha256sum "$NAME" > "$NAME.sha256" && sha256sum "boot-$DATE.img" "vendor_boot-$DATE.img" > "recovery-$DATE.sha256" )
cat "$DEST/$NAME.sha256" "$DEST/recovery-$DATE.sha256"
ls -l "$DEST"
finish 0
