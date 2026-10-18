#!/bin/bash
# Verify a cheetah build (cheetah-images.sh) offline and pack it as a
# `fastboot update` zip. Refuses to upload if any check fails.
#
#   cheetah-pack.sh            # verify + pack
#   cheetah-pack.sh --upload   # verify + pack + upload to SourceForge (cheetah/17)
#
# The zip holds what out/fastboot-info.txt flashes (ROM partitions and
# super_empty), not the bootloader and radio: like the Pixel 11 zips, users
# flash the latest stock release first, and the OTA carries the firmware.
set -euo pipefail
MODE=${1:-}

cd ~/evolution
O=out/target/product/cheetah
H=out/host/linux-x86/bin
V=vendor/google/cheetah
# The build's own name, e.g. EvolutionX-17.0-20261018-cheetah-12.3-Unofficial
NAME=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)-UNTESTED-fastboot.zip
DEST=~/releases/cheetah; mkdir -p $DEST
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/cheetah/17
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $NAME == EvolutionX-*-cheetah-* ]] || fail "can't read ro.evolution.build.version from $O"
# A second build on the same day gets -r2, -r3...: a released file name (and
# its posted SHA-256) must never be overwritten.
base=${NAME%-fastboot.zip}; r=2
while [ -e "$DEST/$NAME" ]; do NAME=$base-r$r-fastboot.zip; r=$((r + 1)); done
ZIP=$DEST/$NAME

pgrep -x soong_ui >/dev/null && fail "a build is running"
grep -q "BUILD_EXIT=0" ~/cheetah-build.log || fail "the cheetah build didn't succeed"

echo "== identity"
prop() { grep -h -m1 "^$1=" $O/system/build.prop $O/product/etc/build.prop $O/system_ext/etc/build.prop $O/vendor/build.prop 2>/dev/null | head -1 | cut -d= -f2-; }
for kv in ro.product.product.device=cheetah "ro.product.product.model=Pixel 7 Pro" \
          ro.product.vendor.device=cheetah ro.evolution.device=cheetah; do
    [[ "$(prop "${kv%%=*}")" == "${kv#*=}" ]] || fail "${kv%%=*} is '$(prop "${kv%%=*}")', want '${kv#*=}'"
done
grep -q "^require board=cheetah" $O/android-info.txt || fail "android-info.txt: $(cat $O/android-info.txt)"
echo "OK: cheetah, Pixel 7 Pro, board=cheetah"

echo "== our patches and overlays"
for s in "cheetah: set unofficial maintainer" "cheetah: get updates from denson9874/evolution_ota"; do
    git -C device/google/pantah log --format=%s | grep -xF "$s" >/dev/null || fail "device/google/pantah lacks '$s' (run prepare.sh)"
done
# A runtime_resource_overlay installs as product/overlay/<name>.apk (in a <theme>/
# subfolder only if it sets one)
ovl=$(find $O/product/overlay -name UpdaterOverlayCheetah.apk -print -quit 2>/dev/null || true)
[ -n "$ovl" ] || fail "no UpdaterOverlayCheetah.apk under $O/product/overlay"
if [ -x $H/aapt2 ]; then
    # Not grep -q: exiting at the first match would kill aapt2 with SIGPIPE under pipefail
    $H/aapt2 dump resources $ovl | grep "denson9874/evolution_ota" >/dev/null || fail "$ovl doesn't point at denson9874/evolution_ota"
fi
echo "OK: unofficial maintainer, Updater overlay -> denson9874/evolution_ota"

echo "== firmware"
fwsrc=$(cat $V/FIRMWARE_SOURCE 2>/dev/null || echo "vendor repo default")
cached=$(cat ~/android-dt/firmware/cheetah/CURRENT 2>/dev/null || echo none)
[[ "$fwsrc" == "$cached" ]] || echo "WARNING: firmware is $fwsrc but the newest cached factory release is $cached"
for img in $(grep -oE 'radio/[a-z0-9_]+\.img,[0-9a-f]{40}' $V/Android.mk); do
    f=${img%%,*}; f=${f#radio/}; want=${img##*,}
    [ -f $O/$f ] || fail "the build has no $f"
    [[ "$(sha1sum $O/$f | cut -d' ' -f1)" == "$want" ]] || fail "out/$f doesn't match the firmware in $V/Android.mk"
done
echo "OK: firmware $fwsrc (the OTA ships it; the fastboot zip doesn't)"

echo "== pack (unrooted)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir $T/z
[ -f $O/fastboot-info.txt ] || fail "no $O/fastboot-info.txt"
: > $T/z/fastboot-info.txt
while read -r line; do
    set -- $line
    if [ "${1:-}" = flash ]; then
        shift; args=(); for a in "$@"; do [[ $a == --* ]] || args+=("$a"); done
        img=${args[-1]}; [[ $img == *.img ]] || img=$img.img
        if [ ! -f $O/$img ]; then
            # No dexpreopt: there is no system_other to flash to the other slot
            [ "$img" = system_other.img ] && continue
            fail "fastboot-info.txt flashes $img, which the build didn't make"
        fi
        [ -f $T/z/$img ] || ln $O/$img $T/z/ 2>/dev/null || cp $O/$img $T/z/
    fi
    echo "$line" >> $T/z/fastboot-info.txt
done < $O/fastboot-info.txt
for f in android-info.txt super_empty.img; do
    [ -f $O/$f ] || fail "the build has no $f"
    cp $O/$f $T/z/
done
rm -f $ZIP
(cd $T/z && zip -q -0 $ZIP ./*)
( cd $DEST && sha256sum $NAME > $NAME.sha256 )

echo "== verify the zip"
mkdir $T/x; unzip -q -o $ZIP -d $T/x
for f in $T/x/*.img; do cmp -s $f $O/$(basename $f) || fail "$(basename $f) differs from out/"; done
for f in $(ls $T/x); do grep -qiE "magisk|ROOT" <<<"$f" && fail "zip contains $f"; done
# gs201 chains boot and system: their patch levels are in boot.img's footer and vbmeta_system.img
avb=$(for i in vbmeta vbmeta_system boot; do $H/avbtool info_image --image $T/x/$i.img; done)
grep -q "com.android.build.boot.security_patch -> '" <<<"$avb" || fail "no boot patch level in vbmeta, vbmeta_system or boot"
spl=$(sed -n "s/.*com.android.build.system.security_patch -> '\(.*\)'/\1/p" <<<"$avb" | head -1)
[ -n "$spl" ] || fail "no system patch level in vbmeta, vbmeta_system or boot"
echo "OK: $(ls $T/x | wc -l) files, all identical to out/, unrooted, system patch level $spl"
ls -la $ZIP; cat $DEST/$NAME.sha256

if [ "$MODE" = "--upload" ]; then
    echo "== upload to SourceForge: $SF_DIR"
    printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/cheetah\n-mkdir $SF_DIR\nput $ZIP $SF_DIR/$NAME\nput $DEST/$NAME.sha256 $SF_DIR/$NAME.sha256\nls -l $SF_DIR\nbye\n" \
        | sftp -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net
    echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/cheetah/17/"
fi
