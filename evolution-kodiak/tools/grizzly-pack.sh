#!/bin/bash
# Verify a grizzly build (grizzly-images.sh) offline and pack it as a
# `fastboot update` zip. Refuses to upload if any check fails.
#
#   grizzly-pack.sh            # verify + pack
#   grizzly-pack.sh --upload   # verify + pack + upload to SourceForge (grizzly/17)
set -euo pipefail

cd ~/evolution
O=out/target/product/grizzly
H=out/host/linux-x86/bin
IMG=vendor/google/grizzly-images/images
# The build's own name, e.g. EvolutionX-17.0-20261012-grizzly-12.3-Unofficial
NAME=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)-fastboot.zip
DEST=~/releases/grizzly; mkdir -p $DEST
ZIP=$DEST/$NAME
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/grizzly/17
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $NAME == EvolutionX-* ]] || fail "can't read ro.evolution.build.version from $O"
# A second build on the same day gets -r2, -r3...: a released file name (and
# its posted SHA-256) must never be overwritten.
base=${NAME%-fastboot.zip}; r=2
while [ -e "$DEST/$NAME" ] || [ -e "$DEST/$NAME.sha256" ]; do NAME=$base-r$r-fastboot.zip; r=$((r + 1)); done
ZIP=$DEST/$NAME

pgrep -x soong_ui >/dev/null && fail "a build is running"
grep -q "BUILD_EXIT=0" ~/grizzly-build.log || fail "the grizzly build didn't succeed"

echo "== identity"
prop() { grep -h -m1 "^$1=" $O/system/build.prop $O/product/etc/build.prop $O/system_ext/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2-; }
for kv in ro.product.product.device=grizzly "ro.product.product.model=Pixel 11 Pro" \
          ro.product.device_for_attestation=grizzly bluetooth.device_id.product_id=16667 \
          ro.quick_start.device_id=grizzly; do
    [[ "$(prop "${kv%%=*}")" == "${kv#*=}" ]] || fail "${kv%%=*} is '$(prop "${kv%%=*}")', want '${kv#*=}'"
done
grep -q "^board=grizzly" $O/android-info.txt || fail "android-info.txt: $(cat $O/android-info.txt)"
echo "OK: grizzly, Pixel 11 Pro, attestation/quick-start ids, BT product id, board=grizzly"

echo "== Pixel feature packages in out/"
n=$(ls $O/product/priv-app $O/product/app | grep -cE "AICore|PixelAI|PixelSense|CreativeAssistant|AmbientStreaming|Hotword|PixelCameraServices|SatelliteGateway|NowPlaying|CarrierWifi" || true)
echo "found $n Pixel feature packages"

