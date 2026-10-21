# Deep pass: eSIM, SIM and carrier stack (kodiak, 2026-10-19)

Static audit of our Pixel 11 build against stock CD1A.261005.003. The goal is that eSIM, carrier
provisioning and SIM switching work once EuiccGoogle ships. **Nothing on the server was changed**:
it was read-only, with no builds, commits or extract runs. Labels follow GEMINI.md: **Evidence** (read from a file, tool output or
source), **Inference** (deduced from evidence), **Unknown** (needs a phone).

Sources:
- Stock dump: `~/android-dt/dumps/kodiak`.
- Server tree: `~/android-dt/trees/device_google_kodiak` at `3caa75a`, which includes `485219f` (EuiccGoogle) and `f9e97eb` (APN source).
- `~/evolution/vendor/gms` at `1d69071`.
- Source in `~/evolution` (`frameworks/opt/telephony`, `frameworks/base`, `packages/providers/TelephonyProvider`, `packages/modules/Connectivity`).
- **The finished 2026-10-19 images build**: `out/target/product/kodiak`, `BUILD_EXIT=0`.
- The 10-18 user log `~/Downloads/logcat.txt`.

Tools: manifests from `aapt2 dump xmltree`, signers from `apksigner verify --print-certs`, permission
protection levels from `frameworks/base/core/res/AndroidManifest.xml`.

## 0. Summary

| # | Finding | Label | Action |
|---|---|---|---|
| S1 | With `485219f`, the eSIM chain (EuiccGoogle → phone process → UiccController → MTK RIL; EuiccSupportPixel → SE) has **no missing permission, allowlist, signer or SELinux piece** that I could find statically. The built image has EuiccGoogle byte-identical to stock and passes every `EuiccConnector` validity check | Evidence (static), Unknown (runtime) | Flash and run section 6 |
| S2 | **CarrierSetup can't get `MANAGE_NETWORK_POLICY`** (signature-only). It's PRESIGNED with stock kodiak's platform key, not ours | Evidence | Diff A: re-sign it |
| S3 | `f9e97eb` is right, and it also turns on CarrierSettings' own APN updater, which checks that TelephonyProvider points at it. The SFR report fits Lineage's `apns-conf.xml`, which has `208/10` default APNs with no MVNO match. **Existing installs keep their old APN rows** in TelephonyProvider | Evidence (code), Inference (effect on existing rows) | Release note: Settings > APN > Reset to default |
| S4 | **WfcActivation not shipped**: 48 carrier configs (AT&T, Rogers, Telus, Cricket, Spectrum, Cox, Boost/Sprint, ...) name it as the Wi-Fi calling e911 address app. vendor/gms already allowlists it | Evidence | Diff B: highest-value missing package |
| S5 | Fi `T120`: not in our logs. Tycho, its carrier-privilege certs and its default grants match stock. The absent LPA (B1) is the documented cause. A public report ties T120 to Fi's permissions and data access | Evidence (parity), Inference (cause) | Section 2 test |
| S6 | MEP: the vendor RRO values apply unchanged. No overlay of ours overrides an eSIM/slot key. The stock product keys are covered | Evidence | none |
| S7 | Per-device signing: CarrierSetup, EuiccGoogleOverlay and EuiccSupportPixelPermissions carry each phone's own key | Evidence (P11_FAMILY_DIFF) | grizzly/cubs/yogi: extract from their own dumps (Diff A also removes CarrierSetup from this list) |

## 1. eSIM chain with EuiccGoogle added

### 1.1 Packages and signers (Evidence)

Our platform key is `2d5efc1e…` (built grilservice and TeleService). Stock kodiak's platform key is `606aafa6…`.

