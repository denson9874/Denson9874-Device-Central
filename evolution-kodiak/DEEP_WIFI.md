# Deep Wi-Fi pass: kodiak (Pixel 11 Pro XL) vs stock CD1A.261005.003 (2026-10-19)

Labels follow GEMINI.md: **Evidence** (read from a file, binary, build output or log), **Inference** (deduced
from evidence), **Unknown** (needs a phone or a user log). **Nothing here has been tested on a phone.**

Sources:
- Stock: `~/android-dt/dumps/kodiak`.
- Ours: `out/target/product/kodiak` from the 10-19 build (`BUILD_EXIT=0`, images 13:46). Our Wi-Fi APEX came
  from the 10-18 build (copied before the rebuild); the supplicant pieces are prebuilt and unchanged.
- Both Wi-Fi APEXes, unpacked on the Mac: stock `system/apex/com.google.android.wifi.apex`, ours `com.android.wifi.capex`.
- User logcat on the 10-18 build: `~/Downloads/logcat.txt`.
- Setup Wizard report: `community/daily_raw/raw_20261017.json`, post 90779478.

Server access was read-only; two scratch files I wrote to the server's `/tmp` were deleted.

## Summary

1. **The only stock deviation found in the supplicant path is the two missing `system_ext` overlay confs**, and
   the 10-19 build now ships them byte-identical to stock. The mainline supplicant binary, its template conf, its
   init script, its SELinux policy and all 66 Wi-Fi aconfig flags are identical to stock (section 1).
2. **Google's Wi-Fi module gives stock nothing our AOSP module lacks in configuration.** Same 597 resource names,
   same effective values, same flags. Both keys the audit called "missing" (`config_wifiUpdateCountryCodeFromScanResultSetupWizard`,
   `config_wifiDisableFirmwareRoamingInIdleMode`) don't exist in Google's own target, so they do nothing on stock either.
   The real difference is code version: stock module 370546200, ours 370399999 (section 2).
3. **Setup Wizard:** no proven cause. The report ("scanning, then networks drop from the list") points at scans
   stopping during setup, not at association, captive portal or permissions. Permissions, role, APK version and
   Wi-Fi/NetworkStack resources are ruled out with evidence. Ranked leads and the log that separates them: section 3.
4. **New stock deviations not in the audit:**
   - Lineage forces `ro.boot.wificountrycode=00` and `def_wifi_on=true`; stock sets neither.
   - A downstream WifiTrackerLib change makes Settings save WPA2/WPA3 transition networks as SAE-only.
   - Lineage carries a Miracast scan-suppression hunk and a Wi-Fi auto-off hunk in the Wi-Fi service; both are
     inactive by default.

## 0. Corrections to KODIAK_AUDIT_20261019.md

| Audit item | Correction | Label |
|---|---|---|
| M6, "Checked and fine": `config_wifiUpdateCountryCodeFromScanResultSetupWizard` is "Google-only" | Not in Google's `ServiceWifiResourcesGoogle.apk` either. Stock's overlay entry has no target, so it's a no-op on stock too. Same for `config_wifiDisableFirmwareRoamingInIdleMode` | Evidence (`aapt2 dump resources`, both APKs: 597 identical names) |
| L3: NetworkStack `config_force_enable_apfv6_nd_offload` missing | Not in Google's `NetworkStackGoogle.apk` either. The stock overlay entry is a no-op, so no APF difference comes from it | Evidence (both NetworkStack APKs: same 41 resources, same values) |
| H1: `driver_param=…p2p_device=1` gives a dedicated P2P device iface | This supplicant parses only `use_p2p_group_interface=1` from that string. `p2p_device=1` isn't in `nl80211_set_param` or the prebuilt's strings, and the two flags it sets are also set when the driver advertises P2P concurrency | Evidence: `driver_nl80211.c:10733`, `driver_nl80211_capa.c:1462-1466`, `strings` on the prebuilt |

## 1. Mainline supplicant, end to end

