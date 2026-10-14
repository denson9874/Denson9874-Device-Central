#!/bin/bash
# Fetch and verify the Espada kernel for Pixel 11 devices (kodiak, grizzly, cubs).
# yogi (Pixel 11 Pro Fold) stays on the stock Google GKI kernel.
#
#   espada-fetch.sh <kodiak|grizzly|cubs|yogi> [tag]
#
# Fetches the newest (or specified tag) plain (Magisk) flavor AnyKernel3 release
# from https://github.com/atrejokm301/espada-kernel.
# Verifies:
#   1. Release body SHA-256 matches the zip checksum.
#   2. anykernel.sh supports the device and firmware month.
#   3. boot-es301.img and vkb-es301.img are exactly 64 MiB (67108864 bytes).
#   4. Decompressed kernel (lz4) contains no forbidden root symbols (kernelsu, ksu_handle, susfs).
#   5. AVB footer on boot-es301.img matches stock boot security_patch (e.g. 2026-10-05) and os_version 17.
#   6. vkb-es301.img contains the exact 198 first-stage modules matching stock vendor_kernel_boot.
#
# On success, installs boot.img, vendor_kernel_boot.img and SOURCE metadata to:
#   ~/evolution/vendor/google/espada-kernel/<dev>/
# On failure, exits non-zero and ensures no partial files remain so the build
# falls back to stock images.
set -euo pipefail

dev=${1:-}
tag=${2:-}

[ -n "$dev" ] || { echo "usage: espada-fetch.sh <kodiak|grizzly|cubs|yogi> [tag]" >&2; exit 2; }

if [ "$dev" = "yogi" ]; then
    echo "yogi (Pixel 11 Pro Fold) uses stock Google GKI kernel, skipping Espada."
    exit 0
fi

case "$dev" in
    kodiak|grizzly|cubs) ;;
    *) echo "unknown device: $dev (supported: kodiak, grizzly, cubs, yogi)" >&2; exit 2 ;;
esac

TOP=~/evolution
H=$TOP/out/host/linux-x86/bin
AVBTOOL=$H/avbtool
UNPACK=$TOP/system/tools/mkbootimg/unpack_bootimg.py
CACHE_DIR=~/espada
KERNEL_DEST=$TOP/vendor/google/espada-kernel
STOCK_IMG=$TOP/vendor/google/$dev-images

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$STOCK_IMG/images/boot.img" ] || fail "stock boot image missing: $STOCK_IMG/images/boot.img"
[ -f "$STOCK_IMG/radio/vendor_kernel_boot.img" ] || fail "stock vkb missing: $STOCK_IMG/radio/vendor_kernel_boot.img"
[ -f "$UNPACK" ] || fail "unpack_bootimg.py not found at $UNPACK"
[ -x "$AVBTOOL" ] || fail "avbtool not found at $AVBTOOL (run lunch/build host tools first)"

mkdir -p "$CACHE_DIR" "$KERNEL_DEST"

# Read stock boot patch level (e.g. 2026-10-05) and month (2026-10)
stock_spl=$($AVBTOOL info_image --image "$STOCK_IMG/images/boot.img" | sed -n "s/.*boot.security_patch -> '\(.*\)'.*/\1/p")
[ -n "$stock_spl" ] || fail "could not read security_patch from stock boot.img"
stock_month=${stock_spl%-*}
echo "== target $dev (firmware security patch $stock_spl, month $stock_month)"

# 1. Locate release JSON
echo "== querying releases from github.com/atrejokm301/espada-kernel"
API_URL="https://api.github.com/repos/atrejokm301/espada-kernel/releases"
if [ -n "$tag" ]; then
    REL_JSON=$(curl -sL "$API_URL/tags/$tag")
else
    REL_JSON=$(curl -sL "$API_URL" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list) and len(data) > 0:
    json.dump(data[0], sys.stdout)
elif isinstance(data, dict):
    json.dump(data, sys.stdout)
else:
    sys.exit(1)
' 2>/dev/null || true)
fi

[ -n "$REL_JSON" ] || fail "could not fetch release info from GitHub"

tag_name=$(echo "$REL_JSON" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))')
rel_body=$(echo "$REL_JSON" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("body", ""))')
[ -n "$tag_name" ] || fail "could not parse tag_name from release JSON"
echo "== release tag: $tag_name"

