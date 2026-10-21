# kodiak audit: Wi-Fi, eSIM/SIM and stock parity (2026-10-19)

Audit of the tree the 2026-10-18 release was built from, against the stock
CD1A.261005.003 firmware of the same phone and the LineageOS Pixel 10 trees.
Nothing has been changed yet; the remediation plan at the end waits for approval.

Labels follow GEMINI.md: **Evidence** (read from a file, build output, source or log),
**Inference** (deduced from evidence), **Unknown** (needs a phone or a user log).

## 0. Scope and corrections to the brief

- **kodiak is the Pixel 11 Pro XL** (Tensor G6 `malibu`, MediaTek T900 modem, Android 17 `cnb`).
  It is newer than the Pixel 9 (`zumapro`) and Pixel 10 (`muzel`/`laguna`) trees, so the exact
  parity target is **stock kodiak CD1A.261005.003** (`~/android-dt/dumps/kodiak`). The Pixel 10
  LineageOS trees (`~/android-dt/ref/{laguna,muzel}`) were used for structural patterns.
- **There is no Shannon modem, `sitril`, ShannonIms/ShannonRcs, or `gs-common` here.** The RIL is
  MediaTek (`vendor.ril-daemon-mtk`, GRIL, `ril-extension`). The tree inherits AOSP
  `generic_system`/`handheld_system_ext`/`telephony_system_ext`/`aosp_product` plus
  `vendor/lineage/config/common_full_phone.mk`; no SoC common tree exists.
- **Vendor-side items in the brief are stock and untouched:** vendor, vendor_dlkm, system_dlkm,
  boot (Espada or stock GKI) and dtbo are prebuilt stock images (`BoardConfig.mk:147-159`). That
  covers the WLAN driver (`bcmdhd4390.ko`, `cfg80211.ko`, `mac80211.ko` in vendor_dlkm
  `modules.load:119-122`), firmware/NVRAM/CLM (`/vendor/firmware/fw_bcmdhd.bin_4390_b1`,
  `bcmdhd.cal_4390_b1`, `fw_bcmdhd.map_4390_b1`), the Wi-Fi HAL, vendor `wpa_supplicant`/`hostapd`
  init scripts, the vendor VINTF manifest and the RIL daemon. None of them can differ from stock.
  What we build is **system, system_ext and product**, so that is where every finding below lives.
- **Audited state:** server build clone `~/evolution/device/google/kodiak` (`0f60690`; differs from
  the 10-18 build only by the Now Playing `vendor_gms` patch), `vendor/google/kodiak` `828b388`,
  and the 10-18 build output `out/target/product/kodiak` (images 2026-10-18 22:14).
- **User log used:** `~/Downloads/logcat.txt`, a full-boot kodiak logcat on the 10-18 build (the
  Now Playing reporter's). Its main buffer starts at 21:06:14, after Wi-Fi had started.

## 1. Findings

### Highest user impact: apps with no network until access is turned on by hand

Reported by many users and seen by Daryl. **Cause is likely but not proven on our builds.**

- Evidence, code: LineageOS's `NetworkPolicyManagerService` (in our `frameworks/base`, receiver
  at `services/core/java/com/android/server/net/NetworkPolicyManagerService.java:1528-1539`) gives
  `POLICY_REJECT_ALL` to any non-system app that doesn't hold `INTERNET` when `ACTION_PACKAGE_ADDED`
  arrives. Nothing removes that policy when the app later holds `INTERNET`. The user then has to
  turn the app's network access back on in App info.
