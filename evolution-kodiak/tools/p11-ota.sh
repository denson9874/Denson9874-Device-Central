#!/bin/bash
# Verify a device's signed A/B OTA package (built by `m evolution`) and, with --upload,
# publish it for the Updater: upload it to SourceForge next to the fastboot zip (manual
# downloads) and to the R2 bucket the OTA mirror serves (tools/ota_mirror), check the mirror
# serves it, then update builds/<dev>.json and changelogs/<dev>.txt in
# denson9874/evolution_ota (the repo the device tree's UpdaterOverlay points at). The JSON
# goes out last, so it never points at a file that isn't downloadable yet.
#
#   p11-ota.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--upload | --preview] [--changes <file>]
#
# --preview prints the JSON and changelog an upload would publish, without uploading.
#
# Checks: the package is A/B, for this device and from this build; its zip and payload
# signatures verify against the build's own otacerts.zip; the payload carries every
# partition the device tree lists (ROM plus firmware.txt; for cheetah and husky, the build's own
# AB_OTA_PARTITIONS list); its vbmeta has the same boot and
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
    grizzly) MODEL="Pixel 11 Pro";      FORUM=https://xdaforums.com/t/4804712/; TAG= ;;
    cubs)    MODEL="Pixel 11";          FORUM=https://xdaforums.com/t/4804723/; TAG= ;;
    yogi)    MODEL="Pixel 11 Pro Fold"; FORUM=https://xdaforums.com/t/4804826/; TAG= ;;
    # Evolution X's own trees (evolution-cheetah/)
    cheetah) MODEL="Pixel 7 Pro";       FORUM=https://xdaforums.com/t/4806248/; TAG= ;;
    # LineageOS's trees and TheMuppets' blobs (evolution-husky/)
    husky)   MODEL="Pixel 8 Pro";       FORUM=https://xdaforums.com/t/4805239/; TAG= ;;
    *) echo "usage: p11-ota.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--upload | --preview] [--changes <file>]" >&2; exit 2 ;;
esac