| Package | Path | Signer (SHA-256 prefix) | Shared uid | Ours |
|---|---|---|---|---|
| `com.google.android.euicc` (EuiccGoogle, the LPA), versionCode 236971 | product/priv-app | `7e26b6d5` (Google) | – | **built image sha256 `5e8f39a2…` = stock** |
| `com.google.android.euiccoverlay` | system_ext/priv-app | `606aafa6` stock platform | – | PRESIGNED, = stock |
| `com.google.euiccpixel` (EuiccSupportPixel-P23) | system_ext/priv-app | `e0afeca7` | – | PRESIGNED, = stock |
| `com.google.euiccpixel.permissions` | system_ext/priv-app | `6175bc12` (per-device 2nd key) | – | PRESIGNED, = stock |
| `com.google.android.grilservice` | system_ext/priv-app | stock `6175bc12` | – | re-signed `2d5efc1e` |
| `com.google.android.carrier` (CarrierSettings) | product/priv-app | `c00409b6` | – | PRESIGNED, = stock |
| `com.google.android.carriersetup` | system_ext/priv-app | `606aafa6` stock platform | – | PRESIGNED, = stock (**S2**) |
| `com.google.android.apps.tycho` (Fi) V154, vc 5276410 | product/app (not priv, same as stock) | `4c36af4a` | – | vendor/gms, same versionCode |
| `com.android.phone` / `com.android.providers.telephony` | system/priv-app | platform | `android.uid.phone` | AOSP, ours |

### 1.2 Will the framework accept EuiccGoogle? (Evidence)

`frameworks/opt/telephony/.../euicc/EuiccConnector.java`:
- `findBestComponent` queries `android.service.euicc.EuiccService` with `MATCH_SYSTEM_ONLY`.
- `isValidEuiccComponent` (`:1210-1245`) requires three things:
  1. `checkPermission(WRITE_EMBEDDED_SUBSCRIPTIONS) == GRANTED`
  2. the service is guarded by `BIND_EUICC_SERVICE`
  3. intent-filter priority ≠ 0

| Check | EuiccGoogle | Result |
|---|---|---|
| `WRITE_EMBEDDED_SUBSCRIPTIONS` (signature\|privileged) | vendor/gms `privapp-permissions-google-p.xml:407`, on product (same partition as the APK); built `out/.../product/etc/permissions/privapp-permissions-google-p.xml` contains the package | pass |
| `BIND_EUICC_SERVICE` | `EuiccServiceImpl` and every `android.service.euicc.action.*` activity declare it | pass |
| priority | `100` on the service and all UI filters | pass |

The `EuiccUiDispatcherActivity` path (Settings "Add SIM", Setup Wizard) uses the same check through
`EuiccConnector.findBestActivity`. This is exactly where the 10-18 log failed:
`EuiccConnector: No valid component found for intent: ... PROVISION_EMBEDDED_SUBSCRIPTION` (log line 14721).

The privapp mode is `ro.control_privapp_permissions=log` (built `build.prop`). In
`frameworks/base/services/permission/.../AppIdPermissionPolicy.kt:1608-1623`, `log` mode **grants**
a privileged permission even when it isn't allowlisted, and only logs it. The allowlist is complete anyway:
`privapp-permissions-google-p.xml:394-411` covers all 15 privileged permissions EuiccGoogle requests,
including `READ_PRIVILEGED_PHONE_STATE`, which the 10-18 Play copy crashed on.

### 1.3 Every permission EuiccGoogle and EuiccSupportPixel request (Evidence)

| Permission | Defined by (protection) | How the app gets it on our build |
|---|---|---|
| `com.google.android.permission.USE_GRIL` | grilservice (signature\|privileged) | privileged + allowlist (`:410`). Re-signing GRIL doesn't matter: on stock, GRIL's key `6175bc12` doesn't match EuiccGoogle's either |
| `…scone.connectivitymonitor.permission.WRITE_NIMBUS_DATA` | SCONE | we ship `product/priv-app/SCONE-v77459` |
| `com.android.permission.WRITE_EMBEDDED_SUBSCRIPTIONS` | **no package on stock** | dead on stock too; harmless |
| `com.qualcomm.permission.USE_QCRIL_MSG_TUNNEL` | none | Qualcomm-only; harmless |
| `com.google.android.setupwizard.SETUP_COMPAT_SERVICE`, `READ_DEVICE_ORIGIN_FIRST_PARTY` | SetupWizardPrebuilt (vendor/gms) | shipped |
| `com.google.euiccpixel.permission.SECURE_ELEMENT` (EuiccSupportPixel) | EuiccSupportPixelPermissions (signature\|privileged), mapped to **gid `secure_element`** by `com.google.euiccpixel.permissions.xml` | privileged + `com.google.euiccpixel.xml` allowlist; both files are in the built system_ext |
| `SECURE_ELEMENT_PRIVILEGED_OPERATION`, `NFC_SET_CONTROLLER_ALWAYS_ON`, `WRITE_EMBEDDED_SUBSCRIPTIONS` (EuiccSupportPixel) | framework (signature\|privileged) | `com.google.euiccpixel.xml` |
| Default grants | `default-permissions.xml:168-171` (EuiccGoogle `POST_NOTIFICATIONS`), `default-permissions-euiccpixel.xml` | same as stock |
| Install-in-user | `preinstalled-packages-pixel-carrier.xml` (euicc in SYSTEM/FULL/PROFILE; euiccpixel and its permissions package in SYSTEM) | shipped |

