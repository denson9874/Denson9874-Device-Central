# Pixel 11 Pro Fold (yogi) for Evolution X 17

Device tree for Google Pixel 11 Pro Fold (`yogi`, Tensor G6 `malibu`, GKI
6.12), built from the stock factory image `CD1A.261005.003`.

It's the Pixel 11 Pro XL (`kodiak`) tree adapted for yogi. Stock yogi and
kodiak share the bootloader, radio, kernel command line, partition layout and
first-stage ramdisk. The fold itself is described by the stock vendor
(`device_state_configuration.xml`, `display_layout_configuration.xml`), but
the framework, SystemUI and Settings fold behaviour (device states, hinge
area, rear display, per-state rotation, split shade, large-screen letterboxing)
comes from Google's product RROs, which this ROM doesn't ship. Those values
are generated from the stock yogi overlays with `tools/rro2xml.py` into
`rro_overlays/*Yogi`. The fingerprint sensor is in the power button
(`TARGET_HAS_UDFPS := false`).

**Untested:** this tree has not been booted on a yogi yet.

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
git clone <this repo> device/google/yogi
device/google/yogi/apply-patches.sh   # patches/: build/make (prebuilt partitions), frameworks/base (AOD brightness, favorites call lights, charging screensaver), vendor/gms (Dreamliner)

# Stock factory image CD1A.261005.003 for yogi, from https://developers.google.com/android/images
device/google/yogi/extract-images.sh <yogi-cd1a.261005.003-factory-*.zip>   # -> vendor/google/yogi-images
cd device/google/yogi && ./extract-files.py <dumpyara dump of the yogi image>   # -> vendor/google/yogi

. build/envsetup.sh
lunch lineage_yogi-cp2a-user
m
```

Build the `user` variant. `userdebug` mounts debugfs early, which the stock vendor
policy denies, and the display driver can panic on boot.

Extract the blobs from the phone's own image, never from kodiak's: their contents
match, but stock signs several of them with the phone's own platform key, and the
stock vendor SELinux policy only trusts that phone's key.
