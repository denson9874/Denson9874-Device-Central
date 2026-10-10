#!/bin/bash
# Pack a kodiak build's images into a zip for `fastboot update`.
# Firmware and vendor_kernel_boot are left out: they're flashed by the OTA and
# already match stock. super_empty.img comes from the stock factory image (same
# super layout as BoardConfig.mk), because this tree doesn't build one.
#
#   kodiak-imgzip.sh <product-out> <image-kodiak-*.zip> <output.zip>
set -euo pipefail
out="$(cd "$1" && pwd)"; factory="$2"; zip_out="$3"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

for img in boot init_boot dtbo pvmfw vendor_boot vbmeta vbmeta_system \
           vbmeta_vendor system system_dlkm system_ext product vendor vendor_dlkm; do
    [[ -f "$out/$img.img" ]] || { echo "missing $img.img" >&2; exit 1; }
    ln "$out/$img.img" "$work/" 2>/dev/null || cp "$out/$img.img" "$work/"
done
cp "$out/android-info.txt" "$work/"
if [[ -f "$out/system_other.img" ]]; then
    cp "$out/system_other.img" "$work/"
    cp "$out/fastboot-info.txt" "$work/"
else
    # No dexpreopt: there is no system_other to flash to the other slot
    grep -v -- '--slot-other system system_other.img' "$out/fastboot-info.txt" > "$work/fastboot-info.txt"
fi
unzip -q -o -j "$factory" super_empty.img -d "$work"

rm -f "$zip_out"
(cd "$work" && zip -q -0 "$zip_out" ./*)
sha256sum "$zip_out" | tee "$zip_out.sha256"
