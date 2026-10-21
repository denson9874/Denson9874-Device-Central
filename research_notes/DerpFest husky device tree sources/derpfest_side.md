# DerpFest side: DerpFest 17 for husky (Pixel 8 Pro, device/google/shusky + zuma)

State as of 2026-10-21. "Server" means `build@157.180.50.152:~/derpfest`, which was read without changes. One exception: a stray shell redirect created an empty scratch file, `/tmp/.x`, on the server. Nothing in the tree was touched. Line numbers come from `cat -n` / `grep -n` output.

## Q1. Does DerpFest have husky/shusky/zuma trees for 17 or 16, who maintains husky, and is it official?

### Takeaway
DerpFest-Devices has `device_google_shusky` and `device_google_zuma`, plus older `device_google_gs-common_zuma` and `device_google_zumapro`. The newest branch is **16.2**, and there is **no `17` branch** on any of them. husky is listed as Official/Active, maintained by Adrian Szymański (@Adi20_01, GitHub adi8900). The last husky build is **DerpFest-v16.2-20260612**, and no v17 husky build had been published as of 2026-10-21. The trees are LineageOS histories (mostly Michael Bestas commits with Change-Ids) with a small set of DerpFest commits by adi8900 on top.

### Cited Findings
- A GitHub search of org DerpFest-Devices for husky/shusky/zuma/shiba returns 4 repos:
  - `device_google_shusky`: default branch 16.2, pushed 2026-07-05
  - `device_google_zuma`: default 16.2, pushed 2026-07-10
  - `device_google_gs-common_zuma`: default 16.1, pushed 2025-12-07
  - `device_google_zumapro`: default 15, pushed 2025-02-17, historical

  None is marked as a GitHub fork. — [GitHub search API](https://api.github.com/search/repositories?q=org:DerpFest-Devices+husky+OR+shusky+OR+zuma+OR+shiba&per_page=50)
- A name search for "husky" in DerpFest-Devices returns 0 repos, so there is no DerpFest `vendor_google_husky` or husky kernel repo. — [GitHub search API](https://api.github.com/search/repositories?q=husky+in:name+org:DerpFest-Devices)
- `device_google_shusky` branches: 16-kernel, 16, 16.1-test, 16.1, 16.2-n, 16.2. No 17. — [branches](https://api.github.com/repos/DerpFest-Devices/device_google_shusky/branches)
- `device_google_zuma` branches: 16-kernel, 16, 16.1-test, 16.1-tmp, 16.1, 16.2-n, 16.2-vipert, 16.2. No 17. — [branches](https://api.github.com/repos/DerpFest-Devices/device_google_zuma/branches)
- The 16.2 history of shusky is LineageOS commits plus a few by adi8900:
  - Michael Bestas (lineageos.org): "shusky: sepolicy: Regenerate" e6617db (2026-07-05), "shusky: Inherit from zuma common.mk" a4458ea (2026-03-27), "Import generated overlays from BP4A.260205.001"
  - adi8900: "shusky: Restore CarrierWifi app" e092210, "SPL: BP4A.260205.001" 7eea548

  So the tree is still on the Android 16 BP4A base. — [commits](https://api.github.com/repos/DerpFest-Devices/device_google_shusky/commits?sha=16.2&per_page=15)
- DerpFest commits by adi8900 on zuma 16.2:
  - "zuma: Rename conflicting overlays with vendor/gms" c2a2f62 (2026-03-22)
  - "zuma: Don't include BCR" e5cd1f9 (2026-02-15)
  - "zuma: Enable clear calling" deaacba
  - "zuma: Allow debloating apk" f330df0
  - "zuma: Restore file manager" f73bffd
  - "zuma: Include BCR" bc3035f
  - "zuma: Include pixel camera if exists" 57cfed7
  - "zuma: We are shipping with gapps" 0d08d79
  - "zuma: Drop duplicated prop" ca5790e
  - "zuma: props: AptX HFP prop shouldn't be overriden" 9e96087

  — [commits](https://api.github.com/repos/DerpFest-Devices/device_google_zuma/commits?sha=16.2&per_page=40&author=adi8900)
- The 16.2 `lineage_husky.mk` in DerpFest's shusky tree:
  - sets `DERPFEST_BUILD_TYPE := Official` before `inherit-product vendor/lineage/config/common_full_phone.mk`
  - sets `DEVICE_PATH := device/google/shusky` and `VENDOR_PATH := vendor/google/husky`, and inherits `aosp_husky.mk`
  - sets `PRODUCT_NAME := lineage_husky`, `TARGET_SCREEN_HEIGHT := 2992` and `TARGET_SCREEN_WIDTH := 1344`
  - fingerprint is `google/husky/husky:16/BP4A.260205.001/14624666`
  - inherits `$(VENDOR_PATH)/husky-vendor.mk`

  — [lineage_husky.mk @16.2](https://raw.githubusercontent.com/DerpFest-Devices/device_google_shusky/16.2/lineage_husky.mk)
- The official device list (`Updater-Stuff/info/device-info.json`):
  - husky "Google Pixel 8 Pro": maintainer "Adrian Szymański (@Adi20_01)", status "Active"
  - shiba and akita: same maintainer, Active
  - cheetah, panther, lynx: Sean Dabes, Active
  - blazer, frankel, mustang (Pixel 10): Wang Daning, Active
  - caiman, tokay, komodo: Discontinued
  - kodiak: not listed

  — [device-info.json](https://raw.githubusercontent.com/DerpFest-AOSP/Updater-Stuff/master/info/device-info.json)
- The husky OTA JSON still points at 16.2: filename `DerpFest-v16.2-20260612-husky-Official-Stable.zip`, romtype "Official", size 2657092328, version "v16.2", URL on sourceforge.net/projects/derpfest/files/husky/. — [husky.json](https://raw.githubusercontent.com/DerpFest-AOSP/Updater-Stuff/master/husky.json)
- SourceForge `derpfest/files/husky` holds 16.0 builds from 2025-08-16 through 2025-11-08 (historical), 16.1 from 2025-12-08, and 16.2 Beta/Stable from 2026-02-04 through 2026-06-12. **There are no v17 husky files.** The site-wide latest is `DerpFest-v17-20261020-onyx-Official-Stable.zip`, which confirms DerpFest 17 official builds exist for other devices. — [SourceForge husky](https://sourceforge.net/projects/derpfest/files/husky/)
- An aggregator agrees: husky current build v16.2, 2026-06-12, maintainer Adi20_01. — [thecustomrom.com](https://thecustomrom.com/roms/derpfest/husky)

### Inferences
- husky has no DerpFest 17 tree yet. A DerpFest 17 husky build means porting LineageOS lineage-24.0 shusky/zuma, the way kodiak was done, or rebasing adi8900's 16.2 DerpFest commits onto lineage-24.0. adi8900's zuma commits are the list of DerpFest-specific adjustments worth carrying over: gms overlay renames, BCR, "shipping with gapps", and Pixel camera.
- Because husky is still listed as Active/Official under Adi20_01, an unofficial 17 build should use `DERPFEST_BUILD_TYPE=Community` (the default). The filename and JSON then say "Community" and won't look official.
- There is no DerpFest husky vendor or kernel repo, so the 16.2 builds very likely use TheMuppets `proprietary_vendor_google_husky` and Lineage's prebuilt kernel repos. This is unverified because the local_manifest wasn't found.

### Gaps
- No public 17 branch or roadmap for husky from adi8900 was found. Telegram wasn't searchable.
- The shusky/zuma local manifest DerpFest uses for husky (kernel and vendor sources) wasn't found.

## Q2. What does the DerpFest 17 manifest declare that matters for Pixels, and what can collide?

### Takeaway
DerpFest 17 is the LineageOS lineage-24.0 manifest (`default.xml`, AOSP tag `android-17.0.0_r1`) with DerpFest forks swapped in. For Pixels the important ones are:
- `device/lineage/sepolicy` → `android_device_derpfest_sepolicy`
- `hardware/google/pixel-sepolicy` → DerpFest fork
- `vendor/lineage` → `android_vendor_derpfest`
- `vendor/pixel/gms` → PixelOS GitLab `proprietary_vendor_pixel_gms-17`
- plus `vendor/pixel/{clocks,sounds,themepicker}`, `vendor/overlay` and `vendor/certification`

The PixelOS GMS package forces `com.google.android.extservices` into PRODUCT_PACKAGES, and it ships GMS overlays, sysconfig, default-permissions and an AICore module. These are the main collision and behaviour-change sources against LineageOS husky trees and TheMuppets blobs.

### Cited Findings
- Remotes in `snippets/derp.xml`: `derp` = github.com/DerpFest-AOSP (rev 17), `derp-devices` = github.com/DerpFest-Devices (rev 17), `gitlab` = gitlab.com (rev `seventeen`). — server `.repo/manifests/snippets/derp.xml`
- Pixel-relevant projects in derp.xml:
  - `device/lineage/sepolicy` → `android_device_derpfest_sepolicy`
  - `hardware/google/pixel-sepolicy` → `android_hardware_google_pixel-sepolicy`
  - `vendor/lineage` → `android_vendor_derpfest`
  - `vendor/pixel/gms` → `PixelOS-AOSP/proprietary_vendor_pixel_gms-17` (gitlab, clone-depth 1)
  - `vendor/pixel/clocks|sounds|themepicker`, `vendor/overlay`, `vendor/certification`, `vendor/fontage`, `vendor/support`
  - `packages/apps/FaceUnlock`, `ColumbusService`, `Updater`, `Settings`, and `packages/apps/Launcher3` (as DerpLauncher)
  - frameworks/base, av and native forks

  — server `.repo/manifests/snippets/derp.xml`
- `snippets/lineage.xml` comments out the LineageOS `device/lineage/sepolicy` (line 8) and `hardware/google/pixel-sepolicy` (line 67) because DerpFest replaces them. It keeps `hardware/google/pixel` from LineageOS (line 66). — server `.repo/manifests/snippets/lineage.xml:8,66,67`
- `default.xml`: aosp remote revision `refs/tags/android-17.0.0_r1`, and default revision `refs/heads/lineage-24.0` on the LineageOS GitHub remote. — server `.repo/manifests/default.xml`
- Kernel snippets available: `kernel-5.15.xml`, `kernel-6.6.xml`, `kernel-6.12.xml`, `kernel-6.18.xml`. — server `ls .repo/manifests/snippets`
- Tree freshness:
  - `vendor/lineage` HEAD `8c4e2ba6` (2026-10-14) "Merge branch 'lineage-24.0' of LineageOS/android_vendor_lineage into 17"
  - manifest HEAD `04cf624` (2026-10-04)
  - `vendor/pixel/gms` HEAD `7feb332` (2026-08-31)

  — server `git log -1`
- What `vendor/pixel/gms` installs:
  - `products/gms.mk`:
    - `TARGET_DOES_NOT_SUPPORT_GOOGLE_BATTERY ?= true`, which adds `TurboAdapter_NoBatt` and `libpowerstatshaldataprovider`
    - `GoogleSettingsOverlay`
    - `ro.opa.eligible_device=true`
    - many setupwizard props, plus `setupwizard.theme=glif_expressive`
    - inherits `common/common-vendor.mk`

    — server `vendor/pixel/gms/products/gms.mk:18-68`
  - `common/common-vendor.mk` (203 lines, generated):
    - **`com.google.android.extservices`** (line ~124) and `com.google.android.gmssystem.prodvic`
    - `GoogleExtShared`, `GooglePrintRecommendationService`, `DocumentsUIGoogle`, `TagGoogle`
    - Phonesky, `GoogleServicesFramework`, `PrebuiltGmsCoreVic_*`, `SetupWizardPrebuilt_versioned`, `SetupWizardPixelPrebuilt_versioned`, Velvet, `DevicePersonalizationAiAiPrebuiltPixel2025`, `SettingsIntelligenceGooglePrebuilt`, `StorageManagerGoogle`, TurboAdapter, etc.
    - `GoogleDialer`, `PrebuiltBugle` and `com.google.android.dialer.support` unless `WITH_GMS_COMMS_SUITE=false`
    - `AICorePrebuilt-aicore_20260302.01_RC00` only if `WITH_GMS_AICORE=true`

    — server `vendor/pixel/gms/common/common-vendor.mk:85-203`
  - Copy files:
    - `product/etc/default-permissions/` default-permissions.xml, -safetyhub.xml and -com.google.android.apps.pixel.agent.xml
    - `product/etc/sysconfig/` google.xml, google_build.xml, nexus.xml, nga.xml, google-hiddenapi-package-whitelist.xml, google-staged-installer-whitelist.xml, contextual_search.xml, game_service.xml, allowed_apex_com.google.android.gmssystem.xml, and pixel_experience_2017 through 2023 (incl. midyear)
    - `product/etc/permissions/privapp-permissions-google-p.xml`, `system/etc/permissions/privapp-permissions-google.xml`, `system_ext/etc/permissions/privapp-permissions-google-se.xml`
    - `preferred-apps/google.xml`, fsverity certs, and gzipped Chrome, Trichrome and WebView APKs

    — server `vendor/pixel/gms/common/common-vendor.mk`
  - RRO overlays in `common/overlays.mk`, all with a `_GMS` suffix and `*_gms` package names (e.g. `GoogleConfigOverlay_GMS` → `com.google.android.overlay.googleconfig_gms`): `PixelConfigOverlayCommon_GMS`, `PixelConfigOverlay2018/2019Midyear/2021_GMS`, `SystemUIGXOverlay_GMS` (package `...pixelconfig2019_gms`), `FrameworkResOverlay_GMS`, `SettingsOverlay_GMS`, `SystemUIOverlay_GMS`, `TeleServiceOverlay_GMS`, `TelecomOverlay_GMS`, `PixelSetupWizardOverlay2024/Expressive_GMS`, etc. `GoogleSettingsOverlay` has package `com.plus.android.overlay.settings`. — server `vendor/pixel/gms/common/overlays.mk` and AndroidManifest.xml files
  - Soong namespace: `vendor/pixel/gms/common`, added to `PRODUCT_SOONG_NAMESPACES`. — server `common-vendor.mk`, `common/Android.bp:5`
- DerpFest's own zuma tree had to rename 8 overlays "conflicting with vendor/gms" by adding a `Zuma` suffix to module and package names:
  - GoogleConfigOverlay
  - PixelConfigOverlayCommon
  - PixelConfigOverlay2019
  - PixelConfigOverlay2021
  - GlanceableHubConfigOverlay
  - GlanceableHubSettingsConfigOverlay
  - GlanceableHubSettingsConfigOverlay2022
  - GlanceableHubSysuiConfigOverlay

  The commit was made for 16.2, when vendor/gms names may have differed. — [zuma c2a2f62](https://github.com/DerpFest-Devices/device_google_zuma/commit/c2a2f62.diff)
- DerpFest zuma removed `-include vendor/lineage/config/BoardConfigReservedSize.mk` ("We are shipping with gapps"). Lineage's zuma `BoardConfigLineage.mk` also already carries `BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3` and adds `vbmeta_vendor` to `AB_OTA_PARTITIONS`. — [zuma 0d08d79](https://github.com/DerpFest-Devices/device_google_zuma/commit/0d08d79.diff)
- Checks against the husky blobs already on the server (`~/evolution/vendor/google/husky`, remote `TheMuppets/proprietary_vendor_google_husky`):
  - `comm` of PRODUCT_COPY_FILES destinations between `vendor/pixel/gms/common-vendor.mk` and `husky-vendor.mk` finds **no duplicates**.
  - `comm` of Android.bp module names between vendor/pixel/gms and evolution's vendor/google/husky, shusky and zuma finds **one duplicate: `AICorePrebuilt-aicore_20260302.01_RC00`**, defined in both `vendor/pixel/gms` and `vendor/google/husky` (Android.bp and husky-vendor.mk). Both are in separate soong namespaces.

  — server `comm` output
- DerpFest's own `vendor/lineage` also installs files that could overlap Pixel blobs:
  - `common.mk:188`: `product/etc/sysconfig/pixel_2016_exclusive.xml`
  - `common.mk:85`: `system/etc/sysconfig/derpfest-sysconfig.xml`
  - `derpfest.mk:38`: `product/etc/sysconfig/preinstalled-packages-derpfest.xml`
  - `common.mk:18`: the call-recording features XML (`TARGET_CALL_RECORDING_SUPPORTED ?= true`)
  - `derpfest.mk:100`: `system_ext/etc/permissions/android.hardware.biometrics.face.xml` when face unlock is enabled
  - `derpfest.mk:83-84`: `WeatherPixelPrebuilt_10006113` and `default-permissions_pixelweather`

  — server `vendor/lineage/config/common.mk`, `derpfest.mk`

### Inferences
- When LineageOS lineage-24.0 shusky/zuma or TheMuppets husky define overlays with the same Android package or module names as vendor/pixel/gms, expect duplicate-module or overlay-package errors. Re-check zuma's GoogleConfigOverlay / PixelConfigOverlay* against the `_gms` names. DerpFest's 16.2 fix was to suffix the device copies with `Zuma`.
- The AICore duplicate is harmless while `WITH_GMS_AICORE` is unset and the husky blob installs it. If both namespaces export it to Make, or both add it to PRODUCT_PACKAGES, there is a risk of "multiple modules named"/duplicate-install errors. Keep `WITH_GMS_AICORE` unset, or drop the husky copy.
- A device XML with the same destination as a vendor/pixel/gms or vendor/lineage copy-file (e.g. a `product/etc/sysconfig/pixel_experience_2023.xml` added by a device tree) triggers PRODUCT_COPY_FILES override warnings, or an error with `BUILD_BROKEN_DUP_RULES` off. The TheMuppets husky set showed none.

### Gaps
- The LineageOS lineage-24.0 shusky/zuma overlay names weren't compared directly against vendor/pixel/gms, because no lineage-24.0 shusky tree is in ~/derpfest. The comparison above used Evolution's husky tree on the same server.

## Q3. What does DerpFest 17 need from a device's product makefile and BoardConfig? Variables, lunch/target names, OTA naming, Updater JSON, and the kodiak edits

### Takeaway
A LineageOS lineage-24.0 tree builds with DerpFest almost unchanged:
- Keep `PRODUCT_NAME := lineage_husky` and inherit `vendor/lineage/config/common_full_phone.mk`.
- Run `lunch lineage_husky-cp2a-user` then `m derp`.
- The output zip is `DerpFest-v17-<UTCdate>-husky-<Community|Official>-<Stable|Beta>.zip`, plus `husky.json`.

`WITH_GMS := true` is forced in derpfest.mk, so GMS is always included. The DerpFest knobs are listed below. Evolution X knobs (`TARGET_HAS_UDFPS`, `TARGET_INCLUDE_BOOT_ANIMATIONS`, `TARGET_ENABLE_BLUR`) do nothing in DerpFest.

The three kodiak-only edits are needed for these reasons:
1. `PRODUCT_BUILD_IGNORE_APEX_CONTRIBUTION_CONTENTS := true` is needed because vendor/pixel/gms puts `com.google.android.extservices` into PRODUCT_PACKAGES. That turns off AOSP's automatic "this is an AOSP product, ignore Google apex contributions" detection. **husky will need it too.**
2. The TrafficLightFaceOverlay removal is about the Settings face-enrollment overlay versus DerpFest's ParanoidSense face unlock (inferred).
3. The vbmeta_system/vendor `--flags 3` lines have no build-file requirement; they are bring-up consistency (inferred).

### Cited Findings
Build entry points:
- README: `repo init -u https://github.com/DerpFest-AOSP/android_manifest.git -b 17 --git-lfs`, then `. build/envsetup.sh`, then `lunch lineage_$device-cp2a-user`, then `m derp`. The alternative is `derpfest <codename>`. — server `.repo/manifests/README.mkdn` ([upstream](https://github.com/DerpFest-AOSP/android_manifest/tree/17))
- `vendor/lineage/vars/aosp_target_release`: `aosp_target_release=cp2a`. — server
- `derpfest()` sources that file and runs `vendor/lineage/tools/build-derpfest.sh`, which runs `lunch "lineage_${device}-${release}-${variant}"` (line 285) and `make -j${jobs} derp` (line 306). `alias df=derpfest`. — server `vendor/lineage/build/envsetup.sh:786-795`, `build-derpfest.sh:285,306`
- `check_product()` sets `LINEAGE_BUILD` by stripping `lineage_` from the product. The product must be named `lineage_<device>`. — server `envsetup.sh:8-30`
- `build_kernel()` exists in `vendor/lineage/build/envsetup.sh:660`. The inline kernel tasks are `vendor/lineage/build/tasks/kernel.mk` and `dt_image.mk`. `BoardConfigLineage.mk` includes `BoardConfigKernel.mk` (line 7) and `BoardConfigSoong.mk` (line 13). — server

The `derp` target and OTA naming:
- `LINEAGE_TARGET_PACKAGE := $(PRODUCT_OUT)/$(LINEAGE_VERSION).zip`. The rule moves `INTERNAL_OTA_PACKAGE_TARGET` to that path, writes `.sha256sum`, and runs `vendor/lineage/tools/generate_json_build_info.sh`. The target is `.PHONY: derp` / `derp: $(LINEAGE_TARGET_PACKAGE) $(DEFAULT_GOAL)`. — server `vendor/lineage/build/tasks/derp.mk:19-52`
- `version.mk`:
  - `DERPFEST_VERSION := 17`
  - `DERPFEST_BUILD_TYPE` comes from the environment or the makefile via `ifdef`, defaulting to `Community`
  - `ifeq ($(DERPFEST_BETA),false)` gives `Beta`, otherwise `Stable`. **The logic is inverted:** `DERPFEST_BETA=false` produces Beta.
  - `LINEAGE_VERSION := DerpFest-v$(DERPFEST_VERSION)-$(shell date +%Y%m%d)-$(LINEAGE_BUILD)-$(DERPFEST_BUILD_TYPE)-$(DERPFEST_BUILD_VARIANT)`
  - props `ro.derpfest.version`, `.display.version`, `.build.version`, `.build.variant` and `.releasetype`

  The result is `DerpFest-v17-YYYYMMDD-husky-Community-Stable.zip`. — server `vendor/lineage/config/version.mk:2-32`
- The official 16.x naming matches, e.g. `DerpFest-v16.2-20260612-husky-Official-Stable.zip`. — [SourceForge](https://sourceforge.net/projects/derpfest/files/husky/)
- `generate_json_build_info.sh`:
  - device = field 4 of the filename split on `-`
  - reads `out/target/product/<device>/system/build.prop` for `ro.build.date.utc`
  - version = field 2 (`v17`)
  - romtype = "Official" if the filename contains "Official", otherwise "Community"
  - url = `https://sourceforge.net/projects/derpfest/files/<device>/<file>/download`
  - writes `{"response":[{"datetime","filename","id"(sha256),"romtype","size","url","version"}]}` to `out/target/product/<device>/<device>.json`

  — server `vendor/lineage/tools/generate_json_build_info.sh:20-66`

Updater:
- `updater_server_url` = `https://raw.githubusercontent.com/DerpFest-AOSP/Updater-Stuff/master/{device}.json`, and `device_info_url` = `.../info/device-info.json`. — server `packages/apps/Updater/app/src/main/res/values/strings.xml:25-26`
- `NetworkUpdateResponse{response: List}` with fields `datetime: Long`, `filename`, `id`, optional `romtype`, `size: Long`, `url` and `version` (`@JsonIgnoreUnknownKeys`). — server `packages/apps/Updater/app/src/main/java/org/lineageos/updater/data/source/network/NetworkUpdate.kt:20-35`
- Download path `/data/derpfest_updates/`, and an init rc `init.derpfest-updater.rc` is installed. — server `strings.xml:15`, `common.mk:177`

Device-facing DerpFest variables (all read in vendor/lineage or vendor/pixel). The full repo-wide grep found these:

| Variable | Behaviour | Source (server) |
| --- | --- | --- |
| `DERPFEST_BUILD_TYPE` | default Community; set Official for official builds | `version.mk:7-11` |
| `DERPFEST_BETA` | inverted, see above | `version.mk:14-18` |
| `TARGET_SUPPORTS_BLUR` | anything but `false` sets `ro.surface_flinger.supports_background_blur=1` | `derpfest.mk:28-30` |
| `TARGET_INCLUDE_ACCORD ?= true` | adds the Accord package | `derpfest.mk:56-60` |
| `TARGET_SUPPORTS_QUICK_TAP` | anything but `false` adds ColumbusService | `derpfest.mk:87-90` |
| `TARGET_FACE_UNLOCK_SUPPORTED ?= $(TARGET_SUPPORTS_64_BIT_APPS)` | true adds ParanoidSense, `ro.face.sense_service=true` and `android.hardware.biometrics.face.xml` in system_ext; otherwise adds `SettingsGoogleFutureFaceEnroll` | `derpfest.mk:93-104` |
| `WITH_GMS := true` | hard-set, plus `DONT_DEXPREOPT_PREBUILTS := true` | `derpfest.mk:107-110` |
| `WITH_GMS_COMMS_SUITE` | `false` drops Google Dialer/Messages | `common-vendor.mk` |
| `WITH_GMS_AICORE` | true adds AICore | `common-vendor.mk` |
| `TARGET_DOES_NOT_SUPPORT_GOOGLE_BATTERY ?= true` | | `gms.mk:18` |
| `TARGET_IS_TABLET` | | `gms.mk:36` |
| `TARGET_CALL_RECORDING_SUPPORTED ?= true` | | `common.mk:15` |
| `TARGET_EXCLUDE_BACKUPTOOL` | | `common.mk:52` |
| `TARGET_DISABLE_LINEAGE_SDK` | | `common.mk:107` |
| `TARGET_DISABLE_EPPE` | | `common.mk:154` |
| `TARGET_DISABLE_FASTBOOTD` | | `common.mk:213` |
| `TARGET_SCREEN_WIDTH` / `TARGET_SCREEN_HEIGHT` | boot animation size | `vendor/lineage/bootanimation/Android.mk:15-16` |

- `TARGET_PRODUCT` filter list for `LMODroidEdgeCutout`: Pixels in it are tokay, caiman, komodo, but not husky. — server `derpfest.mk:62-64`
- `derpfest.mk` is inherited from `common.mk:3`, after `vendor/extra/product.mk` (line 2). `vendor/lineage-priv/keys/keys.mk` is `-include`d at `common.mk:346`. — server
- Not present anywhere in vendor/lineage, vendor/overlay, vendor/pixel/{clocks,themepicker}, DerpFestParts res or DerpFestCustomizations: `TARGET_BOOT_ANIMATION_RES`, `ro.derpfest.maintainer`, `TARGET_HAS_UDFPS`, `TARGET_USES_PICO_GAPPS`, `TARGET_INCLUDE_BOOT_ANIMATIONS`, `TARGET_ENABLE_BLUR`. — server grep, no hits
- Signing: on non-eng builds, if `vendor/lineage/signing/keys/releasekey.pk8` exists it sets `PRODUCT_DEFAULT_DEV_CERTIFICATE`. If `otakey.x509.pem` exists it sets `PRODUCT_OTA_PUBLIC_KEYS`. — server `derpfest.mk:128-137`
- On the server, `vendor/lineage-priv/keys/keys.mk` sets `AVB_CUSTOM_KEY_PATH := vendor/evolution-priv/keys/avb.pk8`, `AVB_CUSTOM_ALGORITHM := SHA256_RSA4096`, `WITH_AVB ?= false` and `PRODUCT_CERTIFICATE_OVERRIDES` (`vendor/evolution-priv` is a symlink to `lineage-priv`). The kodiak BoardConfig consumes them for all AVB keys (`BoardConfig.mk:175-201`). — server

The three uncommitted DerpFest-only kodiak edits (`git diff` in `device/google/kodiak`; HEAD 6e108f1 2026-10-16):

1. **`lineage_kodiak.mk:40` `PRODUCT_BUILD_IGNORE_APEX_CONTRIBUTION_CONTENTS := true`.**
   - `build/make/core/product_config.mk:300-321` auto-sets this to true only when PRODUCT_PACKAGES contains none of `com.google.android.conscrypt%`, `com.google.android.go.conscrypt%`, `com.google.android.extservices%` or `com.google.android.go.extservices%` (comment: "aosp products do not use google signed apexes", TODO b/308187268).
   - vendor/pixel/gms adds `com.google.android.extservices` to PRODUCT_PACKAGES (`common-vendor.mk` ~line 124), so DerpFest products lose the auto-detection.
   - Without the setting, Soong honours the `contents` of the release config's apex_contributions (`RELEASE_APEX_CONTRIBUTIONS_*` declared in `build/release/flag_declarations/`). It also adds `RELEASE_APEX_BOOT_JARS_PREBUILT_EXCLUDED_LIST` to `APEX_BOOT_JARS_EXCLUDED` (`build/make/core/art_config.mk:30-37`), which assumes Google mainline prebuilts the tree doesn't have.
   - The value goes to Soong as `BuildIgnoreApexContributionContents` (`soong_config.mk:345`).
   - Evolution X kodiak didn't need it. LineageOS/Evolution trees without PixelOS GMS keep the AOSP auto-detection.
2. **`BoardConfig.mk:208-209` `BOARD_AVB_MAKE_VBMETA_SYSTEM_IMAGE_ARGS += --flags 3` and `BOARD_AVB_MAKE_VBMETA_VENDOR_IMAGE_ARGS += --flags 3`** (inside `ifneq ($(WITH_AVB),true)`, next to the existing top-level `BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3`).
   - kodiak chains `BOARD_AVB_VBMETA_SYSTEM := system system_dlkm system_ext product` (line 183) and `BOARD_AVB_VBMETA_VENDOR := vendor` (line 194), with separate key paths.
   - `build/make/core/Makefile:5153-5190,5287-5305` builds the chained images, and `6238-6247` records `avb_vbmeta_system_args` / `avb_vbmeta_vendor_args` into target-files `misc_info`. The OTA/target-files re-sign then reuses those args.
   - The 2026-10-19 build log shows the vbmeta_system, vbmeta_vendor and vbmeta images regenerated during packaging with the evolution-priv AVB key. — server `~/derp-build.log`
   - No DerpFest build file requires these lines. DerpFest's `vendor/lineage` and `build/make` contain no AVB or vbmeta settings (grep empty), and DerpFest build/make's AVB-related history (e.g. `fd2140b696 core: Correct system_dlkm AVB rollback index flag`, `e5e5680d04 sign_target_files_apks: Fix avbtool usage`) doesn't mandate flags on chained vbmeta.
   - LineageOS zuma's BoardConfigLineage.mk already sets top-level `--flags 3` and `vbmeta_vendor` ([zuma 0d08d79](https://github.com/DerpFest-Devices/device_google_zuma/commit/0d08d79.diff)).
3. **`proprietary-files.txt` `# product/overlay/TrafficLightFaceOverlay.apk;MAKE_COPY_RULE_ONLY`.**
   - The blob exists at `vendor/google/kodiak/proprietary/product/overlay/TrafficLightFaceOverlay.apk`.
   - Its manifest shows `package com.google.android.overlay.trafficlightfaceoverlay`, `targetPackage com.android.settings`, `isStatic`, and a resource table plus `res/raw/face_education_lottie.json`. It is Google's Settings face-enrollment and education overlay. — server `unzip -l` / `strings` of the APK
   - DerpFest defaults `TARGET_FACE_UNLOCK_SUPPORTED` to true on 64-bit, so it ships ParanoidSense with `ro.face.sense_service=true` instead of Google face (`derpfest.mk:93-100`).
   - No other file references TrafficLightFace (the only grep hit is inside the Maps APK). husky's TheMuppets vendor makefile has no TrafficLightFaceOverlay entry (grep empty).
- None of the three edits were explained in the server logs: `out/error*.log` and verbose logs only show a separate BCR `enforce_uses_libraries` failure. The local HANDOFF.md only records that they exist (`evolution-kodiak/HANDOFF.md:1820`). — server `out/`; local `/Users/densond/Developer/ExpressiveOS/evolution-kodiak/HANDOFF.md:1820`

Artifact-path rules:
- kodiak's `lineage_kodiak.mk` inherits `generic_system.mk` with `PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed`.
- Its `PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST` covers AppDataBackup and the `system/` GMS apps: `system/app/GoogleExtShared`, `GooglePrintRecommendationService`, `system/priv-app/DocumentsUIGoogle`, `GooglePackageInstaller` and `TagGoogle`. The comment says it is "Same allow-list as device/google/shusky (husky)".
- DerpFest's vendor/pixel/gms installs `GoogleExtShared`, `GooglePrintRecommendationService`, `DocumentsUIGoogle` and `TagGoogle`, and writes `system/etc/permissions/privapp-permissions-google.xml`.

— server `device/google/kodiak/lineage_kodiak.mk:7-32`, `vendor/pixel/gms/common/common-vendor.mk`

### Inferences
- **For husky on DerpFest 17:**
  1. Keep `PRODUCT_NAME := lineage_husky` and the `common_full_phone.mk` inherit.
  2. Add `PRODUCT_BUILD_IGNORE_APEX_CONTRIBUTION_CONTENTS := true`. This is needed for the same reason as kodiak, since it is caused by vendor/pixel/gms rather than the device.
  3. If the husky product inherits `generic_system.mk` / artifact-path enforcement as the Lineage Pixel trees do, the allow-list must cover vendor/pixel/gms's /system apps and `system/etc/permissions/privapp-permissions-google.xml`.
  4. Leave `DERPFEST_BUILD_TYPE` unset (Community) for an unofficial build.
  5. Set `TARGET_SCREEN_WIDTH := 1344` and `TARGET_SCREEN_HEIGHT := 2992` (same as DerpFest 16.2 husky).
  6. Evolution-only variables can stay; they are inert.
- `TARGET_FACE_UNLOCK_SUPPORTED` matters more on husky than on kodiak. Pixel 8 Pro has Google's Class-3 face unlock, so leaving it at its default (true) replaces Google face with ParanoidSense. Setting `TARGET_FACE_UNLOCK_SUPPORTED := false` installs `SettingsGoogleFutureFaceEnroll`, which is the path to keep Google face. The TrafficLightFaceOverlay question depends on this choice: with ParanoidSense the Google Settings face overlay is probably wrong or broken and is best dropped, as on kodiak. With Google face it should probably be kept. This is inferred; there is no log of the original failure.
- The vbmeta_system/vendor `--flags 3` lines look like a consistency choice: AVB honours flags only from the top-level vbmeta. That top-level `--flags 3` already comes from Lineage zuma's BoardConfigLineage.mk for husky. They are safe to copy to husky, but nothing in the DerpFest build requires them. If husky's BoardConfig doesn't chain vbmeta_system/vendor with its own keys, they aren't needed at all.
- TheMuppets husky blob paths showed no PRODUCT_COPY_FILES destination clashes with vendor/pixel/gms (Evolution's husky vendor was used as a proxy). The remaining collision risks are overlay module and package names in shusky/zuma (see DerpFest zuma c2a2f62) and the AICore module.

### Gaps
- No preserved build log shows the exact error that led to each kodiak edit. The APEX explanation is derived from build files. The face overlay and vbmeta reasons are inference.
- Telegram groups and XDA threads about DerpFest Pixel 8/8 Pro build errors on 16/17 couldn't be searched effectively. A web search for DerpFest husky returned only the aggregator, and an XDA-targeted search returned nothing relevant. No reliable public discussion of DerpFest shiba/husky/zuma build errors was found.