| Piece | Stock | Ours | Label |
|---|---|---|---|
| `/apex/com.android.wifi/bin/wpa_supplicant_mainline` | sha1 `02dd9c841729…` | `02dd9c841729…` (prebuilt `packages/modules/Wifi/apex/prebuilts/version_202605-0`) | Evidence: identical |
| `etc/wpa_supplicant_mainline.conf` (template) | `39239dab7b93…` | same | Evidence |
| `etc/mainline_supplicant.rc` | `0e3ea8059035…` | same | Evidence |
| `RELEASE_WIFI_MAINLINE_SUPPLICANT_BINARY` | n/a | `true` (`build/release/flag_values/cp2a`) | Evidence |
| aconfig `com.android.wifi.flags.mainline_supplicant` | ENABLED, READ_ONLY | same; all 66 flags identical | Evidence (decoded `etc/aconfig_flags.pb`) |
| `config_wifiMainlineSupplicantEnabled` | true | true | Evidence |
| `/system_ext/etc/wifi/wpa_supplicant_mainline_overlay.conf` | sha1 `6db64bce9fc5…` | missing on 10-16/10-18; **10-19 build: `6db64bce9fc5…`** | Evidence |
| `/system_ext/etc/wifi/p2p_supplicant_mainline_overlay.conf` | `2290c5a8aed5…` | missing on 10-16/10-18; **10-19 build: `2290c5a8aed5…`** | Evidence |
| `libnl.so`, `android.system.wifi.mainline_supplicant-ndk.so` (in APEX) | Google build | ours, different hashes | Evidence. Unknown: ABI not compared. The binary links and runs, since Wi-Fi works after setup |

- **Config chain (Evidence, `strings` on the prebuilt, matching `external/wpa_supplicant_8/wpa_supplicant/aidl/supplicant.cpp:34-37, 459-461, 528-530`):**
  1. Template `/apex/com.android.wifi/etc/wpa_supplicant_mainline.conf`.
  2. Per-device copy under `…/apexdata/com.android.wifi/mainline_supplicant/wpa/{wpa,p2p}_supplicant_mainline.conf`.
  3. `confanother` = `/system_ext/etc/wifi/{wpa,p2p}_supplicant_mainline_overlay.conf`, used only if `access()` succeeds.

  The vendor `/vendor/etc/wifi/*_overlay.conf` files (identical content) only reach the vendor supplicant, which
  this path doesn't use.
- **What the overlays change (Evidence: stock files vs template).** Template: `wowlan_triggers=magic_pkt`,
  `rsn_overriding=1`. The STA overlay adds or overrides `wowlan_triggers=any`, `rsn_overriding=2`, `interworking=1`,
  `hs20=1`, `auto_interworking=0`, `bss_max_count=512`, `bss_no_flush_when_down=1`, `btm_offload=1`,
  `disable_scan_offload=1`, `use_priv_cmd_mbo_cell_status=1` and `driver_param=use_p2p_group_interface=1p2p_device=1`.
  The P2P overlay adds the same `driver_param`, `disable_scan_offload=1`, `p2p_go_vht=1`, `p2p_pref_chan=124:149, 115:36`,
  `p2p_dfs_chan_enable=1` and `p2p_6ghz_disable=1`.
  - Evidence (`wpa_supplicant/scan.c:1712`): without `disable_scan_offload=1`, the supplicant may run its own
    driver scheduled scan.
  - Inference: that can collide with wificond's PNO, which also uses the single BCM scheduled-scan slot.
- **Init (Evidence).**
  - `wpa_supplicant_mainline`: `interface aidl wifi_mainline_supplicant`, `socket wpa_wlan0`, `disabled oneshot` (lazy).
  - Stock vendor `wpa_supplicant` (lazy AIDL `ISupplicant/default`) also declares `socket wpa_wlan0`.
    Both are `disabled`, so only the one the framework asks for starts. Inference: they can't both run.
  - Stock vendor `hostapd`: lazy `IHostapd/default` V3.
- **SELinux (Evidence).**
  - Every `wifi_mainline_supplicant` and `mainline_supplicant_data_file` statement in our compiled `plat_sepolicy.cil`
    (120 lines) matches stock; only `base_typeattr_N` numbering and attribute membership lists differ.
  - Stock `system_ext_sepolicy.cil`, `product_sepolicy.cil` and `vendor_sepolicy.cil` reference the domain only in
    attribute sets. No vendor HAL, `wificond` or `wifi_ext` rule targets it.
  - `plat_file_contexts` entries for `/dev/socket/wpa_wlan*`, `/data/misc/wifi/mainline_supplicant(/.*)?` and
    `/data/misc/wifi/sockets` are identical.
  - The new confs are `system_file`, which coredomains may read. **No policy gap.** Unknown: no device AVC check yet.