- Evidence, upstream: [LineageOS/issues#746](https://github.com/LineageOS/issues/issues/746)
  (lineage-23.2) reports the same symptom; toggling network access off and on fixes it. A LineageOS
  maintainer's unmerged change, [Gerrit 505011](https://review.lineageos.org/c/LineageOS/android_frameworks_base/+/505011),
  blames an install/update race. **Corrected after the deep pass (`DEEP_NETWORK_ACCESS.md` §3):**
  our PackageManager grants permissions during commit, before the broadcast, so that race isn't
  shown by our source.
- Evidence, code: an **archived install** (`EXTRA_ARCHIVAL`, `pm/BroadcastHelper.java:614-617`)
  hits the rule every time: `markPackageAsArchivedIfNeeded` (`PackageManagerService.java:1566-1590`)
  sets the package to null and not installed, so `INTERNET` reads as denied. Evidence, log: Play on
  our 10-18 build runs with `ENABLE_PRE_ARCHIVING_FOR_RESTORES is true`, i.e. restored apps arrive as
  archived placeholders first. Inference: the uid and its block outlive the real APK. This fits
  "most apps" after a clean flash with restore, and Reset app preferences fixing it (it deletes every
  uid policy). **Most likely trigger; not observed on a phone yet.**
- Ruled out: the policy-file migration `migrateToPolicyRejectAll` (`:2876-2924`) runs only when an
  Android 12+ policy file has no Lineage version, i.e. a dirty flash over stock. Backup restore is
  keyed by package name (`readUidAttribute`, `:7325`), so it can't move blocks onto other apps.
  Settings' `DynamicDenylistManager` has no caller in our source.
- Not in the device tree: this is ROM framework code, so it affects every device built from it.
- Unknown: no log we hold shows it. The 10-18 user logcat starts before any install or restore.
  Confirm on an affected phone:
  `adb logcat -b system -d | grep "ACTION_PACKAGE_ADDED for uid"` and
  `adb shell dumpsys netpolicy | grep -A40 "UID policy"` (look for `REJECT_ALL` on the app's uid,
  from `adb shell cmd package list packages -U <pkg>`).
- Fix carried as `patches/frameworks_base/0007` (section 4). Apps blocked before it stay blocked
  until the user re-enables their network access; the patch can't tell those from a user's choice.

### Blocker

**B1. No eSIM LPA: `EuiccGoogle` (`com.google.android.euicc`) has never shipped.** All four Pixel 11 trees.

- Evidence, build: no `com.google.android.euicc` APK anywhere in system, system_ext or product of the
  10-18 output. `git log -S"EuiccGoogle/EuiccGoogle"` on `proprietary-files.txt` is empty in both the
  build clone and `~/android-dt/trees/device_google_kodiak`: it was never listed.
- Evidence, what we do ship around it (`proprietary-files.txt:10-18, 185-186`):
  `EuiccGoogleOverlay` (an RRO whose target is `com.google.android.euicc`), `EuiccSupportPixel-P23`,
  `EuiccSupportPixelPermissions`, and `android.hardware.telephony.euicc.xml` +
  `android.hardware.telephony.euicc.mep.xml`. The framework therefore advertises eSIM and MEP, with
  nothing to serve them.
- Evidence, stock: `product/priv-app/EuiccGoogle/EuiccGoogle.apk` (D.2.1.948592891-google) is the only
  component declaring `android.service.euicc.EuiccService` and the `android.service.euicc.action.*`
  UI activities (provision, manage, transfer, convert, toggle).
- Evidence, references: Evolution's own husky, shiba, cheetah and panther trees and LineageOS muzel
  (mustang, blazer, frankel) list `product/priv-app/EuiccGoogle/EuiccGoogle.apk;PRESIGNED`.
  grizzly, cubs and yogi stock dumps all contain it; none of our four trees lists it.
- Evidence, user log on the 10-18 build:
  - 21:04:59 and 21:05:05: Setup Wizard (`com.android.wizard`) opens
    `com.android.phone/.euicc.EuiccUiDispatcherActivity` (eSIM step in setup). The 21:04:59
    sequence is the **Next/Skip loop after sign-in**: `AccountExistsActivity` closes,
    `carrier.QuickSetupEsimSetupWrapper` opens and launches the dispatcher, then 22 ms later the
    wrapper closes and `account.AccountSetupWrapper` comes back to the front. It repeats at 21:05:05.
  - 21:05:51.970: Play Store installs `com.google.android.euicc` into `/data/app` (not privileged).
  - 21:05:52.154: `FATAL EXCEPTION ... Process: com.google.android.euicc` →
    `SecurityException: getUiccSlotsInfo: Neither user 10476 nor current process has
    android.permission.READ_PRIVILEGED_PHONE_STATE` in `RestoreUiccSlotSettingsOnBootReceiver`.
  - 21:06:15-17: `EuiccConnector: No valid EuiccService implementation found` (×4).
  - 21:06:43 (×3): `EuiccUiDispatcher: Could not resolve activity for intent ...
    PROVISION_EMBEDDED_SUBSCRIPTION`: the user tapped "Add SIM" three times and nothing opened.
- Mechanism: Settings' "Add SIM" (`packages/apps/Settings/.../spa/network/SimsSection.kt:177`) sends
  `ACTION_PROVISION_EMBEDDED_SUBSCRIPTION` to the phone process, which forwards it to the LPA's
  activity. With no privileged LPA there is nothing to forward to. Downloading, switching, converting
  and deleting eSIM profiles all fail, and a Play-installed copy crashes on its boot receiver because
  it can't hold privileged permissions.
- This matches the reported "SIM Manager crashes" and "eSIM provisioning failures" exactly.

### High

**H1. Wi-Fi STA and Wi-Fi Direct run on the mainline supplicant without the device's supplicant configs.** All four trees.

- Evidence, the chain that selects the supplicant:
  1. `rro_overlays/PixelWifiOverlay2026Kodiak/res/values/config.xml:38` sets
     `config_wifiMainlineSupplicantEnabled=true` (copied from stock).
  2. `build/release/aconfig/cp2a/com.android.wifi.flags/mainline_supplicant_flag_values.textproto`:
     `ENABLED`, `READ_ONLY`.
  3. Our `com.android.wifi` APEX contains `bin/wpa_supplicant_mainline` (prebuilt
     `version_202605-0`), `etc/wpa_supplicant_mainline.conf` and `etc/mainline_supplicant.rc`.
  4. `packages/modules/Wifi/.../SupplicantStaIfaceHal.java:924` and
     `.../p2p/SupplicantP2pIfaceHal.java:130` then pick the **mainline** implementation over the
     vendor `android.hardware.wifi.supplicant` HAL, for both STA and P2P.
- Evidence, the missing files: `external/wpa_supplicant_8/wpa_supplicant/aidl/supplicant.cpp:34-37`
  reads `/system_ext/etc/wifi/wpa_supplicant_mainline_overlay.conf` and
  `p2p_supplicant_mainline_overlay.conf`, and only if present (`:528-530`, `access()` then
  `confanother`). Stock ships both; we ship neither. So our STA and P2P run on the generic APEX
  template alone. The vendor's own `/vendor/etc/wifi/*_overlay.conf` only reach the vendor
  supplicant, which this path no longer uses.
- What stock adds that we lose (stock overlay vs our APEX template):

  | Setting | Stock (system_ext overlay) | Ours (APEX template) |
  |---|---|---|
  | `driver_param` | `use_p2p_group_interface=1p2p_device=1` | none |
  | `interworking` / `hs20` | `1` / `1` (Passpoint) | unset (off) |
  | `bss_max_count` | `512` | default (200) |
  | `wowlan_triggers` | `any` | `magic_pkt` |
  | `rsn_overriding` | `2` | `1` |
  | `btm_offload`, `bss_no_flush_when_down`, `disable_scan_offload`, `use_priv_cmd_mbo_cell_status` | `1` | unset |
  | P2P: `p2p_pref_chan`, `p2p_dfs_chan_enable`, `p2p_6ghz_disable`, `p2p_go_vht`, `disable_scan_offload` | set | unset |

- Inference: Passpoint/Hotspot 2.0 networks can't be used (we ship `CarrierWifi`, which depends on
  them). Wi-Fi Direct lacks the dedicated P2P-device driver params that `p2p-dev-wlan0` relies on
  (Quick Share, casting). Suspend wake behaviour, BSS-table size and roaming offload differ from what
  Google tuned for the BCM4390. This is the most concrete system-side lead for "Wi-Fi instability".
