#!/bin/bash
# Patch a kodiak init_boot.img with Magisk on the build server, following
# Magisk's own assets/boot_patch.sh for an init_boot (ramdisk only) image.
#
# Usage: kodiak-magisk-patch.sh <stock init_boot.img> <output.img>
#
# Flags are what the Magisk app computes on kodiak (checked 2026-10-11):
# system-as-root -> KEEPVERITY=true; FBE /data -> KEEPFORCEENCRYPT=true;
# `magisk --preinit-device` on the phone -> sda12.
set -euo pipefail

MAGISK_VER=${MAGISK_VER:-v30.7}
M=~/android-dt/ref/magisk/$MAGISK_VER/x
PREINITDEVICE=${PREINITDEVICE:-sda12}
# magiskboot's "cpio patch" reads these from the environment (boot_patch.sh exports them).
export KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false
IN=$(readlink -f "$1")
OUT=$(readlink -f "$2")

W=$(mktemp -d /tmp/magiskpatch.XXXXXX)
trap 'rm -rf "$W"' EXIT
cd "$W"

# Host tool: x86_64 magiskboot. Device payload: arm64 binaries.
cp "$M/lib/x86_64/libmagiskboot.so" magiskboot
cp "$M/lib/arm64-v8a/libmagiskinit.so" magiskinit
cp "$M/lib/arm64-v8a/libmagisk.so" magisk
cp "$M/lib/arm64-v8a/libinit-ld.so" init-ld
cp "$M/assets/stub.apk" stub.apk
chmod 755 magiskboot

./magiskboot unpack "$IN" >/dev/null 2>&1 || { echo "unpack failed ($?)"; exit 1; }
[ -f ramdisk.cpio ] || { echo "no ramdisk.cpio in $IN"; exit 1; }

set +e
./magiskboot cpio ramdisk.cpio test
STATUS=$?
set -e
[ "$STATUS" = 0 ] || { echo "ramdisk status $STATUS: not a stock init_boot"; exit 1; }

SHA1=$(./magiskboot sha1 "$IN")
cp -a ramdisk.cpio ramdisk.cpio.orig

./magiskboot compress=xz magisk magisk.xz
./magiskboot compress=xz stub.apk stub.xz
./magiskboot compress=xz init-ld init-ld.xz

cat > config <<EOF
KEEPVERITY=$KEEPVERITY
KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT
RECOVERYMODE=false
VENDORBOOT=false
PREINITDEVICE=$PREINITDEVICE
SHA1=$SHA1
EOF

./magiskboot cpio ramdisk.cpio \
  "add 0750 init magiskinit" \
  "mkdir 0750 overlay.d" \
  "mkdir 0750 overlay.d/sbin" \
  "add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
  "add 0644 overlay.d/sbin/stub.xz stub.xz" \
  "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
  "patch" \
  "backup ramdisk.cpio.orig" \
  "mkdir 000 .backup" \
  "add 000 .backup/.magisk config"

./magiskboot repack "$IN" new-boot.img >/dev/null 2>&1
cp new-boot.img "$OUT"

# Verify: the repacked ramdisk must now read as Magisk-patched (status 1).
mkdir v && cd v
../magiskboot unpack "$OUT" >/dev/null 2>&1
set +e
../magiskboot cpio ramdisk.cpio test
VSTATUS=$?
set -e
[ "$VSTATUS" = 1 ] || { echo "verify failed: status $VSTATUS"; exit 1; }
echo "OK: $OUT (Magisk $MAGISK_VER, stock sha1 $SHA1, preinit $PREINITDEVICE)"
sha256sum "$OUT"