- **SoftAP and bridged AP:** still the vendor `hostapd` through `IHostapd`, as on stock. The mainline supplicant
  plays no part. P2P goes through the mainline supplicant (`SupplicantP2pIfaceHal.java:130`).
- **Things that work only with Google's APEX: none found.** The binary and every config file are the same.

## 2. Google `com.google.android.wifi` vs our AOSP `com.android.wifi`

- **Module version (Evidence, `apex_manifest.pb`):** stock 370546200, ours 370399999. Our source is the cp2a
  snapshot (APK paths `@CP2A.260605.016`) as one squashed commit (`a45b3c1`), so its history can't be split.
- **Resources:** same 597 names. Defaults differ only for `config_wifi_framework_wifi_score_{bad,entry}_rssi_threshold_5GHz`,
  and both overlays set those to -80/-77. Country, DTIM, APF and roaming keys are identical:
  `config_wifiDriverWorldModeCountryCode=00`, `config_wifiStaDynamicCountryCodeUpdateSupported=false`,
  `config_wifiDtimMultiplierConfigEnabled=true` (overlay), `config_wifiUseHalApiToDisableFwRoaming=true`. Evidence.
- **Overlay:** `PixelWifiOverlay2026Kodiak` = stock's 59 keys minus the 2 no-ops in section 0. Evidence.
- **aconfig:** identical. Evidence.
- **Code (`dexdump` method signatures of `service-wifi.jar`).** Evidence that these exist in ours only:
  - `WifiConnectivityManager.saveMiracastMode`/`saveP2pGroupStarted` (`WifiConnectivityManager.java:2545-2548`) skip
    connectivity scans only while a P2P group **and** Miracast source/sink are both active. Inference: no effect in
    setup, and it doesn't touch Quick Share (no Miracast).
  - `WifiServiceImpl.setWifiTimeout` (`WifiServiceImpl.java:1301`) is Lineage's Wi-Fi auto-off, driven by
    `Settings.Global.wifi_off_timeout`, default 0 = off. Our Settings has no UI for it (`git grep` empty). Inactive.
  - Everything else in the diff is anonymous-class renumbering or constants Google's R8 removed. Unknown: the
    behaviour of Google's newer train versus cp2a can't be compared without source.
- **What stock's Google module does that ours can't, and what it costs:** nothing found in configuration. Only
  bug fixes newer than cp2a could differ (Unknown).

## 3. Setup Wizard Wi-Fi failure (ISS-20261017-03)

### What we know

- **Evidence, report (10-16 build):** "I can't connect to any wifi networks during setup. It's stuck on scanning for
  a while and then they drop from the list." Wi-Fi "does connect fine once I skip through all of that."
  - Inference: networks first appeared, so at least one scan worked. Then they aged out: pickers drop entries whose
    scan results get older than the max scan age (15 s in AOSP Settings, `WifiPickerTrackerHelper.java:53`).
    So during setup, scans stopped delivering fresh results.
  - That points at the scan path. Association, DHCP, captive portal and validation happen after the user taps a
    network, and the list empties before that.
- **Evidence, 10-18 user log:** that phone was already on Wi-Fi during setup (`AdbWifiNetworkMonitor: Wi-Fi network
  available` from 21:04:53; WPA3 network on 5785 MHz). So setup Wi-Fi isn't broken for every user on 10-18.
  - The log's buffers start after boot; the main buffer starts at 21:06:14, after setup's Wi-Fi step. So there are
    no setup-time Wi-Fi lines.
  - After setup, each scan logs `WificondScannerImpl: Filtering out 18–31 scan results`, which is normal-looking but uncounted.

### The Setup Wizard Wi-Fi path

Evidence: `aapt2` on both builds.

- Setup Wizard is Google's `com.google.android.setupwizard` 236.953424739 (versionCode 43869), the same version as
  stock. Its `uses-permission` set is identical to stock's, and so is its `privapp-permissions-google-p.xml` block.
  The APK hash differs; the signing block was not compared.
- It is the **only** package declaring `android.intent.category.SETUP_WIZARD`, in stock and ours. So the
  `setup`-protected `NETWORK_SETUP_WIZARD` permission (requested in its manifest) is granted the same way on both.
  The location-gated scan path is **ruled out** as a difference.
