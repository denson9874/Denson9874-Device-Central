#!/bin/bash
# Pack the personal kodiak build for a no-wipe update that keeps the phone's
# own (Magisk-patched) init_boot: no init_boot.img, no "flash init_boot" line.
set -euo pipefail
cd ~/evolution
O=out/target/product/kodiak; H=out/host/linux-x86/bin
fail() { echo "FAIL: $*"; exit 1; }
grep -q "BUILD_EXIT=0" ~/kodiak-personal-build.log || fail "build didn't succeed"
echo "== checks"
[ -f $O/system_ext/priv-app/GbaService/GbaService.apk ] || fail "no GbaService in system_ext"
c=$($H/apksigner verify --print-certs $O/system_ext/priv-app/GbaService/GbaService.apk | grep -m1 "SHA-256 digest" | awk '{print $NF}')
p=$($H/apksigner verify --print-certs $O/system/framework/framework-res.apk | grep -m1 "SHA-256 digest" | awk '{print $NF}')
[ "$c" = "$p" ] || fail "GbaService isn't signed with our platform key"
ov=$(find $O/product/overlay -name "TeleServiceOverlayKodiak*.apk" | head -1)
$H/aapt2 dump resources "$ov" | grep -A1 "config_gba_package" | grep -q com.android.gbaservice || fail "overlay lacks config_gba_package"
n=$(ls $O/product/priv-app $O/product/app | grep -cE "AICore|PixelAI|PixelSense|NowPlaying" || true)
echo "GbaService platform-signed, overlay sets config_gba_package, personal apps: $n"
D=~/releases/kodiak-personal; mkdir -p $D
NAME=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)-personal-keep-initboot.zip
[[ $NAME == EvolutionX-* ]] || fail "no build name"
ZIP=$D/$NAME
echo "== pack"
KODIAK_ROOT=none ~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip $ZIP >/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unzip -q -o $ZIP fastboot-info.txt vbmeta.img -d $T
grep -v "^flash init_boot$" $T/fastboot-info.txt > $T/fi && mv $T/fi $T/fastboot-info.txt
grep -q "init_boot" $T/fastboot-info.txt && fail "init_boot still in fastboot-info"
zip -q -d $ZIP init_boot.img
(cd $T && zip -q -0 $ZIP fastboot-info.txt)
$H/avbtool info_image --image $T/vbmeta.img | grep -q "com.android.build.boot.security_patch -> '2026-10-05'" || fail "vbmeta lacks boot patch level"
unzip -l $ZIP | grep -q "init_boot" && fail "zip still has init_boot"
echo "OK: no init_boot, vbmeta boot patch level 2026-10-05"
unzip -l $ZIP | awk 'NR>3 && $4!="" {print $1, $4}'
sha256sum $ZIP | tee $ZIP.sha256
