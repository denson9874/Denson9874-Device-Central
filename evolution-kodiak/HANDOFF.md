# Handoff: Evolution X 17 on the Pixel 11 Pro XL (kodiak)

Written 2026-10-10 for an agent (Google Antigravity) continuing this work until
Claude is available again. Read all of it before running anything.

> **Update, late 2026-10-10.** The radio.te fix did **not** fix calls (still 401).
> The next attempt (stock PixelImsMediaService) is committed and being built.
> The phone is now on **Android Canary** (Daryl needed a working phone), so there are no logs.
> See section 2a, plus section 11 if you're a cloud session.

> **Update 2026-10-11 (cloud session).** A source-level review against a working
> LineageOS 24.0 Pixel 11 tree found several more causes for the calls failure and
> fixed them in the device tree (section 2b).
>
> **Voice calls work** (section 2c): two-way audio on T-Mobile VoLTE, tested on the phone
> with server tree `b16749b` (ExpressiveOS `bd85ff9`). The phone is back on stock-matching
> CD1A.261005.003 firmware with our build flashed (wiped).

> **Update 2026-10-11, about 11:00 UTC. Read section 2d first.** It lists every fix made
> since 2c, the phone's state, and the rules for changing this tree without undoing them.
> **The phone is mid-flash.** `fastboot update` of `kodiak-evox-img-9190352.zip` stalled at
> `Sending sparse 'super' 2/10`, and the Mac can no longer reach the phone. Section 2d
> covers recovery: no wipe, no lock, no bootloader or firmware flash.
> **Build from `claude/wizardly-hopper-gnqtlx` (PR #5), not `evolution/kodiak-port`.**
> The base branch doesn't build until PR #5 merges.

## 1. Goal

Make a working **Evolution X 17** (Android 17, branch `cnb`, LineageOS-based)
build for the **Pixel 11 Pro XL** (`kodiak`, Tensor G6 `malibu`, MediaTek T900
modem, GKI kernel 6.12), for testing now and distribution later.

The original instructions are in `~/Downloads/android-device-tree-toolchain-guide.md`.
Its operating rules still apply (see section 9).

## 2. Current status

| Area | Status |
|---|---|
| Builds | ✅ `user` variant, test-keys |
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
- `com.google.android.apps.scone` crashes once at boot (not essential).
- Google's other product RROs (SystemUI/Settings device config) aren't shipped.
  extract-utils rejects prebuilt overlay APKs ("does not match known package rules"),
  so use **source RROs** in the device tree, as with `rro_overlays/TeleServiceOverlayKodiak`.
- Distribution needs: release keys (it's test-keys now), `WITH_AVB` / verified boot
  (vbmeta uses `--flags 3` now), and `m evolution` for the OTA zip.

## 2d. State as of 2026-10-11, about 11:00 UTC (supersedes 2c's "Still to do")

### Branches and builds

- `evolution/kodiak-port` (base) has PR #3 merged: the satellite services and the narrower `radio.te`.
  **It doesn't build on its own.** PR #3 shipped stock's `product/etc/sysconfig/satellite_sos.xml`,
  which Evolution's GMS also installs, and kati fails with "overriding commands".
- **PR #5, branch `claude/wizardly-hopper-gnqtlx`,** has everything below, including that fix.
  Build and sync from this branch until it merges.
- Builds go through the runner (section 11): `action: round`, `tree_ref: claude/wizardly-hopper-gnqtlx`.
  The zip is named after the **server** tree's commit (`~/android-dt/trees/device_google_kodiak`),
  not the ExpressiveOS commit.

| Runner run | ExpressiveOS commit | Zip on the server | sha256 | State |
|---|---|---|---|---|
| [#14](https://github.com/denson9874/ExpressiveOS/actions/runs/38109019533) | `9d13062` | `/tmp/kodiak-evox-img-45a812a.zip` | `bd22199bf63657e8227bd944bbf766169ef74dedf36ef6dba99c522832306934` | Flashed and checked (table below) |
| [#17](https://github.com/denson9874/ExpressiveOS/actions/runs/38131554424) | `8cc9b64` | `/tmp/kodiak-evox-img-9190352.zip` | `f7d1122e294800d7985e82914659cc75dcd5133597424e4e5970e200e03c87ed` | **Flash stalled** at `super` 2/10 |
| [#20](https://github.com/denson9874/ExpressiveOS/actions/runs/38133386540) | `1a10718` | `/tmp/kodiak-evox-img-acd4512.zip` | `0ef682095e5621e279308b6afcd896722fa4e88b9b6fa9c7996f6489de07db15` | Flashed and checked: TPU labels, TPU and camera services, no crashes |
| [#21](https://github.com/denson9874/ExpressiveOS/actions/runs/38135812562) | `851b0ab` | none | none | Failed in kati: `SCONE-v77459` defined twice. Fixed by `41ea3b5` |
| built by hand on the server | `41ea3b5` | `/tmp/kodiak-evox-img-e974478.zip` | in the `.sha256` file next to the zip | `BUILD_EXIT=0`; `check-sepolicy.sh: OK` ([#24](https://github.com/denson9874/ExpressiveOS/actions/runs/38138299112)). **Flashed and checked; newest** |

Every build except #21 passed with `BUILD_EXIT=0` and `check-sepolicy.sh: OK`. In #20 the six types
from item 9 below dropped off the unmapped list. A hand-run build holds `~/evolution`, so the
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

On `e974478` (the hand-run build of `41ea3b5`):
- scone runs as `priv_app_36` from `/product/priv-app/SCONE-v77459`, with no crashes.
  - `pm get-privapp-permissions` lists about 50 permissions; nothing logs "not in privapp-permissions allowlist".
  - GMS's module brings its own allowlist once it's installed. That's why it printed `{}` before.
  - `configs/permissions/privapp-permissions-kodiak-scone.xml` now overlaps with it; the entries
    combine, so it stays as a backstop.
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
2. Copy and verify:
   ```bash
   cd ~/Downloads/kodiak-evox
   scp -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152:/tmp/kodiak-evox-img.zip .
   ```
   Compare `shasum -a 256 kodiak-evox-img.zip` with the server's `/tmp/kodiak-evox-img.zip.sha256`.
3. Flash **without wiping** (keeps Daryl's data):
   ```bash
   adb -s 66020DLDV0049F reboot bootloader
   ```
   ```bash
   fastboot -s 66020DLDV0049F update kodiak-evox-img.zip
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
- **ImsStack and ImsMediaService must be built from AOSP**
  (`packages/modules/ImsStack`, `packages/modules/ImsMedia`).
  - The stock ImsStack blob collides with the AOSP install.
  - The stock `PixelImsMediaService` uses `android.uid.phone` with **Google's** key.
    That gives `Signature mismatch … for shared user`, system_server crashes, and the
    phone bootloops.
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

After device-tree commits on the server, refresh the repo copy on the Mac:
```bash
cd ~/Developer/ExpressiveOS
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'cd ~/android-dt/trees/device_google_kodiak && git archive HEAD' | tar -x -C evolution-kodiak/device_google_kodiak
git add evolution-kodiak && git commit -m "evolution-kodiak: sync device tree"
```
As of this update the backup matches the server (device tree `7385c90`). It includes:
- the telephony blob list and `extract-files.py`
- the PixelImsMediaService change
- `TeleServiceOverlayKodiak` and `PixelImsMediaServiceOverlayKodiak`
- `radio.te`
- the move of the stock images to `kodiak-images`

`tools/` also holds copies of the server's `kodiak-images.sh` and `kodiak-build.sh`.

Sync again after further commits.

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
- **Good cloud-only tasks:**
  - Write `imsstack_app.te`, `vendor_ims_app.te` and the matching `seapp_contexts` (REEKY_DIFF section 3).
    Rule text has to come from the stock CIL, so ask Daryl to paste excerpts or run a grep on the server.
  - Draft product source RROs (REEKY_DIFF section 4).