- Its Wi-Fi step is `com.google.android.setupwizard.network.WifiActivity`. It handles `android.net.wifi.PICK_WIFI_NETWORK`
  (priority 5, `enabled=false` until enabled at runtime) and `com.android.setupwizard.WIFI_SETTINGS`.
  `setupwizard.feature.enable_wifi_tracker=true` is set on both builds.
- Its dex contains `com/android/wifitrackerlib/BaseWifiTracker$WifiTrackerLifecycleObserver`. Inference: Setup
  Wizard bundles its own WifiTrackerLib, so our downstream WifiTrackerLib change (section 5) doesn't affect the
  setup list. Settings (`com.android.settings`, shipped as `SettingsGoogle.apk` on both) also handles `PICK_WIFI_NETWORK`.
- Captive portal and validation: our NetworkStack resources (captive-portal URLs and probe specs) are identical to
  Google's (Evidence). Not the reported symptom.

### Country code during setup

Evidence:
- Ours sets `ro.boot.wificountrycode=00` in `product/etc/build.prop` (`vendor/lineage/config/common.mk:310`,
  `PRODUCT_PRODUCT_PROPERTIES += ro.boot.wificountrycode?=00`). Stock sets it in no prop file; the stock vendor_boot
  only has the property_contexts entry.
- `WifiSettingsConfigStore.WIFI_DEFAULT_COUNTRY_CODE` defaults to that prop (`WifiSettingsConfigStore.java:145-146`).
  `WifiCountryCode.pickCountryCode()` falls back to it when there's no override, telephony or scan-result country
  (`:653-669`). So ours pushes `00` into the driver at Wi-Fi start; stock pushes nothing until it learns a country.
- The BCM4390 NVRAM has `ccode=0`, `regrev=0` (`/vendor/firmware/bcmdhd.cal_4390_b1`), so the driver boots in its
  world domain anyway; `bcmdhd4390.ko` has the string "locale mapped to world domain".
  Inference: our forced `00` mostly repeats the driver default and doesn't by itself change channels.
- Ours: Wi-Fi is on from first boot (`def_wifi_on=true`, `vendor/lineage/overlay/common/.../SettingsProvider/res/values/defaults.xml:20`).
  Stock: AOSP default `false` (`frameworks/base/packages/SettingsProvider/res/values/defaults.xml:51`); Setup Wizard
  turns it on.
- Country changes during setup come from `updateCountryCodeFromScanResults` (`config_wifiUpdateCountryCodeFromScanResultGeneric=true`
  on both; needs ≥3 agreeing US APs or ≥2 for other countries, `:66-67`) or from telephony.
  - `bcmdhd4390.ko` has `wldev_set_country`, `wl_cfgscan_scan_abort` and "ccode change" strings.
  - Inference, from open-source bcmdhd and **not verified on this binary**: a country change aborts the scan in
    progress.
- `config_wifiStaDynamicCountryCodeUpdateSupported=false` on both. With a telephony country that differs from a
  world-mode driver, the framework may disconnect a low-traffic connection once (`DISCONNECT_WIFI_COUNT_MAX = 1`,
  `:520-548`). That code is the same on stock.
- 6 GHz and DFS in world mode: 6 GHz is unusable and 5 GHz is passive-scan until a country is set. Inference:
  networks show up more slowly but don't disappear, and stock is in the same driver world domain until it learns a country.

### Ranked hypotheses (Inference unless marked)

1. **Mainline supplicant without its overlays (fixed in the 10-19 build, untested).** It's the only Wi-Fi-path
   config that differs from stock while Setup Wizard is scanning.
   - Without `disable_scan_offload=1`, the supplicant may start its own scheduled scans (Evidence: `scan.c:1712`).
   - Without the P2P overlay, Wi-Fi Direct runs with untuned P2P settings while Setup Wizard's Quick Start step
     (`CheckQuickStartActivity` appears in the log) may use device-to-device links.
   - Either can make the BCM driver reject or abort scans, so results age out.
   - Test: repeat setup on the 10-19 build.
