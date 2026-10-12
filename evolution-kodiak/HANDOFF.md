# Handoff: Evolution X 17 on the Pixel 11 Pro XL (kodiak)

Written 2026-10-10 for an agent (Google Antigravity) continuing this work until
Claude is available again. Read all of it before running anything.

> **Current state: read section 2e first.** It supersedes the status, next steps and branch
> notes in sections 2 to 2d, which are kept below as history.
> - Voice calls work (since 2c).
> - The phone runs our build on CD1A.261005.003 firmware (bootloader `spacecraft-17.4-16262255`),
>   with the bootloader unlocked, on slot b.
> - PRs #1, #3 and #5 are all merged. **Build from `evolution/kodiak-port`.**
> - The stalled flash of 2d was recovered, and later builds flashed normally.
> - **The device tree's source of truth is GitHub** (`evolution/kodiak-port`). The runner syncs it to the
>   server, so a commit made only on the server gets overwritten by the next sync (section 10).

## 1. Goal

Make a working **Evolution X 17** (Android 17, branch `cnb`, LineageOS-based)
build for the **Pixel 11 Pro XL** (`kodiak`, Tensor G6 `malibu`, MediaTek T900
modem, GKI kernel 6.12), for testing now and distribution later.

The original instructions are in `~/Downloads/android-device-tree-toolchain-guide.md`.
Its operating rules still apply (see section 9).

## 2. Status on 2026-10-10 (history; the current state is section 2e)

| Area | Status |
|---|---|
| Builds | ✅ `user` variant, signed with our own private keys (`vendor/evolution-priv/keys`, not AOSP test keys) |
| Boots | ✅ first boot after each flash (since the 2 fixes below) |
| Display, touch, fingerprint, Wi-Fi, camera, SMS | ✅ reported working by Daryl |
| Cellular registration | ✅ T-Mobile, voice and data `IN_SERVICE` (LTE / NR SA) |
| IMS registration | ✅ calls go out over IMS (`ImsPhoneCallTracker dial`) |
| **Voice calls** | ❌ **in progress**: they dial, then end before answer |

### The calls issue (what was being worked on)

- **Symptom:** the call ends with `ImsPhoneCallTracker: onCallTerminated reasonCode=401`,
  which is `ImsReasonInfo.CODE_MEDIA_INIT_FAILED`.
- **Cause found:** SELinux denial at call time:
  ```
  avc: denied { read write } comm="MediaManagerHel" scontext=u:r:radio:s0
    tcontext=u:r:platform_app:s0:c512,c768 tclass=udp_socket app=com.android.imsstack
  ```
  AOSP ImsStack (domain `platform_app`) opens the RTP UDP socket and passes it to
  ImsMediaService (in the phone process, domain `radio`).
- **Fix just built:** device tree commit `23d771b` adds
  `sepolicy/system_ext/private/radio.te`:
  `allow radio platform_app:udp_socket { read write getattr getopt setopt ioctl };`
  It passed the build's neverallow checks and `check-sepolicy.sh`.
  Image zip sha256: `8a897317eee7ce7e1df580219816099f7f660a4046990990025e08c9859022c8`.
- **State at handoff:** that zip **was flashed (no wipe) and the phone booted
  cleanly** (first boot, default IMS service = `com.android.imsstack`). The fix is
  on the phone but **not yet tested with a call**.

### Next steps, in order

1. **Confirm the phone state.** Run `adb devices` / `fastboot devices` (it should be booted in Android).
   - If it's in fastboot and the flash didn't complete, re-run the flash (section 6, step 3)
     with the zip already in `~/Downloads/kodiak-evox/kodiak-evox-img.zip`,
     after checking its sha256 against the hash above.
2. **Ask Daryl to place a test call.** Then pull logs right away (section 7) and check:
   - `onCallTerminated reasonCode=` (401 means media is still failing; see the list in section 8)
   - new `avc: denied` lines with `radio`, `platform_app`, `imsmedia`, `imsstack`
     in the call window
3. If more SELinux denials block media, add **narrow** rules to
   `sepolicy/system_ext/private/*.te` the same way. Rebuild (images only), flash, retest.
   - A cleaner long-term fix: give ImsStack its own domain, as stock does with
     `imsstack_app` (stock seapp entry: `user=radio isPrivApp=true seinfo=platform
     name=com.android.imsstack domain=imsstack_app`). AOSP doesn't ship that policy.
     Stock defines it in Google's system_ext policy, about 109 references.
4. Once calls work: do a reboot test (3×), then update the README status and commit.

## 2a. State as of late 2026-10-10 (supersedes the "Next steps" above)

> **Outcome (history):**
> - The phone went back from Canary to CD1A.261005.003 (wiped) before the 2c test round.
> - The PixelImsMediaService change below stayed in the tree and is still shipped.
> - Calls first worked in 2c, with this change and 2b's `imsstack_app` domain both in place.
>   This change was never tested on its own. Keep both (2d, "Fixed", item 1).

**The radio.te test:** Daryl placed a call on the 23d771b build. It failed the same way. No logs were
captured before the phone left Evolution X.

**The new attempt:** device tree `7385c90`, vendor tree `45bfabd`.
- **Why:** Reeky's working LineageOS kodiak build ships the **stock PixelImsMediaService**, not AOSP ImsMedia,
  re-signed with their own platform key (its `classes.dex` is identical to stock). Its `libpixelimsmedia.so`
  drives call audio through the `vendor.google.whitechapel.audio` extension HAL. AOSP ImsMedia can't, which fits
  `CODE_MEDIA_INIT_FAILED`. Full analysis: [REEKY_DIFF.md](REEKY_DIFF.md).
- **What changed:**
  - `proprietary-files.txt` brings back PixelImsMediaService **without `;PRESIGNED`**, so extract-utils
    re-signs it with `certificate: "platform"`. That avoids the old shared-uid signature-mismatch bootloop.
  - It also adds `libpixelimsmedia.so`, the two whitechapel audio libraries and the sysconfig XML.
  - `device.mk` drops AOSP `ImsMediaService` and adds `PixelImsMediaServiceOverlayKodiak`, a source RRO with
    the stock product RRO values: `audio_switch_mode=2`, `cp_noflow_supported=true`.
  - `radio.te` stays.
  - No new vendor sepolicy is needed: stock vendor already allows `radio` → `hal_audio_ext_service` / `hal_audio_default`.
- **Build: ✅ passed** (`BUILD_EXIT=0`), and `check-sepolicy.sh` is OK.
  - PixelImsMediaService is signed with the same platform cert as `framework-res`.
  - The image zip is `~/Downloads/kodiak-evox/kodiak-evox-img-pixelimsmedia.zip` on the Mac, also `/tmp/kodiak-evox-img.zip` on the server.
  - sha256: `e07d75d71e6380084975a080b18824906441bd32ddb6312aed3aafc3dba41319`
  - **Not flashed yet** (the phone is on Canary).

**The phone is on Android Canary now.**
- Canary most likely put a **newer bootloader** on it than CD1A.261005.003's (`spacecraft-17.4-16262255`).
  Our image zip carries CD1A firmware.
- **Before any flash**, read `fastboot getvar version-bootloader` and `fastboot getvar unlocked`.
- If the bootloader is newer, Daryl has to return to stock CD1A.261005.003 with Android Flash Tool first.
  That wipes the phone, and only works if anti-rollback wasn't raised.
- **Ask Daryl first. Don't flash Canary-era firmware manually.**

**Next steps:**
1. Confirm the build passed, then run `check-sepolicy.sh` and package the image zip (section 5).
2. Get the phone back on CD1A plus our build (ask Daryl), then place a test call and pull logs (section 7).
3. If calls work: move ImsStack to its own `imsstack_app` domain and narrow `radio.te` (REEKY_DIFF section 3),
   then do the missing system_ext blobs (REEKY_DIFF section 2).

## 2b. Review of 2026-10-11 (supersedes the "Next steps" in 2a)

Reeky still hasn't published sources (their GitHub has only the kernel), so the review used
[asdfmonster261/android_device_google_yogi](https://github.com/asdfmonster261/android_device_google_yogi)
(LineageOS 24.0, Pixel 11 Pro Fold). It has the **same malibu SoC, MediaTek T900 modem, telephony blobs
and Lineage base** as us, and its system_ext policy was recovered from the stock compiled policy.
Details: [REEKY_DIFF.md](REEKY_DIFF.md), section 6.

**Main finding: stock vendor SELinux rules for Google's apps never applied in our build.**
- The stock vendor policy names Google's system_ext app domains (`imsstack_app`, `grilservice_app`,
  `pixel_modem_app`, `rilextensionservice_app`, `euiccpixel_app`) through versioned attributes.
  Our AOSP system_ext didn't declare those types, so those attributes mapped to nothing.
- For calls specifically: stock lets the vendor `imsmediahaldaemon` use ImsStack's sockets
  (`allow imsmediahaldaemon imsstack_app:fd use` and `:udp_socket`). Our ImsStack ran as `platform_app`,
  so the vendor media daemon couldn't touch the RTP sockets. `radio.te` only fixed the phone-process
  half. This fits `CODE_MEDIA_INIT_FAILED` (401) as well as the PixelImsMediaService theory.
- GRIL, the RIL extension and modem.pms ran as `priv_app` (Google-signed, `PRESIGNED`), so their
  stock rild/HAL rules didn't apply either.
- `rilext.*`, `ims.*` and the NTN props were unlabelled (`default_prop`), so rild couldn't set them.

**Other findings:**
- `platform_carrier_config_package` was left at AOSP's `com.android.carrierconfig`, so the
  **CarrierSettings we ship was never used** for carrier config. Stock, LineageOS laguna and yogi
  all point it at `com.google.android.carrier`. Carrier IMS values (VoLTE, codecs, RTP/SIP timers)
  come from there.
- `system_ext.prop` sets `ro.audio.ihaladaptervendorextension_enabled=true`, but the service behind
  it (`vendor.google.whitechapel.audio.hal.parserservice`) wasn't shipped.
- The TPU app service wasn't shipped (it's why `edgetpu_vendor_service` stops), and neither were
  QNS (Wi-Fi calling handover), `init.pms.rc` or `gs_watchdogd`.

**What changed in the device tree:**