TOP=~/evolution; O=$TOP/out/target/product/$dev; H=$TOP/out/host/linux-x86/bin
# The device tree whose commits the changelog lists
DEVTREE=$TOP/device/google/$dev
if [ "$dev" = cheetah ]; then DEVTREE=$TOP/device/google/pantah; fi
if [ "$dev" = husky ]; then DEVTREE=$TOP/device/google/shusky; fi
DEST=~/releases/$dev; mkdir -p "$DEST"
SF_USER=daryldenson0405; SF_PROJECT=denson9874-s-user-builds; SF_DIR=/home/frs/project/$SF_PROJECT/$dev/17
# The Updater downloads from the OTA mirror; rclone's r2: remote writes to the bucket it serves
R2=r2:denson9874-ota/$dev/17; MIRROR=https://ota-mirror.daryldenson-apps.workers.dev/$dev/17
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
if [ "$dev" = cheetah ] || [ "$dev" = husky ]; then
    # What the payload must carry: the vendor repo's firmware partitions (its radio/*.img) and the ROM's
    need="$(grep -oE 'radio/[a-z0-9_]+\.img' $TOP/vendor/google/$dev/Android.mk | sed 's|radio/||; s|\.img$||' | sort -u | tr '\n' ' ')"
    need+="boot init_boot vendor_boot vendor_kernel_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor"
    # Plus the rest of the build's own list: AB_OTA_PARTITIONS as the images script saved it
    # after lunch, else target-files META (as a folder or only in the zip)
    tf=$O/obj/PACKAGING/target_files_intermediates
    ab=$(ls -t $O/ab_partitions.txt $tf/*/META/ab_partitions.txt 2>/dev/null | head -1 || true)
    tfz=$(ls -t $tf/*.zip 2>/dev/null | head -1 || true)
    if [ -n "$ab" ]; then
        want=$(cat "$ab")
    elif [ -n "$tfz" ]; then
        want=$(unzip -p "$tfz" META/ab_partitions.txt 2>/dev/null || true)
    else
        want=
    fi
    if [ -z "$want" ]; then
        echo "note: no META/ab_partitions.txt under $tf; checking the required partitions only"
        want=$(tr ' ' '\n' <<<"$need")
    fi
    for p in $need; do
        grep -qx "$p" <<<"$want" || fail "AB_OTA_PARTITIONS lacks $p"
    done
else
want=$(grep -v '^#' $TOP/device/google/$dev/firmware.txt | sed '/^$/d')
want+=$'\n'"boot init_boot vendor_kernel_boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor vendor_dlkm system_dlkm"
fi
missing=$(for p in $want; do grep -qx "$p" $T/partitions || echo "$p"; done)
[ -z "$missing" ] || fail "the payload lacks: $(echo $missing)"

# 4. vbmeta keeps the patch levels (KeyMint must never see them go missing or backwards)
mkdir $T/x
# Where the boot and system patch levels live: vbmeta.img, or for gs201 and zuma, whose boot and
# system partitions are chained, boot.img's footer and vbmeta_system.img.
AVB=vbmeta
if [ "$dev" = cheetah ] || [ "$dev" = husky ]; then AVB="vbmeta vbmeta_system boot"; fi
$H/ota_extractor -payload "$OTA" -payload_offset "$off" -output_dir $T/x -partitions "${AVB// /,}" > $T/x.log 2>&1 \
    || { tail -3 $T/x.log; fail "couldn't extract $AVB"; }
props() { local d=$1 i; for i in $AVB; do $H/avbtool info_image --image "$d/$i.img"; done | grep -oE "com\.android\.build\.(boot|system)\.security_patch -> '[0-9-]+'" | sort -u; }
[ "$(props $T/x | wc -l)" = 2 ] || fail "the OTA's $AVB lack the boot or system patch level"
[ "$(props $T/x)" = "$(props $O)" ] || fail "the OTA's patch levels differ from the build's $AVB images"
boot_spl=$(props $T/x | sed -n "s/.*boot.security_patch -> '\(.*\)'/\1/p")
system_spl=$(props $T/x | sed -n "s/.*system.security_patch -> '\(.*\)'/\1/p")
if [ "$dev" = cheetah ] || [ "$dev" = husky ]; then
    # cheetah's prepare.sh records the factory release it took the firmware from; otherwise
    # the vendor repo's firmware is the release its blobs (and stock fingerprint) come from
    firmware=$(tr a-z A-Z 2>/dev/null < $TOP/vendor/google/$dev/FIRMWARE_SOURCE ||
               grep -oE "$dev:17/[A-Z0-9]{4}\.[0-9]{6}\.[0-9]{3}" $DEVTREE/lineage_$dev.mk | head -1 | cut -d/ -f2)
else
firmware=$(grep -oE '^[a-z0-9]+\.[0-9]+\.[0-9]+' $TOP/vendor/google/$dev-images/SOURCE | tr a-z A-Z)
fi
echo "OTA_VERIFIED $OTA (patch levels: system $system_spl, vendor/boot $boot_spl; firmware $firmware)"
[ $UPLOAD = 1 ] || [ $PREVIEW = 1 ] || exit 0

# 5. Upload next to the fastboot zip, and to the mirror. A package already uploaded with the same
# content (marked <name>.uploaded; husky: the pack script uploads the OTA zip itself as the release)
# isn't uploaded to SourceForge again. A copy that never reached SourceForge is uploaded under its name.
# The mirror always gets it (rclone skips a copy it already has).
NAME=$ver$TAG.zip; r=2; REUSE=0
while [ -e "$DEST/$NAME" ]; do
    if cmp -s "$OTA" "$DEST/$NAME"; then
        [ -f "$DEST/$NAME.uploaded" ] && REUSE=1
        break
    fi
    NAME=$ver$TAG-r$r.zip; r=$((r + 1))
done
URL=$MIRROR/$NAME
size=$(stat -c %s "$OTA")
md5=$(md5sum "$OTA" | cut -d' ' -f1)
sha256=$(sha256sum "$OTA" | cut -d' ' -f1)
if [ $PREVIEW = 1 ]; then
    OUT=$T/preview; mkdir -p $OUT/builds $OUT/changelogs
else
OUT=$REPO; mkdir -p "$OUT/builds" "$OUT/changelogs"
if [ $REUSE = 1 ]; then
echo "== $NAME is already in $DEST (uploaded by the pack script); not uploading it to SourceForge again"
else
[ -e "$DEST/$NAME" ] || cp "$OTA" "$DEST/$NAME"
(cd "$DEST" && echo "$sha256  $NAME" > "$NAME.sha256")
echo "== upload $NAME to SourceForge: $SF_DIR"
printf -- "-mkdir /home/frs/project/%s/%s\n-mkdir %s\nput %s %s/%s\nput %s %s/%s\n" \
    "$SF_PROJECT" "$dev" "$SF_DIR" "$DEST/$NAME" "$SF_DIR" "$NAME" "$DEST/$NAME.sha256" "$SF_DIR" "$NAME.sha256" \
    | sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net > $T/sftp.log 2>&1 \
    || { tail -5 $T/sftp.log; fail "SourceForge upload failed"; }
touch "$DEST/$NAME.uploaded"
echo "== upload OTA to Google Drive: EvolutionX/$dev"
~/upload-to-drive.sh EvolutionX "$dev" "$DEST/$NAME" "$DEST/$NAME.sha256" || true
fi
echo "== upload $NAME to the OTA mirror: $R2"
~/bin/rclone copyto --s3-no-check-bucket "$DEST/$NAME" "$R2/$NAME" > $T/rclone.log 2>&1 \
    || { tail -5 $T/rclone.log; fail "R2 upload failed (rclone remote r2: missing? see tools/ota_mirror/README.md)"; }
len=$(curl -sIL --max-time 60 "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:" {l=$2} END {print l}')
[ "$len" = "$size" ] || fail "the OTA mirror doesn't serve $URL (got length '$len', want $size)"
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
# cheetah's and husky's HEAD carry our patches, re-applied (new hashes) on every run: list and
# record the upstream commits (the manifest revision repo checked out) instead.
DEVHEAD=HEAD
if [ "$dev" = cheetah ] || [ "$dev" = husky ]; then
    DEVHEAD=$(git -C $DEVTREE rev-parse --verify -q refs/remotes/m/cnb || git -C $DEVTREE rev-parse --verify -q refs/remotes/evox-devices/cnb || echo HEAD)
fi
{
    echo "Evolution X $(cut -d- -f5 <<<"$ver") (Android 17) for the $MODEL ($dev), build $(cut -d- -f3 <<<"$ver")"
    echo "Security patch: $system_spl (system), $boot_spl (vendor). Stock Pixel firmware $firmware."
    echo
    echo "Notes:"
    echo "=============================="
    [ -n "$TAG" ] && echo "- Untested: this build has never been booted on a $MODEL. If it doesn't boot, the phone goes back to the build you had."
    echo "- The update includes the stock Pixel firmware $firmware (bootloader and radio)."
    echo "- Rooted? Before rebooting, install Magisk (or KernelSU) to the inactive slot, or root is gone after the update."
    if [ "$dev" = "yogi" ]; then
        echo "- Kernel: stock Google GKI (Linux 6.12)."
    elif [ "$dev" = "cheetah" ]; then
        echo "- Kernel: Linux 6.1, Google's signed GKI with the Pixel 7 Pro's modules and device tree built from LineageOS's gs-6.1 kernel source."
    elif [ "$dev" = "husky" ]; then
        echo "- Kernel: Linux 6.1, Google's signed GKI with the Pixel 8 Pro's modules and device tree built from LineageOS's gs-6.1 kernel source."
    else
        echo "- Kernel: Espada v3 (Linux 6.12.92) by Kevtrejo37 (CASS scheduler, Simple LMK, GrapheneOS zram fix; source: https://github.com/atrejokm301/espada-kernel)."
    fi
    echo "- First installs need a computer: see $FORUM"
    echo
    echo "Device changes:"
    echo "=============================="
    last=$(cat "$DEST/LAST_DEVICE_COMMIT" 2>/dev/null || true)
    if [ -n "$last" ] && git -C $DEVTREE cat-file -e "$last" 2>/dev/null; then
        git -C $DEVTREE log --no-merges --format='%s' "$last..$DEVHEAD" | sed "s/^$dev: //; s/^/- /"
    else
        git -C $DEVTREE log --no-merges --format='%s' -10 $DEVHEAD | sed "s/^$dev: //; s/^/- /"
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
git -C $DEVTREE rev-parse $DEVHEAD > "$DEST/LAST_DEVICE_COMMIT"
# The mirror keeps this build and the one before it, for downloads still running (SourceForge keeps every build)
~/bin/rclone lsf --files-only --format tp "$R2" | sort | awk -F';' -v keep="$NAME" '$2 != keep {print $2}' | head -n -1 \
    | while read -r f; do ~/bin/rclone deletefile "$R2/$f"; done || echo "note: couldn't remove old builds from $R2"
echo "OTA_PUBLISHED $RAW/builds/$dev.json"