2. **Country-code changes while Setup Wizard scans.** Ours starts Wi-Fi at boot with `00`; then a scan-derived or
   telephony country triggers a driver country change, which likely aborts in-flight scans. Stock reaches the
   same final country but starts Wi-Fi later and never pushes `00`. One or two extra aborts shouldn't empty the
   list for long, so this ranks below 1.
3. Driver or firmware behaviour that is the same on stock but triggered by something unique to that user's
   environment (DFS-only or 6 GHz-only APs, many APs). Can't be separated without their log.

Ruled out with evidence: setup-wizard identity and `NETWORK_SETUP_WIZARD`, Setup Wizard version and permissions,
the Wi-Fi resource overlay, Wi-Fi aconfig flags, mainline-supplicant SELinux, NetworkStack and captive-portal
resources, and vendor RROs (none target Wi-Fi, NetworkStack or tethering).

**Log that separates them** (section 6, steps 5-6): `dumpsys wifi` (country-code timestamps, the
WifiScanningService log of scan failures and aborts) and `logcat -b all`, taken right after reproducing.
- Scan failures without a nearby `setCountryCodeNative` point at 1.
- Failures right after each `setCountryCodeNative`/`onDriverCountryCodeChanged` point at 2.

## 4. Wi-Fi idle power: APF, DTIM, wowlan, roaming

| Area | Stock | Ours (10-19 build) | Label |
|---|---|---|---|
| wowlan triggers armed by supplicant | `any` | `any` (10-16/10-18: `magic_pkt`) | Evidence (conf files) |
| BTM / roaming offload in supplicant | `btm_offload=1` | same (10-16/10-18: unset) | Evidence |
| Firmware roaming control | `config_wifiUseHalApiToDisableFwRoaming=true` | same | Evidence |
| DTIM multiplier | `config_wifiDtimMultiplierConfigEnabled=true`, default multipliers | same | Evidence (resources identical) |
| APF: NetworkStack resources (`config_apfEthTypeDenyList`, `config_apfDrop802_3Frames`, …) | Google NetworkStack | AOSP NetworkStack, same names and values | Evidence |
| APF: overlay `config_force_enable_apfv6_nd_offload` | set, but no such key in the target | absent | Evidence: no-op on stock |
| Wake-packet mark (`config_networkWakeupPacketMark/Mask`) | `ConnectivityOverlay` 0x80000000 | `PixelConnectivityOverlay2024` 0x80000000 | Evidence |
| Wi-Fi HAL, firmware, `wifi_ext` APEX | stock vendor | same images | Evidence (audit §0) |
| NetworkStack and Wi-Fi code versions | Google trains | AOSP cp2a | Evidence of different versions; impact Unknown |

Inference: the 10-16/10-18 builds differed from stock in suspend wake triggers (`magic_pkt` vs `any`) and roaming
offload. The 10-19 build matches stock on every configuration point found. Unknown: actual drain, and whether the
BCM firmware honours the supplicant's wowlan triggers.

## 5. RRO, props and feature XMLs

- **Vendor RROs (Evidence):** stock `vendor/overlay` targets `android`, `com.android.settings`,
  `com.android.providers.settings`, `com.android.phone`, `com.android.systemui`, NFC, UWB, Traceur, DeviceDiagnostics,
  DMService, `com.google.android.{crossdeviceaccessservice,flipendo,nfc,rilextension,storagemanager}`. None targets
  Wi-Fi, NetworkStack or tethering, so none is lost by building AOSP modules.
  - The `framework-res` vendor RRO sets `config_tether_wifi_regexs=[wlan0, softap.*]`, `config_wifi_dual_band_support`,
    `config_wifi_softap_ieee80211ac_supported` and the IWLAN packages. It targets `android`, so it applies to our build.
  - No product overlay of ours overrides those keys.
  - The Settings vendor RRO (`config_network_selection_list_aggregation_enabled`) applies to our `com.android.settings`.
- **Our product RROs that differ from stock on Wi-Fi:** `def_wifi_on=true` (Lineage; section 3).
- **Props:** both builds have `ro.wifi.channels=` and `setupwizard.feature.enable_wifi_tracker=true` (ours lists
  each twice in `product/etc/build.prop`, which is harmless). Only ours has `ro.boot.wificountrycode=00`. No vendor
  `wifi`/`wlan` props differ, because vendor is stock.
