# Pixel 11 Pro XL (kodiak) for Evolution X 17

Device tree for Google Pixel 11 Pro XL (`kodiak`, Tensor G6 `malibu`, GKI
6.12), built from the stock factory image `CD1A.261005.003`.

Started from `aospdtgen 1.2.1` output, then restructured after LineageOS's
Tensor trees (`device/google/laguna`, `device/google/muzel`).

## Layout

| Image | Source |
| --- | --- |
| system, system_ext, product | built (Evolution X) |
| init_boot (generic ramdisk) | built |
| vendor_boot (first-stage fstab, recovery) | built |
| vbmeta, vbmeta_system, vbmeta_vendor | built (verification disabled: `--flags 3`) |
| boot (GKI kernel), dtbo | stock |
| pvmfw | built (AOSP) |
| vendor, vendor_dlkm, system_dlkm | stock |
| vendor_kernel_boot, bootloader/modem firmware | stock, flashed raw by the OTA |

Google publishes no malibu vendor sources (SELinux policy, HAL configs), so
vendor stays stock for now.

## Setup

```bash
# inside the Evolution X (cnb) tree
git clone <this repo> device/google/kodiak
device/google/kodiak/apply-patches.sh   # build/make fix for prebuilt partitions (until it's merged upstream)

# Stock factory image CD1A.261005.003 for kodiak, from https://developers.google.com/android/images
device/google/kodiak/extract-images.sh <kodiak-cd1a.261005.003-factory-*.zip>   # -> vendor/google/kodiak-images
cd device/google/kodiak && ./extract-files.py <dump of the factory image> && cd -   # -> vendor/google/kodiak

. build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m evolution
```

Build the `user` variant. `userdebug` mounts debugfs early, which the stock vendor
policy denies, and the display driver can panic on boot.

Neither generated vendor directory is published here. `vendor/google/kodiak-images`
holds whole stock partition images (vendor, vendor_dlkm, system_dlkm, boot, dtbo,
firmware), and `vendor/google/kodiak` holds the proprietary blobs from
`proprietary-files.txt`. Both are generated from Google's factory image.
