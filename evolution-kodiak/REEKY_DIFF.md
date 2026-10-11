# Reeky's LineageOS 24.0 kodiak build: diff against our Evolution X tree

Written 2026-10-10. This compares Reeky's unofficial build with our port and lists what's worth adopting.
Nothing from it was flashed.

**Source:** Reeky's Google Drive folder `10qZ2NTJpTJpo_VnQF8aeZjvjlq5_C2x4`, binaries only (no source has been released).

| File | sha256 |
|---|---|
| `lineage-24.0-20260913-UNOFFICIAL-reeky-kodiak.zip` | `13a031f1a84100cc4ef23d408ecfc695ed7212d4b3b4aa4f8aecb8db31bb01b9` |
| `boot.img` | `4688188357b97ee112df948335f53d08a29b17cebf74bfbd2aad7b8baed31488` |
| `init_boot.img` | `ed8e00a42906b138ac441e4c571c11680a43780a0a50dd2942fbc98806534831` |
| `vendor_boot.img` | `6e1bb86ad7c6716681c9169c26c0fe84895e3cc6801b2a5ad8e33176fcf2af2b` |

**Unpacked on the build server**, under `~/android-dt/ref/reeky/`:

| Folder | Contents |
|---|---|
| `dl/` | The downloaded files |
| `imgs/` | Every payload partition (ota_extractor) |
| `fs/{vendor,system,system_ext,product,vendor_dlkm,system_dlkm}` | Filesystems (ext4, unpacked with 7zz) |
| `boot/` | unpack_bootimg output |
| `vb/r` | The vendor_boot ramdisk |
| `lists/` | File lists: reeky, stock CD1A.261005.003 and ours |
| `overlays/*.txt` | `aapt2 dump resources` for every overlay APK |
| `sepol/` | imsstack_app rules extracted from the CIL |

## What the build is

- **LineageOS 24.0:** build id `CP2A.260605.016`, userdebug, dev-keys, built 2026-09-13.
- **Spoofed fingerprint:** stock `CD1A.260714.001.A9`, August patch level.
- **The OTA carries firmware too** (abl, bl31, dbl, gsa, tzsw, modem and others) from CD1A.260714. That's older than the
  phone's CD1A.261005.003, so **never flash this zip on the test phone** (bootloader downgrade risk).
- **Everything is built from source**, which is a different architecture from ours:
  - **Vendor:** ext4 rather than stock erofs, with a full malibu vendor sepolicy written from source
    (around 3,700 rules in `device/google/kodiak/malibu/sepolicy/vendor`).
  - **Kernel:** a custom one, `6.12.92-android16-6-Reeky-4k`. Stock is 6.12.69, so vendor_dlkm is rebuilt too.
  - **Tree layout:** `device/google/kodiak/{malibu,sepolicy/kodiak}`, the Lineage Pixel 10 pattern.
  - **Lineage HALs:** touch, health and powershare.
- **What this means for us:** it isn't a base. Swapping our stock-prebuilt vendor for a rebuilt one would mean redoing
  the port. The parts below can be lifted individually without that.

The CIL files keep `;;* lmx <line> <source path>` markers. These give the file and line layout of Reeky's sepolicy
source, so their `.te` files can be rebuilt fairly faithfully.

## Findings, by value to us

### 1. IMS media: likely root cause of the calls failing (reasonCode 401)

| | Ours | Reeky |
|---|---|---|
| ImsStack | AOSP, `platform_app` domain | AOSP, its own `imsstack_app` domain |
| IMS media | **AOSP ImsMediaService** | **Stock `PixelImsMediaService`, re-signed with their platform key** |
| `libpixelimsmedia.so` | absent | shipped (system_ext/lib64) |
| `vendor.google.whitechapel.audio.extension-V8-ndk.so`, `vendor.google.whitechapel.audio.audioext@4.0.so` | absent | shipped (system_ext/lib64) |
| `preinstalled-packages-pixelimsmedia.xml` | absent | shipped |
| `radio → platform_app udp_socket` rule | `radio.te` (23d771b) | the same rule in their `radio.te`, plus the same for `vendor_ims_app` |

- **Reeky's APK is the stock APK, only re-signed.** Its `classes.dex` is identical to stock (sha256 `e14f8f5e…`).
- **Why that matters:** the native library links against Pixel's whitechapel audio extension HAL, which is the
  modem-to-audio path. AOSP ImsMedia has no equivalent, which fits `CODE_MEDIA_INIT_FAILED`.
