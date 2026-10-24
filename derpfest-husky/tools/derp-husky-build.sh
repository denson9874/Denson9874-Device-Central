#!/bin/bash
# Build DerpFest 17 for the Pixel 8 Pro (husky) in ~/derpfest, check the result offline, then verify the signed
# OTA package with derp-ota.sh (and, with --upload, publish it: SourceForge derpfest/husky and the OTA mirror,
# then denson9874/derpfest_ota for the Updater).
#
#   derp-husky-build.sh [--clean] [--kernel-sync] [--upload] [--changes <file>] [--check-only]
#
#   --clean       full build: remove out/target/product/husky first (installclean for this device only)
#   --upload      publish the OTA after every check passed (derp-ota.sh husky --upload)
#   --changes     ROM changes for the changelog, passed to derp-ota.sh
#   --kernel-sync re-sync the kernel source (LineageOS gs-6.1 manifest) before building it, and save the synced
#                 manifest to ~/derpfest-husky-kernel-manifest.xml (GPL source offer); otherwise it's rebuilt as is
#   --check-only  only run the offline checks on the existing out/; no lunch, no build
#
# There is no phone to test on (see README.md), so the gate is a clean build plus these checks. Exit status:
# the build's on failure, 3 if a check fails, 4 if there's no OTA zip. The last line of a build is
# "=== DerpFest husky Build Finished: <date> (EXIT=<n>) ===".
set -uo pipefail

CHECKONLY=0; CLEAN=0; UPLOAD=0; KSYNC=0; CHANGES=
while [ $# -gt 0 ]; do
    case $1 in
        --check-only) CHECKONLY=1 ;;
        --clean) CLEAN=1 ;;
        --upload) UPLOAD=1 ;;
        --kernel-sync) KSYNC=1 ;;
        --changes) CHANGES=${2:-}; shift ;;
        *) echo "usage: derp-husky-build.sh [--clean] [--kernel-sync] [--upload] [--changes <file>] [--check-only]" >&2; exit 2 ;;
    esac
    shift
done

TREE=$HOME/derpfest
O=$TREE/out/target/product/husky

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
    # frameworks_base 0001/0002 (restored apps keep network access): the dex in services.jar is stored, so the
    # 0002 log string is greppable
    # App odex on /system_ext, not system_other (which an OTA never writes): shusky 0003
    [ -d "$O/system_ext/priv-app/SystemUIFundamental/oat/arm64" ] || no "SystemUI odex isn't on /system_ext (shusky 0003)"
    grep -a -q 'Keeping REJECT_ALL for uid=' "$O/system/framework/services.jar" \
        || no "NetworkPolicy fixes (frameworks_base 0001/0002) not in services.jar"
    # ADB must ask for authorization on a user build (vendor/lineage common.mk had it off from 10-17 to 10-23)
    grep -qx 'ro.adb.secure=0' "$O/system_ext/etc/build.prop" "$O/recovery/root/prop.default" 2>/dev/null \
        && no "ADB authentication disabled (ro.adb.secure=0)"
    grep -qx 'persist.sys.usb.config=adb' "$O/system_ext/etc/build.prop" && no "ADB enabled by default (persist.sys.usb.config=adb)"
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
    # Signed with DerpFest's own keys, never Evolution X's: otherwise either ROM's packages install over the other
    local otacert=$TREE/vendor/lineage-priv/keys/releasekey.x509.pem evokeys=$HOME/evolution/vendor/evolution-priv/keys
    if [ -n "$zip" ]; then
        unzip -p "$zip" META-INF/com/android/otacert | cmp -s - "$otacert" || no "OTA isn't signed with vendor/lineage-priv's releasekey"
    fi
    for k in releasekey platform shared media networkstack avb; do
        cmp -s "$TREE/vendor/lineage-priv/keys/$k.x509.pem" "$evokeys/$k.x509.pem" && no "DerpFest's $k key is Evolution X's"
    done
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
# DerpFest is its own ROM (README): its own keys, nothing taken from the Evolution X tree
[ -e "$TREE/vendor/evolution-priv" ] && { echo "vendor/evolution-priv exists: DerpFest must use its own keys"; finish 1; }
[ -f "$TREE/vendor/lineage-priv/keys/testkey.pk8" ] || { echo "no DerpFest keys in vendor/lineage-priv/keys"; finish 1; }
# Kernel: lunch runs build_kernel (LineageOS gs-6.1 manifest, lineage-24.0) in out-kernel/; once the source is
# there, rebuild without re-syncing it
[ "$KSYNC" = 0 ] && [ -d "$TREE/out-kernel/google/gs-6.1/.repo" ] && export SKIP_KERNEL_SYNC=1
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export DERPFEST_BUILD_TYPE=Unofficial
export BUILD_USERNAME=android-build
export BUILD_HOSTNAME=voltage-build

if [ "$CLEAN" = 1 ]; then
    echo "== full build: removing $O"
    rm -rf "$O"
fi

source build/envsetup.sh
lunch lineage_husky-cp2a-user || finish 1
if [ "$KSYNC" = 1 ]; then
    # lunch's build_kernel just re-synced the kernel source: keep the exact manifest for the GPL source offer
    (cd "$TREE/out-kernel/google/gs-6.1" && repo manifest -r -o "$HOME/derpfest-husky-kernel-manifest.xml") \
        && echo "== kernel source manifest saved: ~/derpfest-husky-kernel-manifest.xml" || finish 1
fi

echo "=== DerpFest husky Build Started: $(date) ==="
m -j"$(nproc)" derp 2>&1 | tee ~/derp-husky-build.log
BUILD_EXIT=${PIPESTATUS[0]}
[ "$BUILD_EXIT" -eq 0 ] || finish "$BUILD_EXIT"

checks || finish 3

# The signed OTA package: verified always, published with --upload (derp-ota.sh stages and uploads the release files)
ota=(husky); [ "$UPLOAD" = 1 ] && ota+=(--upload)
[ -n "$CHANGES" ] && ota+=(--changes "$CHANGES")
"$HOME/derpfest-husky/tools/derp-ota.sh" "${ota[@]}" || finish 4
finish 0
