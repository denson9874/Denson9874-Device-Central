# DerpFest 17 (Android 17) for the Pixel 8 Pro (husky)

> **Unofficial build.** DerpFest lists husky as officially maintained by Adrian Szymański (@Adi20_01). The last official
> build is v16.2 (2026-06-12), and DerpFest-Devices has no 17 branch for husky yet. This is a Community/Unofficial
> Android 17 build by Daryl Denson until an official 17 build exists. It never uses DerpFest's official update server
> (see the Updater overlay below).

DerpFest 17 is LineageOS 24.0-based (`lunch lineage_<device>-cp2a-user`, `m derp`), so LineageOS's own lineage-24.0
husky trees are used, with TheMuppets blobs. Research behind every choice here: [`reports/DerpFest husky device tree sources.md`](../reports/DerpFest%20husky%20device%20tree%20sources.md).

## Build (x86-64 Linux, ~64 GB RAM)

```bash
# in a synced DerpFest 17 tree (DerpFest-AOSP/android_manifest, branch 17)
cp derpfest-husky/local_manifests/husky.xml .repo/local_manifests/
repo sync -c -j4 --no-tags --no-clone-bundle --force-sync \
    device/google/husky device/google/shusky device/google/zuma device/google/shusky-kernels vendor/google/husky
git -C vendor/google/husky lfs install --local && git -C vendor/google/husky lfs pull   # blobs are git-lfs
derpfest-husky/update-firmware.sh . bootloader-husky-ripcurrent-17.0-15681527.img radio-husky-g5300i-260604-260807-b-16036236.img
derpfest-husky/apply.sh .
# kernel prebuilts into device/google/shusky-kernels/6.1 (build_kernel, or the ones Evolution X husky ships)
SKIP_KERNEL_BUILD=1 . build/envsetup.sh
lunch lineage_husky-cp2a-user
m derp
```

On the build server, `~/derp-husky-build.sh` (here: `tools/derp-husky-build.sh`) does all of this in `~/derpfest`. It also
runs the offline checks and stages the OTA zip, boot/vendor_boot and checksums in `~/releases/derpfest-husky`. It
doesn't upload. Its last line is `=== DerpFest husky Build Finished: … (EXIT=<n>) ===`; 3 means a check failed.

## Sources (`local_manifests/husky.xml`)

| Path | Repo | Pin |
|---|---|---|
| device/google/husky | LineageOS/android_device_google_husky | 58fde14 (a stub: the tree lives in shusky) |
| device/google/shusky | LineageOS/android_device_google_shusky | bf38587 |
| device/google/zuma | LineageOS/android_device_google_zuma | f085107 |
| device/google/shusky-kernels | LineageOS/android_device_google_shusky-kernels | cd4a90f |
| vendor/google/husky | TheMuppets/proprietary_vendor_google_husky (git-lfs) | 7085ddc (CP2A.260805.005) |

- The pins are the official LineageOS 20261016 husky nightly's (its `build-manifest.xml`) plus the Muppets tip. The
  trees and the blobs are both from CP2A.260805.005. A CP3A update is open in LineageOS Gerrit, so bump all five
  together, never one.
- Everything else husky needs (hardware/google/pixel, pixel-sepolicy, camera, interfaces) is already in DerpFest's
  manifest. Don't add gs-common: lineage-24.0 zuma doesn't use it.
- **Face unlock:** LineageOS's 2026-10-12 commits after these pins (zuma "Enable face unlock", "Import face unlock
  overlays", shusky "Import face unlock overlays") are left out on purpose. DerpFest installs its own face unlock
  (ParanoidSense) by default, as in the official DerpFest 16.2 husky tree. Its other branch
  (`TARGET_FACE_UNLOCK_SUPPORTED := false`) asks for `SettingsGoogleFutureFaceEnroll`, which nothing in DerpFest 17
  defines (the build stops: `includes non-existent modules in PRODUCT_PACKAGES`).
- **Kernel:** GKI android14-6.1 (6.1.157), built by `build_kernel` from LineageOS's
  `android_kernel_google_gs-6.1_manifest` (lineage-24.0; `kernel/common` at `android14-6.1-2025-12_r30`). DerpFest's
  `lunch` would sync and build the whole kernel source again, so the build script copies the prebuilts Evolution X husky
  ships (from the same manifest) and sets `SKIP_KERNEL_BUILD=1`.
- **Firmware:** `update-firmware.sh` (the same script as Evolution X husky) replaces the blobs' CP2A firmware with
  CP3A.261005.005 (bootloader ripcurrent-17.0-15681527, radio g5300i-260604-260807-B-16036236), so the OTA never carries
  firmware older than the phone's.

## Patches

| Project | Patch | Change |
|---|---|---|
| device/google/shusky | `0001` | `lineage_husky.mk`: `TARGET_DOES_NOT_SUPPORT_GOOGLE_BATTERY := false` (PixelOS gms otherwise installs TurboAdapter_NoBatt) and `WITH_GMS_AICORE := true`, both before `common_full_phone.mk` because gms reads them while it's inherited; `PRODUCT_BUILD_IGNORE_APEX_CONTRIBUTION_CONTENTS := true`, as on DerpFest kodiak (gms adds extservices, which turns on the release config's Google APEX lists) |
| device/google/shusky | `0002` | `UpdaterOverlayDerpHusky`: points the Updater at `denson9874/evolution_ota` (`derpfest/builds/husky.json`), not DerpFest-AOSP/Updater-Stuff, whose husky.json lists the official builds (other keys). Delete it if this build becomes official |
| device/google/zuma | `0001` | Installs the Pixel default permissions as `default-permissions-zuma.xml`, so they don't silently lose to gms's `default-permissions.xml` (same as Evolution X) |
| vendor/google/husky | `0001` | Doesn't install `gpuflag`: the policy has no `gpuflag` domain, so init's child aborts at every boot (same as Evolution X) |
| vendor/google/husky | `0002` | Defers `AICorePrebuilt-aicore_20260302.01_RC00` and `DeviceIntelligenceNetworkPrebuiltAstrea` to vendor/pixel/gms. Soong stops otherwise: `found in multiple namespaces(vendor/pixel/gms/common and vendor/google/husky)`. Both are the same version, DeviceIntelligence byte-identical |

Evolution X husky patches that aren't needed here: the artifact-path allow-list (DerpFest sets
`DISABLE_ARTIFACT_PATH_REQUIREMENTS`), the zuma overlay removals (gms-17 suffixes its overlays `_GMS`), the nowplaying
deferral (gms-17 doesn't ship it), the maintainer overlay and BODEGA charging (Evolution X frameworks only), and the
app-odex-on-/system change (optional; not carried over for the first build).

## Release checks (no phone)

There's no husky to test on: Daryl's Pixel 8 Pro is in daily use. Builds go out without a phone test and without an
UNTESTED tag; users report issues on XDA or Telegram. `derp-husky-build.sh` checks offline: a `user` build,
husky vendor props, no `gpuflag`, `default-permissions-zuma.xml` present, no `TurboAdapter_NoBatt`, the 11 firmware
images in the target files byte-identical to the CP3A set, and BCR unmodified (DerpFest's `vendor/extra`).