- Unknown: not confirmed on a phone. The user log starts after Wi-Fi init. To confirm, check a boot
  logcat for `Initializing SupplicantStaIfaceHal using AIDL Mainline implementation`.
- SELinux: no new policy needed. `wifi_mainline_supplicant` is a coredomain, and
  `system/sepolicy/private/domain.te:164` lets coredomains read `system_file`.
  `check-sepolicy.sh` should still be run.

**H2. USB tethering asks for RNDIS, which neither kernel provides.** All four trees.

- Evidence: we build AOSP `com.android.tethering`, whose defaults are `config_tether_usb_functions=0`
  (RNDIS) and an empty NCM regex. The stock fix is `PixelTetheringOverlay2021` (`usb_functions=1`
  NCM, `ncm\d`, `p2p-wlan\d-.*`), but it targets Google's `com.google.android.networkstack.tethering`,
  so it isn't shipped and wouldn't apply. No overlay of ours targets tethering at all.
- Evidence: the stock GKI kernel has `ncm_bind` and no RNDIS strings. Espada v3.5 only carries the
  `android_vh_is_rndis_enabled` hook, with no RNDIS gadget function.
- Evidence, reference: LineageOS laguna builds `PixelTetheringOverlay2021` from source
  (`laguna/common.mk:361`, `usb_functions=1`).
- Inference: USB tethering fails to bring up its gadget function. Wi-Fi Direct group interfaces
  named `p2p-wlan0-*` aren't recognised as tetherable P2P. Unknown: not tested on a phone.

### Medium

**M1. `EuiccSupportPixelOverlay` missing.** Stock sets the secure-element busy/ready/request intent
lists (GMS digital car key + Qorvo UWB) so `com.google.euiccpixel` coordinates eUICC firmware updates
with other SE users. LineageOS laguna builds it from source (`common.mk:345`). Without it,
EuiccSupportPixel has no SE coordination (inference: eUICC OS updates such as
`DKA_0303_03x_25.up` can collide with Wallet/digital key).

**M2. APNs don't come from CarrierSettings.** Stock's TelephonyProvider RRO and LineageOS laguna
(`TelephonyProviderOverlayProductLaguna`) set `apn_source_service =
com.google.android.carrier/.ApnSourceService`. We set nothing, so TelephonyProvider uses Lineage's
`/product/etc/apns-conf.xml` while carrier config comes from CarrierSettings (`HANDOFF 2b`): two
different carrier databases. No report ties a failure to this yet.