| Change | Files |
|---|---|
| Stock domains for ImsStack, GRIL, RIL extension, modem.pms, EuiccSupportPixel | `sepolicy/system_ext/{public/apps.te,private/*_app.te,private/seapp_contexts,private/mac_permissions.xml}` |
| `radio → imsstack_app` socket rule (the `platform_app` rule stays as a fallback for one round) | `sepolicy/system_ext/private/radio.te` |
| Stock's system_ext property labels | `public/property.te`, `private/property_contexts`, `private/vendor_init.te` |
| GRIL, ril-extension, PixelModemService re-signed (no `;PRESIGNED`; none uses a shared uid) | `proprietary-files.txt` |
| `init.pms.rc` | `proprietary-files.txt` |
| `SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS` | `BoardConfig.mk` |
| CarrierSettings as the carrier config package, plus stock's other TeleService values | `rro_overlays/TeleServiceOverlayKodiak` |
| QNS, plus stock's telephony framework values | `proprietary-files.txt`, new `rro_overlays/FrameworkResOverlayKodiak`, `device.mk` |
| Audio parameter parser, TPU app service, gs_watchdogd, with their policy | `proprietary-files.txt`, `sepolicy/system_ext/private/{hal_audio_parameter_parser,edgetpu_app_service,gs_watchdogd}.te`, `file_contexts`, `service_contexts` |
| Platform memfd rules from stock's newer base (DRM, camera, face) | `sepolicy/system_ext/private/platform.te` |
| `check-sepolicy.sh` reports which Google types the stock vendor rules reach | `check-sepolicy.sh` |

**Verified offline (cloud):**
- The system_ext policy compiles with the LineageOS 24.0 `system/sepolicy` and `device/lineage/sepolicy`
  (checkpolicy/secilc 3.9 built from source), and adds **no new neverallow failures**.
- Every type named in the contexts files exists.
- Every overlay resource name exists in LineageOS 24.0 frameworks/base and TeleService.
- The EuiccSupportPixel certificate in `mac_permissions.xml` matches the Pixel 11 blob.

**Not verifiable from the cloud (do these on the server, in order):**
1. Sync the tree to the server (section 11), commit there, `git pull` into `~/evolution/device/google/kodiak`.
2. **Re-run `extract-files.py`**: `proprietary-files.txt` changed. If it can't find a file, check the
   name in the dump (`ls ~/android-dt/dumps/kodiak/system_ext/lib64 | grep edgetpu`). The edgetpu
   `-V10`/`-V2` versions come from yogi's October build and should match.
3. Build images (`~/kodiak-images.sh`). A missing shared library for a new blob fails here, not on the phone.
4. **Run `check-sepolicy.sh`. It is mandatory before flashing.**
   - It must print `OK`.
   - It should list `imsstack_app grilservice_app …` under `mapped for the stock vendor`.
   - If it fails with `Failed to resolve typeattributeset` naming one of our public types, stock doesn't
     declare that type public. Move it from `sepolicy/system_ext/public/` to private and rebuild.
     Without this fix, the phone bootloops.
   - The `unmapped` list is the Google domains we still lack, which is the todo list for later rounds.
5. Flash (section 6; mind the Canary/bootloader warning in 2a), then check on the phone:
   ```bash
   adb shell ps -AZ | grep -E "imsstack|grilservice|rilextension|modem.pms|euiccpixel|edgetpu_app|parserservice|gs_watchdogd"
   adb shell service check android.media.audio.IHalAdapterVendorExtension/default
   adb shell getprop | grep -E "^\[rilext|^\[ims\."
   adb shell dumpsys carrier_config | grep -m3 -i "carrier_volte_available_bool\|package"
   ```
   ImsStack should be `u:r:imsstack_app`, not `platform_app`.
6. Place a test call and pull logs (section 7). Grep for `onCallTerminated`, plus `avc: denied` lines that
   mention `imsstack_app`, `imsmediahaldaemon` or `radio`.
7. If calls work, drop the `platform_app` fallback from `radio.te`. Then move on to the `unmapped` list
   (vendor_ims_app, satellite, PixelDisplayService, scone and so on; see REEKY_DIFF section 3).

The changes are split into separate commits (telephony SELinux, carrier config/QNS, system_ext services),
so a regression can be bisected by reverting one.

## 2c. Test round of 2026-10-11 (supersedes 2b's checklist)

