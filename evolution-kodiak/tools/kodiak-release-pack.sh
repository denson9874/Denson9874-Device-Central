#!/bin/bash
# Pack the PUBLIC release from out/ (built by kodiak-release-images.sh), verify
# it, and upload it to SourceForge. Refuses to upload if any check fails.
#
#   kodiak-release-pack.sh            # pack + verify only
#   kodiak-release-pack.sh --upload   # pack + verify + upload
set -euo pipefail

cd ~/evolution
O=out/target/product/kodiak
H=out/host/linux-x86/bin
DATE=$(date +%Y%m%d)
NAME=EvolutionX-17.0-$DATE-kodiak-12.3-Unofficial-fastboot.zip
ZIP=/tmp/$NAME
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/kodiak/17
fail() { echo "FAIL: $*" >&2; exit 1; }

pgrep -f "soong_ui|ninja" >/dev/null && fail "a build is running"
grep -q "BUILD_EXIT=0" ~/kodiak-release-build.log || fail "the release build didn't succeed"

echo "== personal extras must be absent from out/"
n=$(ls $O/product/priv-app $O/product/app | grep -cE "AICore|PixelAI|PixelSense|CreativeAssistant|AmbientStreaming|Hotword|PixelCameraServices|SatelliteGateway|NowPlaying" || true)
[ "$n" = 0 ] || fail "$n personal apps found in out/"
echo "none"

echo "== check-sepolicy"
sp=$(device/google/kodiak/check-sepolicy.sh $H/secilc $O ~/android-dt/dumps/kodiak/vendor 2>&1) || fail "check-sepolicy: $sp"
grep -q "^OK" <<<"$sp" || fail "check-sepolicy: $sp"
echo "OK"

echo "== pack (unrooted)"
KODIAK_ROOT=none ~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip $ZIP >/dev/null
( cd /tmp && sha256sum $NAME > $NAME.sha256 )   # name only, so users can run sha256sum -c

echo "== verify the zip"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -l $ZIP | grep -q "ROOT.txt" && fail "zip is rooted"
unzip -q -o $ZIP vbmeta.img init_boot.img -d $T
$H/avbtool info_image --image $T/vbmeta.img | grep -q "com.android.build.boot.security_patch -> '2026-10-05'" \
    || fail "vbmeta lacks the boot patch level"
cmp -s $T/init_boot.img $O/init_boot.img || fail "init_boot differs from out/ (patched?)"
echo "unrooted, vbmeta boot patch level 2026-10-05, init_boot = out/"
ls -la $ZIP; cat /tmp/$NAME.sha256

if [ "${1:-}" = "--upload" ]; then
    echo "== upload to SourceForge: $SF_DIR"
    K=~/.ssh/sourceforge_ed25519
    printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/kodiak\n-mkdir $SF_DIR\nput $ZIP $SF_DIR/$NAME\nput /tmp/$NAME.sha256 $SF_DIR/$NAME.sha256\nls -l $SF_DIR\nbye\n" \
        | sftp -o BatchMode=yes -i $K $SF_USER@frs.sourceforge.net
    echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/kodiak/17/"
fi