**M3. The public repos can't reproduce the release.** `denson9874/vendor_google_kodiak` `cnb` has 2
commits (2026-10-12). The build used `828b388`, 4 commits later: the AICore, PixelAI/Sense, Now
Playing, Hotword, CarrierWifi, eSIM/MEP and feature-overlay blobs are absent from GitHub.
`denson9874/device_google_kodiak` `cnb` (`a9659d3`) differs from the build in `extract-images.sh`,
the missing `patches/vendor_gms/0002`, and a stale `nowplaying_app_26q1.xml` line.

**M4. Three diverged copies of the device tree.** `~/android-dt/trees/device_google_kodiak` (the
documented source of truth, HANDOFF §4) is at `6e108f1`. The build clone has 4 more commits
(`8ea61d5`, `a2220d5`, `e858083`, `0f60690`) made directly in the clone, which HANDOFF §4 forbids.
GitHub has a rewritten history. A `git pull` in the build clone is currently safe (fast-forward
only), but the next edit made in the trees repo would conflict.

**M5. `ConnectivityThermalPowerManagerNextgen` not shipped.** Stock runs it as
`connectivity_thermal_power_manager` (platform-signed, MediaTek MIPC: `libMIPC-native.so`,
`libmipc.so`). It is the modem/connectivity thermal power manager. Impact unknown; porting needs a
re-signed APK, its libraries, an seapp domain and policy. Investigate before adding.

**M6. Setup Wizard Wi-Fi (`ISS-20261017-03`): no root cause offline.** Ruled out: the Wi-Fi overlay
(it differs from stock only by `config_wifiDisableFirmwareRoamingInIdleMode` and
`config_wifiUpdateCountryCodeFromScanResultSetupWizard`; the latter is Google-only and doesn't exist
in AOSP Wi-Fi), the four missing Setup Wizard RROs (illustrations and Pearl/Spoon actions only), and
Wi-Fi props. Open leads: H1, and Lineage's global `ro.boot.wificountrycode?=00`
(`vendor/lineage/config/common.mk:310`; AOSP still updates the country code from scan results in
setup). Needs a logcat taken inside Setup Wizard while it fails, plus
`adb shell dumpsys wifi | grep -iE "country|SupplicantStaIfaceHal"`.

### Low

- **L1.** `lineage_kodiak.mk:61` `TARGET_DISABLE_EPPE := true` ("bring-up only"). It currently hides
  nothing (every requested module is installed, checked against `module-info.json`), but it would
  silently drop a mistyped package. Remove it.
- **L2.** `core_64_bit_only.mk` is inherited twice (`lineage_kodiak.mk:7`, `device.mk:10`). Harmless.
- **L3.** NetworkStack `config_force_enable_apfv6_nd_offload=true` (stock) is missing: APFv6
  neighbour-discovery offload, a power cost only.
- **L4.** TeleService `vvm3_enabled=true` (Verizon VVM3) is missing.
- **L5.** `TelephonyGoogle` (`com.google.android.telephony`, `android.uid.phone`, provides
  `RESTART_TELEPHONY_PROCESS`) isn't shipped. It would need re-signing with our platform key; low value.
- **L6.** The `SimAppDialog` product RRO is missing. It only carries an illustration, so it isn't
  the "SIM Manager" crash.

### Checked and fine

- Wi-Fi resources overlay: 57 of stock's 59 keys identical, and the right target
  (`com.android.wifi.resources`, because we build AOSP `com.android.wifi`).
- Stock vendor RROs still apply. Our product overlays override them only for `theming_defaults`,
  `config_battery_percentage_setting_available` and the TeleService IMS packages; the last is
  intended, since the vendor RRO still names `com.shannon.*`.
- `proprietary-files*.txt` ↔ `vendor/google/kodiak` correspond 1:1: no missing or orphan blobs.
- SELinux mapping for `euiccpixel_app`, `grilservice_app`, `rilextensionservice_app`,
  `pixel_modem_app`, `imsstack_app` (`seapp_contexts:8-14`, `mac_permissions.xml`). Stock gives
  EuiccGoogle no special domain (plain `priv_app`).
- Adding EuiccGoogle can't bootloop: `ro.control_privapp_permissions=log`, and `vendor/gms` already
  ships its allowlist (`privapp-permissions-google-p.xml:394`) and default permissions.
- Telephony props: vendor props are stock. Product props match stock (`persist.radio.multisim.config=dsds`,
  `ro.setupwizard.esim_cid_ignore`, `masterclear.allow_retain_esim_profiles_after_fdr`).
- `ISS-20261017-01` ("some apps can't access mobile/Wi-Fi data"): nothing in the tree explains it.
  Needs `adb shell dumpsys netpolicy` and the app's network-access toggles in App info.