echo "== SELinux"
sp=$(device/google/grizzly/check-sepolicy.sh $H/secilc $O ~/android-dt/dumps/grizzly/vendor 2>&1) || fail "check-sepolicy: $sp"
grep -q "^OK" <<<"$sp" || fail "check-sepolicy: $sp"
grep "^OK" <<<"$sp"
mac=$O/system_ext/etc/selinux/system_ext_mac_permissions.xml
grep -q pixelsystemservice $mac && fail "system_ext mac_permissions still maps seinfo=pixelsystemservice"
# grizzly's stock platform cert must stay mapped only by the stock vendor policy
grep -q 'signature="308205c8308203b0a003020102021463e2034c11' $mac && fail "system_ext mac_permissions maps grizzly's platform cert"
echo "OK: system_ext mac_permissions doesn't map grizzly's platform cert (signers: $(grep -o 'seinfo value="[^"]*' $mac | cut -d'"' -f2 | paste -sd' '))"

echo "== blobs signed with grizzly's own keys"
AS=$H/apksigner
for a in system_ext/priv-app/EuiccGoogleOverlay/EuiccGoogleOverlay.apk; do
    c=$($AS verify --print-certs $O/$a | grep -m1 "SHA-256 digest" | awk '{print $NF}')
    [[ $c == 48bfd9b0874531e6* ]] || fail "$a signer $c is not grizzly's stock platform key"
done
echo "OK: PRESIGNED platform blobs carry grizzly's stock platform key"
# CarrierSetup is re-signed with our platform key: it needs the signature-only
# MANAGE_NETWORK_POLICY, which stock's per-device key can't get on our build.
c=$($AS verify --print-certs $O/system_ext/priv-app/CarrierSetup/CarrierSetup.apk | grep -m1 "SHA-256 digest" | awk '{print $NF}')
p=$($AS verify --print-certs $O/system/framework/framework-res.apk | grep -m1 "SHA-256 digest" | awk '{print $NF}')
[[ $c == "$p" ]] || fail "CarrierSetup signer $c is not our platform key $p"
echo "OK: CarrierSetup carries our platform key"

echo "== pack (unrooted)"
KODIAK_ROOT=none ~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-grizzly-cd1a.261005.003.zip $ZIP >/dev/null
( cd $DEST && sha256sum $NAME > $NAME.sha256 )

echo "== verify the zip"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -l $ZIP | grep -q "ROOT.txt" && fail "zip is rooted"
unzip -q -o $ZIP -d $T
$H/avbtool info_image --image $T/vbmeta.img | grep -q "com.android.build.boot.security_patch -> '2026-10-05'" \
    || fail "vbmeta lacks the boot patch level"
$H/avbtool info_image --image $T/vbmeta.img | grep -q "Flags:                    3" || fail "vbmeta flags aren't 3"
cmp -s $T/init_boot.img $O/init_boot.img || fail "init_boot differs from out/"
for i in vendor vendor_dlkm system_dlkm; do
    cmp -s $T/$i.img $IMG/$i.img || fail "$i.img isn't stock grizzly"
done
# boot and dtbo are stock but re-signed with our AVB key (as for kodiak): compare
# the kernel, and the dtbo payload before the AVB footer
python3 system/tools/mkbootimg/unpack_bootimg.py --boot_img $T/boot.img --out $T/b-ours >/dev/null
if [ -f vendor/google/espada-kernel/grizzly/boot.img ]; then
    python3 system/tools/mkbootimg/unpack_bootimg.py --boot_img vendor/google/espada-kernel/grizzly/boot.img --out $T/b-ref >/dev/null
    cmp -s $T/b-ours/kernel $T/b-ref/kernel || fail "boot.img kernel doesn't match Espada grizzly kernel"
else
    python3 system/tools/mkbootimg/unpack_bootimg.py --boot_img $IMG/boot.img --out $T/b-stock >/dev/null
    cmp -s $T/b-ours/kernel $T/b-stock/kernel || fail "boot.img kernel isn't stock grizzly's"
fi
n=$($H/avbtool info_image --image $IMG/dtbo.img | awk '/Original image size/ {print $4}')
cmp -s <(head -c "$n" $T/dtbo.img) <(head -c "$n" $IMG/dtbo.img) || fail "dtbo payload isn't stock grizzly's"
unzip -p ~/android-dt/firmware/image-grizzly-cd1a.261005.003.zip super_empty.img | cmp -s - $T/super_empty.img || fail "super_empty isn't grizzly's"
grep -q "^board=grizzly" $T/android-info.txt || fail "zip android-info.txt isn't for grizzly"
echo "OK: unrooted, vbmeta flags 3 + boot patch level 2026-10-05, stock grizzly kernel/dtbo/vendor/vendor_dlkm/system_dlkm/super_empty"
ls -la $ZIP; cat $DEST/$NAME.sha256

if [ "${1:-}" = "--upload" ]; then
    echo "== upload to SourceForge: $SF_DIR"
    printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/grizzly\n-mkdir $SF_DIR\nput $ZIP $SF_DIR/$NAME\nput $DEST/$NAME.sha256 $SF_DIR/$NAME.sha256\nls -l $SF_DIR\nbye\n" \
        | sftp -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net
    echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/grizzly/17/"
fi