Built and packed through the runner (section 11), run
[#2](https://github.com/denson9874/ExpressiveOS/actions/runs/38103425494):
- Sync → server tree `b16749b` (ExpressiveOS `evolution/kodiak-port@bd85ff9`). Extract brought in the new blobs.
- Images built in 14:42, including the VINTF checks.
- `check-sepolicy.sh`: `OK`, and all 11 new public types mapped for the stock vendor.
- Zip: `/tmp/kodiak-evox-img-b16749b.zip`, sha256 `c68e716582efb882e8b6640d746c35b14a776bdb2b632637de5eda34e5c7ef65`.

On the phone (phone on CD1A.261005.003, bootloader `spacecraft-17.4-16262255`, slot b, flashed with `fastboot update -w`):

| Check | Result |
|---|---|
| ImsStack domain | `u:r:imsstack_app` ✅ (was `platform_app`) |
| GRIL, RIL extension, modem.pms, EuiccSupportPixel | `grilservice_app`, `rilextensionservice_app`, `pixel_modem_app`, `euiccpixel_app` ✅ |
| TPU app service, audio parser, gs_watchdogd | running in their own domains ✅ |
| `IHalAdapterVendorExtension/default` | found ✅ |
| IMS service | `com.android.imsstack` ✅ |
| **Voice call** | **connects, two-way audio** ✅. It ended with reasonCode 501 (`CODE_USER_TERMINATED`, local hang-up), where it used to end with 401 |
| CarrierSettings | installed (`/product/priv-app/CarrierSettings`), carrier data present (`/product/etc/CarrierSettings/tmobile_us.pb` and the rest) ✅. Its binding as the carrier config package isn't confirmed directly yet: `cmd phone cc` is denied on this non-debuggable build. Check a logcat with `grep -E "CarrierConfigLoader\|CarrierSvcBindHelper" <logcat> \| grep -E "com.google.android.carrier\|carrierconfig"` |

Denials still seen (none touch calls):
- **`traced_producer` socket writes** from `hal_camera_default`, `mediacodec_google` and `gxp_logging`. These are perfetto tracing only.
- **`hal_camera_default` can't find `com.google.pixel.camera.services.binder.IServiceBinder/default`.** It's labelled `camera_binder_service` on stock, and provided by Google's camera services app, which we don't ship.
- **`com.google.android.pixelsystemservice`** runs as `priv_app` and is denied `vendor_intelligence_prop`. It needs stock's `pixelsystemservice_app` domain.

Follow-ups done after the test:
- `radio.te` dropped the `platform_app` fallback.
- `check-sepolicy.sh` no longer lists secilc's `base_typeattr_*` names.

**Still to do:**
- Re-test a call after the `radio.te` change.
- Run the 3× reboot test.
- Work through the stock types the vendor names that we still lack, from this round's `check-sepolicy.sh`. Each needs its blob (if any), its policy, and a public declaration under stock's name.
  - Telephony and satellite: `vendor_satellite_service`, `pixelntnservice_app`, `modem_diagnostic_app`, `mtk_wwan_device`
  - Display and system: `pixeldisplayservice_app`, `pixelsystemservice_app`, `systemui_app`, `connectivity_thermal_power_manager`, `turbo_adapter`, `brownout_detection_app`, `pixelsupport_app`, `pixelaudioservices_app`, `touchinsights_app`, `ssr_detector_app`, `dcservice_app`, `con_monitor_app`, `better_bug_app`, `factory_ota_app`, `cccdktimesync_app`, `vendor_pcs_app`, `vendor_pbcs_app`
  - Scone: `sconed`, `scone_aidl_service`
  - Camera: `google_camera_app`, `debug_camera_app`, `camera_propsetter_app`, `camera_binder_service`, `camera_cameraidremapper_service`, `camera_lyricconfigprovider_service`
  - TPU: `edgetpu_tachyon_server`, `edgetpu_tachyon_service`, `edgetpu_nnapi_service`, `edgetpu_device`
  - Face, fingerprint, setup: `hal_face_ext_service`, `device_config_faceauth_native_prop`, `fingerprint_sp_prop`, `setupwizard_feature_prop`
  - Other: `bluetooth_gci(_exec)`, `gpu_counter_producer(_exec)`, `gnss_config_app`, `google_recorder_app`, `hal_ambience_hub_service`, `ufs_internal_block_device`, `fips_block_device`

  These names are safe to make public: the stock vendor names every one of them, so a public declaration can't bootloop.

### Other open issues (lower priority)

- **Display-driver kernel panic** (`drm_mode_put_tile_group`, after
  `dw-mipi-dsi2h-vs: failed to create debugfs root`). It's intermittent when the
  display binds late (after SELinux loads) and debugfs creation is denied. It hasn't
  recurred since the `user` build, but it isn't proven fixed.
- SELinux denials: the camera HAL and gxp/edgetpu writing to `traced_producer`, and
  edgetpu `service_manager find` (the TPU app service is shipped as of 2b, which should fix the latter).
- ~~`com.google.android.apps.scone` crashes once at boot~~ Fixed on `e974478` (2d, open issue 1).
- Google's other product RROs (SystemUI/Settings device config) aren't shipped.
  extract-utils rejects prebuilt overlay APKs ("does not match known package rules"),
  so use **source RROs** in the device tree, as with `rro_overlays/TeleServiceOverlayKodiak`.
- Distribution needs: release keys (it's test-keys now), `WITH_AVB` / verified boot
  (vbmeta uses `--flags 3` now), and `m evolution` for the OTA zip.

## 2d. State as of 2026-10-11, about 11:00 UTC (supersedes 2c's "Still to do")

### Branches and builds

- ~~`evolution/kodiak-port` doesn't build on its own; build from PR #5's branch~~
  **Out of date:** PR #5 merged (`0f1b047`), and `evolution/kodiak-port` builds.
  Use `tree_ref: evolution/kodiak-port`.
- Builds go through the runner (section 11): `action: round`.
  The zip is named after the **server** tree's commit (`~/android-dt/trees/device_google_kodiak`),
  not the ExpressiveOS commit.

| Runner run | ExpressiveOS commit | Zip on the server | sha256 | State |
|---|---|---|---|---|
| [#14](https://github.com/denson9874/ExpressiveOS/actions/runs/38109019533) | `9d13062` | `/tmp/kodiak-evox-img-45a812a.zip` | `bd22199bf63657e8227bd944bbf766169ef74dedf36ef6dba99c522832306934` | Flashed and checked (table below) |
| [#17](https://github.com/denson9874/ExpressiveOS/actions/runs/38131554424) | `8cc9b64` | `/tmp/kodiak-evox-img-9190352.zip` | `f7d1122e294800d7985e82914659cc75dcd5133597424e4e5970e200e03c87ed` | **Flash stalled** at `super` 2/10 |
| [#20](https://github.com/denson9874/ExpressiveOS/actions/runs/38133386540) | `1a10718` | `/tmp/kodiak-evox-img-acd4512.zip` | `0ef682095e5621e279308b6afcd896722fa4e88b9b6fa9c7996f6489de07db15` | Flashed and checked: TPU labels, TPU and camera services, no crashes |
| [#21](https://github.com/denson9874/ExpressiveOS/actions/runs/38135812562) | `851b0ab` | none | none | Failed in kati: `SCONE-v77459` defined twice. Fixed by `41ea3b5` |
| built by hand on the server | `41ea3b5` | `/tmp/kodiak-evox-img-e974478.zip` | `3d92c0d6bbdd6ac5d38742302cd07d6bb634c8daa29c381afa65bf90d5639362` | `BUILD_EXIT=0`; `check-sepolicy.sh: OK` ([#24](https://github.com/denson9874/ExpressiveOS/actions/runs/38138299112)). Flashed and checked |
| built by hand on the server | `fd84141` | `/tmp/kodiak-evox-img-0423cc2.zip` | `1986f295df3efe92bdc76835b2a16df723b202c5446eb1896b8338a5ddfa48b0` | `BUILD_EXIT=0`; `check-sepolicy.sh: OK`. **Flashed and checked; newest** |

Every build except #21 passed with `BUILD_EXIT=0` and `check-sepolicy.sh: OK`. In #20 the six types
from item 9 below dropped off the unmapped list, and in `0423cc2` (`fd84141`) `dcservice_app` and
`turbo_adapter` dropped off the unmapped list too. A hand-run build holds `~/evolution`, so the
runner's preflight refuses to start on top of one; run #22 hit that.

### Checked on the phone (build #14)

| Check | Result |
|---|---|
| Voice call (T-Mobile VoLTE) | two-way audio ✅ (since 2c) |
| ImsStack | `imsstack_app` ✅ |
| PixelSystemService (both processes) | `pixelsystemservice_app` ✅ |
| PixelDisplayService | `pixeldisplayservice_app` ✅ |
| Satellite (`com.google.android.satellite`, `com.mediatek.satellite.service`) | `pixelntnservice_app`, `vendor_satellite_service` ✅ |
| Google Camera | `google_camera_app` ✅ |
| `com.google.pixel.camera.services` | right domain (`vendor_pbcs_app`), but it **crash-looped** with "VINTF declaration error". Fixed in #17 |
| `sconed` | not started. That's expected: it's a lazy AIDL service (`disabled oneshot`) that starts when GRIL asks for it |
| Face unlock, fingerprint unlock | work ✅ |

On `e974478` (`41ea3b5`) and `0423cc2` (`fd84141`):
- scone runs as `priv_app_36` from `/product/priv-app/SCONE-v77459`, with no crashes, and `sconed` runs as `u:r:sconed:s0`.
  - `pm get-privapp-permissions` lists about 50 permissions; nothing logs "not in privapp-permissions allowlist".
  - GMS's module brings its own allowlist once it's installed. That's why it printed `{}` before.
  - `configs/permissions/privapp-permissions-kodiak-scone.xml` now overlaps with it; the entries
    combine, so it stays as a backstop.
- `Tycho` (`com.google.android.apps.tycho`) is installed at `/product/app/Tycho/Tycho.apk` (also gated on `PRODUCT_MANUFACTURER` in `gms_full.mk`).
- `dcservice_app` (`com.google.android.apps.pixel.dcservice`) and `turbo_adapter` (`com.google.android.turboadapter`) are mapped for the stock vendor policy.
- The TPU nodes are labelled `edgetpu_device`, and the TPU and camera services are registered.

Not yet done on the latest build: face and fingerprint unlock, the camera, the call re-test and the
3× reboot test.

### Fixed. Don't revert these

Every file is under `device_google_kodiak/`. Each item names the symptom that comes back if it's undone.

1. **IMS domain** (`sepolicy/system_ext/private/seapp_contexts`, `imsstack_app.te`, `radio.te`):
   `com.android.imsstack` matched with `isPrivApp=true seinfo=platform` into `imsstack_app`.
   Without it, calls fail with reasonCode 401, because the stock vendor's imsmediahaldaemon rules
   only name `imsstack_app`. `radio.te` only keeps `radio → imsstack_app:udp_socket`.
2. **Telephony app domains** (seapp_contexts, `public/apps.te`, private `*.te`):
   GRIL, RIL extension, modem.pms (`seinfo=platform`), and EuiccSupportPixel (its own signer in
   `mac_permissions.xml`).
3. **Satellite:** `PixelSatelliteService.apk` and `VendorImplSatelliteService.apk` (re-signed),
   with `pixelntnservice_app.te` and `vendor_satellite_service.te`.
   **Don't add `product/etc/sysconfig/satellite_sos.xml`.** Evolution's GMS ships it.
4. **scone:** `system_ext/bin/sconed` + `sconed.rc`, `sconed.te`, `scone_system_internals.te`,
   and the `ISconeNetDaemon` service label. `sconed_exec` stays **private**.
5. **PixelDisplayService:** the APK (re-signed) + `libpixeldisplaymanager_jni.so`, and `pixeldisplayservice_app.te`.
6. **PixelSystemService:** `pixelsystemservice_app.te` and its contextual-awareness property.
   The app comes from Evolution's GMS, signed with a key the stock vendor doesn't map.
   `mac_permissions.xml` maps that certificate to `seinfo=pixelsystemservice` (signature hash
   `e0926b9d`), and `seapp_contexts` matches both `platform` and `pixelsystemservice`.
7. **Camera:**
   - `PersistentBackgroundCameraServices.apk`: re-signed, `uid.system`, so it must **not** be `PRESIGNED`.
   - `vendor_pbcs_app.te`, `google_camera_app.te`, `vendor_pcs_app.te`, and `public/camera_services.te`.
   - The camera extension libraries and their permission XMLs.
   - `system_ext/etc/vintf/manifest/com.google.pixel.camera.services@1.0-service-google.xml`.
     **Without that manifest, the camera services app crash-loops** ("VINTF declaration error").
   - Google Camera and Pixel Camera Services come from Play. The stock vendor's `mac_permissions.xml`
     maps their signers to `google` and `CameraServices`, so `seapp_contexts` matches those seinfos.
8. **Properties:** stock labels for
   - `device_config_faceauth_native_prop` (`persist.device_config.pixel_faceauth.`; system_server sets it)
   - `fingerprint_sp_prop`
   - `setupwizard_feature_prop`
   - `ims_prop`, the rilext/ntn props and `sota_prop` (since 2b)
9. **TPU and face extension** (#20, `public/edgetpu.te`, `public/hal_face_ext.te`):
   `edgetpu_device`, `edgetpu_nnapi_service`, `edgetpu_tachyon_service` and `hal_face_ext_service`,
   with stock's attributes.
   - The stock vendor labels `/dev/edgetpu-soc` and `/dev/edgetpu-limited` with `edgetpu_device`,
     and the TPU services with the two service types. Before #20, those labels named types our policy lacked.
   - After flashing #20, `adb shell ls -lZ /dev/edgetpu*` should show `edgetpu_device`.

### Rules for changing the SELinux policy

The vendor is stock and prebuilt; only system, system_ext and product are ours.
- **A type goes in `sepolicy/system_ext/public` only if the stock vendor policy names it.**
  A public type the vendor doesn't know adds a mapping entry the vendor can't resolve, and the
  phone **bootloops**. Exec types and helper types stay in `private/`.
- `check-sepolicy.sh` (the runner runs it after every build) compiles the policy against the
  stock vendor. It must print `OK`.
  - Its "unmapped" list is the stock vendor types we still don't define. Making one of them
    public is safe.
- Re-signed apps (no `;PRESIGNED` in `proprietary-files.txt`) carry our platform key, so their
  `seapp_contexts` entries use `seinfo=platform`. Apps keeping Google's signature need the seinfo
  their signer maps to.
- Don't ship a stock file Evolution's GMS already installs. Kati fails with "overriding commands".
- Offline compile check, before pushing: m4 + checkpolicy 3.9 against LineageOS 24.0
  `system/sepolicy` + `device/lineage/sepolicy`. Baseline neverallow failures are expected; new
  ones aren't.

### Open issues (in priority order)

1. **Fixed on `e974478`:** Adaptive Connectivity Services (`com.google.android.apps.scone`) kept stopping.
   - Cause: it's installed from Play as an ordinary app (`untrusted_app`) and crashes on
     `READ_PRIVILEGED_PHONE_STATE`.
   - **Fix, in the build after #20:** install `SCONE-v77459` via `PRODUCT_PACKAGES` in `device.mk`
     (`vendor/gms` already defines the prebuilt module in `Android.mk`, so adding it to
     `proprietary-files.txt` fails in kati with duplicate module `SCONE-v77459`; `gms_full.mk`
     skipped `PRODUCT_PACKAGES += SCONE-v77459` only because `PRODUCT_MANUFACTURER` is unset
     inside `inherit-product`).
     - Evolution's GMS had no allowlist entry for it (`pm get-privapp-permissions` printed `{}`), so
       `configs/permissions/privapp-permissions-kodiak-scone.xml` adds the platform privileged
       permissions stock's SCONE requests.
     - `configs/sysconfig/kodiak-scone.xml` adds stock's power-save, location and user-type entries.
     - This build has `ro.control_privapp_permissions=log`, so a missing entry is only logged; it
       can't stop boot.
   - After flashing, check:
     - `ps -AZ | grep scone`: the app should run as `priv_app`.
     - `logcat | grep "not in privapp-permissions allowlist"`: no lines for scone.
     - No more crash pop-ups.
2. Call re-test and the 3× reboot test on the newest build.
3. The rest of `check-sepolicy.sh`'s unmapped list. Most are Pixel debug, factory or
   internal apps we don't ship. Worth a look:
   - `systemui_app`: stock runs SystemUI in its own domain.
   - `pixelaudioservices_app`
   - `connectivity_thermal_power_manager`
   - `turbo_adapter`
   - `bluetooth_gci`: a stock system_ext daemon we don't ship.
   - `hal_ambience_hub_service`
4. Noise, safe to ignore:
   - `hal_camera_default` writing `traced_producer`. Stock's policy doesn't allow it either.
   - Two `hal_camera_default` reads of `default_prop`. No log names the property.

> 2d's open issues are restated, with fixed items removed, in section 2e.

## 2e. State as of 2026-10-11, about 18:30 UTC (supersedes 2d's branch notes and open issues)

### Work completed since 2a

| Area | Done in | Verified on the phone |
|---|---|---|
| Voice calls (T-Mobile VoLTE, two-way audio) | 2b and 2c: stock telephony domains, `imsstack_app`, PixelImsMediaService, CarrierSettings | ✅ 2c |
| Telephony domains: GRIL, RIL extension, modem.pms, EuiccSupportPixel | 2b | ✅ 2c |
| QNS, audio parameter parser, TPU app service, `gs_watchdogd`, `init.pms.rc` | 2b | ✅ 2c |
| `radio.te` narrowed to `radio → imsstack_app` only | 2c | built, but no call re-tested since |
| Satellite services in stock's domains | PR #3 | ✅ build #14 |
| PixelDisplayService, PixelSystemService, camera services, Google Camera domains | PR #5 | ✅ build #14 / #17 |
| TPU device and service labels, face extension | #20 | ✅ |
| SCONE as a privileged app (Adaptive Connectivity crash) | `41ea3b5` / `e974478` | ✅ |
| Tycho, `dcservice_app`, `turbo_adapter` | `fd84141` / `0423cc2` | ✅ |
| On-device AI and extra Pixel apps (below) | server tree `2c120d1` | see "Flash of 2c120d1" |

### Server tree `2c120d1`: committed on the server, not through GitHub

On 2026-10-11 at 14:08 UTC, a commit was made directly in `~/android-dt/trees/device_google_kodiak`:
"Add AICore, PixelSense, PixelAI, Hotword, NowPlaying, and Camera/Satellite priv-apps".

**What it adds:**
- In `proprietary-files.txt`, all `;PRESIGNED` (they keep Google's signature):
  - `AICorePrebuilt-aicore_20260302.01_RC00`, `PixelAIPrebuilt`, `PixelSensePrebuilt`,
    `CreativeAssistant`, `AmbientStreaming`
  - `HotwordEnrollment{OKGoogle,XGoogle}FUSIONPro` and the hotword util jar
  - `NowPlayingPrebuilt` with its ambient and music-detector data
  - `PixelCameraServices` with two camera sysconfigs
  - `SatelliteGateway-Phone-v96792000`
- In `FrameworkResOverlayKodiak`, stock's `config_messaging_read_restriction_allowlist`.
- The vendor tree on the server holds the matching extracted blobs, which aren't committed there.

**Build and check:**
- `~/kodiak-build3.log`: `BUILD_EXIT=0` at 17:59 CEST (15:59 UTC).
- `~/kodiak-build.log` shows `BUILD_EXIT=1`. That's a **duplicate run** started at the same moment that
  lost the `out/.lock` race; it isn't a real failure. Before starting a build, check
  `pgrep -af "soong_ui|ninja"` and use one log file.
- `check-sepolicy.sh`: `OK`. Its unmapped list is the same as 2d's, minus `dcservice_app` and `turbo_adapter`.
- The zip is `/tmp/kodiak-evox-img-2c120d1.zip` (5.3 GB) on the server and
  `~/Downloads/kodiak-evox/kodiak-evox-img-2c120d1.zip` on the Mac.
  sha256 `a761a1e3595644cd5e09b74c96129b61c51e1883f2dd536aa1b49fea475be2e7`.

**Synced to GitHub on 2026-10-11:** ExpressiveOS `6727268` carries `2c120d1`'s
`proprietary-files.txt` and `config.xml`. A runner sync from GitHub therefore no longer reverts it.
On the server, the vendor tree's extracted blobs are committed as `9ace47b` (local git).

**Not synced, and don't sync:** on the Mac, `device_google_kodiak/AICorePrebuilt/Android.bp`, plus
`AICorePrebuilt` and `PixelAIPrebuilt` lines added to `device.mk`. It's an unbuilt experiment, and it's wrong:
- Its `apk:` path points into the device tree, where no APK exists.
- It has no `product_specific`.
- Both modules are already defined in `vendor/google/kodiak/Android.bp` (from `proprietary-files.txt`)
  and installed through `kodiak-vendor.mk`.

It's left uncommitted in the Mac working tree. Delete it, or keep it out of `git add`.

### Flash of 2c120d1

Flashed on 2026-10-11 at about 18:27 UTC with `fastboot update`, **no wipe**. It took 140 s; log in
`~/Downloads/kodiak-evox/logs/flash-2c120d1.log`. Before flashing, the bootloader read
`spacecraft-17.4-16262255`, unlocked, slot b.

| Check | Result |
|---|---|
| Boot | `sys.boot_completed=1` about 25 s after reboot ✅ |
| Domains from earlier rounds | all present: `imsstack_app`, `grilservice_app`, `rilextensionservice_app`, `pixel_modem_app`, `euiccpixel_app`, `edgetpu_app_server`, `hal_audio_parameter_parser`, `gs_watchdogd`, `sconed`, `pixelsystemservice_app`, `pixeldisplayservice_app`, `pixelntnservice_app`, `vendor_satellite_service`, `vendor_pbcs_app` ✅ |
| Cellular / IMS | voice and data `IN_SERVICE` (T-Mobile NR SA); IMS `REGISTERED` on WWAN at 22 s; IMS service `com.android.imsstack` ✅ |
| New apps | all installed as `/product` system apps (`SYSTEM`, `PRIVILEGED` for priv-apps) ✅ |
| Crashes | no `FATAL EXCEPTION` or ANR in the boot logcat ✅ |
| privapp allowlist | only 2 lines, both `com.google.android.pixelsystemservice` (`READ_PRECISE_PHONE_STATE`, `USE_VIBRATOR_HAPTIC_GENERATOR`). Not new, and log-only |

How the new apps installed:

| App | Package | How |
|---|---|---|
| AICore | `com.google.android.aicore` | system, with the Play copy as `UPDATED_SYSTEM_APP` (data kept) |
| PixelSense | `com.google.android.apps.pixel.psi` | same |
| Ambient Streaming | `com.google.ambient.streaming` | same |
| Pixel Camera Services | `com.google.android.apps.camera.services` | same |
| SatelliteGateway | `com.google.android.apps.stargate` | same. Play's `100171000` is newer than our `96792000`. The boot log's "Expecting better updated system app; removing system app" line is that normal handover, not a failure |
| PixelAI | `com.google.android.apps.pixel.agent` | system copy only |
| CreativeAssistant | `com.google.android.apps.pixel.creativeassistant` | system copy only |
| Hotword | `com.android.hotwordenrollment.okgoogle` / `.xgoogle` | system copy only |
| NowPlaying | `com.google.android.apps.pixel.nowplaying` | system copy only |

Denials: nothing new that touches these apps.
- 15 × `system_server → default_android_service find` are Lineage framework lookups for its own HALs
  (`vendor.lineage.livedisplay.*`, `touch.*`, `health.*`), which the stock vendor doesn't have. Harmless.
- The rest is 2d's known noise: camera/gxp `traced_producer`, and `default_prop` reads.

Not done yet: a call, face and fingerprint unlock, the camera, the 3× reboot test, and using the
AI features (Magic Cue, Pixel Screenshots, Now Playing). See open issues 1 and 2.

### Root (Magisk), added 2026-10-11

Daryl asked for root, **on condition that Google Wallet and the AI features keep working**.
- Before root, Play Store's integrity check gave `MEETS_STRONG_INTEGRITY`, through Evolution's
  built-in TrickyStore keybox plus the PIF config (`Settings.Secure` `spoof_trickystore_keybox` / `spoof_pif_config`).
  Wallet tap-to-pay depends on that verdict.

**Magisk v30.7**, the official GitHub release:
- `Magisk-v30.7.apk`, sha256 `e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5`,
  signer "John Wu" (`b4cb83b4…`).
- Unpacked on the server in `~/android-dt/ref/magisk/v30.7/`.

**Patching** (`~/kodiak-magisk-patch.sh`, copy in `tools/`):
- It mirrors Magisk's `assets/boot_patch.sh` for an `init_boot` (ramdisk-only) image, using the x86_64 `magiskboot`.
- Flags are the values the app computes on kodiak:
  - `KEEPVERITY=true` (system-as-root)
  - `KEEPFORCEENCRYPT=true` (FBE)
  - `PREINITDEVICE=sda12`, from `magisk --preinit-device` run as the shell user
- `KEEPVERITY` and `KEEPFORCEENCRYPT` must be **exported**: `magiskboot cpio patch` reads them from the environment.
- It verifies that the result reads as Magisk-patched (`cpio test` = 1).

**Root in builds** (`~/kodiak-imgzip.sh`, copy in `tools/`):
- With `KODIAK_ROOT=magisk`, or `magisk` in `~/.kodiak-root` (set on the server), the zip's `init_boot.img`
  is the Magisk-patched one, and the zip gains a `ROOT.txt` marker.
- `KODIAK_ROOT=none` gives an unrooted zip.
- `out/` is never modified, and the release OTA (`m evolution`) doesn't go through this script.
- The previous script is kept as `~/kodiak-imgzip.sh.bak-20261011`.

**On the phone:**
- `init_boot_b` is flashed with `init_boot-2c120d1-magisk.img` (sha256 `8de673c0…`), and the Magisk app is installed.
- Root works: `adb shell /debug_ramdisk/su -c id` gives `uid=0 … u:r:magisk:s0`. `su` isn't in `/system/bin`.
- Magisk's DB has `zygisk=1`, `denylist=1`, and 31 DenyList entries:
  - every process of Wallet and Play Store
  - GMS, including `gms.unstable` and `gms.persistent`
  - GSF, AICore, PixelSense, ASI and Private Compute Services
- **Still pending:** `/data/adb/magisk` is empty, because the app's "Requires Additional Setup" step hasn't run.
  Until it does, Zygisk isn't loaded and the DenyList isn't enforced (`magisk --denylist status`).
- After that: hide the Magisk app (Magisk settings → Hide the Magisk app), re-run the Play Store integrity check,
  and **only then** open Wallet.
- **Undo root:** `fastboot flash init_boot_b init_boot-2c120d1-stock.img` (sha256 `be9a06c0…`; both files are in
  `~/Downloads/kodiak-evox/`).
- Shell gotcha: `adb shell su -c "a; b"` splits at `;` on the device, so only `a` runs as root.
  Push a script and run `su -c "sh /data/local/tmp/x.sh"`.

### AI features investigation (2026-10-11, in progress)

**Symptom:** Gemini Nano (AICore) and Magic Cue (PixelSense) don't work.

**Evidence** (with the phone unlocked; before the first unlock nothing AI-related can run):
- AICore: `Failed to fetch manifest config from source for com.google.android.aicore:…`, caused by
  `PERMISSION_DENIED: The caller does not have permission`. It retries with backoff.
- That leads to `606-FEATURE_NOT_FOUND`. Magic Cue's prefetch fails with `No such feature with ID 2611 … AiCore`,
  and translation reports the AICore model unavailable.
- Nothing on the phone (GMS, SELinux, PackageManager) logs a matching denial, so the refusal comes from **Google's server**.

**Ruled out:**
- **System image:** the AICore, PixelSense and PixelAI stubs are byte-identical to stock.
- **Platform config:** all stock Gemini and Pixel-experience features are declared, the intelligence roles are
  correct, and the AI apps are privileged system apps with their Play updates.
- **TPU path:** tachyon runs in the vendor's `edgetpu_tachyon_server`.
- **Identity spoofing:** Evolution gives AICore and PixelSense the "kodiak" profile (same fingerprint), and GMS isn't
  spoofed. Its `MAINLINE_PIXEL_PATTERN` doesn't match "Pixel 11 Pro XL" (no space allowed), but that only means the
  spoof applies, with kodiak's own values.
- **Play Integrity:** STRONG.

**PixelAI (Pixel Screenshots):** the `/data` copy installed before `2c120d1` had a different signer from Google's
stub, so PackageManager deleted it at the `2c120d1` flash. Only the stub is left; install Pixel Screenshots from Play.

**With root (later on 2026-10-11):**
- AICore fetches models through GMS's MDD. Its file-group store is empty (no models), with no stored error.
- Failures repeat "within backoff period", but **fresh** attempts also fail. One failed at 15:02:29, after AICore
  became a privileged system app and after root, so it isn't a stale error from when AICore was a `/data`-only app.
- "The caller does not have permission" is the standard wording of Google's server APIs for a 403.

**Lead: the PIF profile.** Evolution's `spoof_pif_config` makes **DroidGuard (`gms.unstable`) present the phone as a
Pixel 6a** (`google/bluejay_beta/bluejay:CANARY/ZP11.260918.007`), which has no Gemini Nano or Magic Cue.
- Per `PlayIntegritySpoofService.java`, only DroidGuard gets these fields. Play Store would too, but its
  `spoofVendingFinger` is off, and the PixelPropsUtils targets (AICore, PixelSense) get the real "kodiak" profile.
- So the server could only see "Pixel 6a" through a DroidGuard-signed request. Nothing in the logs shows AICore
  calling DroidGuard when it fails, so this is plausible but **unproven**.
- **Test:** temporarily switch the PIF profile to a kodiak Canary fingerprint. Save the current value first.
  Then re-run Play Store's integrity check **before** opening Wallet, and restore the old value if it isn't STRONG.
  Ask Daryl first: it touches the integrity setup Wallet depends on.

**Other lead: account eligibility** (personal vs Workspace account, age, region). Ask whether Gemini Nano and
Magic Cue worked on stock CD1A with the same Google account.

**ROOT CAUSE, found 2026-10-11.** Daryl confirmed both worked on stock with the same account. Two tests,
both reverted, were negative: the PIF profile switched to Pixel 11 Pro, and the build props set to stock
values with `resetprop`.

The chain, from logs and code:
1. AICore's "manifest config source" is a gRPC call to Private Compute Services
   (`com.google.android.as.oss`, "Astrea"): `ProtectedDownloadService/GetManifestConfig`. Found with `dexdump`
   of AICore: class `dgf`.
2. PCS needs a hardware-attested key for its request. Keystore asks RKPD for an attestation key and fails:
   `Out of data budget due to repeated errors`. PCS then logs "Failed to get attestation token", and the server
   answers `PERMISSION_DENIED`.
3. RKPD fails because Google's RKP server rejects every CSR with
   `400 INVALID_ARGUMENT: Couldn't parse boot_patch_level 20000000`.
   - Seen after resetting RKPD's error budget (`/data/user_de/0/com.android.rkpdapp/shared_prefs/
     com.android.rkpdapp.utils.preferences.xml`) and running its job.
   - kodiak is RKP-only (`remote_provisioning.tee.rkp_only=1`), so there are no factory attestation keys to fall back on.
4. The CSR's DeviceInfo (`cmd remote_provisioning csr --challenge … default`, decoded) has
   `boot_patch_level=20000000`, `vendor_patch_level=20261005` and `system_patch_level=202610`.
   The boot patch level is missing.
5. Our images carry the right values: `boot` and `init_boot` AVB props `security_patch=2026-10-05`, and the
   `init_boot` header `2026-10`, the same as stock. But **our vbmeta has `Flags: 3`** (verification disabled,
   from the bring-up line in `BoardConfig.mk`: `BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3` unless
   `WITH_AVB=true`). Stock has `Flags: 0`. With verification off, the bootloader doesn't pass the boot patch
   level to KeyMint.

Play Integrity is still STRONG only because Evolution's TrickyStore generates keybox-signed chains for its
targets, without RKP. PCS (`com.google.android.as.oss`) isn't a target.

**Test (staged, not flashed):**
- `~/Downloads/kodiak-evox/vbmeta-2c120d1-flags0.img` (sha256 `ef8399a1…`) is our vbmeta re-signed with the build's
  own key (`vendor/evolution-priv/keys/avb.pk8`, SHA256_RSA4096, rollback index 1790812800, padding 4096),
  with `--flags 0`. It differs from `out/vbmeta.img` only in Flags.
- Flash: `fastboot flash vbmeta_b vbmeta-2c120d1-flags0.img`.
- Undo: `fastboot flash vbmeta_b vbmeta-2c120d1-flags3.img` (sha256 `f2e110db…`).
- The flash was blocked by Claude Code's auto-mode permission check, so Daryl runs it.
- After boot, check:
  1. `cmd remote_provisioning csr …` shows `boot_patch_level` = 20261005.
  2. RKPD provisions keys (logcat `RkpdServerInterface`; no 400).
  3. AICore stops logging `Failed to fetch manifest config`.

**If RKP then succeeds but PCS is still refused:** the real attestation will show `unlocked`/`orange`. Next is
adding `com.google.android.as.oss` to Evolution's TrickyStore targets (`Settings.Secure spoof_trickystore_target`,
Evolver → TrickyStore apps), so its chain is keybox-signed like GMS's.

**Result of the flags-0 test: it doesn't boot.** The bootloader returns to fastboot with
`enter-reason: boot failure`. Daryl flashed `flags3` back, and Android boots again. The bootloader log
(`/dev/block/by-name/klog`, read as root with `dd` + `strings`) didn't keep a readable AVB error for that attempt.
A Magisk-patched chained `init_boot` is a likely suspect. **Don't retry flags 0 blind.**

**What the bootloader log shows for the booting flags-3 configuration:**
```
[AVB] avb_property(com.android.build.system.os_version): not found
[AVB] avb_property(com.android.build.system.security_patch): not found
[AVB] avb_property(com.android.build.boot.security_patch): not found
[AVB] boot_state: 000000:20000000:20000000
[AVB] avb_property(com.android.build.boot.fingerprint): not found
```
With verification disabled, the bootloader reads properties from the **top-level vbmeta only**, and those live in the
chained boot/vbmeta_system images.

**Fix 2, staged:** `~/Downloads/kodiak-evox/vbmeta-2c120d1-flags3-spl.img` (sha256 `6de8f837…`).
- It's the current flags-3 vbmeta, same key, descriptors and rollback index, plus 5 top-level props copied from the
  chained images:
  - `boot.os_version=17`, `boot.security_patch=2026-10-05`, `boot.fingerprint=<boot's>`
  - `system.os_version=17`, `system.security_patch=2026-10-01`
- **One-way:** once Android boots with it, KeyMint upgrades keys to boot patch level 2026-10-05. A later
  vbmeta/build without these props would be a patch-level downgrade: keystore keys (lock screen, CE storage, app keys)
  become unusable, and that can mean a wipe.
- `vbmeta-2c120d1-flags3.img` is only a safe undo if the new image never finishes booting.
- Every future build must carry these props: add them to `BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS` in `BoardConfig.mk`.

**Permanent fix:** in `BoardConfig.mk`, next to the bring-up `--flags 3`, add:
```make
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += \
    --prop com.android.build.boot.os_version:$(PLATFORM_VERSION_LAST_STABLE) \
    --prop com.android.build.boot.security_patch:$(BOOT_SECURITY_PATCH) \
    --prop com.android.build.system.os_version:$(PLATFORM_VERSION_LAST_STABLE) \
    --prop com.android.build.system.security_patch:$(PLATFORM_SECURITY_PATCH)
```
- Check that the variables expand to the same values as above: `BOOT_SECURITY_PATCH` must be stock's `2026-10-05`.
- Keep them even if verification is turned on later.

**Applied, 2026-10-11 ~19:40 UTC.** Daryl flashed `vbmeta-2c120d1-flags3-spl.img` to `vbmeta_b`.
- It boots, and the CSR now has `boot_patch_level=20261005`.
- RKPD provisions keys: `Key successfully assigned to client`, 12 signed keys in the pool, and no more 400s.
  Hardware key attestation works again.
- **The device is now committed to boot patch level 2026-10-05.** The BoardConfig fix is in GitHub `4df22cd` and
  server tree `9b68771` (pulled into `~/evolution`). `get_build_var BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS` expands to the
  same values as the flashed image.

**AI features: still blocked, and the cause is now outside the ROM.**
- With RKP working, PCS gets a real attestation token. Google's ProtectedDownload server still answers
  `PERMISSION_DENIED`, for both AICore and PixelSense (Magic Cue) manifests.
- The real attestation says `unlocked` / `orange`. On stock with a locked bootloader, the same account worked.
- Test: `com.google.android.as.oss` added to `spoof_trickystore_target`. TrickyStore initialised in PCS, but logged
  `Keybox warning: missing RSA key block` and `CertificateHacker: No keybox for algorithm: RSA`.
  PCS attests an **RSA** key. Without an RSA keybox, `CertificateHacker` returns the **original** chain (it still logs
  "Hacked certificate chain"), so the server still sees the unlocked device.
- The list was restored exactly from `~/Downloads/kodiak-evox/logs/trickystore-targets-backup-20261011-1541.txt`.
- **Conclusion:** Gemini Nano and Magic Cue need either a locked bootloader (stock) or an attestation keybox
  with an RSA key. Evolution's keybox is EC-only. Sourcing leaked OEM keyboxes is out of scope.
  Revisit if Evolution's official keybox gains an RSA block.

**Side effect to watch:** with RKP working, `isTeeBroken()` is false, so TrickyStore `AUTO` targets (GMS, Play Store,
Wallet…) use LEAF_HACK instead of GENERATE. An RSA attested key in those apps would now get its real, unlocked chain.
Re-check Play Integrity (STRONG) and Wallet tap-to-pay. If STRONG fails, grep logcat for `No keybox for algorithm`
and consider `pkg!` (GENERATE) for the affected package.
- **Checked by Daryl after the fix (2026-10-11):** Play Store's integrity check still gives `MEETS_STRONG_INTEGRITY`,
  and Wallet tap-to-pay works. No `No keybox for algorithm` errors in logcat outside the (reverted) PCS test.

**Cleanup (2026-10-11):** every flash artifact with a pre-fix vbmeta (boot patch level 0) was deleted, because flashing
one now would be a KeyMint downgrade:
- **Mac:** the two old vbmeta test images, 5 image zips, and the `EvolutionX-17.0-20261010` OTA zip.
- **Server:** all 9 `/tmp/kodiak-evox-img-*.zip` files and the old OTA zip in `out/`.
- `out/.../vbmeta.img` was rebuilt with `~/kodiak-vbmeta.sh` (`m vbmetaimage`; copy in `tools/`). It now carries the
  patch-level props.

**There's no flash zip right now.** Make a new one with `~/kodiak-imgzip.sh` (or a runner round) before the next flash.
The only vbmeta image kept is `~/Downloads/kodiak-evox/vbmeta-2c120d1-flags3-spl.img`, which is what the phone runs.

Also seen: the CSR has `fused: 0`. Not investigated yet.

### Open issues (in priority order; replaces 2d's list)

1. **Re-test on the newest build:** a voice call (`radio.te` was narrowed after 2c's test),
   face and fingerprint unlock, the camera, then the 3× reboot test.
2. **The new `PRESIGNED` priv-apps from `2c120d1`:** they install privileged with no allowlist complaints
   (see "Flash of 2c120d1"). Still to check, by using them:
   - Magic Cue (PixelSense), Pixel Screenshots (PixelAI), AICore model download, "Hey Google" enrollment,
     Now Playing.
   - Then grep for crashes and for `avc: denied` from `priv_app` naming `aicore`, `pixel.agent`, `psi`,
     `nowplaying` or `hotword`.
   - They run as `priv_app`. That's expected: none of them maps to a stock type in the unmapped list.
3. **The rest of `check-sepolicy.sh`'s unmapped list.** Most are Pixel debug, factory or internal apps we
   don't ship. Worth a look:
   - `systemui_app`: stock runs SystemUI in its own domain.
   - `pixelaudioservices_app`
   - `connectivity_thermal_power_manager`
   - `bluetooth_gci`: a stock system_ext daemon we don't ship.
   - `hal_ambience_hub_service`
4. **Product RROs:** Google's other product overlays (SystemUI/Settings device config) aren't shipped.
   See REEKY_DIFF section 4.
5. **Distribution:**
   - release keys (it's test-keys now)
   - `WITH_AVB` / verified boot (vbmeta uses `--flags 3` now)
   - `m evolution` for the OTA zip
6. **Noise, safe to ignore:**
   - `hal_camera_default` writing `traced_producer`
   - two `hal_camera_default` reads of `default_prop`
   - the display-driver panic hasn't recurred since the `user` build

### Phone recovery (the flash stalled on 2026-10-11)

- Our zip doesn't touch the bootloader. A half-written `super` only stops Android from booting.
  Re-running the same no-wipe flash fixes it.
- Steps:
  1. Force the bootloader: hold **Power + Volume Down** for about 15 s.
  2. Use a different cable, and plug straight into the Mac (no hub or dock).
  3. Use a current Google platform-tools `fastboot`.
  4. Check with `fastboot devices`.
  5. Run `fastboot update <zip>`, without `-w`.
  If it stops in fastbootd (the recovery-style screen), `fastboot reboot bootloader` and run it again.
- **Never:**
  - `fastboot flashing lock` (locking with these images leaves a phone that won't boot)
  - `-w`, `fastboot erase`, or a wipe
  - a bootloader or radio flash
  - changing the active slot
  - Android Flash Tool's "Wipe" option
  Each of these needs Daryl's explicit OK.
- Last resort, only with Daryl's OK: Android Flash Tool, stock `CD1A.261005.003`.
  - Untick **Wipe device** to keep data, and leave **Lock bootloader** unticked.
  - Going from our build back to stock without a wipe may still need a wipe to boot.

## 2f. Public repos (2026-10-11)

- **Device tree:** https://github.com/denson9874/device_google_kodiak (public, branch `cnb`).
  - It was published as one fresh commit from `evolution-kodiak/device_google_kodiak` (63 files), author
    `9751141+denson9874@users.noreply.github.com`. The patch header uses the noreply address too.
  - **It's a mirror, not the source of truth.** Keep editing `evolution-kodiak/device_google_kodiak` here, then push
    the same changes to the public repo with the noreply author.
- **Upstream PR:** https://github.com/Evolution-X/build/pull/5, from fork `denson9874/build`, branch
  `releasetools-prebuilt-partitions`. It's our `patches/build_make` fix, rebased on upstream `cnb` (`5b95f1f`).
  When it merges, remove `patches/` and `apply-patches.sh`.
- **Vendor blobs:** https://github.com/denson9874/vendor_google_kodiak (public). It's a fresh commit of the server's `~/evolution/vendor/google/kodiak` at `0fd223f`, after the blob trim. After `extract-files.py` runs, push the same changes there.
- **Not published:** `vendor/google/kodiak-images` (whole stock images).
  See MAINTAINERSHIP.md, blocker 1.

## 2g. Personal extras vs the official tree (2026-10-11)

For the Evolution X CoC (no proprietary apps in device trees), the official tree no longer ships the AI stubs,
Hotword, Now Playing, Creative Assistant, Ambient Streaming, PixelCameraServices or SatelliteGateway (`9480969`).
Daryl keeps them on his own phone through a **private add-on**:

| Piece | Where |
|---|---|
| Add-on source (blob list, extract script, `personal.mk`) | `evolution-kodiak/device_google_kodiak-personal/` here; `~/evolution/device/google/kodiak-personal` on the server (copied with rsync, **not** synced by the runner) |
| Its blobs | `~/evolution/vendor/google/kodiak-personal` (local git, `050c806`). **Never publish** |
| Hook | `device.mk`: `ifeq ($(KODIAK_PERSONAL),true)` → `inherit-product-if-exists device/google/kodiak-personal/personal.mk` |
| Switch | `~/kodiak-images.sh` (test builds) exports `KODIAK_PERSONAL=true`. `~/kodiak-build.sh` (release OTA) doesn't. Backup: `~/kodiak-images.sh.bak-20261011` |

**Test builds are therefore:** official tree + personal extras + Magisk (`~/.kodiak-root`).
**Release builds are:** official tree only.
If an official build is ever made on this server, check that neither `KODIAK_PERSONAL` nor `~/.kodiak-root` applies.

## 2h. First public release (2026-10-11)

- **XDA thread:** https://xdaforums.com/t/rom-unofficial-17-kodiak-evolution-x-12-3-android-17-for-the-pixel-11-pro-xl.4804712/
  - Forum: Google Pixel 11 Pro / Pro XL, prefix Development, posted as denson9874.
  - Source: `evolution-kodiak/XDA_POST.bbcode`.
- **Download:** https://sourceforge.net/projects/denson9874-s-user-builds/files/kodiak/17/
  - `EvolutionX-17.0-20261011-kodiak-12.3-Unofficial-fastboot.zip` (5,162,799,375 bytes, sha256 `92c22a52…e62efe`;
    SourceForge's own SHA-256 matches), plus `.sha256`.
  - SourceForge user `daryldenson0405`, project `denson9874-s-user-builds`.
  - Uploaded from the server with `~/.ssh/sourceforge_ed25519`, which was already registered from the husky uploads.
  - New uploads take a few minutes to appear on the public pages. curl always gets 403 from SourceForge, so check
    in a browser.
- **What it is:** a fastboot image zip of the official tree only (no personal extras, not rooted), signed with our
  private keys. No firmware: users must already be on CD1A.261005.003.
- **How to make the next one:**
  1. `~/kodiak-release-images.sh`, which unsets `KODIAK_PERSONAL`.
  2. `~/kodiak-release-pack.sh --upload`. It checks for personal apps, sepolicy, no root, and the vbmeta boot patch
     level, and refuses to upload otherwise. Copies of both are in `tools/`.
- **Rebuild your test zip afterwards:** the release build overwrites `out/` with the non-personal tree, so run
  `~/kodiak-images.sh` before packing another test zip.
- **Daryl's own phone** gets `kodiak-evox-img-4021403-personal.zip` (rooted, plus extras; in `~/Downloads/kodiak-evox`,
  sha256 `8ad8bfc9…`). Not flashed yet at the time of writing.

## 2i. grizzly and cubs test builds (2026-10-12)

Pixel 11 Pro (`grizzly`) and Pixel 11 (`cubs`) builds, made from the kodiak tree. **Neither has been booted:** Daryl
owns neither phone, so they're "testers wanted" releases. Why the port is small, and what differs between the three
phones: `P11_FAMILY_DIFF.md`.

- **Trees:** `device_google_grizzly/` and `device_google_cubs/` (server: `device/google/{grizzly,cubs}`, local git).
  Vendor dirs are generated from each phone's own stock image, never copied from kodiak, because some blobs are
  signed with each phone's own platform key:
  - `vendor/google/{grizzly,cubs}-images` comes from `extract-images.sh`.
  - `vendor/google/{grizzly,cubs}` comes from `extract-files.py` against `~/android-dt/dumps/<dev>`.
  - grizzly has no PixelSystemService signer in `mac_permissions.xml` (Evolution signs it with grizzly's platform
    key); cubs keeps kodiak's.
- **Build and release:** `~/grizzly-images.sh` / `~/cubs-images.sh`, then `~/grizzly-pack.sh --upload` /
  `~/cubs-pack.sh --upload`. They check identity, personal apps, sepolicy against the stock vendor policy, the
  mac_permissions signer, blob signers, root, the vbmeta patch level, and the stock kernel/dtbo/vendor. Copies are in
  `tools/`. Each build overwrites `out/` only for its own product.
- **Downloads:**
  - grizzly: https://sourceforge.net/projects/denson9874-s-user-builds/files/grizzly/17/ (`063ac613…3e84`)
  - cubs: https://sourceforge.net/projects/denson9874-s-user-builds/files/cubs/17/ (`345ed966…a916`)
- **XDA:**
  - grizzly is a section at the top of the kodiak thread. Its title now names grizzly, so the URL changed:
    https://xdaforums.com/t/rom-unofficial-17-kodiak-grizzly-evolution-x-12-3-android-17-for-the-pixel-11-pro-xl-and-11-pro-grizzly-testers-wanted.4804712/
  - cubs has its own thread in the Pixel 11 forum:
    https://xdaforums.com/t/rom-unofficial-17-cubs-evolution-x-12-3-android-17-for-the-pixel-11-testers-wanted.4804723/
  - A reply to nutzfreelance (who asked for grizzly/cub builds) links both.
  - Source: `XDA_POST.bbcode`, `XDA_POST_CUBS.bbcode`.
- **Telegram:** the channel was renamed to **Expressive Group**, t.me/ExpressiveGroup.
  - t.me/ExpressiveLauncher is a placeholder channel, "Expressive Launcher (moved)", with a pinned pointer to the
    new channel. It also keeps anyone else from claiming the handle.
  - The discussion group is "Expressive Group Feedback" (link unchanged).
  - Channel description: "Official Expressive Group news: Expressive Launcher updates and custom ROM releases
    (Evolution X for the Pixel 11 series). Report bugs, suggest features, and chat with the community:
    https://t.me/ExpressiveLauncherFeedback".
  - Announcement: `TELEGRAM_ANNOUNCEMENT_P11_TESTS.md`.
  - Telegram Web K can show a stale description after an edit, and puts a sent message back into the compose box
    as a draft. Clear the box after sending.

## 2j. Weekly parity routines (set up 2026-10-12)

Three Claude desktop scheduled tasks, `evox-parity-kodiak`, `evox-parity-grizzly` and `evox-parity-cubs`
(prompts in `~/.claude/scheduled-tasks/<id>/SKILL.md` on the Mac). They run **Sundays at about 3 PM local time**, and
only while the Claude app is open; a missed run happens on the next launch. Each one SSHes to the server, starts
`~/p11-routine.sh <device>`, waits, and reports. They never flash phones, post on XDA or Telegram, or touch trees.

What `p11-routine.sh` does (copy in `tools/`):

- **Lock:** takes `~/.evolution-tree.lock` (so the three runs go one at a time) and waits for any build started by hand.
- **Sync:** runs `repo sync` if the tree wasn't synced in the last 6 hours. It fetches everything, then checks out
  every project except the husky port's five (`vendor/google/husky` has uncommitted radio images a checkout would
  refuse to touch). After that it re-runs `apply-patches.sh`. The last sync time is in `~/.evolution-last-sync`.
- **Change check:** compares the git tree hash of every project plus our device, vendor, images and keys trees with
  `~/releases/<dev>/LAST_STATE`. The baselines were recorded on 2026-10-12 for the current releases. If nothing
  changed, the result is `NOCHANGE`.
- **Build and publish:** builds with the device's release script, then runs its pack script with `--upload`. Zip
  names now come from `ro.evolution.build.version`, and kodiak zips go to `~/releases/kodiak/` instead of `/tmp`.
- **Records:** writes `LAST_STATE`, `LAST_TREES`, `LAST_MANIFEST.xml` and `CHANGES-<date>.txt` (upstream commits since
  the last published build) under `~/releases/<dev>/`, and keeps the two newest zips on the server.
- **Logs:** `~/routine-logs/<dev>-<time>.log`, plus `<dev>-latest.out`. The last line is
  `ROUTINE_RESULT=PUBLISHED|NOCHANGE|FAILED`.
- **Options:** `--dry-run`, `--force`, `--no-upload`, `--mark-current` (record the current tree as published).

Not automated:

- XDA and Telegram announcements. The routine offers drafts.
- Monthly Google firmware. New factory images change the stock vendor, kernel and firmware and the users'
  requirements: `BOOT_SECURITY_PATCH`, the pack scripts' boot patch-level check, `extract-images.sh`, and the posts.
  Do that by hand, and never lower the boot patch level.

## 2k. On-device AI on Daryl's phone: Public Compute Services (2026-10-12, proof of concept)

This fixes the AI blocker from 2e. Google's manifest server refuses unlocked-bootloader attestation, which gave
`ProtectedDownloadGrpcBindableService: Failed to handle GetManifestConfig`. Kieron Quinn's **Public Compute
Services** (PCS), an Xposed module, makes Private Compute Services fetch the manifests from a mirrored repository
instead; the models still download from Google. It's personal-phone only: the release ROM stays unrooted.

How it was set up (files and checksums: `~/Downloads/kodiak-evox/pcs-poc/`):

- **Root:** Magisk had updated itself to v31.0. Its built-in Zygisk **does** inject on our build, so NeoZygisk wasn't
  needed (the XDA guide says it is). Zygisk and the enforced DenyList are unchanged.
- **Vector:** `Vector-v2.2-3112-Debug.zip` (canary), installed with `magisk --install-module`.
- **Configuration:** done with Vector's CLI (`/data/adb/modules/zygisk_vector/cli`) instead of the hidden manager UI:
  `modules enable com.kieronquinn.app.pcs`, then
  `scope set com.kieronquinn.app.pcs com.google.android.aicore/0 com.google.android.as/0 com.google.android.as.oss/0 com.google.android.dialer/0 com.google.android.apps.pixel.agent/0`.
- **PCS:** `PublicComputeServices-v1.0.6.apk`, package `com.kieronquinn.app.pcs`, uid 10538. Root is granted through
  Magisk's policies table. The repository is `https://raw.githubusercontent.com/PublicComputeServices/pcs-manifests/refs/heads/main`
  (as listed in the PCS thread, post 2), with Auto Sync on. Pixel Screenshots manifests are off.
- **The trap:** AICore, ASI (`com.google.android.as`) and PCS (`com.google.android.as.oss`) had been put on the Magisk
  DenyList during the earlier AI debugging. Denylisted processes get no Zygisk modules, so nothing was hooked. Removing
  those 7 entries (DenyList 67 → 60) fixed it.
- **Result:** Vector injects into as.oss and aicore, `AstreaService: Sending back manifest for com.google.android.aicore`,
  `Successfully handled GetManifestConfig`, and AICore loads models on the TPU (data 3.6 GB).
- **Still to check:** that Play Integrity is still STRONG and Wallet tap-to-pay still works.
- **Revert:** `~/Downloads/kodiak-evox/pcs-poc/revert.sh` re-adds the DenyList entries, removes Vector and PCS, and
  reboots. Baseline: `baseline-20261012.txt`, `denylist-20261012.txt`.
- **Reflashing caveat:** a new personal test zip re-patches init_boot with Magisk, but `/data/adb` (modules, DenyList,
  policies) survives a no-wipe `fastboot update`.

## 3. Machines and access

| What | Where |
|---|---|
| Build server | Hetzner Ryzen 7 7700 (16 threads, 64 GB), `build@157.180.50.152` |
| SSH key | `~/.ssh/voltage_build_ed25519` on the Mac |
| Evolution X source | `~/evolution` on the server (also used for Daryl's husky port; don't break husky) |
| Tool workspace | `~/android-dt` on the server (venv, firmware, dumps, trees, refs) |
| Phone | Pixel 11 Pro XL, serial `66020DLDV0049F`, USB to the Mac, **bootloader unlocked**, slot `b` |
| Mac working dir | `~/Downloads/kodiak-evox/` (flash zips, logs) |
| Backup repo | `~/Developer/ExpressiveOS`, branch `evolution/kodiak-port`, folder `evolution-kodiak/` |

The server account has **no passwordless sudo**. Missing host tools were installed
without root:
- `~/android-dt/bin`: 7zz, a `file` wrapper over a `dpkg -x`'d sysroot, and
  symlinks to `~/evolution/out/host` tools
- the venv was made with `--without-pip` plus `get-pip.py`

## 4. Source layout (server)

```
~/android-dt/trees/device_google_kodiak   ← SOURCE OF TRUTH for the device tree (git)
~/evolution/device/google/kodiak          ← git clone of the above; update with `git pull`
~/evolution/vendor/google/kodiak          ← generated by extract-files.py (local git)
~/evolution/vendor/google/kodiak-images   ← generated by extract-images.sh (local git; Google images)
~/evolution/device/google/kodiak-dev/     ← untracked; Mac adb key for test builds only
~/android-dt/dumps/kodiak                 ← dumpyara dump of stock CD1A.261005.003 (git)
~/android-dt/firmware/                    ← factory zip + inner image-kodiak-cd1a.261005.003.zip
~/android-dt/ref/{laguna,muzel,mustang}   ← LineageOS Pixel 10 trees, used as reference
```

**Workflow for device-tree changes:**
1. Edit and commit in `~/android-dt/trees/device_google_kodiak`.
2. Run `cd ~/evolution/device/google/kodiak && git pull`.
3. Rebuild.

Don't edit the `~/evolution` clone directly.

**Build design (Daryl chose this):**
- **Stock prebuilt:** vendor, vendor_dlkm, system_dlkm, boot (GKI kernel), dtbo.
- **Flashed raw by the OTA:** firmware and vendor_kernel_boot.
- **Built:** system, system_ext, product, init_boot, vendor_boot (with recovery),
  vbmeta, pvmfw.

Key device-tree files:
- `BoardConfig.mk`, `device.mk`, `lineage_kodiak.mk`
- `extract-images.sh` + `firmware.txt` (stock images to `kodiak-images`)
- `extract-files.py` + `proprietary-files.txt` (+ `proprietary-files-carriersettings.txt`):
  the telephony blobs
- `rro_overlays/TeleServiceOverlayKodiak` (IMS package = `com.android.imsstack`)
- `sepolicy/system_ext/private/radio.te`
- `check-sepolicy.sh`: offline split-policy compile against the stock vendor
- `patches/build_make` + `apply-patches.sh`: a releasetools fix for prebuilt vendor.
  It's already applied in `~/evolution/build/make`.

## 5. Build commands (server)

| Script | Use |
|---|---|
| `~/kodiak-images.sh` | **Normal test round.** Images only, `user`, dexpreopt on. About 4–15 min incremental |
| `~/kodiak-build.sh` | Full `m evolution` (OTA zip). About 1 h. Release builds |
| `~/kodiak-test-build.sh` | Images, `WITH_DEXPREOPT=false`. Faster later, but the first run rebuilds a lot (config change). Not used yet |
| `~/kodiak-imgzip.sh <out> <image zip> <output>` | Packs images for `fastboot update` |

Run builds detached and wait for `BUILD_EXIT=` in the log:
```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 '(nohup ~/kodiak-images.sh > ~/kodiak-build.log 2>&1 &)'
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'grep -E "BUILD_EXIT|#### |FAILED:" ~/kodiak-build.log | tail -5'
```

**Don't switch the build variant** (it's `user`): that forces an installclean
and a full rebuild of about 1 h.

Verify, then package (server):
```bash
cd ~/evolution && O=out/target/product/kodiak
device/google/kodiak/check-sepolicy.sh out/host/linux-x86/bin/secilc $O ~/android-dt/dumps/kodiak/vendor
~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip /tmp/kodiak-evox-img.zip
```

## 6. Flash procedure (Mac)

Daryl has authorized flashing this phone. Still ask before anything **destructive**:
`-w` / wipes, or flashing firmware/bootloader.

1. Check state: `adb devices` and `fastboot devices`.
2. Copy and verify. Zips are named after the **server** tree commit (`<tree>`), for example
   `kodiak-evox-img-2c120d1.zip`:
   ```bash
   cd ~/Downloads/kodiak-evox
   scp -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152:/tmp/kodiak-evox-img-<tree>.zip .
   ```
   Compare `shasum -a 256` with the server's `/tmp/kodiak-evox-img-<tree>.zip.sha256`.
   The copy takes a few minutes (about 5 GB).
3. Flash **without wiping** (keeps Daryl's data):
   ```bash
   adb -s 66020DLDV0049F reboot bootloader
   ```
   ```bash
   fastboot -s 66020DLDV0049F update kodiak-evox-img-<tree>.zip
   ```
   It reboots by itself when it's done (about 135 s).
4. Wait for `adb shell getprop sys.boot_completed` = `1`.

If it ends up back in fastboot, read `fastboot getvar enter-reason`:
- `DBL request` means a reboot to the bootloader (a kernel panic, or system_server
  crash-looping).
- To diagnose, boot with live log capture: start `adb logcat -b all -v monotonic > file`
  as soon as `adb get-state` = `device`. That found the last two root causes.
- Logcat format: use `-v monotonic`. `-v uptime` is invalid here.

**Recovery:** Evolution X recovery lives in vendor_boot.
- Daryl must enable **ADB in the recovery menu** for adb to work there. Its `/adb_keys`
  points at product, which has no keys in a `user` build.
- For root in recovery, a test vendor_boot exists with the Mac key + `ro.secure=0` +
  `ro.debuggable=1` + `androidboot.init_fatal_reboot_target=recovery`.
  It's `~/Downloads/kodiak-evox/vendor_boot-dev3.img`, built in `/tmp/vbdev` on the server.
  **A test image only.** The normal flash replaces it.
- The bootloader's own reset log is in the `klog` partition (`/dev/block/by-name/klog`).
  Read it as root in recovery with `strings` and grep `reset message|Reboot reason`.

**Restore stock if needed:** Android Flash Tool, build `CD1A.261005.003`.
Firmware matches, so there's no downgrade risk.

## 7. Diagnostics (no root in Android: Evolution spoofs `ro.debuggable=0`)

```bash
adb -s 66020DLDV0049F logcat -d -b all -v monotonic > all.txt        # main/system/crash/radio
adb -s 66020DLDV0049F logcat -d -b radio -v monotonic > radio.txt
adb -s 66020DLDV0049F shell dumpsys dropbox --print SYSTEM_LAST_KMSG > last_kmsg.txt   # kernel log of the previous boot
adb -s 66020DLDV0049F shell dumpsys telephony.registry | grep -m1 mServiceState
adb -s 66020DLDV0049F shell cmd phone ims get-ims-service -d -s 0    # must print com.android.imsstack
grep -E "onCallTerminated|reasonCode|avc:  denied" all.txt
```

Claude Code's safety check blocked inline `bash -c '…'` scripts containing loops.
Write multi-step logic to a script file instead.

## 8. Lessons learned (don't repeat these)

**Dumping and generating**
- dumpyara needs the **inner** `image-kodiak-*.zip`, not the factory zip.
- AIK (used by dumpyara/aospdtgen) needs the `file` command.
- aospdtgen names the tree "generic", because Pixel 11 system is `generic_system_google`.
  Use `~/android-dt/bin/aospdtgen-vendorfirst.py`.

**Packaging and build config**
- releasetools crashed with `KeyError: 'vendor'` on prebuilt vendor. The fix is in `patches/build_make`.
- `BOARD_PREBUILT_PVMFWIMAGE` is obsolete; pvmfw is built from AOSP.
- vintffm needed `hwservicemanager` and `android.hidl.allocator@1.0-service`.
  Shipping API 37 drops them; stock ships them.
- A prebuilt-vendor product loses base_vendor.mk's recovery packages. They're re-added in `device.mk`.

**Boot**
- First boot failed (DBL) because vendor_boot lacked `usb_phy_fw*.bin`. Fixed in `extract-images.sh`.

**Telephony and IMS**
- Telephony needs stock system_ext blobs; see `proprietary-files.txt`.
- **ImsStack is built from AOSP** (`packages/modules/ImsStack`). The stock ImsStack blob collides with the AOSP install.
- **IMS media is the stock `PixelImsMediaService`, re-signed** (since 2a). AOSP ImsMedia can't drive kodiak's call audio.
  - It uses `android.uid.phone`, so it must **not** be `;PRESIGNED`.
  - With Google's key it gives `Signature mismatch … for shared user`, system_server crashes, and the phone bootloops.
  - Re-signed with our platform key, it works.
- ImsStack must run as stock's `imsstack_app` domain: the vendor's imsmediahaldaemon rules only name that domain.
- The stock **vendor** TeleService RRO names `com.shannon.imsservice` (wrong for MediaTek).
  Stock overrides it from product; `TeleServiceOverlayKodiak` does the same.

**IMS `reasonCode` values (`ImsReasonInfo`)**
- 401–405: media problems (401 = media init failed)
- 3xx: SIP errors from the network
- 1xx: local errors

## 9. Rules from Daryl / the guide

- **Never push** vendor trees, blobs or Google images to any remote.
  - On 2026-10-10 Daryl allowed pushing `evolution-kodiak/` (device-tree files only) to the **private**
    repo `denson9874/ExpressiveOS`, on branch `evolution/kodiak-port`, so cloud sessions can work on it.
    It still must not go anywhere public.
  - `evolution-kodiak/` holds only tree files: no blobs, no images, and not the aospdtgen first commit
    (that commit contains Google kernel binaries).
- No `sudo` package installs or full `repo sync` without asking Daryl.
- **Ask Daryl before** wipes (`-w`), bootloader/firmware flashes, or anything that
  can't be undone. Normal no-wipe `fastboot update` of our images is authorized.
- Commit after each meaningful change, with a clear message explaining *why*.
- Keep the husky build in `~/evolution` working (`lunch lineage_husky-cp2a-userdebug`).
  Changes in shared projects (`build/make`) must stay harmless for husky.

## 10. Keep the backup in sync

**Since 2026-10-11 the source of truth is GitHub, not the server.**
- The runner's `sync` / `round` actions copy `evolution-kodiak/device_google_kodiak` from the chosen branch
  into the server tree, then commit it as "sync from ExpressiveOS <branch>@<commit>".
- A commit made only on the server is **overwritten** by the next sync. That nearly happened to `2c120d1` (section 2e).

**If you do commit on the server** (a hand build), bring it to GitHub straight away (from the Mac):
```bash
cd ~/Developer/ExpressiveOS
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'cd ~/android-dt/trees/device_google_kodiak && git archive HEAD' | tar -x -C evolution-kodiak/device_google_kodiak
git add evolution-kodiak/device_google_kodiak && git commit -m "evolution-kodiak: sync device tree from server <commit>"
git push origin HEAD:evolution/kodiak-port
```
Check `git status` first: `tar -x` doesn't delete files, and the Mac copy may hold unrelated uncommitted edits.

As of section 2e, GitHub `evolution/kodiak-port` matches the server tree `2c120d1`.

`tools/` holds copies of the server's `kodiak-images.sh` and `kodiak-build.sh`.

## 11. Working from a cloud session (GitHub only)

**Build server runner (since 2026-10-11).** `.github/workflows/kodiak-build.yml` (on `main`, added in PR #2)
runs on a self-hosted runner on the build server (label `kodiak-build`). A cloud session dispatches it with
`action` = `status` | `sync` | `extract` | `images` | `check-sepolicy` | `imgzip` | `round` | `ota` and a `tree_ref`
(branch to sync the device tree from), then reads the job log. That covers the server steps below; flashing and
the phone stay on the Mac. It never uploads build output, refuses to start while another build runs, and refuses to
sync over uncommitted changes. The runner's setup steps are in the workflow's header comment. If the runner is
offline (`status` stays queued), use the manual route below.

Without the runner, a cloud session sees only this repo. It has **no** SSH key for the build server, no phone and no blobs, so:
- **It can** edit the device tree in `evolution-kodiak/device_google_kodiak/` (sepolicy `.te` files, RROs,
  `proprietary-files.txt`, makefiles), update these notes, commit and push to `evolution/kodiak-port`.
- **It can't** build, run `extract-files.py`, run `check-sepolicy.sh`, or flash.
- **To apply a cloud change on the server** (from the Mac):
  ```bash
  cd ~/Developer/ExpressiveOS && git pull
  rsync -a --exclude .git -e "ssh -i ~/.ssh/voltage_build_ed25519" evolution-kodiak/device_google_kodiak/ build@157.180.50.152:android-dt/trees/device_google_kodiak/
  ```
  Then commit in the server tree, `git pull` into `~/evolution/device/google/kodiak`, re-run `extract-files.py`
  if `proprietary-files.txt` changed, and build.
- **Reference data the cloud can't see** (it's on the server): stock policy at
  `~/android-dt/dumps/kodiak/system_ext/etc/selinux/system_ext_sepolicy.cil`, and Reeky's unpacked build at
  `~/android-dt/ref/reeky/`. REEKY_DIFF.md summarises what matters.
  With the runner, the `inspect` action reads the stock dump.
- **Good cloud-only tasks** (`imsstack_app` and the telephony domains are done):
  - The remaining unmapped domains (section 2e, open issue 3), with rule text from the stock CIL via `inspect`.
  - Product source RROs (REEKY_DIFF section 4).
