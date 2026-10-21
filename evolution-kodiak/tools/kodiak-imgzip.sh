#!/bin/bash
# Pack a kodiak build's images into a zip for `fastboot update`.
# Firmware and vendor_kernel_boot are left out: they're flashed by the OTA and
# already match stock. super_empty.img comes from the stock factory image (same
# super layout as BoardConfig.mk), because this tree doesn't build one.
#
#   kodiak-imgzip.sh <product-out> <image-kodiak-*.zip> <output.zip>
#
# Root for test builds: KODIAK_ROOT=magisk (or the word "magisk" in
# ~/.kodiak-root) swaps in a Magisk-patched init_boot made by
# ~/kodiak-magisk-patch.sh. KODIAK_ROOT=none forces an unrooted zip.
# out/ is never modified, and the release OTA (m evolution) doesn't use
# this script.
set -euo pipefail
out="$(cd "$1" && pwd)"; factory="$2"; zip_out="$3"
root="${KODIAK_ROOT:-$(cat ~/.kodiak-root 2>/dev/null || true)}"
root="${root:-none}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

for img in boot init_boot dtbo pvmfw vendor_boot vbmeta vbmeta_system \
           vbmeta_vendor system system_dlkm system_ext product vendor vendor_dlkm; do
    [[ -f "$out/$img.img" ]] || { echo "missing $img.img" >&2; exit 1; }
    ln "$out/$img.img" "$work/" 2>/dev/null || cp "$out/$img.img" "$work/"
done
if [[ -f "$out/vendor_kernel_boot.img" ]]; then
    ln "$out/vendor_kernel_boot.img" "$work/" 2>/dev/null || cp "$out/vendor_kernel_boot.img" "$work/"
fi
cp "$out/android-info.txt" "$work/"
if [[ -f "$out/system_other.img" ]]; then
    cp "$out/system_other.img" "$work/"
    cp "$out/fastboot-info.txt" "$work/"
else
    # No dexpreopt: there is no system_other to flash to the other slot
    grep -v -- '--slot-other system system_other.img' "$out/fastboot-info.txt" > "$work/fastboot-info.txt"
fi
if [[ -f "$work/vendor_kernel_boot.img" ]] && ! grep -q "^flash vendor_kernel_boot" "$work/fastboot-info.txt"; then
    sed -i '/^flash vendor_boot/a flash vendor_kernel_boot' "$work/fastboot-info.txt"
fi
unzip -q -o -j "$factory" super_empty.img -d "$work"

case "$root" in
    none) ;;
    magisk)
        # init_boot.img in $work is a hard link to out/: replace it, don't edit it.
        rm -f "$work/init_boot.img"
        ~/kodiak-magisk-patch.sh "$out/init_boot.img" "$work/init_boot.img" | grep "^OK:"
        echo "init_boot.img is Magisk-patched (kodiak-magisk-patch.sh). To remove root, flash the unpatched out/init_boot.img to init_boot." > "$work/ROOT.txt"
        echo "ROOT: magisk"
        ;;
    *) echo "unknown KODIAK_ROOT=$root (use magisk or none)" >&2; exit 1 ;;
esac

rm -f "$zip_out"
(cd "$work" && zip -q -0 "$zip_out" ./*)
sha256sum "$zip_out" | tee "$zip_out.sha256"
