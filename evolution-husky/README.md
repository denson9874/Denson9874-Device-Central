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
/path/to/evolution-husky/apply.sh .      # device patches below (idempotent)
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

## Patches

LineageOS's husky trees build unchanged on LineageOS; Evolution X adds Pixel-style overlays,
GMS and extra /system apps that collide with them:

| Project | Change |
|---|---|
| device/google/shusky | `lineage_husky.mk` allow-lists Evolution X's /system additions (AppDataBackup, five vendor/gms system apps) under generic_system.mk's artifact-path rules. Evolution's skip-on-Pixel check for AppDataBackup can't work: it reads PRODUCT_MANUFACTURER, which inherited product makefiles never see |
| device/google/zuma | Drops nine RRO overlays whose names vendor/pixel-style also defines (Evolution's copies are supersets); installs the Pixel default permissions as `default-permissions-zuma.xml` so they don't collide with vendor/gms's `default-permissions.xml` |
| vendor/google/husky | Defers `DeviceIntelligenceNetworkPrebuiltAstrea` (vendor/gms ships a newer one) and 16 byte-identical Pixel sysconfig/default-permission XMLs to vendor/gms |