## 2. Comparison matrix

| Subsystem | kodiak now | Stock kodiak (CD1A) | LineageOS Pixel 10 (laguna/muzel) |
|---|---|---|---|
| eSIM LPA | **absent** | `EuiccGoogle` priv-app (product) | muzel: `EuiccGoogle;PRESIGNED` |
| eSIM SE coordination | absent | `EuiccSupportPixelOverlay` | laguna: built from source |
| Supplicant (STA/P2P) | mainline, **no overlay confs** | mainline + `system_ext/etc/wifi/*_mainline_overlay.conf` | A16: vendor supplicant + `vendor/etc/wifi/*_overlay.conf` |
| Wi-Fi resources RRO | `PixelWifiOverlay2026Kodiak` (AOSP target) | `PixelWifiOverlay2026` (Google target) | `PixelWifiOverlay2025Laguna` |
| Tethering RRO | **none** (RNDIS default) | `PixelTetheringOverlay2021` (NCM) | `PixelTetheringOverlay2021` from source |
| APN source | Lineage `apns-conf.xml` | CarrierSettings `ApnSourceService` | CarrierSettings `ApnSourceService` |
| WLAN kmod/firmware | stock vendor_dlkm/vendor | same | same pattern (stock) |
| RIL / radio VINTF | stock vendor + GRIL/ril-extension re-signed | same apps, Google-signed | Shannon (different modem) |
| Kernel | Espada v3.5 (kodiak/grizzly/cubs), stock GKI (yogi) | stock GKI 6.12 | stock |

## 3. Remediation plan (not applied; waiting for approval)

Work happens in `~/android-dt/trees/device_google_kodiak`, then `git pull` in the build clone (HANDOFF §4).

0. **Reconcile the trees (M4).** Fast-forward `~/android-dt/trees/device_google_kodiak` to the build
   clone's `0f60690` (`git push origin master` from the build clone, a fast-forward only).
1. **eSIM LPA (B1).** `proprietary-files.txt`, eSIM section: add
   `product/priv-app/EuiccGoogle/EuiccGoogle.apk;PRESIGNED`. Run `./extract-files.py
   ~/android-dt/dumps/kodiak`. No sepolicy change. Users who installed EuiccGoogle from Play keep it
   as an update of the system app (same Google signature).
2. **Supplicant configs (H1).** `proprietary-files.txt`, new Wi-Fi section:
   `system_ext/etc/wifi/wpa_supplicant_mainline_overlay.conf` and
   `system_ext/etc/wifi/p2p_supplicant_mainline_overlay.conf`. Re-extract.
3. **Tethering (H2).** New `rro_overlays/TetheringOverlayKodiak` (target
   `com.android.networkstack.tethering`, static, product) with stock's `config_tether_usb_functions=1`,
   `config_tether_usb_regexs`, `config_tether_ncm_regexs`, `config_tether_wifi_p2p_regexs`. Leave
   out stock's `config_mobile_hotspot_provision_app*` keys: they name `TetheringEntitlement`, which we
   don't ship, and pointing at a missing app would block hotspot on those carriers. Add to
   `device.mk` `PRODUCT_PACKAGES`.
4. **eUICC SE coordination (M1).** New `rro_overlays/EuiccSupportPixelOverlayKodiak` (target
   `com.google.euiccpixel`) with stock's four intent/permission arrays.
5. **APN source (M2).** New `rro_overlays/TelephonyProviderOverlayKodiak` with
   `apn_source_service=com.google.android.carrier/.ApnSourceService`, as stock and laguna do.
   This changes where APNs come from, so it's a separate commit that can be reverted alone.
6. **Low items.** Remove `TARGET_DISABLE_EPPE`, add `vvm3_enabled` to `TeleServiceOverlayKodiak`.
7. **Verify on the server.** `~/kodiak-images.sh` to `BUILD_EXIT=0`; `check-sepolicy.sh`; confirm the
   APK, both confs and the three overlays in `out/target/product/kodiak`; `aapt2 dump` each overlay.
8. **Verify on a phone** (not possible from here; none attached):
   - boot logcat shows the Mainline supplicant path and no `EuiccConnector: No valid EuiccService`
   - Settings > SIMs > Add eSIM opens Google's flow
   - USB tethering, Wi-Fi Direct/Quick Share, and a Passpoint network
9. **Family.** Repeat 1-6 for grizzly, cubs and yogi, each extracted from its own dump (per-device
   signing keys, `P11_FAMILY_DIFF.md`). cubs' supplicant confs are byte-identical to kodiak's.
10. **Publish (M3).** Push device and vendor trees to GitHub `cnb`. Outward-facing, so a separate go-ahead.

## 4. Second brief: status per item (2026-10-19)

