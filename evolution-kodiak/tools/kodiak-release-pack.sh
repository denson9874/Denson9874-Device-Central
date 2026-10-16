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
# The build's own name, e.g. EvolutionX-17.0-20261011-kodiak-12.3-Unofficial
NAME=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)-fastboot.zip
DEST=~/releases/kodiak; mkdir -p $DEST
ZIP=$DEST/$NAME
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/kodiak/17
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $NAME == EvolutionX-* ]] || fail "can't read ro.evolution.build.version from $O"
# A second build on the same day gets -r2, -r3...: a released file name (and
# its posted SHA-256) must never be overwritten.
base=${NAME%-fastboot.zip}; r=2
while [ -e "$DEST/$NAME" ]; do NAME=$base-r$r-fastboot.zip; r=$((r + 1)); done
ZIP=$DEST/$NAME

pgrep -x soong_ui >/dev/null && fail "a build is running"
grep -q "BUILD_EXIT=0" ~/kodiak-release-build.log || fail "the release build didn't succeed"

echo "== Pixel feature packages in out/"
n=$(ls $O/product/priv-app $O/product/app | grep -cE "AICore|PixelAI|PixelSense|CreativeAssistant|AmbientStreaming|Hotword|PixelCameraServices|SatelliteGateway|NowPlaying" || true)
echo "found $n Pixel feature packages"

echo "== check-sepolicy"
sp=$(device/google/kodiak/check-sepolicy.sh $H/secilc $O ~/android-dt/dumps/kodiak/vendor 2>&1) || fail "check-sepolicy: $sp"
grep -q "^OK" <<<"$sp" || fail "check-sepolicy: $sp"
echo "OK"

echo "== pack (unrooted)"
KODIAK_ROOT=none ~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip $ZIP >/dev/null
( cd $DEST && sha256sum $NAME > $NAME.sha256 )   # name only, so users can run sha256sum -c

echo "== verify the zip"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -l $ZIP | grep -q "ROOT.txt" && fail "zip is rooted"
unzip -q -o $ZIP vbmeta.img init_boot.img -d $T
$H/avbtool info_image --image $T/vbmeta.img | grep -q "com.android.build.boot.security_patch -> '2026-10-05'" \
    || fail "vbmeta lacks the boot patch level"
cmp -s $T/init_boot.img $O/init_boot.img || fail "init_boot differs from out/ (patched?)"
echo "unrooted, vbmeta boot patch level 2026-10-05, init_boot = out/"
ls -la $ZIP; cat $DEST/$NAME.sha256

if [ "${1:-}" = "--upload" ]; then
    echo "== upload to SourceForge: $SF_DIR"
    K=~/.ssh/sourceforge_ed25519
    printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/kodiak\n-mkdir $SF_DIR\nput $ZIP $SF_DIR/$NAME\nput $DEST/$NAME.sha256 $SF_DIR/$NAME.sha256\nls -l $SF_DIR\nbye\n" \
        | sftp -o BatchMode=yes -i $K $SF_USER@frs.sourceforge.net
    echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/kodiak/17/"
fi