Signature-only permissions requested by any PRESIGNED app in this chain (checked against our
`core/res/AndroidManifest.xml` for EuiccGoogle, EuiccSupportPixel, EuiccGoogleOverlay, CarrierSettings,
CarrierSetup, Tycho, WfcActivation and TetheringEntitlement):
- `MANAGE_NETWORK_POLICY` (pure signature), requested by **CarrierSetup** → **S2**.
- `WRITE_SETTINGS` has `preinstalled|appop`, so it's granted to the preinstalled app.

### 1.4 SELinux (Evidence)

- **EuiccGoogle is plain `priv_app` on stock.** It has no line in `system_ext_seapp_contexts`, `vendor_seapp_contexts` or
  `product_seapp_contexts`. The stock vendor policy has exactly one priv_app rule:
  `vendor_sepolicy.cil:13614` (`proc_version` getattr/open). So EuiccGoogle never reaches the radio HAL,
  SE HAL or modem directly. It goes through binder to the phone process, `econtroller` and `euicc_card_controller`, and from there:
  `EuiccCardController` → `UiccController` → `IRadioSim` (stock VINTF: `IRadioSim/slot1,slot2,se1,se2,imsSlot1,2`, v5) → MTK `rild`. AOSP platform policy covers that. **No vendor rule is lost.**
- **`euiccpixel_app`** vendor rules (`vendor_sepolicy.cil:9227-9251`, from `gs-common/euiccpixel_app`):
  set and read `vendor_secure_element_prop` (`persist.vendor.se.`) and `vendor_modem_prop`, read `dck_prop`.
  They apply on our build because:
  - our `public/apps.te` declares `euiccpixel_app`
  - `seapp_contexts` (`seinfo=EuiccSupportPixel`) matches stock's line exactly
  - our `mac_permissions.xml` maps the EuiccSupportPixel cert
- **GRIL / RIL extension**: `grilservice_app ↔ rild` binder (`:11512-11518`), `rilextensionservice_app ↔ rild`,
  and `hal_ril_ext_service` (`:15281-15311`) apply through our public types and `seinfo=platform` seapp lines.
- **Secure element HALs** (stock vendor VINTF):
  - `ISecureElement/SIM1`, `SIM2`: MediaTek `secure_element@1.2-service-mediatek`, `mtk_hal_secure_element`, which binds rild (`:13108-13120`)
  - `eSE1`: Thales GTO, `hal_secure_element_st54spi_aidl`
  - Their only client is `com.android.se` (AOSP `secure_element` domain, uid `se`). We ship `system/app/SecureElement`.
  - Stock vendor declares `android.hardware.se.omapi.uicc`.
- **CarrierSetup / EuiccGoogleOverlay** (stock platform key) → stock `vendor_mac_permissions.xml` maps that key
  to `seinfo=platform` → `platform_app`, as on stock. Diff A keeps them in `platform_app`, now through our key.
- **Verdict:** no sepolicy change is needed for eSIM. `check-sepolicy.sh` needs no new types.

### 1.5 Slots and MEP in the framework (Evidence)

- `UiccController.java:269,316` reads `config_num_physical_slots` and `non_removable_euicc_slots`.
  `EuiccPort.java:634` reads `config_telephonyEuiccDeviceCapabilities`. All three come from the **stock vendor
  framework-res RRO**, which applies unchanged because our vendor is stock:
  - `config_num_physical_slots = 2`
  - `non_removable_euicc_slots = [0]`
  - `config_telephonyEuiccDeviceCapabilities = [gsm,9 utran,9 eutran,15 nrepc,15 nr5gc,17 eutran5gc,15]`
