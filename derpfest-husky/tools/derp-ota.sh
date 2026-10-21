#!/bin/bash
# Verify DerpFest's signed A/B OTA package for a device (built by `m derp` in ~/derpfest) and, with --upload,
# publish it for DerpFest's Updater: upload it with the recovery images to SourceForge (derpfest/<dev>), wait until
# SourceForge serves it, then update builds/<dev>.json and changelogs/<dev>.txt in denson9874/derpfest_ota (the repo
# the device tree's UpdaterOverlayDerp* points at). The JSON goes out last, so it never points at a file that isn't
# downloadable yet. DerpFest's counterpart of Evolution X's p11-ota.sh; the two never share keys, folders or repos.
#
#   derp-ota.sh <husky> [--upload | --preview] [--changes <file>]
#
# --preview prints the JSON and changelog an upload would publish, without uploading.
#
# Checks: the package is A/B, for this device and from this build; its zip and payload signatures verify against the
# build's own otacerts.zip, which holds DerpFest's release key and not Evolution X's; the payload carries the ROM and
# firmware partitions; its boot and system patch levels (boot footer, vbmeta_system) are the build's.
# Prints OTA_VERIFIED, and OTA_PUBLISHED <json url> after a successful --upload.
set -euo pipefail

dev=${1:-}; [ $# -gt 0 ] && shift
UPLOAD=0; PREVIEW=0; CHANGES=
while [ $# -gt 0 ]; do
    case $1 in
        --upload) UPLOAD=1 ;;
        --preview) PREVIEW=1 ;;
        --changes) CHANGES=${2:-}; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case $dev in
    # FORUM: the XDA thread, once it exists
    husky) MODEL="Pixel 8 Pro"; DEVTREE=device/google/shusky; FORUM=https://sourceforge.net/projects/denson9874-s-user-builds/files/derpfest/husky/ ;;
    *) echo "usage: derp-ota.sh <husky> [--upload | --preview] [--changes <file>]" >&2; exit 2 ;;
esac

TOP=~/derpfest; O=$TOP/out/target/product/$dev; H=$TOP/out/host/linux-x86/bin
DEVTREE=$TOP/$DEVTREE
DEST=~/releases/derpfest-$dev; mkdir -p "$DEST"
SF_USER=daryldenson0405; SF_PROJECT=denson9874-s-user-builds; SF_DIR=/home/frs/project/$SF_PROJECT/derpfest/$dev
REPO=~/derpfest_ota; RAW=https://raw.githubusercontent.com/denson9874/derpfest_ota/main
KEYS=$TOP/vendor/lineage-priv/keys; EVOKEYS=~/evolution/vendor/evolution-priv/keys
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. The package of this build
OTA=$(ls -t "$O"/DerpFest-v17-*-"$dev"-Unofficial-*.zip 2>/dev/null | grep -v -- '-fastboot\.zip$' | head -1 || true)
[ -n "$OTA" ] || fail "no DerpFest-v17-<date>-$dev-Unofficial-*.zip in $O (the build has to run m derp)"
NAME=$(basename "$OTA")
DATE=$(sed -n "s/^DerpFest-v17-\([0-9]\{8\}\)-$dev-.*/\1/p" <<<"$NAME")
unzip -p "$OTA" META-INF/com/android/metadata > $T/metadata || fail "$OTA has no OTA metadata"
grep -qx "ota-type=AB" $T/metadata || fail "not an A/B package"
grep -qx "pre-device=$dev" $T/metadata || fail "the package isn't for $dev"
ts=$(sed -n 's/^post-timestamp=//p' $T/metadata)
[ -n "$ts" ] && [ "$ts" = "$(sed -n 's/^ro.build.date.utc=//p' $O/system/build.prop)" ] \
    || fail "the package isn't from the current build (post-timestamp $ts)"

