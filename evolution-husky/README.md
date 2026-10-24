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
lunch lineage_husky-cp2a-user
build_kernel            # kernel prebuilts into device/google/shusky-kernels/6.1
m evolution
```

On the Hetzner build server (`157.180.50.152`), husky is part of the weekly routine since 2026-10-24, like the Pixel 11 phones and cheetah:

```bash
~/p11-routine.sh husky [--no-sync] [--no-upload]
```

It takes the tree lock, checks out the husky projects and re-applies `apply.sh` (plus the shared `device/google/kodiak/apply-patches.sh`), builds with `~/husky-images.sh` (`lineage_husky-cp2a-user`, `build_kernel`, `m evolution`), runs `~/release-checks.sh husky`, then `~/husky-release-pack.sh` (verify, recovery images, the `.device-ok` gate, upload), and `~/p11-ota.sh husky` publishes `builds/husky.json` in `denson9874/evolution_ota` for the Updater. The release zip is the OTA package, so `p11-ota.sh` publishes the file the pack script uploaded instead of uploading it twice. `~/husky-build.sh` (manual build) still works.

**OTA path:** builds before 2026-10-24 asked Evolution X's own feed (`Evolution-X/OTA`, no husky entry) and never offered an update. shusky `0005` points the Updater at `denson9874/evolution_ota`; users on 20261023 or older install the first build with it by sideload, then get updates in Settings.

After a rate-limited sync, re-sync projects that came down empty with `-j1`; a few AOSP projects are legitimately empty ("Initial empty repository").

## Firmware

LineageOS's husky trees always put the vendor blobs' bootloader/modem firmware in the OTA. Since 2026-10-24 the trees and TheMuppets' blobs are CP3A.261005.005 (shusky 5eceafc, zuma 9eeeb27b, vendor f80d252d; vendor security patch 2026-10-05), and their firmware is byte-identical to the factory release (bootloader ripcurrent-17.0-15681527, radio g5300i-260604-260807-B-16036236), so `update-firmware.sh` is only needed when Google ships firmware newer than the blobs. It unpacks a Google factory bootloader + radio with the tree's `lineage/scripts/fbpacktool` into `vendor/google/husky/radio/` and rewrites the sha1s in that repo's `Android.mk` (an uncommitted change: commit it, or `repo sync` refuses to check the project out).

## Patches

LineageOS's husky trees build unchanged on LineageOS; Evolution X adds Pixel-style overlays, GMS, extra /system apps, and maintainer branding:

| Project | Patch | Change |
|---|---|---|
| device/google/shusky | `0001` | `lineage_husky.mk` allow-lists Evolution X's /system additions (AppDataBackup, five vendor/gms system apps) under generic_system.mk's artifact-path rules. Evolution's skip-on-Pixel check for AppDataBackup can't work: it reads PRODUCT_MANUFACTURER, which inherited product makefiles never see |
| device/google/shusky | `0002` | Adds `overlay-evolution` to `DEVICE_PACKAGE_OVERLAYS` and provides `evolution_strings.xml` configuring `build_maintainer_summary` to "Daryl Denson (Unofficial)" |
| device/google/zuma | `0001` | Drops nine RRO overlays whose names vendor/pixel-style also defines (Evolution's copies are supersets); common.mk installs them by name |
| device/google/zuma | `0002` | Installs the Pixel default permissions as `default-permissions-zuma.xml` so they don't collide with vendor/gms's `default-permissions.xml` |
| device/google/shusky | `0003` | Keeps app odex on /system: zip/OTA installs never write `system_other`, so SystemUIGoogle and Settings otherwise lose their AOT code after every update ([plan](HUSKY_PERF_CHARGING_PLAN.md) F1) |
| device/google/shusky | `0004` | Installs SCONE (Adaptive Connectivity) and Tycho (Google Fi): vendor/gms defines both, but gms_full.mk's PRODUCT_MANUFACTURER gate never matches under inherit-product. Without it Play installed SCONE as a user app, which crashed after boot (ISS-20261022-06) |
| device/google/shusky | `0005` | `UpdaterOverlayHusky`: the Updater reads `denson9874/evolution_ota` (Evolution X has no husky cnb feed) |
| device/google/shusky | `0006` | `NfcOverlayHusky`: NFC on after a clean flash (LineageOS's NfcOverlay turns it off), plus stock's URL-open dialog for three carriers. As kodiak e016d25 |
| device/google/shusky | `0007` | `disable-google-ota.xml`: Play services doesn't prepare Google's OTAs, which armed resume-on-reboot and made the first unlock after a reboot ask for the PIN twice. As kodiak |
| device/google/zuma | `0003` | PinnerService pins `SystemUIGoogle.apk` (the SystemUI we ship) instead of a non-existent `SystemUI.apk` |
| device/google/zuma | `0004` | Restart SystemUI in the advanced reboot menu, as gs201 and the Pixel 11 trees |
| device/google/zuma | `0006` | Keeps `app_domain(ssr_detector_app)` in private policy: the CP3A import put it in system_ext/public, and its type_transition rules stop version_policy (`plat_pub_versioned.cil`) |
| device/google/zuma | `0005` | Doesn't install LineageOS's 2022 `allowlist_com.google.android.as.xml`: it restricted Private Compute Services to ASI and AICore, which stock CP3A doesn't (stock's ASI rules come from vendor/gms) |
| device/google/shusky | `0008` | Stock values our build left at the AOSP default, copied from stock CP3A.261005.005's overlays by `rro2xml.py` (camera pinning, Play Store pre-reboot compile, Play Protect events, 3440x1600 external display peak, screenshot editor/Files/Quick Share copy, avatar picker, Settings slices, 5 GHz Wi-Fi thresholds, Photos in the photo picker) |
| vendor/google/husky | `0001` | Defers `DeviceIntelligenceNetworkPrebuiltAstrea` (vendor/gms ships a newer one) and 17 byte-identical Pixel sysconfig/default-permission XMLs (google_build.xml and nowplaying_app_26q1.xml included) to vendor/gms |
| vendor/google/husky | `0002` | Adds a `BODEGA` power hint and a conservative `bodega` charge-thermal profile ([plan](HUSKY_PERF_CHARGING_PLAN.md) workstream A). **Known limitation (found 2026-10-24):** the profile went into `thermal_info_config_charge.json`, which only the off-mode charger reads; in Android the tile shows but changes nothing. Making it work means adding the profile to `thermal_info_config.json`, which loosens charging temperature limits in normal use: do that only with a supervised charge test |
| vendor/google/husky | `0004` | One Android System Intelligence: the Pixel 8 Pro build (`DevicePersonalizationAiAiPrebuiltPixel2023`) overrides vendor/gms's Pixel 11 build (`...Pixel2026`); both are com.google.android.as and PackageManager kept the higher-versioned Pixel 11 one |
| device/google/shusky | `0010` | `ro.vendor.usb.userspace.aoa.enabled=false`: CP3A's usb_accessory_utils can hand accessory mode (wired Android Auto) to the userspace `aoad` daemon, which this platform lacks; a build prop is read-only, so accessory mode stays on the kernel's accessory function as with CP2A |
| vendor/google/husky | `0005` | The gadget HAL's group and init.zuma.usb.rc's FunctionFS owners name `aoad` by number (1103): the platform has no aoad AID, and host_init_verifier stopped the build. Drop `0005`/shusky `0010` once the platform gains AID_AOAD and aoad (system/core + system/usb upstream) |
| device/google/shusky | `0009` | Stock's TrustTokenService root keys (`vendor_required_trust_token_roots` and timestamp), which zuma `0001` dropped with the tree's GoogleConfigOverlay |
| vendor/google/husky | `0003` | Doesn't install `gpuflag` (+ its rc and library): our policy has no `gpuflag` domain, so init's child aborted at every boot, and it targets another SoC's GPU anyway |
| frameworks/base | `0009`, `0010` | App Lock Recents and the Dynamic Bar island without blur (also carried by `device/google/kodiak/patches`, which every build from this tree applies) |

Stability, fluidity and charging capture: `tools/husky-audit.sh {baseline|fluidity|charge}` (see the plan).

## Upstream `cnb` Parity Highlights (2026-10-16)

- **Photos Tensor Detection:** Google Photos correctly identifies the Tensor G3 processor, restoring Photo Unblur, Magic Eraser, and Ultra HDR processing.
- **Play Integrity Hardening:** Upstream PIF updates integrated for passing `MEETS_DEVICE_INTEGRITY` and CTS.
- **Quick Settings Security:** Sensitive QS tiles (Data, Hotspot, Wi-Fi) require device unlock when triggered from secure lock screen.
- **Typography & UI:** Upstream Google Sans Flex and Material 3 Expressive typography polish.
- **Evolution X 12.3 Uprev:** Platform version 12.3 with updated bootanimations and theme engine.

## Community Releases

- **Telegram posts (archived):** [archive/evolution-husky/](../archive/evolution-husky/)
- **XDA Release Thread Draft:** [XDA_RELEASE_HUSKY.bbcode](XDA_RELEASE_HUSKY.bbcode)

## Hardware Verification Status (Tested on Physical Pixel 8 Pro)

- Boots on slot `_b`, verified boot green, kernel 6.1.157 from `build_kernel`, October firmware kept (payload firmware hashes verified against CP3A.261005.005).
- Device gate: 10/10 on two consecutive runs.
- Wi-Fi, Bluetooth, NFC service, 2 camera devices, fingerprint, face, audio, 43 sensors, 120/60 Hz, GMS + Play Store present.
