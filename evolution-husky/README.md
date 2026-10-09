# Evolution X (Android 17) for the Pixel 8 Pro (husky)

Evolution X's `cnb` manifest is LineageOS-based (`lunch lineage_<codename>-cp2a-user`,
`m evolution`), so LineageOS's own `lineage-24.0` husky trees and its `build_kernel`
envsetup function are used as-is. Blobs come from TheMuppets.

## Build (x86-64 Linux, ~64 GB RAM, ~1 TB disk)

```bash
mkdir evolution && cd evolution
repo init -u https://github.com/Evolution-X/manifest -b cnb --git-lfs --depth=1
mkdir -p .repo/local_manifests
cp /path/to/evolution-husky/local_manifests/husky.xml .repo/local_manifests/
repo sync -c -j4 --force-sync --no-clone-bundle --no-tags   # -j4: Google rate-limits (HTTP 429)
# Firmware the OTA ships must be >= the phone's (bootloader downgrades are refused):
/path/to/evolution-husky/update-firmware.sh . bootloader-husky-*.img radio-husky-*.img
. build/envsetup.sh
lunch lineage_husky-cp2a-userdebug
build_kernel            # kernel prebuilts into device/google/shusky-kernels/6.1
m evolution
```

After a rate-limited sync, re-sync projects that came down empty with `-j1`; a few AOSP
projects are legitimately empty ("Initial empty repository").

## Firmware

LineageOS's husky trees always put the vendor blobs' bootloader/modem firmware in the OTA.
`update-firmware.sh` unpacks a Google factory bootloader + radio with the tree's
`lineage/scripts/fbpacktool` into `vendor/google/husky/radio/` and rewrites the sha1s in that
repo's `Android.mk`. Builds since 2026-10-10 use CP3A.261005.005 firmware (bootloader
ripcurrent-17.0-15681527, radio g5300i-260604-260807-B-16036236).