- MEP comes from the modem: `UiccSlot.updateSupportedMepMode` (`:300-315`) takes the mode reported over IRadioConfig
  (stock `android.hardware.radio.config` v5), with an ATR fallback to MEP-B. `EuiccController.java:1327` gates MEP
  operations on it. The feature XMLs `android.hardware.telephony.euicc` and `.euicc.mep` are in the built product.
- **Overrides:** I scanned every built overlay that targets `android` for euicc, slot, sim and telephony keys. None of ours touches the three vendor keys.
  The stock **product** RRO's extra keys are covered:
  - `config_esim_bootstrap_data_limit_bytes`, by Evolution's `Pixelframework-res.apk`
  - `config_smppsim_response_via_ims=true`, by `FrameworkResOverlayKodiak`
- Unknown: the MEP mode the T900 modem actually reports. Check `dumpsys isub` / `dumpsys phone` (`MEP=` in the `UiccSlot` dump, `UiccSlot.java:827`).

### 1.6 Users who installed EuiccGoogle from Play on 10-18 (Inference)

The 10-18 log shows EuiccGoogle installed to `/data/app` as uid 10476 (line 6563). The system copy is the same package
with the same signer (`7e26b6d5`). At boot, PackageManager either drops the data copy (when the system copy is
newer or equal) or keeps it as an update of the now-system app. Either way the package becomes a system priv-app:
- `AppIdPermissionPolicy.kt:1603`: updated system apps need no allowlist.
- `MATCH_SYSTEM_ONLY` matches updated system apps.

Verify with `dumpsys package com.google.android.euicc` (section 6). If it stays a non-system app, the fix is
`adb shell pm uninstall --user 0 com.google.android.euicc` followed by a reboot, which restores the system copy.

## 2. Google Fi T120 and carrier activation

- **Evidence: Tycho matches stock.** vendor/gms ships Tycho V154 (vc 5276410, the same as stock) in product/app, not privileged, as on stock.
  `nexus.xml:64` lists it as `disabled-until-used-preinstalled-carrier-app`. Neither stock nor gms has a
  default-permissions entry for Tycho. Its needs: runtime Phone/SMS/Location/Contacts permissions, `SETUP_COMPAT_SERVICE` (shipped), GSF and C2DM.