Items from the second brief, checked against stock CD1A.261005.003, our build and the user log.
`[PASS]` means our build matches stock or the claim doesn't apply.

| Item | Status | Evidence |
|---|---|---|
| 1.1 SIMs / "Add SIM" no-op, Fi `T120` | **[FAIL - MISSING]** → fixed in tree | EuiccGoogle never shipped (B1); user log `EuiccUiDispatcher: Could not resolve activity`. `T120` itself not seen in a log; an absent LPA is enough to explain it |
| 1.1 `com.google.android.euicc.xml`, `esim.enable_esim_system_ui_by_default`, `ro.telephony.sim_slots.count` | [PASS] | Stock ships none of them (searched every partition) |
| 1.1 `euicc_app`/`grilservice_app` SELinux | [PASS] | Stock has no `euicc_app` domain; EuiccGoogle runs as `priv_app`. `grilservice_app` is mapped (`seapp_contexts:8`) |
| 1.1 wrong default APN (SFR eSIM) | **[FAIL - MISCONFIGURED]** → fixed in tree | `apn_source_service` unset (M2); stock and laguna point it at CarrierSettings |
| 1.2 Setup Wizard Next/Skip loop | **[FAIL]**, cause B1 → fixed in tree | User log 21:04:59: eSIM step → dispatcher → back to `AccountSetupWrapper` |
| 1.3 Wi-Fi in Setup Wizard | Unknown | No log of it; leads: H1, Lineage `ro.boot.wificountrycode?=00` |
| 1.3 MAC filtering | [PASS] | `config_wifi_connected_mac_randomization_supported=true` (`PixelWifiOverlay2026Kodiak` config.xml:54, since 10-16) |
| 1.3 APF / idle drain | [PASS] for the brief's key; L3 open | `config_wifi_apf_enable` doesn't exist in AOSP. Stock's extra NetworkStack key `config_force_enable_apfv6_nd_offload` doesn't exist in AOSP NetworkStack either |
| 1.3 Wi-Fi supplicant settings | **[FAIL - MISSING]** → fixed in tree | H1 |
| 1.3 WLAN firmware in ramdisk | [PASS] | `bcmdhd4390.ko` loads from vendor_dlkm (second stage); firmware is in stock `/vendor/firmware` |
| 1.4 apps with no network until enabled | **[FAIL]** (likely) → patch 0007 | Section 1, first finding |
| 1.5 Now Playing | [FAIL] → fixed in tree on 10-19 (`0f60690`, `vendor/gms` `1d69071`), not built | Cause was `vendor/gms` `nowplaying.xml` (log: `association not allowed`), not SELinux: stock has no seapp entry for ASI/PCS, and `config_defaultMusicRecognitionService` matches stock |
| 2.1 source HALs duplicating prebuilt vendor | [PASS] | No `gs-common`; the only HAL packages are recovery/fastbootd and HIDL service manager pieces stock system also ships |
| 2.2 factory-generated overlays/sepolicy | [FAIL - partial] | Our product RROs are hand-written subsets; tethering, eUICC SE and APN overlays now added. A full generated-overlay import is a larger follow-up. `default_volume_tables.xml` is vendor, so already per device |
| 2.3 16K developer option | [PASS] | No `PRODUCT_16K_DEVELOPER_OPTION`, no `ro.product.build.16k_page.enabled`, no boot OTAs |
| 2.3 ZRAM / lmkd | [PASS] | Stock `mmd.zram.*` props in `product.prop`; lmkd patch for in-kernel LMK carried |
| 2.4 Thread network APEX | [PASS] (n/a) | Stock kodiak has no Thread APEX and no Thread HAL in vendor |
| 2.4 dEQP levels | [PASS] | `android.software.{opengles,vulkan}.deqp.level.xml` are stock vendor files |
| 2.4 recovery USB PHY firmware | [PASS] | `usb_phy_fw*.bin` in our vendor_ramdisk and first_stage_ramdisk |
| 2.4 USB tethering | **[FAIL - MISSING]** → fixed in tree | H2 |
| 4 family isolation | [PASS] by design | Each phone ships its own stock vendor (UWB, lights, FPS, display, devicestate). Corrections: cubs ships Espada like kodiak and grizzly (only yogi is stock GKI), and the staged Espada is v3.5 (6.12.96) |

### Commits (local on the build server, nothing pushed)

`~/android-dt/trees/device_google_kodiak` (fast-forwarded to `0f60690` first), pulled into the build clone:

| Commit | Change |
|---|---|
| `485219f` | ship EuiccGoogle (B1, 1.1, 1.2) |
| `92c4a83` | ship the mainline supplicant config overlays (H1) |
| `720c3bd` | `TetheringOverlayKodiak`: USB tethering over NCM (H2) |
| `6b1c505` | `EuiccSupportPixelOverlayKodiak` (M1) |
| `f9e97eb` | `TelephonyProviderOverlayKodiak`: APNs from CarrierSettings (M2, 1.1 APN) |
| `7b48f13` | drop `TARGET_DISABLE_EPPE` (L1) |
| `3caa75a` | carry `patches/frameworks_base/0007` (1.4); applied in `~/evolution/frameworks/base` as `de0bb43ace` |

`~/evolution/vendor/google/kodiak` `94848e8`: EuiccGoogle and the two supplicant configs, regenerated
by `extract-files.py` and byte-identical to stock.

### Build verification (2026-10-19)

`~/kodiak-images.sh` (user, `KODIAK_PERSONAL=true`): `BUILD_EXIT=0` in 42:35. `check-sepolicy.sh` against the stock
vendor: `OK: split policy compiles against vendor 202604`, same mapped domains as before. In the images: EuiccGoogle
(byte-identical to stock, Google V3 signer `7e26b6d5…`), both mainline supplicant configs, and the three new
overlays with their intended targets and values; patch 0007's log string is in `services.jar`.
Test package: `~/releases/kodiak/check/kodiak-evox-img-audit-20261019.zip` (sha256 `16c82fda…`). It's a personal
test build with Magisk in init_boot, not for release. **Nothing has been booted or tested on a phone.**

## 5. Deep passes and round 2 (2026-10-19)

Four read-only sessions went deeper: `DEEP_NETWORK_ACCESS.md`, `DEEP_WIFI.md`, `DEEP_TELEPHONY.md`,
`DEEP_OVERLAY_PARITY.md`. Their key claims were spot-checked against source and the stock dump before
anything was applied.

### Corrections to this report

- **Network access:** the trigger is most likely archived restore installs, not an install/update race
  (section 1, first finding, now corrected).