# 2. Signed with DerpFest's own release key, which the build trusts for updates (zip and payload signatures)
unzip -q -o $O/system/etc/security/otacerts.zip -d $T/otacerts
certs=("$T"/otacerts/*)
[ ${#certs[@]} = 1 ] || fail "expected one certificate in otacerts.zip, found ${#certs[@]}"
cmp -s "${certs[0]}" "$KEYS/releasekey.x509.pem" || fail "otacerts.zip doesn't hold vendor/lineage-priv's releasekey"
cmp -s "${certs[0]}" "$EVOKEYS/releasekey.x509.pem" && fail "the build trusts Evolution X's release key"
$H/check_ota_package_signature "${certs[0]}" "$OTA" > $T/sig.log 2>&1 || { tail -5 $T/sig.log; fail "signature check failed"; }
grep -q "Payload signatures VERIFIED" $T/sig.log || fail "payload signatures not verified"

# 3. The ROM partitions and the firmware vendor/google/<dev>/radio ships
off=$(python3 - "$OTA" <<'EOF'
import struct, sys, zipfile
info = zipfile.ZipFile(sys.argv[1]).getinfo("payload.bin")
with open(sys.argv[1], "rb") as f:
    f.seek(info.header_offset)
    name_len, extra_len = struct.unpack("<HH", f.read(30)[26:30])
print(info.header_offset + 30 + name_len + extra_len)
EOF
)
python3 - "$OTA" "$off" > $T/partitions <<'EOF'
import re, struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(int(sys.argv[2]))
    if f.read(4) != b"CrAU":
        sys.exit("payload.bin has no CrAU magic")
    f.read(8)
    manifest_len, = struct.unpack(">Q", f.read(8))
    f.read(4)
    manifest = f.read(manifest_len)
names = {m.group(2).decode() for m in re.finditer(rb"\x0a([\x02-\x20])([a-z0-9_]{2,32})", manifest)
         if len(m.group(2)) == m.group(1)[0]}
print("\n".join(sorted(names)))
EOF
want="boot init_boot vendor_boot vendor_kernel_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor vendor_dlkm system_dlkm"
want+=" $(for f in $TOP/vendor/google/$dev/radio/*.img; do basename "$f" .img; done)"
missing=$(for p in $want; do grep -qx "$p" $T/partitions || echo "$p"; done)
[ -z "$missing" ] || fail "the payload lacks: $(echo $missing)"

# 4. The patch levels stay as built (KeyMint must never see them go missing or backwards). zuma chains boot and
# system from vbmeta, so they're in boot.img's footer and vbmeta_system.img, as on Evolution X's gs201.
AVB="vbmeta_system boot"
mkdir $T/x
$H/ota_extractor -payload "$OTA" -payload_offset "$off" -output_dir $T/x -partitions "${AVB// /,}" > $T/x.log 2>&1 \
    || { tail -3 $T/x.log; fail "couldn't extract $AVB"; }
props() { local d=$1 i; for i in $AVB; do $H/avbtool info_image --image "$d/$i.img"; done | grep -oE "com\.android\.build\.(boot|system)\.security_patch -> '[0-9-]+'" | sort -u; }
[ "$(props $T/x | wc -l)" = 2 ] || fail "the OTA's $AVB lack the boot or system patch level"
[ "$(props $T/x)" = "$(props $O)" ] || fail "the OTA's patch levels differ from the build's $AVB images"
boot_spl=$(props $T/x | sed -n "s/.*boot.security_patch -> '\(.*\)'/\1/p")
system_spl=$(props $T/x | sed -n "s/.*system.security_patch -> '\(.*\)'/\1/p")
firmware=$(cat $TOP/vendor/google/$dev/radio/SOURCE)
echo "OTA_VERIFIED $OTA (patch levels: system $system_spl, vendor/boot $boot_spl; firmware $firmware)"
[ $UPLOAD = 1 ] || [ $PREVIEW = 1 ] || exit 0

# 5. Upload with the recovery images for clean installs
URL=https://sourceforge.net/projects/$SF_PROJECT/files/derpfest/$dev/$NAME/download
size=$(stat -c %s "$OTA")
sha256=$(sha256sum "$OTA" | cut -d' ' -f1)
if [ $PREVIEW = 1 ]; then
    OUT=$T/preview; mkdir -p $OUT/builds $OUT/changelogs
else
OUT=$REPO; mkdir -p "$OUT/builds" "$OUT/changelogs"
cp "$OTA" "$DEST/$NAME"
cp $O/boot.img "$DEST/boot-$DATE.img"; cp $O/vendor_boot.img "$DEST/vendor_boot-$DATE.img"
(cd "$DEST" && echo "$sha256  $NAME" > "$NAME.sha256" && sha256sum "boot-$DATE.img" "vendor_boot-$DATE.img" > "recovery-$DATE.sha256")
echo "== upload $NAME to SourceForge: $SF_DIR"
{
    printf -- "-mkdir /home/frs/project/%s/derpfest\n-mkdir %s\n" "$SF_PROJECT" "$SF_DIR"
    for f in "$NAME" "$NAME.sha256" "boot-$DATE.img" "vendor_boot-$DATE.img" "recovery-$DATE.sha256"; do
        printf "put %s %s/%s\n" "$DEST/$f" "$SF_DIR" "$f"
    done
} | sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net > $T/sftp.log 2>&1 \
    || { tail -5 $T/sftp.log; fail "SourceForge upload failed"; }
echo "== upload to Google Drive: DerpFest/$dev"
~/upload-to-drive.sh DerpFest "$dev" "$DEST/$NAME" "$DEST/$NAME.sha256" || true
echo "== waiting for SourceForge to serve $URL"
for i in $(seq 1 60); do
    len=$(curl -sIL --max-time 60 "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:" {l=$2} END {print l}')
    [ "$len" = "$size" ] && break
    sleep 60
done
[ "$len" = "$size" ] || fail "SourceForge didn't serve the package within an hour (got length '$len', want $size)"
git -C "$REPO" pull -q --ff-only
fi

# 6. Publish the Updater JSON (DerpFest's format: org.lineageos.updater NetworkUpdate) and changelog, last
python3 - "$OUT/builds/$dev.json" <<EOF
import json, sys
entry = {
    "datetime": $ts,
    "filename": "$NAME",
    "id": "$sha256",
    "romtype": "Unofficial",
    "size": $size,
    "url": "$URL",
    "version": "v17",
}
with open(sys.argv[1], "w") as f:
    json.dump({"response": [entry]}, f, indent=2)
    f.write("\n")
EOF
{
    echo "DerpFest v17 (Android 17) for the $MODEL ($dev), build $DATE"
    echo "Security patch: $system_spl (system), $boot_spl (vendor). Stock Pixel firmware: $firmware."
    echo
    echo "Notes:"
    echo "=============================="
    echo "- Unofficial build, signed with its own keys: updates from other ROMs (Evolution X included) don't install on it, and moving between ROMs needs a clean install."
    echo "- The update includes the stock Pixel firmware (bootloader and radio)."
    echo "- Rooted? Before rebooting, install Magisk (or KernelSU) to the inactive slot, or root is gone after the update."
    echo "- Kernel: LineageOS's gs-6.1 kernel (Linux 6.1), built from source with the ROM."
    echo "- First installs need a computer: see $FORUM"
    echo
    echo "Device changes:"
    echo "=============================="
    last=$(cat "$DEST/LAST_DEVICE_COMMIT" 2>/dev/null || true)
    if [ -n "$last" ] && git -C $DEVTREE cat-file -e "$last" 2>/dev/null; then
        git -C $DEVTREE log --no-merges --format='%s' "$last..HEAD" | sed "s/^$dev: //; s/^/- /"
    else
        git -C $DEVTREE log --no-merges --format='%s' -10 HEAD | sed "s/^$dev: //; s/^/- /"
    fi
    echo
    echo "ROM changes since the last build:"
    echo "=============================="
    if [ -n "$CHANGES" ] && [ -s "$CHANGES" ]; then cat "$CHANGES"; else echo "None recorded"; fi
} > "$OUT/changelogs/$dev.txt"
if [ $PREVIEW = 1 ]; then
    cat "$OUT/builds/$dev.json"; echo "----- changelogs/$dev.txt"; cat "$OUT/changelogs/$dev.txt"
    exit 0
fi
export GIT_AUTHOR_NAME="Daryl Denson" GIT_AUTHOR_EMAIL="9751141+denson9874@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git -C "$REPO" add "builds/$dev.json" "changelogs/$dev.txt"
git -C "$REPO" commit -q -m "$dev: $NAME" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C "$REPO" push -q origin main || fail "pushing the JSON failed"
git -C $DEVTREE rev-parse HEAD > "$DEST/LAST_DEVICE_COMMIT"
echo "OTA_PUBLISHED $RAW/builds/$dev.json"
