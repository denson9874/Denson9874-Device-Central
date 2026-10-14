#!/bin/bash
# Verify a device's signed A/B OTA package (built by `m evolution`) and, with --upload,
# publish it for the Updater: upload it to SourceForge next to the fastboot zip, wait
# until SourceForge serves it, then update builds/<dev>.json and changelogs/<dev>.txt in
# denson9874/evolution_ota (the repo the device tree's UpdaterOverlay points at). The JSON
# goes out last, so it never points at a file that isn't downloadable yet.
#
#   p11-ota.sh <kodiak|grizzly|cubs|yogi> [--upload | --preview] [--changes <file>]
#
# --preview prints the JSON and changelog an upload would publish, without uploading.
#
# Checks: the package is A/B, for this device and from this build; its zip and payload
# signatures verify against the build's own otacerts.zip; the payload carries every
# partition the device tree lists (ROM plus firmware.txt); its vbmeta has the same boot and
# system patch levels as the build's vbmeta.img.
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
    kodiak)  MODEL="Pixel 11 Pro XL";   FORUM=https://xdaforums.com/t/4804712/; TAG= ;;
    grizzly) MODEL="Pixel 11 Pro";      FORUM=https://xdaforums.com/t/4804712/; TAG=-UNTESTED ;;
    cubs)    MODEL="Pixel 11";          FORUM=https://xdaforums.com/t/4804723/; TAG=-UNTESTED ;;
    yogi)    MODEL="Pixel 11 Pro Fold"; FORUM=https://xdaforums.com/t/4804826/; TAG=-UNTESTED ;;
    *) echo "usage: p11-ota.sh <kodiak|grizzly|cubs|yogi> [--upload | --preview] [--changes <file>]" >&2; exit 2 ;;
esac

TOP=~/evolution; O=$TOP/out/target/product/$dev; H=$TOP/out/host/linux-x86/bin
DEST=~/releases/$dev; mkdir -p "$DEST"
SF_USER=daryldenson0405; SF_PROJECT=denson9874-s-user-builds; SF_DIR=/home/frs/project/$SF_PROJECT/$dev/17
REPO=~/evolution_ota; RAW=https://raw.githubusercontent.com/denson9874/evolution_ota/cnb
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. The package of this build
ver=$(grep -h -m1 "^ro.evolution.build.version=" $O/system/build.prop $O/product/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)
[[ $ver == EvolutionX-*-$dev-* ]] || fail "can't read ro.evolution.build.version from $O"
OTA=$O/$ver.zip
[ -f "$OTA" ] || fail "no OTA package $OTA (the build has to run m evolution)"
unzip -p "$OTA" META-INF/com/android/metadata > $T/metadata || fail "$OTA has no OTA metadata"
grep -qx "ota-type=AB" $T/metadata || fail "not an A/B package"
grep -qx "pre-device=$dev" $T/metadata || fail "the package isn't for $dev"
ts=$(sed -n 's/^post-timestamp=//p' $T/metadata)
[ -n "$ts" ] && [ "$ts" = "$(sed -n 's/^ro.build.date.utc=//p' $O/system/build.prop)" ] \
    || fail "the package isn't from the current build (post-timestamp $ts)"

