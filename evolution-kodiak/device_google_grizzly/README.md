# Pixel 11 Pro (grizzly) for Evolution X 17

Device tree for Google Pixel 11 Pro (`grizzly`, Tensor G6 `malibu`, GKI
6.12), built from the stock factory image `CD1A.261005.003`.

It's the Pixel 11 Pro XL (`kodiak`) tree adapted for grizzly. Stock grizzly
and kodiak share the bootloader, radio, kernel, kernel modules, kernel
command line, partition layout and first-stage ramdisk. They differ in the
screen (1280x2856), a few product props, the signing keys of some stock
apps, and one SELinux signer mapping (see `mac_permissions.xml`).

**Untested:** this tree has not been booted on a grizzly yet.

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
vendor stays stock.

## Setup

```bash
# inside the Evolution X (cnb) tree
git clone <this repo> device/google/grizzly
device/google/grizzly/apply-patches.sh   # patches/: build/make (prebuilt partitions), frameworks/base (AOD brightness, favorites call lights)

# Stock factory image CD1A.261005.003 for grizzly, from https://developers.google.com/android/images
device/google/grizzly/extract-images.sh <grizzly-cd1a.261005.003-factory-*.zip>   # -> vendor/google/grizzly-images
cd device/google/grizzly && ./extract-files.py <dumpyara dump of the grizzly image>   # -> vendor/google/grizzly

. build/envsetup.sh
lunch lineage_grizzly-cp2a-user
m
```

Build the `user` variant. `userdebug` mounts debugfs early, which the stock vendor
policy denies, and the display driver can panic on boot.

Extract the blobs from grizzly's own image, never from kodiak's: their contents
match, but stock signs several of them with the phone's own platform key, and the
stock vendor SELinux policy only trusts that phone's key.
