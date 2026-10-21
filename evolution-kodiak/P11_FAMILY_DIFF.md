# Pixel 11 family: grizzly and cubs vs kodiak (stock CD1A.261005.003)

Compared 2026-10-12 to see how much of the kodiak tree carries over to the
Pixel 11 Pro (**grizzly**) and the Pixel 11 (**cubs**, not "cub"). All three
factory images are the same October build (CD1A.261005.003, build 16262255),
verified against Google's SHA-256.

Server (build@157.180.50.152):
- factory zips and inner image zips: `~/android-dt/firmware/`
- dumpyara dumps, made the same way as kodiak's: `~/android-dt/dumps/{grizzly,cubs}`
- full report: `~/android-dt/p11-diff/report.txt` (details in `detail/`)
- scripts (copies in `tools/`): `~/dl-p11.sh` (download and verify),
  `~/p11-dump.sh <dev>` (unpack and dumpyara), `~/p11-diff.sh` (the report),
  `~/p11-certs.sh` (APK signers and contents per phone)

## Identical on all three

| Area | Result |
|---|---|
| Bootloader and radio | Same versions (spacecraft-17.4-16262255, a900a-MP_260716). `android-info.txt` names `kodiak\|kodiak_2\|grizzly\|grizzly_2\|cubs\|yogi`, so the bootloader is shared |
| Kernel | `boot.img` kernel is byte-identical. Only the AVB props differ (the fingerprint names the device) |
| Kernel modules | vendor_kernel_boot 198, vendor_dlkm 123, system_dlkm 72, with identical module lists |
| Kernel cmdline and bootconfig | Identical, so `BOARD_KERNEL_CMDLINE` and `BOARD_BOOTCONFIG` carry over |
| Partitions | `super_empty.img` is identical (same super and group sizes). boot, init_boot, vendor_boot, dtbo and pvmfw have the same sizes |
| Firmware list | Every partition in `firmware.txt` exists in both image zips |
| vendor_boot ramdisk | `fstab.malibu`, `init.recovery.malibu.rc`, both `usb_phy_fw*.bin` and both recovery HALs are identical. `init.recovery.<dev>.rc` is the same apart from the name. No dtb in vendor_boot (it lives in the per-device stock vendor_kernel_boot) |
| SELinux | `check-sepolicy.sh` with our current kodiak build's system policy **compiles OK against both stock vendor policies** |
| Telephony | CarrierSettings (624 files) identical. TeleService RRO identical. The modem image is identical |
| Blob contents | Every APK in both `proprietary-files.txt` lists has **identical contents** (non-META-INF entries) and the same versionCode on all three phones |

## Differences

**grizzly is the same hardware as kodiak** apart from the screen. Same HALs, same
APK set (289), and an identical framework-res RRO. Only these differ:
- Screen: 1080x2410 default mode (kodiak 1080x2404), density 480
- Vibrator calibration (vendor props)
- `bluetooth.device_id.product_id` 16667 (kodiak 16668), model strings

**cubs has fewer features:**
- No UWB (no `IUwb` HAL, no UWB overlays), no notification light (no `ILights` HAL, `vendor.google.lights-service` and the `notificationPriorityLight*` framework resources), no CccDkTimeSyncService (digital car key)
- Different Wi-Fi overlay (`PixelWifiOverlay2026_4383`), Synaptics touch firmware
- Screen 1080x2424, density **420**, a "lite" VRR display variant
- No LE Audio software offload props (`persist.bluetooth.leaudio_sw_offload`, `persist.vendor.audio.leaudio_sw_offload`); `persist.bluetooth.thread_dispatcher.enabled=false`
- `bluetooth.device_id.product_id` 16666, `ro.gms.dck.eligible_wcc=2` (kodiak 3)
- Stock vendor sepolicy differs only by the light HAL and cccdktimesync rules. The stock system_ext policy differs only by cccdktimesync. We ship neither.

## Two things that would break a naive port

1. **Per-device signing keys.** The blob *contents* match, but each phone's
   stock image signs some APKs with its own platform key (and a second
   per-device key):
   - **Platform key:** CarrierSetup, EuiccGoogleOverlay, PixelImsMediaService, PixelQualifiedNetworksService, PixelSatelliteService, VendorImplSatelliteService, PixelDisplayService, PersistentBackgroundCameraServices
   - **Second per-device key:** EuiccSupportPixelPermissions, grilservice, ril-extension, the Hotword apps

   The stock vendor `vendor_mac_permissions.xml` maps only that phone's own
   platform key to `seinfo=platform`. A PRESIGNED app signed with kodiak's key
   would get the wrong SELinux domain on grizzly or cubs. So **extract blobs per
   device** from each phone's own dump. Never share kodiak's vendor tree.

2. **The PixelSystemService mapping.** `sepolicy/system_ext/private/mac_permissions.xml`
   maps a Google key to `seinfo=pixelsystemservice`. That key is **exactly
   grizzly's stock platform certificate**: Evolution X's bundled
   PixelSystemService is signed with grizzly's platform key. The stock grizzly
   vendor policy maps the same cert to `platform`. system_ext loads before
   vendor and the first match wins (`SELinuxMMAC`, duplicates are only
   logged). On a grizzly build, every stock-platform-signed app (CarrierSetup,
   EuiccGoogleOverlay, ...) would get `seinfo=pixelsystemservice` instead of
   `platform`. **For grizzly, drop that signer stanza.** The stock vendor
   mapping plus our existing `seinfo=platform` seapp lines for
   PixelSystemService cover it, as on stock. Keep it for kodiak and cubs.

## What a grizzly/cubs tree needs

- Names: `lineage_<dev>.mk`, `AndroidProducts.mk`, model, `PRODUCT_BUILD_PROP_OVERRIDES` fingerprints, `TARGET_BOOTLOADER_BOARD_NAME`
- `product.prop` / `system_ext.prop` regenerated from that phone's stock (attestation device, quick_start id, BT product id, LE Audio props on cubs)
- Screen: `TARGET_SCREEN_*` for the boot animation. `TARGET_RECOVERY_UI_MARGIN_HEIGHT` can't be checked offline
- `extract-images.sh`: parameterize the device name (`init.recovery.<dev>.rc`, the `image-<dev>-*.zip` check)
- `extract-files.py` run against the phone's own dump (see point 1)
- mac_permissions: per point 2
- Everything else (BoardConfig partitions/cmdline, `firmware.txt`, sepolicy, telephony overlays, recovery, vbmeta props) carries over unchanged

Best layout: a shared `device/google/malibu-common` (or a LineageOS-style
family tree) plus thin per-device trees, with per-device vendor trees.

## Not verifiable without the phones

Booting, calls/IMS, cameras, fingerprint, Wallet/RKP, the recovery UI margin.
Evolution X maintainership also requires owning the device.
