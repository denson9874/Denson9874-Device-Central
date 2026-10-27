#!/bin/bash
# Verify the husky release built by ~/husky-images.sh (p11-routine.sh husky) or
# ~/husky-build.sh and upload it to SourceForge. p11-ota.sh then publishes the
# same zip for the Updater.
#
#   husky-release-pack.sh            # verify; the candidate goes to ~/releases/husky/check (replaced each time)
#   husky-release-pack.sh --upload   # verify + upload the tested candidate
#
# The on-device gate: after flashing and testing check/<zip>, write check/<zip>.device-ok
# with a line "sha256 <sha256 of that zip>". An upload is refused unless out/'s zip has
# exactly that sha256, so a rebuild (same date, same name, different bytes) can't ride on
# an earlier test. A released file name (and its posted SHA-256) is never overwritten: a
# second release on the same day gets -r2, -r3...
set -euo pipefail
MODE=${1:-}

cd ~/evolution
O=out/target/product/husky
DEST=~/releases/husky; CHECK=$DEST/check
SF_USER=daryldenson0405
SF_DIR=/home/frs/project/denson9874-s-user-builds/husky/17
fail() { echo "FAIL: $*" >&2; exit 1; }

pgrep -x soong_ui >/dev/null && fail "a build is running"
log=$(ls -t ~/husky-build.log ~/husky-build-*.out 2>/dev/null | head -1 || true)
[ -n "$log" ] || fail "no husky build log (~/husky-build.log)"
grep -qE "BUILD_EXIT=0|BUILD COMPLETED with exit code: 0" "$log" || fail "the build didn't succeed ($log)"

# The zip of this build (ro.evolution.build.version), not just the newest one in out/
ver=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)
ZIP=$O/$ver.zip
[ -f "$ZIP" ] || fail "no $ZIP"
NAME=$(basename "$ZIP")
SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
mkdir -p "$DEST" "$CHECK"

echo "== build"
grep -q "^ro.build.type=user$" $O/system/build.prop || fail "not a user build"
grep -q '"PowerHint": "BODEGA"' $O/vendor/etc/powerhint.json || fail "BODEGA hint missing"
grep -q '"Mode": "bodega"' $O/vendor/etc/thermal_info_config_charge.json || fail "bodega charge profile missing"
[ -d $O/system_ext/priv-app/SystemUIGoogle/oat/arm64 ] || fail "SystemUIGoogle odex not on /system_ext"
[ -f $O/product/priv-app/SCONE-v77459/SCONE-v77459.apk ] || fail "SCONE isn't installed"
unzip -p $O/product/overlay/UpdaterOverlayHusky.apk resources.arsc 2>/dev/null | grep -aq "denson9874/evolution_ota" \
    || fail "the Updater doesn't point at denson9874/evolution_ota"
n=$(ls -d $O/product/priv-app/DevicePersonalizationAiAiPrebuilt* 2>/dev/null | wc -l)
[ "$n" = 1 ] || fail "$n copies of Android System Intelligence in product/priv-app (want 1)"
echo "user build, BODEGA hint + profile, SystemUIGoogle odex on /system_ext, SCONE, one ASI, Updater -> evolution_ota"

DATE=$(sed -E 's/.*-17\.0-([0-9]{8})-husky.*/\1/' <<<"$NAME")
M=$CHECK/$NAME.device-ok
if [ "$MODE" != "--upload" ]; then
    # A check isn't a release: one candidate in check/, replaced each time
    if ! cmp -s "$ZIP" "$CHECK/$NAME" 2>/dev/null; then
        rm -f "$CHECK"/*.zip "$CHECK"/*.sha256 "$CHECK"/*.img
        cp "$ZIP" "$CHECK/$NAME"
    fi
    cp $O/boot.img "$CHECK/boot-$DATE.img"; cp $O/vendor_boot.img "$CHECK/vendor_boot-$DATE.img"
    ( cd "$CHECK" && sha256sum "$NAME" > "$NAME.sha256" && sha256sum boot-$DATE.img vendor_boot-$DATE.img > recovery-$DATE.sha256 )
    echo "== candidate: $CHECK/$NAME"
    cat "$CHECK/$NAME.sha256"
    echo "== on-device check"
    if [ -f "$M" ] && grep -q "$SHA" "$M"; then
        cat "$M"
    else
        echo "not verified on a phone yet: test $CHECK/$NAME, then write $M with the line \"sha256 $SHA\""
    fi
    exit 0
fi

echo "== on-device check"
[ -f "$M" ] || fail "not verified on a phone yet (no $M)"
grep -q "$SHA" "$M" || fail "$M doesn't name this build's sha256 $SHA: out/ isn't the zip that was tested"
cat "$M"

# Never overwrite a released name: a different zip under an existing name gets -r2, -r3...
# release-cleanup.sh deletes uploaded zips but keeps their .sha256, so a name with either is taken.
base=${NAME%.zip}; REL=$NAME; SUF=; r=2
while { [ -e "$DEST/$REL" ] || [ -e "$DEST/$REL.sha256" ]; } \
    && ! { cmp -s "$ZIP" "$DEST/$REL" || grep -qs "^$SHA " "$DEST/$REL.sha256"; }; do SUF=-r$r; REL=$base$SUF.zip; r=$((r + 1)); done
BOOT=boot-$DATE$SUF.img; VBOOT=vendor_boot-$DATE$SUF.img; RSUM=recovery-$DATE$SUF.sha256
[ -e "$DEST/$REL" ] || cp "$ZIP" "$DEST/$REL"
cp $O/boot.img "$DEST/$BOOT"; cp $O/vendor_boot.img "$DEST/$VBOOT"
echo "== checksum"
( cd $DEST && sha256sum "$REL" > "$REL.sha256" && sha256sum $BOOT $VBOOT > $RSUM )   # names only, so users can run sha256sum -c
cat "$DEST/$REL.sha256" "$DEST/$RSUM"

echo "== upload to SourceForge: $SF_DIR"
# -b: any failed put fails the upload (the leading '-' lets the mkdirs fail when the folders exist)
printf -- "-mkdir /home/frs/project/denson9874-s-user-builds/husky\n-mkdir $SF_DIR\nput $DEST/$REL $SF_DIR/$REL\nput $DEST/$REL.sha256 $SF_DIR/$REL.sha256\nput $DEST/$BOOT $SF_DIR/$BOOT\nput $DEST/$VBOOT $SF_DIR/$VBOOT\nput $DEST/$RSUM $SF_DIR/$RSUM\nls -l $SF_DIR\nbye\n" \
    | sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net
touch "$DEST/$REL.uploaded"     # p11-ota.sh only skips its own upload for a file marked uploaded
echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/"