- **Why our earlier attempt crashed:** we listed it `;PRESIGNED`, which keeps Google's signature.
  Lineage extract-utils re-signs any blob that isn't presigned, and that's all Reeky did.

**Proposed change** (one test round):
- Add `system_ext/priv-app/PixelImsMediaService/PixelImsMediaService.apk` **without** `;PRESIGNED`.
- Add `libpixelimsmedia.so` and both whitechapel audio libraries.
- Add the sysconfig XML.
- Optionally recreate `PixelImsMediaService__kodiak__auto_generated_rro_product` as a source RRO.
- Drop AOSP ImsMediaService from `PRODUCT_PACKAGES`. Same package name (`com.android.telephony.imsmedia`), so ship only one.
- Keep `radio.te`.

### 2. Missing system_ext blobs (stock ships them; Reeky ships them; we don't)

| Blob | Explains |
|---|---|
| `vendor.google.edgetpu_app_service@1.0-service` + rc, vintf, `com.google.edgetpu_*-ndk.so` | the "stopped edgetpu" service and the edgetpu `service_manager find` denials |
| `sconed` + `sconed.rc` | `com.google.android.apps.scone` crashing at boot |
| `gs_watchdogd` + rc | the watchdog daemon |
| `mosey_server` + `manifest_mosey.xml` + `libmosey_daemon_ffi.so` | the mosey HAL |
| `vendor.google.whitechapel.audio.hal.parserservice` + rc | audio parser service |
| `PixelQualifiedNetworksService` | QNS, which Wi-Fi calling / IWLAN handover needs |
| `PixelSatelliteService` | satellite SOS |
| `PixelDisplayService` + `libpixeldisplaymanager_jni.so` | display features (extra brightness, adaptive refresh) |
| `ConnectivityThermalPowerManagerNextgen` | modem thermal management |
| `malibu-plugin-provider.jar`, camera extension jars, `PersistentBackgroundCameraServices` | camera features and extensions |

Each of these also needs its system_ext SELinux domain (section 3).

### 3. System_ext sepolicy: about 40 Google app and daemon domains

Our system_ext is built from AOSP, so every Google domain that stock defines in system_ext is missing.
Our blobs therefore run as `platform_app` or `priv_app`, which is why we needed `radio.te`. Reeky rebuilt them in
`device/google/kodiak/malibu/sepolicy/system_ext/private/`. The rule counts per file are in the CIL markers:

- **Telephony:** `imsstack_app` (46 rules), `vendor_ims_app` (41), `grilservice_app`, `pixel_modem_app`,
  `rilextensionservice_app`, `oemrilservice_app`, `euiccpixel_app`, `vendor_qualifiednetworks_app`,
  `vendor_satellite_service`, `pixelntnservice_app`, `vendor_rcs_app`, `vendor_rcs_service_app`,
  `vendor_ims_remote_app`
- **Platform:** `edgetpu_app_service`, `pixeldisplayservice_app`, `sconed`, `scone_system_internals`,
  `mosey_server`, `mosey_app`, `gs_watchdogd`, `parser_service`, `connectivity_thermal_power_manager`,
  `bluetooth_gci`, `repair_mode_app`, `ssr_detector_app`, `dcservice_app`, `con_monitor_app`
- **Kodiak-specific:** `cccdk_timesync_app`

**Better source:** stock's `system_ext_sepolicy.cil` from CD1A.261005.003 (the same build as our vendor).
It's newer and authoritative; for imsstack_app, Reeky has 113 references and stock has 109.
- Use Reeky's markers to see how the rules split into files.
- Translate stock's CIL into `.te` files under `sepolicy/system_ext/private/`.
- Add the matching `system_ext_seapp_contexts` entries, for example
  `user=radio isPrivApp=true seinfo=platform name=com.android.imsstack domain=imsstack_app type=app_data_file levelFrom=all`.

### 4. Overlays

- **Our vendor overlays are fine.** Our vendor is stock, so we already ship Google's `*__kodiak__auto_generated_rro_vendor`.
- **The gap is product.** Stock product overlays missing from our build:
  - `framework-res`, `SystemUIGoogle`, `SettingsGoogle`, `SettingsProvider`, `TeleService` and `TelephonyProvider` (each `__kodiak__auto_generated_rro_product`)
  - `PixelImsMediaService__…`, `PixelDisplayService__…`, `DMService__…`
  - `PixelNfcOverlayKodiak`, `PixelUwbOverlayPKK4`, `PixelWifiOverlay2026`, `PixelTetheringOverlay2021`
  - `PixelBatteryHealthOverlay`, `SettingsKodiakOverlay`, `SettingsGoogleKodiakOverlay`, `EuiccSupportPixelOverlay`
  - `CaptivePortalLoginOverlay`, `ConnectivityOverlay` and others
