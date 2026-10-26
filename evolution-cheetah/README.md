# Evolution X (Android 17) for the Pixel 7 Pro (cheetah)

> **Unofficial.** Pixel 7 Pro has an official Evolution X maintainer for Android 16 (nhansp, last build
> 11.10 on 2026-08-08). Evolution X hasn't published official Android 17 (`cnb`) cheetah builds yet:
> Evolution-X/OTA `cnb` lists only marble, raphael, tissot and venus. These builds are labelled
> Unofficial, signed with our own keys, and update from `denson9874/evolution_ota`. **When official
> `cnb` cheetah builds appear, drop patch 0002 (the Updater overlay)** so the Updater uses
> Evolution X's servers, and talk to the official maintainer before publishing more.

Unlike the Pixel 11 ports, nothing here is ported: Evolution X's own `cnb` trees build cheetah. This
folder only adds what an unofficial build needs on top.

| Piece | Source |
|---|---|
| `device/google/pantah` | [Evolution-X-Devices/device_google_pantah](https://github.com/Evolution-X-Devices/device_google_pantah) `cnb` (LineageOS's tree, initialised for Evolution X by nhansp and Lunia) |
| `device/google/gs201` | Evolution-X-Devices/device_google_gs201 `cnb` |
| `device/google/pantah-kernels` | LineageOS/android_device_google_pantah-kernels `lineage-24.0` (module lists only) |
| Kernel (Linux 6.1) | Built from source by LineageOS's `build_kernel` into `out-kernel/`, from LineageOS's gs201 kernel manifest |
| `vendor/google/cheetah` | Evolution-X-Devices/vendor_google_cheetah `cnb`: blobs from CP3A.261005.002.A1 (since 2026-10-24; CP2A.260705.006 before), plus bootloader and radio images. **Git LFS** (GitLab, `.lfsconfig`) |
| Firmware the OTA ships | The newest Google factory release, swapped in by `prepare.sh` (see below) |

## Build (on the build server)

One-time setup (the runner's `cheetah-setup` action does this):

```bash
cd ~/evolution
cp /path/to/evolution-cheetah/local_manifests/cheetah.xml .repo/local_manifests/
repo sync -c -j4 --no-tags --no-clone-bundle \
    device/google/pantah device/google/gs201 device/google/pantah-kernels vendor/google/cheetah
cp -r /path/to/evolution-cheetah ~/evolution-cheetah        # prepare.sh, apply.sh, patches
cp ~/evolution-cheetah/tools/cheetah-{images,pack}.sh ~/
~/evolution-cheetah/fetch-firmware.sh                       # newest factory bootloader + radio
```

Each build:

```bash
~/cheetah-images.sh > ~/cheetah-build.log 2>&1   # prepare.sh, lunch lineage_cheetah-cp2a-user, build_kernel, m evolution
~/cheetah-pack.sh                                # verify + fastboot zip in ~/releases/cheetah/check (--upload: in ~/releases/cheetah, and published)
~/p11-ota.sh cheetah                             # verify the signed A/B OTA (add --upload to publish it and the Updater JSON)
```

The weekly routine runs all of that: `~/p11-routine.sh cheetah` (see "Release schedule").

## What `prepare.sh` does (every build, idempotent)

1. Checks that `vendor/google/cheetah`'s Git LFS objects are real files (`git lfs pull` if they're
   pointers). Without LFS the radio images are 130-byte pointer files.
2. `apply.sh`: our patches, as local commits (same convention as `evolution-husky/apply.sh`):

   | Project | Patch | Change |
   |---|---|---|
   | device/google/pantah | `0001` | Settings > About maintainer: "Daryl Denson (Unofficial)" instead of the official Android 16 maintainer |
   | device/google/pantah | `0002` | `UpdaterOverlayCheetah`: the Updater reads `denson9874/evolution_ota` (as the Pixel 11 trees' `UpdaterOverlay<Dev>`) |
   | device/google/pantah | `0003` | `lineage_cheetah.mk` allow-lists Evolution X's AppDataBackup in /system, which generic_system.mk's artifact-path check otherwise rejects (soong_build stops). Same fix as husky's shusky `0001` |
   | device/google/pantah | `0004` | Installs SCONE (Adaptive Connectivity) and Tycho (Google Fi): vendor/gms defines both, but gms_full.mk's PRODUCT_MANUFACTURER gate never matches under inherit-product. As kodiak's device.mk |
   | device/google/pantah | `0005` | `NfcOverlayCheetah`: NFC on after a clean flash (LineageOS's NfcOverlay turns it off), plus stock's URL-open dialog for three carriers. As kodiak e016d25 |
   | device/google/pantah | `0006` | `disable-google-ota.xml`: Play services doesn't prepare Google's OTAs, which armed resume-on-reboot and made the first unlock after a reboot ask for the PIN twice. As kodiak |
   | device/google/pantah | `0007` | App odex on /system, not system_other (179 MB): an OTA never writes system_other, so SystemUIGoogle and Settings lost their AOT code after every update. As husky's shusky `0003` |
   | device/google/gs201 | `0003` | PinnerService pins `SystemUIGoogle.apk` (the SystemUI we ship) instead of a non-existent `SystemUI.apk` |
   | device/google/gs201 | `0005` | Keeps `app_domain(ssr_detector_app)` in private policy: Evolution's rebased gs201 put it in system_ext/public, and its type_transition rules stop version_policy (`plat_pub_versioned.cil`) |
   | device/google/gs201 | `0004` | Doesn't install LineageOS's 2022 `allowlist_com.google.android.as.xml`: it restricted Private Compute Services to ASI, which stock CP3A doesn't |
   | device/google/pantah | `0008` | Stock values our build left at the AOSP default, copied from stock CP3A.261005.002.A1's overlays by `rro2xml.py` (camera pinning, Play Store pre-reboot compile, operator name after carrier config, Play Protect events, screenshot editor/Files/Quick Share copy, avatar picker, Settings slices, 5 GHz Wi-Fi thresholds, prefer-bad-Wi-Fi, Photos in the photo picker) |
   | device/google/gs201 | `0001` | Drop gs201's nine Pixel config overlays that `vendor/pixel-style` also defines (GlanceableHub*, GoogleConfigOverlay, PixelConfigOverlay*, ...); Kati fails on the duplicate module names. Same as husky's zuma `0001` |
   | device/google/gs201 | `0002` | Install gs201's `default-permissions.xml` as `default-permissions-gs201.xml`; vendor/gms installs its own (different) `default-permissions.xml`. Same as husky's zuma `0002` |
   | vendor/google/cheetah | `0001` | Defer `DeviceIntelligenceNetworkPrebuiltAstrea` (vendor/gms's is newer) and 15 byte-identical Pixel sysconfig/default-permission XMLs (google_build.xml and nowplaying_app_26q1.xml included) to vendor/gms. Same as husky's vendor `0001` |
   | vendor/google/cheetah | `0003` | One Android System Intelligence: the Pixel 7 Pro build (`...Pixel2022`) also overrides vendor/gms's Pixel 11 build (`...Pixel2026`; its override named the old `...Pixel2025`) |
   | device/google/pantah | `0009` | Stock's TrustTokenService root keys, which gs201 `0001` dropped with the tree's GoogleConfigOverlay |
   | vendor/google/cheetah | `0002` | Don't install `gpuflag` (+ its rc and library): our policy has no `gpuflag` domain, so init's child aborted at every boot, and it targets another SoC's GPU anyway. Same as husky's vendor `0003` |

3. Firmware: Pixels refuse bootloader downgrades, and the OTA flashes the bootloader and radio. So the
   OTA must never carry firmware older than what users run. `fetch-firmware.sh` downloads the newest
   generic Android 17 cheetah factory image from developers.google.com, checks Google's SHA-256, and
   keeps its bootloader and radio images in `~/android-dt/firmware/cheetah/` (`CURRENT` holds the
   build id). `update-firmware.sh` unpacks them with the tree's `fbpacktool` into
   `vendor/google/cheetah/radio/`, rewrites the sha1s in its `Android.mk`, records the release in
   `FIRMWARE_SOURCE`, and commits locally. It's skipped if the cached release is older than what the
   vendor repo already ships.

`repo sync` drops the local commits; `prepare.sh` puts them back. Run `fetch-firmware.sh` when Google
ships a monthly release (`--check` only reports the newest one).

**Where the factory image link comes from:** Google now shows the per-device tables only after a visitor
accepts its terms of use, so the script can't read them unattended. A person opens
https://developers.google.com/android/images#cheetah, accepts the terms, and copies the newest generic
Android 17 release (no carrier suffix) into `firmware.conf`:

```
url=https://dl.google.com/dl/android/aosp/cheetah-<build>-factory-<8 hex>.zip
sha256=<the 64-hex SHA-256 from the same row>
```

Commit it, run the runner's `cheetah-setup` (installs the kit) and `cheetah-firmware`. Without
`firmware.conf` the script still tries Google's page, and says what it saw if that fails.

## Shared patches

`device/google/kodiak/apply-patches.sh` patches shared projects (build/make, frameworks/base,
system/memory/lmkd, vendor/gms, vendor/lineage) for every build from this tree, cheetah's included.
None of them depends on the Pixel 11:

- frameworks/base `0011`-`0020` (2026-10-26) stop SystemUI animations that ran forever with the
  screen off or on AOD. The big one was the face unlock scan pulse on an icon copy that's never on
  screen: on this phone SystemUI went from 11% of a core to 2% on AOD, and SurfaceFlinger from 16-18%
  to 0.7%. vendor/lineage `0002` restores stock's 60 fps game default.

- The Extreme Charging tile hides itself where the power HAL has no BODEGA hint, as on cheetah (no
  charge-thermal profile yet: it changes charging temperature limits on a phone that runs warm, so it
  needs a supervised charge test first).
- The lmkd fix only matters with an in-kernel LMK.
- The Dreamliner list only names Pixel 11 devices.

## Release schedule

`p11-routine.sh` and `p11-ota.sh` know cheetah:

- **Sync:** the Pixel 11 runs fetch cheetah's projects but never check them out or count them in their
  state. Cheetah runs check them out (dropping the previous local commits) and run `prepare.sh`
  before computing the state.
- **State:** the repo projects plus `vendor/evolution-priv/keys` and a hash of `~/evolution-cheetah`.
  New firmware changes `vendor/google/cheetah`'s tree, so it triggers a build.
- **No Espada:** the Espada kernel is only for the Pixel 11.
- **OTA checks:** the expected partitions come from the build's own `META/ab_partitions.txt`. gs201
  chains boot and system, so their patch levels are read from `boot.img` and `vbmeta_system.img`.
- **Names:** no `-UNTESTED` tag (Daryl, 2026-10-19), as grizzly/cubs/yogi.
- **Weekly task:** `evox-parity-cheetah` on the Mac (`evox-parity-cheetah.SKILL.md`), Sundays after
  the four Pixel 11 runs. It only starts `~/p11-routine.sh cheetah` and reports.

## Before the first public release

- The first build must pass `cheetah-pack.sh` and `p11-ota.sh cheetah` without `--upload`.
- Daryl decides the first upload, the XDA thread (the Pixel 7 Pro forum) and the Telegram post. Then
  set `FORUM` for cheetah in `p11-ota.sh` to the thread's URL.
- Ideally a tester boots it once, so `-UNTESTED` can be dropped.
