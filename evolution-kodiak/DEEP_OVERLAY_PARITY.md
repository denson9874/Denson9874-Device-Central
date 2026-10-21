# kodiak: product/system_ext overlay and config parity (2026-10-19)

A parity pass of stock CD1A.261005.003 product and system_ext configuration against our build,
outside Wi-Fi and telephony (other sessions cover those). Nothing on the server or in the device tree
was changed. Section 7 has content ready to apply.

Labels follow GEMINI.md: **Evidence** (read from a file, source, the stock dump or our build output),
**Inference**, **Unknown** (needs a phone or a log). Our side is the 2026-10-19 13:46 kodiak build
(`out/target/product/kodiak`, BUILD_EXIT=0; device tree `3caa75a`), plus `/tmp/audit` from the 10-18 build.

## 0. Method, and what it can't see

- Every stock overlay APK was decoded with `aapt2` (`/tmp/audit/stock_rro_*.txt`). The Google
  module names were mapped to the AOSP packages we build (section 1), and each key was compared with
  the union of our default-enabled overlays plus the stock vendor overlays, which ship unchanged.
  User-selectable overlays (fonts, icon shapes, cutouts, navbar modes) were left out.
- Then each stock key was checked against the **resource table of the target APK in our build**,
  dumped from `out/` for 267 APKs including the APEX contents. An RRO can only replace a resource
  the target defines, so a stock key our target lacks is a no-op. Of 497 "missing" keys, 303 are
  no-ops and 34 belong to apps we don't ship (DMService, Traceur, SafetyRegulatoryInfo); most of the
  rest are drawables, strings and illustrations. The functional remainder is in section 2.