- **Feature XMLs:** `android.hardware.wifi{,.direct,.aware,.rtt,.passpoint}.xml` are stock vendor files. Passpoint
  is advertised; the supplicant had `interworking`/`hs20` off until the 10-19 build.
  - Wi-Fi-related system/system_ext/product permission XMLs match by role. `com.google.android.networkstack.xml`
    becomes our `NetworkStack.xml`; `factoryota` is stock-only.
  - Ours also has `privapp-permissions-kodiak-scone.xml` and the gamespace allowlist. Nothing Wi-Fi-critical. Evidence (file lists).
- **Downstream WifiTrackerLib change.**
  - Evidence: `frameworks/opt/net/wifi/libs/WifiTrackerLib/src/com/android/wifitrackerlib/Utils.java:219-250`,
    commit `240b2b5` "Prefer SAE/OWE over PSK/Open in transition-mode pair", by a non-Google author. It inverts
    AOSP's rule; the method's own Javadoc still says "collapse to the lowest security type".
  - It changes `WifiEntry.getSecurity()` and `StandardWifiEntry`'s target config selection (`StandardWifiEntry.java:962`).
  - Inference: networks added from Settings on WPA2/WPA3-transition or OWE-transition APs are saved SAE-only or
    OWE-only. Stock saves PSK or Open, which the framework upgrades to SAE/OWE (`config_wifiSaeUpgradeEnabled=true`),
    with fallback.
  - Possible effect: no PSK fallback on APs with weak SAE/H2E, i.e. "won't connect" or flaky connects outside setup.
    Unknown: no report ties a failure to it yet.

## 6. On-device diagnostic recipe

Expected values come from stock files and our source; none has been checked on a phone.

1. Supplicant service and config files:
   ```bash
   adb shell getprop | grep -E "init.svc.(wpa_supplicant|wpa_supplicant_mainline|hostapd)"
   ```
   Expected with Wi-Fi on: `[init.svc.wpa_supplicant_mainline]: [running]`; vendor `wpa_supplicant` absent or `stopped`.
   ```bash
   adb shell ps -A -o LABEL,NAME | grep -i supplicant
   ```
   Expected: `u:r:wifi_mainline_supplicant:s0  wpa_supplicant_mainline`.
   ```bash
   adb shell sha1sum /system_ext/etc/wifi/wpa_supplicant_mainline_overlay.conf /system_ext/etc/wifi/p2p_supplicant_mainline_overlay.conf
   ```
   Expected on the 10-19 build: `6db64bce9fc5…` and `2290c5a8aed5…`. On 10-16/10-18: "No such file".
2. Framework picked the mainline supplicant, and SELinux is clean:
   ```bash
   adb logcat -b all -d | grep -iE "SupplicantStaIfaceHal|SupplicantP2pIfaceHal|wpa_supplicant_mainline|confanother|_mainline_overlay"
   ```
   Expected: the Mainline-implementation init line for STA and P2P, and, if the supplicant's `-dd` output reaches
   logcat, `Reading configuration file '/system_ext/etc/wifi/wpa_supplicant_mainline_overlay.conf'`.
   ```bash
   adb logcat -b all -d | grep "avc:.*wifi_mainline_supplicant"
   ```
   Expected: nothing.
3. Country code:
   ```bash
   adb shell getprop ro.boot.wificountrycode
   ```
   Expected: ours `00`, stock empty.
   ```bash
   adb shell dumpsys wifi | grep -E "DefaultCountryCode|mTelephonyCountryCode|mDriverCountryCode|mFrameworkCountryCode|mOverrideCountryCode|CountryCodeUpdatedTimestamp|Telephony country"
   ```
   Expected after setup with a SIM: telephony, driver and framework codes all equal the SIM's country.
4. Turn on verbose Wi-Fi logging before reproducing anything:
   ```bash
   adb shell cmd wifi set-verbose-logging enabled
   ```
5. **Setup Wizard reproduction.** adb is usually off during setup, so collect right after:
   1. On the setup Wi-Fi screen, wait until networks drop.
   2. Skip Wi-Fi, finish setup, enable USB debugging, and **within a few minutes** run steps 5 and 6 (the log ring
      buffer is small).
   ```bash
   adb logcat -b all -d > suw_logcat.txt
   ```
   ```bash
   adb shell dumpsys wifi > suw_dumpsys_wifi.txt
   ```
   ```bash
   adb shell dumpsys wifiscanner > suw_wifiscanner.txt
   ```