# 2. Signed with the key the build trusts for updates (zip and payload signatures)
unzip -q -o $O/system/etc/security/otacerts.zip -d $T/otacerts
certs=("$T"/otacerts/*)
[ ${#certs[@]} = 1 ] || fail "expected one certificate in otacerts.zip, found ${#certs[@]}"
$H/check_ota_package_signature "${certs[0]}" "$OTA" > $T/sig.log 2>&1 || { tail -5 $T/sig.log; fail "signature check failed"; }
grep -q "Payload signatures VERIFIED" $T/sig.log || fail "payload signatures not verified"

# 3. Every partition the device tree puts in the OTA, firmware included
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
want=$(grep -v '^#' $TOP/device/google/$dev/firmware.txt | sed '/^$/d')
want+=$'\n'"boot init_boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor vendor_dlkm system_dlkm"
missing=$(for p in $want; do grep -qx "$p" $T/partitions || echo "$p"; done)
[ -z "$missing" ] || fail "the payload lacks: $(echo $missing)"

# 4. vbmeta keeps the patch levels (KeyMint must never see them go missing or backwards)
mkdir $T/x
$H/ota_extractor -payload "$OTA" -payload_offset "$off" -output_dir $T/x -partitions vbmeta > $T/x.log 2>&1 \
    || { tail -3 $T/x.log; fail "couldn't extract vbmeta"; }
props() { $H/avbtool info_image --image "$1" | grep -oE "com\.android\.build\.(boot|system)\.security_patch -> '[0-9-]+'" | sort; }
[ "$(props $T/x/vbmeta.img | wc -l)" = 2 ] || fail "the OTA vbmeta lacks the boot or system patch level"
[ "$(props $T/x/vbmeta.img)" = "$(props $O/vbmeta.img)" ] || fail "the OTA vbmeta's patch levels differ from vbmeta.img"
boot_spl=$(props $T/x/vbmeta.img | sed -n "s/.*boot.security_patch -> '\(.*\)'/\1/p")
system_spl=$(props $T/x/vbmeta.img | sed -n "s/.*system.security_patch -> '\(.*\)'/\1/p")
firmware=$(grep -oE '^[a-z0-9]+\.[0-9]+\.[0-9]+' $TOP/vendor/google/$dev-images/SOURCE | tr a-z A-Z)
echo "OTA_VERIFIED $OTA (patch levels: system $system_spl, vendor/boot $boot_spl; firmware $firmware)"
[ $UPLOAD = 1 ] || [ $PREVIEW = 1 ] || exit 0

# 5. Upload next to the fastboot zip
NAME=$ver$TAG.zip; r=2
while [ -e "$DEST/$NAME" ]; do NAME=$ver$TAG-r$r.zip; r=$((r + 1)); done
URL=https://sourceforge.net/projects/$SF_PROJECT/files/$dev/17/$NAME/download
size=$(stat -c %s "$OTA")
md5=$(md5sum "$OTA" | cut -d' ' -f1)
sha256=$(sha256sum "$OTA" | cut -d' ' -f1)
if [ $PREVIEW = 1 ]; then
    OUT=$T/preview; mkdir -p $OUT/builds $OUT/changelogs
else
OUT=$REPO
cp "$OTA" "$DEST/$NAME"
(cd "$DEST" && echo "$sha256  $NAME" > "$NAME.sha256")
echo "== upload $NAME to SourceForge: $SF_DIR"
printf -- "-mkdir /home/frs/project/%s/%s\n-mkdir %s\nput %s %s/%s\nput %s %s/%s\n" \
    "$SF_PROJECT" "$dev" "$SF_DIR" "$DEST/$NAME" "$SF_DIR" "$NAME" "$DEST/$NAME.sha256" "$SF_DIR" "$NAME.sha256" \
    | sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net > $T/sftp.log 2>&1 \
    || { tail -5 $T/sftp.log; fail "SourceForge upload failed"; }
echo "== waiting for SourceForge to serve $URL"
for i in $(seq 1 60); do
    len=$(curl -sIL --max-time 60 "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:" {l=$2} END {print l}')
    [ "$len" = "$size" ] && break
    sleep 60
done
[ "$len" = "$size" ] || fail "SourceForge didn't serve the package within an hour (got length '$len', want $size)"
git -C "$REPO" pull -q --ff-only
fi

# 6. Publish the Updater JSON and changelog (last)
python3 - "$OUT/builds/$dev.json" <<EOF
import json, sys
entry = {
    "maintainer": "denson9874",
    "currently_maintained": True,
    "oem": "Google",
    "device": "$MODEL",
    "filename": "$NAME",
    "download": "$URL",
    "timestamp": $ts,
    "md5": "$md5",
    "sha256": "$sha256",
    "size": $size,
    "version": "$(cut -d- -f5 <<<"$ver")",
    "buildtype": "user",
    "forum": "$FORUM",
    "firmware": "https://developers.google.com/android/images#$dev",
    "paypal": "",
    "github": "denson9874",
    "initial_installation_images": [],
    "extra_images": [],
}
with open(sys.argv[1], "w") as f:
    json.dump({"response": [entry]}, f, indent=2)
    f.write("\n")
EOF
{
    echo "Evolution X $(cut -d- -f5 <<<"$ver") (Android 17) for the $MODEL ($dev), build $(cut -d- -f3 <<<"$ver")"
    echo "Security patch: $system_spl (system), $boot_spl (vendor). Stock Pixel firmware $firmware."
    echo
    echo "Notes:"
    echo "=============================="
    [ -n "$TAG" ] && echo "- Untested: this build has never been booted on a $MODEL. If it doesn't boot, the phone goes back to the build you had."
    echo "- The update includes the stock Pixel firmware $firmware (bootloader and radio)."
    echo "- Rooted? Before rebooting, install Magisk (or KernelSU) to the inactive slot, or root is gone after the update."
    echo "- A custom kernel is replaced by the stock one; flash it again after the update."
    echo "- First installs need a computer: see $FORUM"
    echo
    echo "Device changes:"
    echo "=============================="
    last=$(cat "$DEST/LAST_DEVICE_COMMIT" 2>/dev/null || true)
    if [ -n "$last" ] && git -C $TOP/device/google/$dev cat-file -e "$last" 2>/dev/null; then
        git -C $TOP/device/google/$dev log --no-merges --format='%s' "$last..HEAD" | sed "s/^$dev: //; s/^/- /"
    else
        git -C $TOP/device/google/$dev log --no-merges --format='%s' -10 | sed "s/^$dev: //; s/^/- /"
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
git -C "$REPO" push -q origin cnb || fail "pushing the JSON failed"
git -C $TOP/device/google/$dev rev-parse HEAD > "$DEST/LAST_DEVICE_COMMIT"
echo "OTA_PUBLISHED $RAW/builds/$dev.json"
