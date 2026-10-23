# Evolution X (Android 17) for the Pixel 8 Pro (husky)

> **Unofficial Maintainer Note:**  
> Because there is an active official maintainer for Android 16 Evolution X (Giovanni / TechPanelGM), this build is not and will never be an official Evolution X build. Daryl Denson (@daryldenson) hosts and maintains this Android 17 (`cnb`) build as the **Unofficial Maintainer** for the Pixel 8 Pro community.

Evolution X's `cnb` manifest is LineageOS-based (`lunch lineage_<codename>-cp2a-user`, `m evolution`), so LineageOS's own `lineage-24.0` husky trees and its `build_kernel` envsetup function are used as-is. Blobs come from TheMuppets.

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

On the Hetzner build server (`157.180.50.152`), the automated build script is available at `/home/build/husky-build.sh`. It waits automatically for the tree lock (`~/.evolution-tree.lock`), applies all patches idempotently, lunches `lineage_husky-cp2a-userdebug`, compiles via `m evolution -j16`, and archives the resulting zip and sha256 checksum to `~/releases/husky/`.

After a rate-limited sync, re-sync projects that came down empty with `-j1`; a few AOSP projects are legitimately empty ("Initial empty repository").

## Firmware

LineageOS's husky trees always put the vendor blobs' bootloader/modem firmware in the OTA. `update-firmware.sh` unpacks a Google factory bootloader + radio with the tree's `lineage/scripts/fbpacktool` into `vendor/google/husky/radio/` and rewrites the sha1s in that repo's `Android.mk`. Builds use CP3A.261005.005 firmware (bootloader ripcurrent-17.0-15681527, radio g5300i-260604-260807-B-16036236).

## Patches

LineageOS's husky trees build unchanged on LineageOS; Evolution X adds Pixel-style overlays, GMS, extra /system apps, and maintainer branding:

| Project | Patch | Change |
|---|---|---|
| device/google/shusky | `0001` | `lineage_husky.mk` allow-lists Evolution X's /system additions (AppDataBackup, five vendor/gms system apps) under generic_system.mk's artifact-path rules. Evolution's skip-on-Pixel check for AppDataBackup can't work: it reads PRODUCT_MANUFACTURER, which inherited product makefiles never see |
| device/google/shusky | `0002` | Adds `overlay-evolution` to `DEVICE_PACKAGE_OVERLAYS` and provides `evolution_strings.xml` configuring `build_maintainer_summary` to "Daryl Denson (Unofficial)" |
| device/google/zuma | `0001` | Drops nine RRO overlays whose names vendor/pixel-style also defines (Evolution's copies are supersets); common.mk installs them by name |
| device/google/zuma | `0002` | Installs the Pixel default permissions as `default-permissions-zuma.xml` so they don't collide with vendor/gms's `default-permissions.xml` |
| device/google/shusky | `0003` | Keeps app odex on /system: zip/OTA installs never write `system_other`, so SystemUIGoogle and Settings otherwise lose their AOT code after every update ([plan](HUSKY_PERF_CHARGING_PLAN.md) F1; needs on-device confirmation) |
| vendor/google/husky | `0001` | Defers `DeviceIntelligenceNetworkPrebuiltAstrea` (vendor/gms ships a newer one) and 16 byte-identical Pixel sysconfig/default-permission XMLs to vendor/gms |
| vendor/google/husky | `0004` | Doesn't install `gpuflag` (+ its rc and library): our policy has no `gpuflag` domain, so init's child aborted at every boot, and it targets another SoC's GPU anyway |
| vendor/google/husky | `0003` | Defers `nowplaying_app_26q1.xml` to vendor/gms, which installs the byte-identical file since its CD1A update (the duplicate stopped the build) |
| vendor/google/husky | `0002` | Adds a `BODEGA` power hint and a conservative `bodega` charge-thermal profile so the shared Extreme Charging tile works on husky ([plan](HUSKY_PERF_CHARGING_PLAN.md) workstream A) |

Stability, fluidity and charging capture: `tools/husky-audit.sh {baseline|fluidity|charge}` (see the plan).

## Upstream `cnb` Parity Highlights (2026-10-16)

- **Photos Tensor Detection:** Google Photos correctly identifies the Tensor G3 processor, restoring Photo Unblur, Magic Eraser, and Ultra HDR processing.
- **Play Integrity Hardening:** Upstream PIF updates integrated for passing `MEETS_DEVICE_INTEGRITY` and CTS.
- **Quick Settings Security:** Sensitive QS tiles (Data, Hotspot, Wi-Fi) require device unlock when triggered from secure lock screen.
- **Typography & UI:** Upstream Google Sans Flex and Material 3 Expressive typography polish.
- **Evolution X 12.3 Uprev:** Platform version 12.3 with updated bootanimations and theme engine.

## Community Releases

- **Telegram Post Draft:** [TELEGRAM_UPDATE_HUSKY.md](TELEGRAM_UPDATE_HUSKY.md)
- **XDA Release Thread Draft:** [XDA_RELEASE_HUSKY.bbcode](XDA_RELEASE_HUSKY.bbcode)

## Hardware Verification Status (Tested on Physical Pixel 8 Pro)

- Boots on slot `_b`, verified boot green, kernel 6.1.157 from `build_kernel`, October firmware kept (payload firmware hashes verified against CP3A.261005.005).
- Device gate: 10/10 on two consecutive runs.
- Wi-Fi, Bluetooth, NFC service, 2 camera devices, fingerprint, face, audio, 43 sensors, 120/60 Hz, GMS + Play Store present.
