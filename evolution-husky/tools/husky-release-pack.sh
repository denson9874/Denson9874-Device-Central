#!/bin/bash
# Verify the husky release built by ~/husky-build.sh and upload it to
# SourceForge. Refuses to upload if any check fails, including the on-device
# check (the <zip>.device-ok marker written after flashing and testing it).
#
#   husky-release-pack.sh            # verify only
#   husky-release-pack.sh --upload   # verify + upload
set -euo pipefail

cd ~/evolution
O=out/target/product/husky
DEST=~/releases/husky
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/husky/17
fail() { echo "FAIL: $*" >&2; exit 1; }

pgrep -x soong_ui >/dev/null && fail "a build is running"
log=$(ls -t ~/husky-build-*.out 2>/dev/null | head -1)
grep -q "BUILD COMPLETED with exit code: 0" "$log" || fail "the build didn't succeed ($log)"

ZIP=$(ls -t "$O"/EvolutionX-17.0-*-husky-*-Unofficial.zip | head -1)
NAME=$(basename "$ZIP")
[ -f "$DEST/$NAME" ] && cmp -s "$ZIP" "$DEST/$NAME" || fail "$DEST/$NAME missing or differs from out/"
ZIP=$DEST/$NAME

echo "== build"
grep -q "^ro.build.type=user$" $O/system/build.prop || fail "not a user build"
grep -q '"PowerHint": "BODEGA"' $O/vendor/etc/powerhint.json || fail "BODEGA hint missing"
grep -q '"Mode": "bodega"' $O/vendor/etc/thermal_info_config_charge.json || fail "bodega charge profile missing"
[ -d $O/system_ext/priv-app/SystemUIGoogle/oat/arm64 ] || fail "SystemUIGoogle odex not on /system_ext"
echo "user build, BODEGA hint + profile, SystemUIGoogle odex on /system_ext"

# Recovery images for clean installs, dated so earlier releases' files stay put
DATE=$(sed -E 's/.*-17\.0-([0-9]{8})-husky.*/\1/' <<<"$NAME")
BOOT=boot-$DATE.img; VBOOT=vendor_boot-$DATE.img
cp $O/boot.img $DEST/$BOOT; cp $O/vendor_boot.img $DEST/$VBOOT

echo "== checksum"
( cd $DEST && sha256sum "$NAME" > "$NAME.sha256" && sha256sum $BOOT $VBOOT > recovery-$DATE.sha256 )   # names only, so users can run sha256sum -c
cat "$DEST/$NAME.sha256" "$DEST/recovery-$DATE.sha256"

echo "== on-device check"
[ -f "$DEST/$NAME.device-ok" ] || fail "not verified on a phone yet (no $NAME.device-ok)"
cat "$DEST/$NAME.device-ok"

if [ "${1:-}" = "--upload" ]; then
    echo "== upload to SourceForge: $SF_DIR"
    printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/husky\n-mkdir $SF_DIR\nput $ZIP $SF_DIR/$NAME\nput $DEST/$NAME.sha256 $SF_DIR/$NAME.sha256\nput $DEST/$BOOT $SF_DIR/$BOOT\nput $DEST/$VBOOT $SF_DIR/$VBOOT\nput $DEST/recovery-$DATE.sha256 $SF_DIR/recovery-$DATE.sha256\nls -l $SF_DIR\nbye\n" \
        | sftp -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net
    echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/"
fi