- **How Reeky covers this:** with hand-written source RROs (`FrameworkResOverlayProductMalibu`, `PixelWifiOverlay2025Malibu`,
  `PixelDisplayServiceOverlayProductKodiak` and so on). Their resource dumps are in `~/android-dt/ref/reeky/overlays/`.
- **Plan:** use the **stock** product overlays as the source of values (decompile with `aapt2 dump resources`, then
  generate source RROs, as we did for `TeleServiceOverlayKodiak`). Use Reeky's split as the checklist for which ones matter.

### 5. Not worth adopting

| Item | Why not |
|---|---|
| Kernel, vendor, vendor_dlkm, vendor sepolicy | Rebuilt from source and incompatible with our stock-prebuilt design |
| Firmware | Older than the phone's |
| boot, init_boot, vendor_boot | Paired with their kernel and ramdisk |
| `adb_root` and `init.kodiak.adbroot.rc` | Debug conveniences, not for shipped builds |
| Lineage HALs (touch, health, powershare) | Optional |

### 6. Update 2026-10-11: source-level comparison through the yogi tree

Reeky's GitHub ([Reeky-ux](https://github.com/Reeky-ux)) still has only the kernel
(`lineage_kernel_google_kodiak`). An open issue there asks for the device tree, and it has had no answer. The closest
published source is [asdfmonster261/android_device_google_yogi](https://github.com/asdfmonster261/android_device_google_yogi)
plus its vendor repo. That's LineageOS 24.0 for the Pixel 11 Pro Fold: same malibu SoC, MediaTek T900 modem and telephony
blobs, and the same base as Evolution X cnb. It's built the way Reeky's is (vendor from source), and its
`sepolicy/vendor/device_allow.te` was generated from the stock compiled policy, so it shows which stock rules name which
domains. (The `0xnullsect0r/android_device_google_{kodiak,malibu,spacecraft}` repos are unmodified forks of the Pixel 10
trees, so they don't help.)

Its findings confirm sections 1 and 3, with one addition that matters for a **stock vendor** like ours:
- The stock vendor policy grants Google's system_ext domains their HAL access, e.g.
  `imsmediahaldaemon imsstack_app:udp_socket`, `grilservice_app rild:binder`,
  `rilextensionservice_app hal_ril_ext_service`, `pixel_modem_app shared_modem_platform`.
- With a prebuilt vendor these reach our build only through the system_ext mapping file. So the types must be
  declared in **system_ext public** policy, under stock's names. Defining them privately would compile, but every
  stock vendor rule would stay dead.
- The reverse is a bootloop: a public type that stock's vendor doesn't know leaves an unresolved `typeattributeset`
  (tested with secilc 3.9). Only types a vendor rule provably names are public. `check-sepolicy.sh` now reports both sides.

What was adopted (device tree commits of 2026-10-11; see HANDOFF section 2b):
- Section 1: already in; `radio.te` now targets `imsstack_app`.
- Section 2: the TPU app service, the audio HAL parser service (`ro.audio.ihaladaptervendorextension_enabled` was
  already set, so audioserver expected it), `gs_watchdogd`, QNS and `init.pms.rc`.
- Section 3: `imsstack_app`, `grilservice_app`, `pixel_modem_app`, `rilextensionservice_app`, `euiccpixel_app`,
  `edgetpu_app_server`, `hal_audio_parameter_parser`, `gs_watchdogd`, and stock's system_ext property labels.
  GRIL, the RIL extension and modem.pms are re-signed with the platform key so seapp can match them on
  `seinfo=platform`, as yogi does.
- Section 4: `platform_carrier_config_package` = `com.google.android.carrier` (this was missing, so the shipped
  CarrierSettings was unused), plus the telephony values from stock's framework-res product RRO.

Still open: `vendor_ims_app` and the satellite domains, scone/mosey, PixelDisplayService, camera extensions, and the
non-telephony product RROs.

## Suggested order

1. **The calls test round:** do section 1 alone, so the result is clear.
2. **Sepolicy:** translate the telephony domains from section 3 (start with `imsstack_app` and `vendor_ims_app`).
   Then move ImsStack to `imsstack_app` and narrow `radio.te`.
3. **The section 2 blobs and their domains:** edgetpu, scone, QNS, PixelDisplayService.
4. **Product source RROs** (section 4).