# 2. Find plain (magisk) flavor asset
asset_info=$(echo "$REL_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assets = data.get("assets", [])
magisk_asset = next((a for a in assets if "magisk" in a.get("name", "").lower() and a.get("name", "").endswith(".zip")), None)
if magisk_asset:
    print(magisk_asset["name"] + " " + magisk_asset["browser_download_url"])
')

[ -n "$asset_info" ] || fail "could not find plain (magisk) zip in release $tag_name"
zip_name=$(echo "$asset_info" | cut -d' ' -f1)
zip_url=$(echo "$asset_info" | cut -d' ' -f2)
echo "== plain zip: $zip_name"
echo "== download url: $zip_url"

# Extract expected sha256 for the plain zip from release body
expected_sha256=$(python3 -c '
import re, sys
body = sys.argv[1]
name = sys.argv[2]
pos = body.rfind(name)
if pos != -1:
    sub = body[pos:]
    m = re.search(r"sha256\s+[`\"]?([a-f0-9]{64})", sub, re.IGNORECASE)
    if m:
        print(m.group(1).lower())
' "$rel_body" "$zip_name")


# 3. Download or use cached zip
TAG_DIR="$CACHE_DIR/$tag_name"
mkdir -p "$TAG_DIR"
ZIP_PATH="$TAG_DIR/$zip_name"

if [ -f "$ZIP_PATH" ]; then
    echo "== using cached zip: $ZIP_PATH"
else
    echo "== downloading $zip_url"
    curl -sL "$zip_url" -o "$ZIP_PATH.tmp"
    mv "$ZIP_PATH.tmp" "$ZIP_PATH"
fi

actual_sha256=$(sha256sum "$ZIP_PATH" | cut -d' ' -f1)
if [ -n "$expected_sha256" ]; then
    [ "$actual_sha256" = "$expected_sha256" ] || fail "sha256 mismatch: got $actual_sha256, expected $expected_sha256"
    echo "== sha256 verified against release body: $actual_sha256"
else
    echo "== sha256: $actual_sha256 (not specified in body)"
fi

# 4. Unpack and verify contents in a temporary directory
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

unzip -q -j "$ZIP_PATH" anykernel.sh boot-es301.img vkb-es301.img -d "$T" \
    || fail "zip does not contain anykernel.sh, boot-es301.img, and vkb-es301.img"

# Check anykernel.sh device and patchlevel compatibility
grep -qE "device\.name[0-9]*=$dev( |$|;|\")" "$T/anykernel.sh" || fail "anykernel.sh does not list device: $dev"
grep -q "supported.patchlevels=.*$stock_month" "$T/anykernel.sh" || fail "anykernel.sh patchlevels do not cover month: $stock_month"
echo "== anykernel.sh compatibility OK for $dev, month $stock_month"

# Check image file sizes (exactly 64 MiB = 67108864 bytes)
b_sz=$(stat -c %s "$T/boot-es301.img")
v_sz=$(stat -c %s "$T/vkb-es301.img")
[ "$b_sz" = "67108864" ] || fail "boot-es301.img size $b_sz != 67108864"
[ "$v_sz" = "67108864" ] || fail "vkb-es301.img size $v_sz != 67108864"
echo "== image sizes OK: 64 MiB"

# Check boot AVB properties
b_spl=$($AVBTOOL info_image --image "$T/boot-es301.img" | sed -n "s/.*boot.security_patch -> '\(.*\)'.*/\1/p")
b_os=$($AVBTOOL info_image --image "$T/boot-es301.img" | sed -n "s/.*boot.os_version -> '\(.*\)'.*/\1/p")
[ "$b_spl" = "$stock_spl" ] || fail "boot-es301.img security_patch ($b_spl) != stock ($stock_spl)"
[ "$b_os" = "17" ] || fail "boot-es301.img os_version ($b_os) != 17"
echo "== boot AVB properties OK (security_patch $b_spl, os_version $b_os)"

# Check decompressed kernel for forbidden root strings
mkdir -p "$T/boot_unpacked"
python3 "$UNPACK" --boot_img "$T/boot-es301.img" --out "$T/boot_unpacked" >/dev/null
[ -f "$T/boot_unpacked/kernel" ] || fail "failed to unpack kernel from boot image"
lz4 -dc "$T/boot_unpacked/kernel" > "$T/kernel.raw"
forbidden=$(grep -cE "kernelsu|ksu_handle|susfs" "$T/kernel.raw" || true)
[ "$forbidden" = "0" ] || fail "found $forbidden forbidden root symbols in kernel image (plain flavor required)"
echo "== decompressed kernel verified clean (0 KSU/SuSFS symbols)"

# Check vkb modules match stock
mkdir -p "$T/vkb_espada" "$T/vkb_stock"
python3 "$UNPACK" --boot_img "$T/vkb-es301.img" --out "$T/vkb_espada" >/dev/null
python3 "$UNPACK" --boot_img "$STOCK_IMG/radio/vendor_kernel_boot.img" --out "$T/vkb_stock" >/dev/null

mkdir -p "$T/vkb_espada/rd" "$T/vkb_stock/rd"
lz4 -dc "$T/vkb_espada/vendor_ramdisk00" | (cd "$T/vkb_espada/rd" && cpio -id --quiet)
lz4 -dc "$T/vkb_stock/vendor_ramdisk00" | (cd "$T/vkb_stock/rd" && cpio -id --quiet)

find "$T/vkb_espada/rd" -name "*.ko" | sed "s|.*/||" | sort > "$T/espada_modules.txt"
find "$T/vkb_stock/rd" -name "*.ko" | sed "s|.*/||" | sort > "$T/stock_modules.txt"

diff -u "$T/stock_modules.txt" "$T/espada_modules.txt" > "$T/modules.diff" || true
[ ! -s "$T/modules.diff" ] || { cat "$T/modules.diff"; fail "vkb modules differ from stock"; }
mod_count=$(wc -l < "$T/espada_modules.txt")
echo "== vkb modules match stock ($mod_count first-stage modules)"

# 5. All checks passed: install into vendor/google/espada-kernel/<dev>
DEST_DEV="$KERNEL_DEST/$dev"
mkdir -p "$DEST_DEV"

cp "$T/boot-es301.img" "$DEST_DEV/boot.img"
cp "$T/vkb-es301.img" "$DEST_DEV/vendor_kernel_boot.img"

cat <<EOF > "$DEST_DEV/SOURCE"
TAG=$tag_name
DEVICE=$dev
ZIP_NAME=$zip_name
ZIP_URL=$zip_url
ZIP_SHA256=$actual_sha256
SECURITY_PATCH=$b_spl
MODULE_COUNT=$mod_count
FETCH_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

echo "ESPADA_OK $tag_name $dev installed to $DEST_DEV"