- **M6 / Wi-Fi:** `config_wifiUpdateCountryCodeFromScanResultSetupWizard` and
  `config_wifiDisableFirmwareRoamingInIdleMode` aren't Google-only: Google's own Wi-Fi module doesn't define
  them either, so stock's overlay entries are no-ops. Same for L3's
  `config_force_enable_apfv6_nd_offload` (not in Google's NetworkStack). Our Wi-Fi module, its resources,
  flags, supplicant binary, template and SELinux are identical to stock; only the two overlay confs differed.
- **H1:** this supplicant parses only `use_p2p_group_interface=1` from the `driver_param` string;
  `p2p_device=1` does nothing (`driver_nl80211.c:10733`).
- **SetupWizard Wi-Fi:** the report reads as networks aging out of the list (scans stop), not as failed
  connections. Leading hypothesis: the mainline supplicant without its overlays (fixed in round 1). Not proven.

### Round 2 commits (local on the build server, nothing pushed)

| Commit | Change | Source |
|---|---|---|
| `303704f` | patch 0007 refreshed: don't restrict an unresolved package; message states the evidence-based cause (`frameworks/base` `0a5cad9fe1`) | DEEP_NETWORK_ACCESS §6 |
| `d3cda50` | re-sign CarrierSetup (needs signature-only `MANAGE_NETWORK_POLICY`) | DEEP_TELEPHONY S2 |
| `8e4212b` | ship WfcActivation (Wi-Fi calling e911 app named by 48 carrier configs) | DEEP_TELEPHONY S4 |
| `7eba785` | ship stock `product/etc/libnfc-nci.conf` (listen tech A+B+F, AID routing) | DEEP_OVERLAY_PARITY N1 |
| `18e1c47` | `SystemUIOverlayKodiak`: temperature and USB port overheat warnings | D1 |
| `76f6e6e` | stock PixelDisplayService RRO (display compensation tables) | P1 |
| `4ebb87c` | `MediaProviderOverlayKodiak`: Google Photos in the photo picker | M1 |
| `318ef3f` | Night Light curve, Play Protect event consumer | F2, F5 |
| `8f416ee` | CarrierWifi default permissions, face feature XML (Evolution leaves it to Pixel device trees) | C1, B1 |

Vendor tree `1a196d0`.

### Waiting for Daryl's decision (not applied)

1. **Heal apps already blocked** (`DEEP_NETWORK_ACCESS` §7): one-time migration clearing automatic
   `REJECT_ALL` from apps that hold `INTERNET` and were installed by restore, vs. telling users to switch
   "Allow network access" on per app. Needs one phone's `dumpsys package` to confirm the install reason.
2. **WifiTrackerLib `240b2b5`** (ROM-wide downstream change): saves WPA2/WPA3 and OWE transition networks
   as WPA3/OWE-only, unlike AOSP and stock. Possible cause of "won't connect" on some routers; no report
   ties a failure to it yet (`DEEP_WIFI` §5, §7.4).
3. **NFC off after a clean flash** (Lineage `NfcOverlay` `enable_nfc_default=false`; stock is on).
4. **Display:** `config_evenDimmerEnabled` (stock on; changes Extra dim) and
   `config_refreshRateSynchronizationEnabled`. Held for a phone test, given the AOD brightness history.
5. **TetheringEntitlement** (turns on carrier hotspot checks, stock parity) and FeliCa/PixelNfc for
   Japanese SKUs: hold until a report.
6. **Community replies:** `COMMUNITY_REPLIES_20261017.md` and `COMMUNITY_REPLIES_20261019.md:120` promise
   an overlay fix for app network access; the fix is a framework patch. The Telegram answer that blocking
   new apps is a battery-saving feature isn't backed by source.

### Open, not yet traced

- Both `SystemUI.apk` and `SystemUIGoogle.apk` install as `com.android.systemui` (Evolution upstream).
- Fi `T120` meaning (no log); MEP mode the T900 reports; CCC digital-key UWB time sync; DMService/OMA-DM.

## 6. Round 3 and the family port (Daryl: "go forward with all the fixes")

### kodiak round 3 (`~/android-dt/trees/device_google_kodiak`, local, nothing pushed)

| Commit | Change |
|---|---|
| `a2efd94` | patch 0008 (`frameworks/base` `39884f34c1`): once (Lineage policy version 3), clear the automatic `REJECT_ALL` from apps installed by device restore or setup that request and hold `INTERNET`; log every app left blocked with its install reason |
| `59b59f9` | `FrameworkResOverlayKodiak` priority 2. **Found while checking overlay order:** Evolution's priority-1 framework overlay was replacing our `config_serviceStateLocationAllowedPackages`, so ImsStack never got the cell location |
| `4db2b58` | even dimmer, refresh-rate sync, UDFPS without swipe gestures, 4 fingerprint templates (stock) |
| `e016d25` | `NfcOverlayKodiak`: NFC on after a clean flash (Lineage default is off), Verizon URL dialog |
| `9376ed9` | FeliCa configs and PixelNfc (Japanese SKUs) |
| `0bf2a70` | SystemUI: Pixel screenshot editors, Quick Share copy, icon haptic |
| `113f16c` | `TerminalOverlayKodiak`: gfxstream for the Linux terminal |

Vendor `e4da7e8`. Round 2 build verified first: `check-sepolicy` OK, all files present, CarrierSetup signed with our
platform key `2d5efc1e…`, `libnfc-nci.conf` = stock.

**Not applied, with reasons:**
- WifiTrackerLib `240b2b5`: Evolution X committed it upstream to fix mixed WPA2/WPA3 routers rejecting association
  ("invalid PMKID"). Reverting would re-break those for every device built from the tree, with no report against it.
- TetheringEntitlement: it adds carrier hotspot entitlement checks; it fixes nothing.
- Healing is limited to restore/setup installs because Android preserves an install reason across an update only
  for users who already had the package installed (`InstallPackageHelper.java:2834-2872`), so an unarchive may
  replace "restore". Clearing every block would also undo users' deliberate blocks. The heal logs show testers' install
  reasons, which decide whether it should reach further.

### grizzly, cubs, yogi (`~/evolution/device/google/<dev>`, local, nothing pushed)

Every change above, in 8 commits per phone (eSIM, Wi-Fi, telephony, tethering, NFC, display/UI, NetworkPolicy
patches 0007/0008, EPPE), with each phone's own stock values. The script refused to copy an overlay whose stock
values differ from kodiak's; none did. yogi keeps its side-sensor fingerprint gestures and gets the SystemUI keys
merged into `SystemUIOverlayYogi`. Vendor trees, extracted from each phone's own dump: grizzly `fe24389`,
cubs `3b4f95b`, yogi `ec7c251`.

| Phone | Device tree commits |
|---|---|
| grizzly | `79eac3f` … `edba05e` |
| cubs | `74a1c13` … `d102a18` |
| yogi | `9986ec6` … `6c7c70f` |

**Pack scripts:** `grizzly-pack.sh`, `cubs-pack.sh` and `yogi-pack.sh` required CarrierSetup to carry the phone's
stock platform key. They now check EuiccGoogleOverlay for that, and CarrierSetup for our platform key (server
copies backed up as `*.bak-20261019-audit`; repo copies in `evolution-kodiak/tools/` updated to match).

Test builds and the tester checklist: `AUDIT_TEST_PLAN_20261019.md`.

### Test builds (2026-10-19/20)

`~/audit-test-chain.sh` built all four non-personal images in sequence (kodiak 15 min, grizzly 16, cubs 20, yogi
20) and packed each with its release pack script, without `--upload`. All checks passed. Zips, checksums and kernels
are listed in `AUDIT_TEST_PLAN_20261019.md`. Nothing has been booted or tested on a phone, uploaded, or pushed.