- The no-op filter undercounts one case: overlay-local supporting resources that an effective key
  references (PixelDisplayService's `config_za_primary_display_*` arrays and `ZACI_*` drawables).
  Those are handled in 4.4.
- `missing.txt` compares exact paths. **Correction to it:** `android.software.freeform_window_management.xml`
  is not missing; Lineage installs it in product (`vendor/lineage/config/common_mobile.mk:45`; present
  in `out/.../product/etc/permissions`).
- **Correction to my own partial draft** (the same file, earlier today): it said the face feature
  XML was "likely correct to omit: no face HAL". That was wrong. Stock vendor has
  `vendor/apex/com.google.android.hardware.biometrics.face.apex` (see 5).
- Raw data in the shared notes folder: `deep_overlay_raw_diff.txt` (every key),
  `deep_overlay_effective_gaps.txt` (the filtered list), `deep_overlay_diff.py` (the script; set
  `TRES=<dir of target resource lists>` for the no-op tagging).

## 1. Inventory and package mapping

- Evidence: stock has 90 product overlays, 15 vendor overlays and **no system_ext overlays**.
- Evidence: all 15 vendor overlays are static RROs. The ones whose target we ship under the same
  name apply to our build unchanged. These include `NfcOverlayKodiakGsi` → `com.android.nfc`,
  `UwbOverlayPKK4Gsi` → `com.android.uwb.resources`, and the auto-generated vendor RROs for
  framework-res, Settings, SystemUI, SettingsProvider, TeleService, DeviceDiagnostics, Flipendo,
  StorageManagerGoogle and CrossDeviceAccessServicePrimary. `Traceur` and `DMService` don't apply
  (we don't ship those apps), and neither does `PixelNfcOverlayCommon` (Google target).
- Evidence, our product overlays that override a stock vendor value where stock's product overlays
  don't: only `theming_defaults` and `config_battery_percentage_setting_available` (both from
  `framework-res__evolution_kodiak__auto_generated_rro_product`, i.e. Evolution choices). This matches
  the 10-19 audit.

| Stock target | What we build (Evidence: package in `out/`) | Our overlay |
|---|---|---|
| com.google.android.nfc | com.android.nfc (`apex/com.android.nfcservices/.../NfcNciApex.apk`) | stock vendor `NfcOverlayKodiakGsi`, lineage `NfcOverlay` |
| com.google.android.uwb.resources | com.android.uwb.resources (`ServiceUwbResources.apk`) | stock vendor `UwbOverlayPKK4Gsi` |
| com.google.android.providers.media.module | com.android.providers.media.module | **none** |
| com.google.android.networkstack | com.android.networkstack (`system/priv-app/NetworkStack`) | lineage `NetworkStackOverlay` |
| com.google.android.captiveportallogin | com.android.captiveportallogin (`system/app/CaptivePortalLogin`) | none |
| com.google.android.cellbroadcastreceiver / service | com.android.cellbroadcastreceiver.module / com.android.cellbroadcastservice | pixel-style, retargeted |
| com.android.connectivity.resources | same | pixel-style `PixelConnectivityOverlay2024` |
| com.google.android.permissioncontroller / healthconnect / devicelockcontroller | com.android.* (APEX) | pixel-style, retargeted |
| com.google.android.documentsui | same (`system/priv-app/DocumentsUIGoogle`) | pixel-style `PixelDocumentsUIGoogleOverlay` |
| com.android.virtualization.terminal | same (virt APEX) | **none** |
| com.android.pixeldisplayservice | same (stock APK, re-signed) | **none** |

## 2. Table: stock item → ours → impact → action

Ranked by functional impact. Telephony and Wi-Fi items are left to their sessions (but see 6).

| # | Stock item | Our equivalent | Functional impact | Action |
|---|---|---|---|---|
| N1 | `product/etc/libnfc-nci.conf` | AOSP default `/system/etc/libnfc-nci.conf` | **Real.** Evidence: HCE listens on A+F only (not B); off-host AID routes only while the phone is switched on; AID subset matching off; eUICC MEP mode 3 instead of stock's 0 (3.1). Inference: Wallet works with Type-A readers but fails with Type-B-only readers; screen-off/locked eSE services such as digital car keys don't route | **Add** stock file (7.1) |
| D1 | SystemUIGoogle product RRO `config_showTemperatureWarning=1`, `config_showUsbPortAlarm=1` | AOSP default `0` (Evidence: `SystemUI/res/values/config.xml:392,395`) | **Real, safety.** No skin-temperature warning notification and no USB-port overheat alarm | **Add** `SystemUIOverlayKodiak` (7.4) |
| P1 | `PixelDisplayService__kodiak__auto_generated_rro_product` (38 entries) | none | Evidence: 10 config keys our PixelDisplayService defines are left at defaults, plus their 19 `ZACI_*` compensation images and threshold arrays. Inference: PixelDisplayService's display compensation (`za_compensation`, OPR/brightness filters, LBE lux switch) runs without kodiak's tables | **Ship stock RRO APK** (7.6) |
| M1 | `MediaProviderOverlay` | none | Photo picker has no Google Photos cloud media (keys exist in our MediaProvider, overlayable `MediaProviderConfig`, product policy) | **Add** (7.3) |
| F1 | framework-res product `config_evenDimmerEnabled=true` | `false` (`config_display.xml:31`) | Evidence: the stock vendor `displayconfig` has `<evenDimmer enabled="true">` (line 195), but the framework flag that gates it is off. Inference: "Extra dim" falls back to the legacy colour-matrix dimming | **Add** (7.5) |
| F2 | framework-res product `config_nightDisplayColorTemperatureCoefficients` | AOSP generic coefficients | Night Light colour curve not calibrated for this panel | **Add** (7.5) |
| F3 | `config_fingerprintSupportsGestures=false` | **true** (pixel-style `PixelConfigOverlayCommon`) | Inference: Settings offers fingerprint swipe gestures that kodiak's ultrasonic UDFPS doesn't support | **Override** (7.5; priority caveat) |
| F4 | `config_refreshRateSynchronizationEnabled=true` | false | Refresh-rate sync with external displays (`config.xml:6069`). Minor | Add (7.5) |
| F5 | `config_dynamicInstrumentationEventConsumer` = ODAD `HummingbirdEventService` | empty: events are discarded (`config.xml:5349`) | Evidence: we ship `OdadPrebuilt` (`com.google.android.odad`, a stub until Play updates it). Inference: Play Protect's dynamic-instrumentation consumer gets no events even after the update | Add (7.5) |
| T1 | `TerminalOverlay` `gfxstream_supported=true` | default | Linux Terminal without GPU acceleration. LineageOS laguna builds this overlay | Add (7.7) |
| J1 | `PixelNfc` + `product/etc/felica/*.cfg` | none, but we ship `felica_feature.xml` | Japanese SKUs: we advertise `android.hardware.felica`, but Osaifu-Keitai has neither config nor the SKU provider | Add (7.2) |
| C1 | `default-permissions_com.google.android.apps.carrier.carrierwifi.xml` | none (we ship `CarrierWifi` and its privapp XML) | `ACTIVITY_RECOGNITION` isn't pre-granted to CarrierWifi. Inference: affects carrier Wi-Fi auto-connect heuristics. Low | Add (7.8) |
| B1 | `product/etc/permissions/android.hardware.biometrics.face.xml` | none | Evidence: face unlock works on our build (HANDOFF §2d, build #14). Inference: apps that query `FEATURE_FACE` see no face sensor, and `AuthService.java:1125` (the R-SDK compat config) omits face | Add (7.8), low |
| U1 | `PixelUwbOverlayPKK4` / vendor `UwbOverlayPKK4Gsi` | vendor GSI overlay applies | none (11 identical keys, same values) | none |
| U2 | `CccDkTimeSyncService` (`com.google.pixel.digitalkey.timesync`, `UWB_PRIVILEGED`) + lib + sysconfig | none | Inference: CCC digital car key UWB time sync is absent; the UWB overlay advertises `android_specific_timesync_supported=true`. Only matters with a UWB car key | Investigate (6) |
| N2 | `PixelNfcOverlayKodiak` (product) | vendor `NfcOverlayKodiakGsi` applies | none (11 identical keys) | none |
| N3 | `PixelNfcOverlayCommon` (vendor, Google target) | doesn't apply | `enable_nfc_url_open_dialog` for mcc204-mnc04, 310-004, 311-480 only. `nfc_proprietary_getcaps_supported=true` is already the AOSP default | Optional (7.9) |
| N4 | lineage `NfcOverlay` `enable_nfc_default=false` | ours only | NFC is off after a clean flash (AOSP default `true`). Stock's Google NFC default not read (erofs APEX) | Daryl's call (7.10) |
| S1 | SystemUI `config_preferredScreenshotEditor`/`config_screenshotEditor`/`config_remoteCopyPackage` | empty | Inference: screenshot "Edit" goes through the chooser instead of Pixel's editor (we ship `CreativeAssistant` and `MarkupGoogle_v2`) | Optional (7.4) |
| K1 | `config_keyChordPowerVolumeUp=2`, `config_longPressOnPowerBehavior=5` | 1 and 1 (Evolution's product RRO) | Behaviour choice (power + vol-up toggles mute instead of opening the power menu; long press opens the power menu instead of the assistant) | none (intended) |
| — | `NetworkStackOverlay` `config_force_enable_apfv6_nd_offload` | key not in AOSP NetworkStack | can't be overlaid (audit L3) | none |
| — | `ConnectivityOverlay`, `CellBroadcast*Overlay` | identical values | none | none |
| — | `CaptivePortalLoginOverlay` | none | icon background colour only | skip |
| — | `PixelDocumentsUIGoogleOverlay` (112 entries) | 20 | Evidence: all 93 stock keys we lack are absent from our DocumentsUIGoogle: no-ops | none |
| — | PermissionController, HealthConnect, DeviceLock, ManagedProvisioning, AccessibilityMenu, ContactsProvider, BuiltInPrint, DeviceDiagnostics | pixel-style | no effective gap | none |
| — | Settings product RROs (`SettingsGoogle__kodiak` 47, `SettingsGoogleKodiakOverlay` 40, `SettingsKodiakOverlay`, `Gaze`, `Ultrasonic`) | partial | Evidence: what's left after filtering is strings ("Pixel Imprint" naming, DE carrier Wi-Fi-calling wording), warranty/regulatory HTML and labels, `config_gazeEnabled` (face attention), and carrier lists (6). Feature flags such as `config_fingerprint_enroll_calibration` and `config_adaptive_touch_sensitivity_enabled` are no-ops: our Settings doesn't define them | none functional; regulatory labels optional |
| — | SetupWizard 2024/2025/2026/PixelPro2026 | `PixelSetupWizardOverlayExpressive` only | strings, lottie colours, Pearl/Spoon (Screenshots, Magic Cue) setup actions, Headstart endpoint (audit M6) | cosmetic |
| — | `SettingsProvider` product `def_wireless_charging_started_sound=""` | default sound | stock is silent when wireless charging starts | cosmetic |

## 3. NFC and payments

**3.1 `libnfc-nci.conf`**
- Evidence, search order (`packages/modules/Nfc/libnfc-nci/src/adaptation/nfc_config.cc:38-41`):
  `/product/etc/`, `/odm/etc/`, `/vendor/etc/`, `/system_ext/etc/`, `/etc/`, then
  `/apex/com.android.nfcservices/etc/`. It tries `persist.nfc_cfg.config_file_name`, then
  `libnfc-nci-<ro.boot.product.hardware.sku>.conf`, then `libnfc-nci.conf` (`:58-71`).
- Evidence: stock ships only `product/etc/libnfc-nci.conf`, and stock vendor has only
  `libnfc-hal-st.conf`/`libnfc-hal-st_p1.conf`. Our build has no product copy (checked in the 10-19
  output), so it loads the AOSP default from `/system/etc` (`libnfc-nci.conf-default`).
- Evidence, **secure element routing is vendor-side and unchanged**. `NfcAdaptation::GetVendorConfigs`
  (`NfcAdaptation.cc:479-587`) takes routes, pipe IDs, the SYS_CODE route and power state, and the
  host allow list from the HAL. The stock HAL conf sets `DEFAULT_ROUTE=0x00`, `DEFAULT_ISODEP_ROUTE=0x00`
  (host, so Wallet HCE is the default), `OFFHOST_ROUTE_ESE={86}`, `OFFHOST_ROUTE_UICC={81}`,
  `DEFAULT_NFCF_ROUTE=0x86`, `DEFAULT_SYS_CODE_ROUTE=0x86`, `DEFAULT_SYS_CODE_PWR_STATE=0x3B`.
  The NFCC is ST54L (`st54l_fw.bin`).
- Evidence, keys that change behaviour in our NFC source:

| Key | Stock | Ours (AOSP file / code default) | Read at |
|---|---|---|---|
| HOST_LISTEN_TECH_MASK | 0x07 (A+B+F) | unset → A\|F | `RoutingManager.cpp:136`, `NativeNfcManager.cpp:1768` |
| OFFHOST_AID_ROUTE_PWR_STATE | 0x3B | unset → 0x01 | `RoutingManager.cpp:131` |
| AID_MATCHING_MODE | 0x03 | 0x01 | `RoutingManager.cpp:112` |
| EUICC_MEP_MODE | unset → 0 | **0x03** | `RoutingManager.cpp:143,296`, `RoutingOptionManager.java:198` |
| NFA_AID_BLOCK_ROUTE | 1 | unset | `nfa_ee_main.cc:130` |
| DEFAULT_SYS_CODE | {FE:FE} | unset | `RoutingManager.cpp:121` |
| PRESENCE_CHECK_RETRY_COUNT | 1 | 0 | `NativeNfcTag.cpp:1478` |
| POLLING_TECH_MASK | 0x2F | 0x0F | `NativeNfcManager.cpp:1755` |
| NFCEE_EVENT_RF_DISCOVERY_OPTION, OPTIMIZE_ROUTING_TABLE_UPDATE, NFA_EE_ROUTE_DEBOUNCE_TIMER, KOVIO_PRESENCE_CHECK_TYPE, NCI_RESET_TYPE | unset | set by the AOSP file | `RoutingManager.cpp:145,160`, `NfcAdaptation.cc:187,696` |

  Evidence: SCREEN_OFF_POWER_STATE, LEGACY_MIFARE_READER, TAG_READ_EVT_TIMEOUT and
  P2P_LISTEN_TECH_MASK aren't read anywhere in our NFC source. They're harmless, carried over from
  Google's module.
- Unknown: no user log of a failed tap. To confirm on a phone, run `adb shell dumpsys nfc` (listen
  tech, routing table) and take a logcat during a tap.
- Reference: Evolution's husky and cheetah trees ship the stock file the same way
  (`vendor/google/husky/husky-vendor.mk:640`). LineageOS laguna's tree doesn't list it (Unknown:
  where laguna's comes from).

**3.2 NFC overlays.** Evidence: AOSP `com.android.nfc` declares `<overlayable name="NfcCustomization">`
with policy `product|system|vendor`, and all 11 keys of the vendor `NfcOverlayKodiakGsi` are in it,
so the vendor overlay applies. Its values equal `PixelNfcOverlayKodiak`'s. Laguna builds
`PixelNfcOverlayCommon` and `PixelNfcOverlayLaguna` from source, retargeted to `com.android.nfc` with
`targetName="NfcCustomization"`; that's the pattern for 7.9.

**3.3 FeliCa / PixelNfc.** Evidence: stock `felica/common.cfg` names `eSE1` and
`content://com.google.android.pixelnfc.provider.DeviceInfoContentProvider/isJapanSku`. The provider
is in `system_ext/priv-app/PixelNfc/PixelNfc.apk` (`com.google.android.pixelnfc`: no sharedUserId,
an exported provider, one external permission `ACCESS_COUNTRY_PROXY`). Its signer
(`6175bc12…c845`) is **not** stock's platform cert (`606aafa6…d548`, framework-res and
SettingsGoogle), so `PRESIGNED` is correct. Stock's
`preinstalled-packages-product-pixel-2019-and-newer.xml:30` lists it. Unknown: whether it reports the
SKU correctly without `com.google.android.apps.pixel.countrydetectionproxy`, which isn't in stock's
product/system_ext lists either. This needs a Japanese-SKU tester.

## 4. Other subsystems

**4.1 UWB.** Evidence: `UwbOverlayPKK4Gsi` (vendor, `targetName="UwbCustomization"`) targets
`com.android.uwb.resources`, which is inside our `com.android.uwb` APEX. Its 11 keys and values
match `PixelUwbOverlayPKK4`. Nothing to add. Digital car key time sync: see U2 and 6.

**4.2 NetworkStack, Connectivity, CaptivePortalLogin, CellBroadcast.** Evidence: the Connectivity
and CellBroadcast values are identical. NetworkStack's only missing key doesn't exist in AOSP. The
CaptivePortalLogin overlay holds only an icon colour. One observation, Unknown impact:
`config_defaultCaptivePortalLoginPackageName=com.google.android.captiveportallogin` comes from
pixel-style `GoogleConfigOverlay`, while we ship `com.android.captiveportallogin`. Where the
framework uses this key wasn't traced. Test hotel/portal Wi-Fi sign-in once before acting on it.

**4.3 SystemUI and Settings.** Evidence: both `system_ext/priv-app/SystemUI/SystemUI.apk` and
`SystemUIGoogle.apk` are in `installed-files-system_ext.txt` with the same package name. Which one
the package manager keeps is Unknown (out of scope; flagged in 6). Functional SystemUI gaps: D1, S1.
Settings: none functional (section 2).

**4.4 PixelDisplayService.** Evidence: the stock RRO references only its own arrays and drawables,
plus literal numbers. No `@0x01…` framework IDs, so the stock APK can ship as is. Our tree already
ships stock product RROs that way (`proprietary-files.txt:194-208`, `;MAKE_COPY_RULE_ONLY`:
PixelBatteryHealth, PixelBatteryLotX, Pearl, TrafficLightFace). Laguna recreates the equivalent in
source (`PixelDisplayServiceOverlayProductLaguna`). Copying the APK is exact and needs no drawable
extraction.

**4.5 MediaProvider.** Evidence: `packages/providers/MediaProvider/res/values/overlayable.xml:18-26`,
`<overlayable name="MediaProviderConfig">`, policy `product|system|vendor`, includes both cloud keys,
whose defaults are empty (`config.xml:28,30`). Stock's overlay uses `targetName="MediaProviderConfig"`.

**4.6 PermissionController, DocumentsUI, ManagedProvisioning, HealthConnect, DeviceLock.** No
effective gap (section 2).

## 5. sysconfig and permission XMLs (`missing.txt`)

| Stock file(s) | Behaviour | Action |
|---|---|---|
| `product/etc/libnfc-nci.conf`, `felica/*.cfg` | sections 3.1 and 3.3 | add (7.1, 7.2) |
| `product/etc/permissions/android.hardware.biometrics.face.xml` | face feature flag (face HAL is in stock vendor `com.google.android.hardware.biometrics.face.apex`; face unlock already works) | add, low (7.8) |
| `default-permissions_com.google.android.apps.carrier.carrierwifi.xml` | pre-grants `ACTIVITY_RECOGNITION` to CarrierWifi, which we ship | add (7.8) |
| `system_ext/etc/permissions/CccDkTimeSyncService.xml`, `preinstalled-packages-cccdktimesync.xml`, `org.carconnectivity.android.digitalkey.timesync.{xml,jar}` | CCC digital key UWB time sync | investigate (6) |
| `system_ext/etc/sysconfig/preinstalled-packages-pixeldisplayservice.xml`, `-tuscany.xml`, `-exo.xml`, `-device-pixel.xml`, `-ramdump-and-coredump.xml` | user-type install lists. Evidence: our `config_userTypePackageWhitelistMode=13` (enforce + implicit allowlist), so unlisted packages are installed for every user type. Effect: they also install in guest/secondary users. No breakage | optional |
| `system_ext/etc/permissions/computercontrol.extension.xml` + jar | `com.android.extensions.computercontrol` library and feature (agent "computer control") | Unknown: needs the jar re-extracted. Look at it with the AI-features work, not here |
| `com.google.input.gia.giaservicemanager.{xml,jar}`, `malibu-plugin-provider.jar` | Google input / malibu display plugin jars | Unknown, not traced |
| `privapp-permlist_com.google.location.lppe.main.xml` + `LPPeService` | LPP Extensions location service (carrier positioning) | Unknown impact; telephony/GNSS follow-up |
| `ConnectivityThermalPowerManagerNextgen.xml`, `preinstalled_packages_connectivity_thermal_power_manager.xml` | audit M5 | unchanged |
| `android.software.angle.xml` + `ANGLE.apk` | ANGLE as an updatable GLES driver; `config_angleAllowList/DenyList` depend on it | skip unless ANGLE is shipped |
| Verizon/OMA-DM set (`com.android.omadm.service.xml`, `sdm.plugins.*`, `com.verizon.*`, `features-verizon.xml`, `vzw_mvs_permissions.xml`, `allowlist_com.android.omadm.service.xml`, `preinstalled-packages-com.verizon.*`, `-vzwapnlib`, `-telephonygoogle`, `-carrier.log`) | only meaningful with those apps. `features-verizon.xml` declares `com.verizon.hardware.telephony.lte`/`ehrpd` | telephony session's call |
| factory OTA, RepairMode, BetterBug, DiagnosticsTool, `fstab.postinstall`, `product/etc/vintf/compatibility_matrix.xml` | apps we don't ship / OTA tooling. The product FCM is only used by VINTF checks | skip |
| `android.software.freeform_window_management.xml` | **not missing**: Lineage puts it in product | none |

## 6. Follow-ups not done here

1. **Telephony keys seen in the Settings RRO** (the telephony session ended with status failed):
   `config_carrier_for_mobile_network_toggle_disable` [19,25,28], `config_carrier_use_rac`,
   `config_carrier_for_wifi_scorer_toggle_off` [1839], `enabled_networks_values` / `_except_gsm_values`,
   `datausage_hiding_carrier_service_*` (Verizon), and framework `config_stk_sms_tp_mr_handling`
   (a no-op: not in our framework-res). All exist in our Settings except the last. Values are in
   `deep_overlay_effective_gaps.txt`.
2. **CCC digital key time sync** (U2): needs `CccDkTimeSyncService.apk` (priv-app, `UWB_PRIVILEGED`),
   its framework jar, permissions and sysconfig, and a signing check.
3. **Duplicate SystemUI**: both `SystemUI.apk` and `SystemUIGoogle.apk` are installed. Check on a
   phone which one is active (`adb shell pm path com.android.systemui`).
4. **Captive portal package key** (4.2): test portal sign-in.
5. Unknown framework keys: `config_cv_available=true`, `config_availableEMValueOptions=[0,1]`
   (DisplayManager EM_VALUE). Both exist in our framework; their meaning wasn't traced, so they aren't
   in 7.5.

## 7. Ready-to-apply content

All paths are relative to `~/android-dt/trees/device_google_kodiak`. The new RROs copy the structure
of the tree's own `TetheringOverlayKodiak` (SPDX header, `runtime_resource_overlay`,
`product_specific: true`) and laguna's manifests. After the build, verify each one with
`aapt2 dump resources` and, on a phone, with `adb shell cmd overlay list` and
`adb shell cmd overlay dump <pkg>`.

### 7.1 Stock `libnfc-nci.conf` (N1)
`proprietary-files.txt`, new section, then `./extract-files.py ~/android-dt/dumps/kodiak`:
```
# NFC: stock libnfc-nci.conf (product is searched first, nfc_config.cc:38)
product/etc/libnfc-nci.conf
```
Verify: `out/target/product/kodiak/product/etc/libnfc-nci.conf` is byte-identical to the dump. On a
phone, `dumpsys nfc` should show listen tech including B.

### 7.2 FeliCa for Japanese SKUs (J1)
```
# FeliCa / Osaifu-Keitai (Japanese SKUs): middleware config and the SKU provider it queries
product/etc/felica/common.cfg
product/etc/felica/mfm.cfg
product/etc/felica/mfs.cfg
system_ext/priv-app/PixelNfc/PixelNfc.apk;PRESIGNED
```
PixelNfc asks for no privileged permissions, so no privapp XML is needed. Without a Japanese-SKU
tester this can't be verified.

### 7.3 `MediaProviderOverlayKodiak` (M1)
`device.mk`: add `MediaProviderOverlayKodiak \` to the overlay `PRODUCT_PACKAGES` block (line 23).

`rro_overlays/MediaProviderOverlayKodiak/Android.bp`
```
//
// SPDX-FileCopyrightText: The LineageOS Project
// SPDX-License-Identifier: Apache-2.0
//

runtime_resource_overlay {
    name: "MediaProviderOverlayKodiak",
    product_specific: true,
}
```
`rro_overlays/MediaProviderOverlayKodiak/AndroidManifest.xml`
```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
    SPDX-FileCopyrightText: The LineageOS Project
    SPDX-License-Identifier: Apache-2.0
-->
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.android.providers.media.module.overlay.kodiak">
    <overlay
        android:isStatic="true"
        android:targetName="MediaProviderConfig"
        android:targetPackage="com.android.providers.media.module" />
</manifest>
```
`rro_overlays/MediaProviderOverlayKodiak/res/values/config.xml`
```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
    SPDX-FileCopyrightText: The LineageOS Project
    SPDX-License-Identifier: Apache-2.0
-->
<resources>
    <!-- From stock MediaProviderOverlay.apk: Google Photos as the photo picker's cloud provider. -->
    <string name="config_default_cloud_media_provider_package" translatable="false">com.google.android.apps.photos</string>
    <string name="config_default_cloud_provider_authority" translatable="false">com.google.android.apps.photos.cloudpicker</string>
</resources>
```

### 7.4 `SystemUIOverlayKodiak` (D1, optional S1)
`device.mk`: `SystemUIOverlayKodiak \`. Target `com.android.systemui`, no `targetName`. Evidence:
SystemUI's `res*/values` has no `<overlayable>`. The tree's `TeleServiceOverlayKodiak` and
`FrameworkResOverlayKodiak` use the same form.

`Android.bp`: as in 7.3 with `name: "SystemUIOverlayKodiak"`.
`AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.android.systemui.overlay.kodiak">
    <overlay
        android:isStatic="true"
        android:targetPackage="com.android.systemui" />
</manifest>
```
`res/values/config.xml`:
```xml
<resources>
    <!-- From stock SystemUIGoogle__kodiak__auto_generated_rro_product. AOSP defaults are 0,
         which hides the high skin-temperature notification and the USB port overheat alarm. -->
    <integer name="config_showTemperatureWarning">1</integer>
    <integer name="config_showUsbPortAlarm">1</integer>
    <bool name="config_vibrateOnIconAnimation">true</bool>

    <!-- Optional (S1): stock's screenshot editors. We ship CreativeAssistant and MarkupGoogle_v2. -->
    <string name="config_preferredScreenshotEditor" translatable="false">com.google.android.apps.pixel.creativeassistant/com.google.android.apps.pixel.creativeassistant.ExternalEditActivity</string>
    <string name="config_screenshotEditor" translatable="false">com.google.android.markup/com.google.android.markup.AnnotateActivity</string>
    <string name="config_remoteCopyPackage" translatable="false">com.google.android.gms/.nearby.sharing.RemoteCopyShareSheetActivity</string>
</resources>
```
Verify on a phone: `adb shell cmd overlay dump com.android.systemui.overlay.kodiak`. Because of the
duplicate SystemUI (6.3), check that it binds to the APK that actually runs.

### 7.5 Additions to `FrameworkResOverlayKodiak` (F1-F5)
Add to `rro_overlays/FrameworkResOverlayKodiak/res/values/config.xml` (values from stock
`framework-res__kodiak__auto_generated_rro_product`):
```xml
    <!-- Display: stock vendor displayconfig enables evenDimmer; the framework gate is off in AOSP. -->
    <bool name="config_evenDimmerEnabled">true</bool>
    <bool name="config_refreshRateSynchronizationEnabled">true</bool>
    <!-- Night Light curve for this panel (stock). -->
    <string-array name="config_nightDisplayColorTemperatureCoefficients" translatable="false">
        <item>0.0</item>
        <item>0.0</item>
        <item>1.0</item>
        <item>-0.000000014365268757</item>
        <item>0.000255092801250106</item>
        <item>-0.064156942434907716</item>
        <item>-0.000000000910931179</item>
        <item>0.000207598323269139</item>
        <item>-0.349361641294833436</item>
    </string-array>
    <!-- The ultrasonic UDFPS has no swipe gestures; pixel-style PixelConfigOverlayCommon sets true. -->
    <bool name="config_fingerprintSupportsGestures">false</bool>
    <integer name="config_fingerprintMaxTemplatesPerUser">4</integer>
    <!-- Play Protect's dynamic instrumentation consumer (OdadPrebuilt). Empty discards events. -->
    <string name="config_dynamicInstrumentationEventConsumer" translatable="false">com.google.android.odad/com.google.android.apps.miphone.odad.hb.HummingbirdEventService</string>
```
- Caveat (F3): this only wins if `FrameworkResOverlayKodiak` sorts above pixel-style
  `PixelConfigOverlayCommon` (both are static product overlays on `android`). The order wasn't
  checked. Confirm with `adb shell cmd overlay list android` and
  `adb shell cmd overlay lookup android android:bool/config_fingerprintSupportsGestures`. If the
  value doesn't win, add `android:priority` to the manifest.
- The night-display array was read from the decoded dump at 18+ significant digits; check it
  against `aapt2 dump resources` of the stock APK when applying.
- Deliberately left out: `config_defaultFirstUserRestrictions` (`no_oem_unlock`),
  `config_repairModeSupported` (no RepairMode), `default_wallpaper_component` (Breel), ANGLE lists,
  and `config_maxDesktopWindowingActiveTasks` (stock 8 vs pixel-style 5; cosmetic).

### 7.6 PixelDisplayService RRO (P1)
`proprietary-files.txt`, under the PixelDisplayService section (`:176`):
```
product/overlay/PixelDisplayService__kodiak__auto_generated_rro_product.apk;MAKE_COPY_RULE_ONLY
```
Same mechanism as `PixelBatteryHealthOverlay` (`:194`). Re-extract and confirm that
`out/.../product/overlay/` holds it.

### 7.7 `TerminalOverlayKodiak` (T1)
Laguna's `overlay/TerminalOverlay`, renamed. `device.mk`: `TerminalOverlayKodiak \`.
`AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.android.virtualization.terminal.overlay.kodiak">
    <overlay
        android:isStatic="true"
        android:targetName="TerminalConfig"
        android:targetPackage="com.android.virtualization.terminal" />
</manifest>
```
`res/values/config.xml`:
```xml
<resources>
    <bool name="gfxstream_supported">true</bool>
</resources>
```
Evidence: `TerminalApp/res/values/overlayable.xml:17-19` lists `gfxstream_supported` in
`TerminalConfig`. Unknown: whether gfxstream works on malibu with our virt APEX (stock enables it).

### 7.8 Small stock files (C1, B1)
```
# CarrierWifi runtime permission default (stock)
product/etc/default-permissions/default-permissions_com.google.android.apps.carrier.carrierwifi.xml
# Face feature flag (face HAL is stock vendor com.google.android.hardware.biometrics.face.apex)
product/etc/permissions/android.hardware.biometrics.face.xml
```
If CarrierWifi was already installed, the default grant only applies on a fresh install or a
`pm reset-permissions`.

### 7.9 Optional: Verizon NFC URL dialog (N3)
`rro_overlays/PixelNfcOverlayCommonKodiak`, the laguna `PixelNfcOverlayCommon` layout (target
`com.android.nfc`, `targetName="NfcCustomization"`), with `res/values-mcc204-mnc04/config.xml`,
`values-mcc310-mnc04/config.xml` and `values-mcc311-mnc480/config.xml`, each containing:
```xml
<resources>
    <bool name="enable_nfc_url_open_dialog">true</bool>
</resources>
```

### 7.10 Daryl's call: NFC on by default (N4)
Lineage's `NfcOverlay` sets `enable_nfc_default=false`. To match AOSP and stock behaviour, add
`<bool name="enable_nfc_default">true</bool>` in a `com.android.nfc` overlay that sorts above it (as
in 7.9). Leaving it as is means NFC stays off after a clean flash until the user turns it on.