6. Read them:
   ```bash
   grep -nE "WifiCountryCode|setCountryCodeNative|onDriverCountryCodeChanged|WificondScannerImpl|WifiScanningService|Scan failed|scan.*abort|onFailure|wpa_supplicant" suw_logcat.txt
   ```
   Scan failures or aborts clustered at country-code changes point at hypothesis 2. Failures without country
   changes, or alongside `p2p`/sched-scan lines, point at 1.
7. Transition-network saving (section 5):
   ```bash
   adb shell cmd wifi list-networks
   ```
   For a WPA2/WPA3 mixed AP added from Settings: AOSP and stock behaviour show a PSK-type config; our downstream
   WifiTrackerLib should show SAE.
8. Idle power baseline (compare with a stock phone if one is available):
   ```bash
   adb shell dumpsys network_stack | grep -iA4 "apf"
   ```
   ```bash
   adb shell dumpsys wifi | grep -iE "dtim|LinkLayerStats|wake"
   ```

## 7. Proposed fixes for the main session

1. **Supplicant overlays (H1): done in tree `92c4a83` and built.** The 10-19 `out/` has both files, byte-identical
   to stock (Evidence). Nothing more to change; it needs the phone checks in steps 1-2 and a setup re-test (step 5).
   Repeat for grizzly, cubs and yogi from their own dumps, as in audit step 9.
2. **Audit text:** apply the corrections in section 0 (M6 key, L3 key, the meaning of `p2p_device=1`).
3. **Optional, only if the step 5 logs implicate country code (hypothesis 2):** match stock by not shipping a
   default Wi-Fi country.
   - This is a ROM-wide Lineage default, so it's an experiment, not a fix.
   - Device-level override in `device/google/kodiak/device.mk`: Lineage's line uses `?=`, so a non-optional
     device value wins at build time.
     ```make
     PRODUCT_PRODUCT_PROPERTIES += \
         ro.boot.wificountrycode=
     ```
     `WifiCountryCode.isValid("")` is false, so the default becomes null, as on stock. Unknown: whether init
     accepts an empty `ro.` value. Confirm with `getprop` after building.
   - Not recommended until a log shows country-code aborts.
4. **Optional, ROM-wide, needs Daryl's decision:** restore AOSP's transition-mode collapse in WifiTrackerLib, so
   Settings saves PSK/Open and the framework upgrades to SAE/OWE with fallback, as on stock. Carry it as a patch
   like `patches/frameworks_base`, against `frameworks/opt/net/wifi`, `libs/WifiTrackerLib/src/com/android/wifitrackerlib/Utils.java`:
   ```diff
            if (securityTypes.size() == 2) {
   -            // Transition-mode pair: prefer the stronger of the two so the
   -            // Settings UI saves the network with the modern AKM. ...
   -            if (securityTypes.contains(WifiInfo.SECURITY_TYPE_SAE)) {
   -                return WifiInfo.SECURITY_TYPE_SAE;
   -            }
   -            if (securityTypes.contains(WifiInfo.SECURITY_TYPE_OWE)) {
   -                return WifiInfo.SECURITY_TYPE_OWE;
   -            }
                if (securityTypes.contains(WifiInfo.SECURITY_TYPE_OPEN)) {
                    return WifiInfo.SECURITY_TYPE_OPEN;
                }
   ```
   The PSK and EAP branches that follow stay as they are. It affects every device built from this source, and
   no report ties a failure to it yet. Check with recipe step 7 first.
5. **Don't add** `config_wifiUpdateCountryCodeFromScanResultSetupWizard` or `config_wifiDisableFirmwareRoamingInIdleMode`
   to the overlay, or `config_force_enable_apfv6_nd_offload` to NetworkStack: no target defines them, on stock or ours.

## 8. Not covered

- `framework-wifi.jar`, `libservice-wifi-jni.so`, OsuLogin and WifiDialog: Google vs AOSP binaries not diffed.
- NetworkStack code (APF program version) and Tethering code, Google vs AOSP: only resources compared.
- The ABI of our `android.system.wifi.mainline_supplicant-ndk.so` and `libnl.so` against the Google-built prebuilt.
- Whether bcmdhd4390 aborts scans on a country change: an inference from strings only.
