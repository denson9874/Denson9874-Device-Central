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
device/google/kodiak/apply-patches.sh   # build/make fix for prebuilt vendor
device/google/kodiak/extract-images.sh ~/android-dt/firmware/kodiak-cd1a.261005.003-factory-006d44d7.zip
. build/envsetup.sh
lunch lineage_kodiak-cp2a-userdebug
m evolution
```

`vendor/google/kodiak` contains Google's proprietary images. Never push it to a
public remote.
