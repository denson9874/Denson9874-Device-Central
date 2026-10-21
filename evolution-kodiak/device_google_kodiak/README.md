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
| boot, vendor_kernel_boot | Espada kernel (Linux 6.12.92, CASS + Simple LMK, plain flavor) by Kevtrejo37; stock GKI fallback |
| dtbo | stock |
| pvmfw | built (AOSP) |
| vendor, vendor_dlkm, system_dlkm | stock |
| bootloader/modem firmware | stock, flashed raw by the OTA |

Google publishes no malibu vendor sources (SELinux policy, HAL configs), so
vendor stays stock for now.

## Kernel Credits

- **Espada Kernel** by **Kevtrejo37** ([XDA Thread](https://xdaforums.com/t/4799975/), [Telegram](https://t.me/+DJmYe5_dfmwyODUx), [GitHub](https://github.com/atrejokm301/espada-kernel)). Features CASS scheduler, Simple LMK, measured EM, and upstream Linux 6.12 patches.
- ZRAM read-ahead fix by **The GrapheneOS Project**.
- Sultan Alsawaf for CASS and Simple LMK.


## Setup

```bash
# inside the Evolution X (cnb) tree
git clone <this repo> device/google/kodiak
device/google/kodiak/apply-patches.sh   # patches/: build/make (prebuilt partitions), frameworks/base (AOD brightness, favorites call lights, charging screensaver), vendor/gms (Dreamliner)

# Stock factory image CD1A.261005.003 for kodiak, from https://developers.google.com/android/images
device/google/kodiak/extract-images.sh <kodiak-cd1a.261005.003-factory-*.zip>   # -> vendor/google/kodiak-images
git clone https://github.com/denson9874/vendor_google_kodiak vendor/google/kodiak   # or: ./extract-files.py <dump>

. build/envsetup.sh
lunch lineage_kodiak-cp2a-user
m evolution
```

Build the `user` variant. `userdebug` mounts debugfs early, which the stock vendor
policy denies, and the display driver can panic on boot.

`vendor/google/kodiak` holds the proprietary blobs from `proprietary-files.txt`:
[vendor_google_kodiak](https://github.com/denson9874/vendor_google_kodiak), or regenerate it
with `extract-files.py`. `vendor/google/kodiak-images` holds whole stock partition images
(vendor, vendor_dlkm, system_dlkm, boot, dtbo, firmware). It isn't published; generate it from
Google's factory image with `extract-images.sh`.