- **Evidence: carrier privileges match stock.** `CarrierSettings/fi_tmo_us.pb` (shipped) lists `4C36AF4A…:com.google.android.apps.tycho`
  (Tycho's signer) and `B9CFCE1C…:com.google.android.apps.tycho` as carrier certificates. They take effect only once
  a Fi profile is active, through CarrierSettings as `platform_carrier_config_package` (TeleServiceOverlayKodiak). When the carrier
  app is enabled, `DefaultPermissionGrantPolicy.grantDefaultPermissionsToEnabledCarrierApps` (`:1122`) grants the Phone/Location/SMS groups.
- **Evidence: the activation path.** Fi's flow uses
  - EuiccGoogle's `CurrentCarrierAppInitActivity` (`android.telephony.euicc.action.START_CARRIER_ACTIVATION_ACTIVITY`)
  - `EuiccManager.downloadSubscription`

  Both need the LPA. On 10-18 the LPA was absent, `EuiccManager.isEnabled()` had nothing to bind, and the
  Setup Wizard eSIM step bounced back to the account screen (log 21:04:59 and 21:05:05).
- **Unknown: the exact meaning of T120.** It's not in any log we hold: the 10-18 log has no radio buffer and no Tycho lines.
  Google doesn't publish the code. On GrapheneOS, Fi support fixed T120 by turning on the eSIM toggle (GrapheneOS ships
  EuiccGoogle disabled, the equivalent of our B1), granting Fi Phone/SMS/Location and giving it unrestricted data
  ([GrapheneOS discussion](https://discuss.grapheneos.org/d/7950-does-grapheneos-work-with-google-fi/17),
  [Google Fi activation help](https://support.google.com/fi/answer/13531116)).
  **Inference:** on our next build T120 should clear with B1 fixed. If it doesn't:
  - check Tycho's runtime permissions
  - check its per-app network toggles (the NetworkPolicy `REJECT_ALL` finding in KODIAK_AUDIT section 1 and patch 0007 apply if Tycho was updated from Play)
- **CarrierSetup** (US carrier Setup Wizard screens):
  - its privileged permissions are allowlisted in vendor/gms `privapp-permissions-google-se.xml:121-125`
  - `MANAGE_NETWORK_POLICY` is missing (S2, Diff A)
  - `com.verizon.mips.services.RECEIVE_SUW_CARRIER_SCREENS_UPDATE` is defined by MyVerizonServices, which we don't ship; that only matters for Verizon

## 3. MEP / dual eSIM

See 1.5. Evidence summary:
- the vendor RRO values apply
- no product overlay of ours overrides an eSIM or slot key
- both feature XMLs ship
- the stock product-RRO eSIM keys are covered
- `persist.radio.multisim.config=dsds`, `ro.setupwizard.esim_cid_ignore=00000001` and
  `masterclear.allow_retain_esim_profiles_after_fdr=true` are in the built props

**No change proposed.**

## 4. APN source change (`f9e97eb`)

Evidence:
- **Built overlay:** `product/overlay/TelephonyProviderOverlayKodiak.apk`, static, target
  `com.android.providers.telephony`, `apn_source_service = "com.google.android.carrier/.ApnSourceService"`.
- **Service:** CarrierSettings declares `com.google.android.carrier.ApnSourceService`, exported and guarded by
  `WRITE_APN_SETTINGS` (signature|privileged). TelephonyProvider runs as `android.uid.phone` (platform-signed), which holds it.
- **TelephonyProvider** (`TelephonyProvider.java`):
  - `apnSourceServiceExists` (`:3456-3473`) resolves the component with `getServiceInfo(…, 0)` and caches the result.
    A disabled CarrierSettings therefore falls back to the XML.
  - `DatabaseHelper.onCreate` (`:830-840`): on a **new database** it skips `apns-conf.xml` and expects CarrierSettings to fill the table.
  - `onCreate` (`:~3592`): on a **build change** it runs `updateApnDb()` only when there is *no* source service.
    `updateApnDb` (`:5960-5990`) refuses to run when the service exists.
  - "Reset to default" (`restoreDefaultApn` → `:5955`): deletes the subscription's rows, then `restoreApnsWithService(subId)`
    binds `IApnSourceService` and bulk-inserts `getApns(subId)` (`:3500-3565`).
- **CarrierSettings has its own updater** (strings in its dex): `ApnUpdater`, `insertApns`, `applyApns`, `deleteApnsWithEdited`,
  `apnSourceServiceMatches: TelephonyProvider not found`, `insertApns: skipping operation`, and
  `versionChanged=%b buildChanged=%b subIdChanged=%b carrier=%s->%s numApnsTooFew=%b`.
  **Inference:** CarrierSettings writes APNs only when TelephonyProvider's `apn_source_service` points at it.
  On 10-18 it skipped, so APNs came only from Lineage's XML. With `f9e97eb` it re-applies on build or carrier change.
- **SFR (Evidence):** the built `apns-conf.xml` (3923 APNs) has `mcc=208 mnc=10` entries of type `default` with
  **no `mvno_type`**, for example `Auchan WAP` (`wap65`), `Coriolis WEB` (`internetcoriolis`), `Internet Joe` (`sl2sfr`) and `Keyyo Mobile Internet`.
  Each matches every SFR SIM. `sfr_fr.pb` holds SFR's own APNs (`sl2sfr` "SFR webphone", "SFR IMS", "SFR attach").
  This fits the wrong default APN reported on SFR eSIM.

Risks:
1. **Existing installs (Inference):** TelephonyProvider won't delete the old XML rows: `updateApnDb` is skipped when the service exists.
   CarrierSettings' updater should replace the active carrier's unedited APNs on `buildChanged`, but whether it deletes
   rows it didn't write is **Unknown**. Release note: users with a wrong APN should use **Settings > Network > SIMs > Access Point Names > ⋮ > Reset to default**.
   That path provably goes through the service.
2. **MVNOs missing from CarrierSettings (Inference):** they lose Lineage's XML APNs on a fresh install, and after a reset.
   This matches stock Pixel behaviour, but users coming from Lineage builds may notice. Workaround: add the APN by hand.
   Don't revert unless reports appear. `f9e97eb` is its own commit and can be reverted alone.
3. **Fresh install with no SIM (Inference):** the table starts empty until a SIM appears. This is the same as stock.

## 5. Stock telephony packages we still don't ship (ranked)

Signer, uid and domain are Evidence; impact is Inference unless stated.

| Rank | Package | Signer / uid | Needs | Impact |
|---|---|---|---|---|
| 1 | **WfcActivation** (`com.google.android.wfcactivation`) | Google `4ef08e4f` (not a per-device key) | PRESIGNED. Already present: vendor/gms allowlist (`privapp-permissions-google-p.xml:461-466`), `nexus.xml:28` power-save, hidden-API list, our `preinstalled-packages-pixel-carrier.xml` entry, `RadioConfigLib`/`com.android.omadm.radioconfig` (optional lib, shipped), `SEND_LOGS` from CarrierMetrics (shipped). Domain `priv_app` (no stock seapp entry) | **Evidence:** 48 CarrierSettings configs set `wfc_emergency_address_carrier_app_string = com.google.android.wfcactivation/.WfcActivationActivity` (AT&T and its MVNOs, Cricket, FirstNet, Boost/Sprint, Spectrum, Cox, Rogers, Fido, Telus, Koodo, ...). Without it those users can't complete Wi-Fi calling e911 setup. T-Mobile US uses ImsServiceEntitlement, which we ship. **High** |
| 2 | TetheringEntitlement | Google `a4960cb7` | PRESIGNED; allowlist already in gms (`:449-453`); plus the provisioning keys in `TetheringOverlayKodiak` (26 MCC/MNC values, Diff C) | **Turns on** hotspot entitlement checks for AT&T/Verizon/FirstNet/SoftBank/Vodafone NL SIMs (stock parity). AOSP's default is no check, so today hotspot is never blocked locally. Optional; don't ship unless a carrier blocks hotspot server-side |
| 3 | DMService + OemDmTrigger, ConnMO, DCMO, DiagMon | stock platform; DMService has shared uid `com.android.uid.omadm.service` | re-sign all (no PRESIGNED); product RRO `DMService__kodiak`; sysconfig already in `preinstalled-packages-pixel-carrier.xml` | OMA-DM provisioning (Sprint/T-Mobile legacy, Verizon). Low to medium; no user report |
| 4 | ConnectivityThermalPowerManagerNextgen | stock platform | re-sign; stock seapp `connectivity_thermal_power_manager` + public type (vendor rules `:10500-10521`: `hal_wifi_ext`, `vendor_modem_prop`); `libmipc.so`/`libMIPC-native.so`; uses `USE_GRIL` | Modem/Wi-Fi thermal mitigation. Unknown impact (M5) |
| 5 | TelephonyGoogle | stock platform, `android.uid.phone` | must be re-signed (shared uid; PRESIGNED would bootloop, like PixelImsMediaService did) | Low (L5) |
| 6 | SSRestartDetector | stock platform, `android.uid.system` | re-sign; `ssr_detector_app` (vendor `:6070-6079`) | Subsystem-restart crash reports. Low |
| 7 | PMSPersistApp | stock platform | re-sign | Unknown, probably modem-service persistence. Low |
| 8 | AppDirectedSMSService, MyVerizonServices, VZWAPNLib | Verizon keys | PRESIGNED | Verizon only (VZW APN lib, carrier Setup Wizard screens). Low outside the US |

Already shipped: CarrierMetrics (`com.google.android.apps.carrier.log`), CarrierLocation, SCONE, CbrsNetworkMonitor,
ImsServiceEntitlement (AOSP), Iwlan, QNS, satellite. CarrierLog has no separate stock APK; its package is CarrierMetrics.

## 6. Proposed changes (exact diffs; not applied)

**Diff A: re-sign CarrierSetup (S2).** No shared uid, so re-signing a system app is accepted:
`ReconcilePackageUtils.java:169,298` "signature changed; retaining data". It stays `platform_app`.
This also removes one per-device-key blob from the family port.
```diff
--- a/proprietary-files.txt
+++ b/proprietary-files.txt
@@ # Carrier setup and settings
 product/etc/sysconfig/preinstalled-packages-pixel-carrier.xml
 product/priv-app/CarrierSettings/CarrierSettings.apk;PRESIGNED
-system_ext/priv-app/CarrierSetup/CarrierSetup.apk;PRESIGNED
+# CarrierSetup is platform-signed on stock and needs MANAGE_NETWORK_POLICY, a
+# signature-only permission. Under the stock kodiak key it can't get it on our
+# build, so extract-utils re-signs it with our platform key. No shared uid.
+system_ext/priv-app/CarrierSetup/CarrierSetup.apk
```

**Diff B: ship WfcActivation (S4).**
```diff
--- a/proprietary-files.txt
+++ b/proprietary-files.txt
@@ # Carrier setup and settings
+# WFC Activation: the Wi-Fi calling emergency-address screen that 48
+# CarrierSettings configs name (wfc_emergency_address_carrier_app_string), e.g.
+# AT&T, Cricket, Rogers, Telus. vendor/gms ships its privapp allowlist and
+# sysconfig; preinstalled-packages-pixel-carrier.xml already lists it.
+product/priv-app/WfcActivation/WfcActivation.apk;PRESIGNED
```
Kati check: `find vendor/gms -iname "*wfc*" -o -iname "*tetheringentitlement*"` finds nothing, no `vendor/gms/*.mk`
names either package, and neither is in the built `product/priv-app`, so there is no "overriding commands" clash.

**Diff C (optional, together with a TetheringEntitlement PRESIGNED line): provisioning keys.** Generate them from stock instead
of typing 26 qualifier directories by hand:
```bash
# in rro_overlays/TetheringOverlayKodiak; values from stock PixelTetheringOverlay2021
for q in 204-4 310-4 440-20 310-30 310-70 310-90 313-100 313-110 310-120 313-120 313-130 313-140 310-150 310-170 311-180 310-280 310-380 310-410 311-480 311-490 312-530 310-560 312-670 310-680 313-790 311-870; do
  d=res/values-mcc${q%-*}-mnc${q#*-}; mkdir -p $d
  cat > $d/config.xml <<'X'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string-array name="config_mobile_hotspot_provision_app" translatable="false">
        <item>com.google.android.tetheringentitlement</item>
        <item>com.google.android.tetheringentitlement.CarrierEntitlementActivity</item>
    </string-array>
    <string name="config_mobile_hotspot_provision_app_no_ui" translatable="false">com.google.android.carrierentitlement.SILENT_ENTITLEMENT_CHECK</string>
    <string name="config_mobile_hotspot_provision_response" translatable="false">com.google.android.carrierentitlement.SILENT_ENTITLEMENT_CHECK_RESULT</string>
</resources>
X
done
```
Plus in `proprietary-files.txt`: `product/priv-app/TetheringEntitlement/TetheringEntitlement.apk;PRESIGNED`.
Also update the comment in `TetheringOverlayKodiak/res/values/config.xml`. **Recommendation: hold this until a user reports it.**

**No sepolicy or framework-res diff is proposed for eSIM** (sections 1.4, 1.5).

**Family:** apply A and B to grizzly, cubs and yogi, extracting from each phone's own dump. WfcActivation is Google-signed, so it's identical on all four.

## 7. On-device test recipe (next build)

Section 7 of HANDOFF applies: no root, `-v monotonic`. Service names `econtroller` and `isub` are AOSP's; if a dumpsys is empty, run `adb shell service list | grep -iE "euicc|econtroller|isub"`.

```bash
S=66020DLDV0049F
adb -s $S logcat -c
```
```bash
adb -s $S shell pm list packages -f com.google.android.euicc
```
Pass: `/product/priv-app/EuiccGoogle/EuiccGoogle.apk` (or a `/data/app` path that `dumpsys package` shows as an updated system app).
```bash
adb -s $S shell dumpsys package com.google.android.euicc | grep -E "codePath|versionCode|pkgFlags|privateFlags|WRITE_EMBEDDED_SUBSCRIPTIONS|USE_GRIL|READ_PRIVILEGED_PHONE_STATE"
```
Pass: `SYSTEM` in pkgFlags, `PRIVILEGED` in privateFlags, all three permissions `granted=true`.
```bash
adb -s $S shell ps -AZ | grep -E "com.google.android.euicc|euiccpixel|grilservice|rilextension"
```
Pass: `u:r:priv_app` for euicc (once it's running), `u:r:euiccpixel_app`, `u:r:grilservice_app`, `u:r:rilextensionservice_app`.
```bash
adb -s $S shell dumpsys econtroller
```
Pass: shows the bound or selected component `com.google.android.euicc/com.android.euicc.service.EuiccServiceImpl`, not "Unavailable".
```bash
adb -s $S shell dumpsys isub | grep -iE "embedded|isEuicc|slot|port|mep"
adb -s $S shell dumpsys phone | grep -iE "UiccSlot|isEuicc|MEP=|supportedMepMode"
```
Expected: slot 0 `isEuicc=true` (`non_removable_euicc_slots=[0]`). Record the `MEP=` value; it comes from the modem.
```bash
adb -s $S shell cmd package query-activities -a android.service.euicc.action.PROVISION_EMBEDDED_SUBSCRIPTION
```
Pass: resolves to `com.google.android.euicc/com.android.euicc.ui.suw.CurrentSuwInitActivity` (priority 100).

Then tap Settings > Network > SIMs > **Add SIM** (or "Download a SIM instead"), and dump the log:
```bash
adb -s $S logcat -d -b all -v monotonic > esim.txt
```
```bash
grep -E "EuiccConnector|EuiccUiDispatcher|EuiccController|EuiccCardController|EuiccPort|com.google.android.euicc|FATAL|SecurityException|avc: denied.*(priv_app|euiccpixel|grilservice)" esim.txt
```

| Must NOT appear (the 10-18 failures) | Must appear |
|---|---|
| `EuiccConnector: No valid EuiccService implementation found` | Google's "Download your SIM" screen opens; no `Could not resolve activity` |
| `EuiccConnector: No valid component found for intent ... PROVISION_EMBEDDED_SUBSCRIPTION` | `EuiccConnector` leaves `UnavailableState` |
| `EuiccUiDispatcher: Could not resolve activity` | |
| `FATAL EXCEPTION ... com.google.android.euicc`, `getUiccSlotsInfo ... READ_PRIVILEGED_PHONE_STATE` | |
| `Log.wtf` `does not declare WRITE_EMBEDDED_SUBSCRIPTIONS` | |

Further checks:
- **Setup Wizard loop:** factory-reset test or the SUW eSIM step. `carrier.QuickSetupEsimSetupWrapper` must stay in front instead of
  returning to `AccountSetupWrapper` 22 ms later (the 10-18 log at 21:04:59).
- **APN source (section 4):** `adb shell content query --uri content://telephony/carriers/preferapn`.
  Grep the log for `TelephonyProvider` (`dbh.onCreate: Skipping apply APNs from xml`, `restoreApnsWithService: restored`)
  and `CarrierSettings`/`ApnUpdater` (`applyApns: %d in settings, %d applied`). On an SFR SIM the default should be `sl2sfr` (SFR webphone).
- **Fi:** install or open Fi, run activation, and capture `adb logcat -d -b all` plus `dumpsys package com.google.android.apps.tycho | grep -E "granted|enabled"`.
  Record any `T###` code with the log.
- **CarrierSetup after Diff A:** `dumpsys package com.google.android.carriersetup | grep MANAGE_NETWORK_POLICY` → `granted=true`.
- **WfcActivation after Diff B** (AT&T/Rogers/Telus SIM): Settings > Wi-Fi calling > emergency address opens `WfcActivationActivity`.

## 8. Not covered / open

- Runtime behaviour of all of the above: no phone was attached.
- Whether CarrierSettings' `ApnUpdater` deletes rows it didn't write on existing installs (section 4, risk 1).
- The MEP mode the modem reports (1.5).
- The `com.google.pixel.euicc.update` vendor APEX: it's in stock vendor (`vendor/apex/com.google.pixel.euicc.update.apex`), so we ship it.
  The 10-18 log has Finsky failing to stat it (`NameNotFoundException`, line 9370). Whether it activates and whether EuiccSupportPixel's
  `EUICC_UPDATE_APEX` flow works is Unknown. Check `adb shell pm list packages --apex-only | grep euicc`.
