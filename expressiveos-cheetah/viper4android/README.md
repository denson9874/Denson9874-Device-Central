# ViPER4Android RE for ExpressiveOS (cheetah)

Public ExpressiveOS builds for the Pixel 7 Pro ship ViPER4Android RE built in (Daryl, 2026-10-26,
"Ship it built in"): the unmodified upstream app as a privileged system app, and the upstream 64-bit
effect driver in `/vendor/lib64/soundfx`. Nothing is rebuilt or re-signed. Credits and the exact
sources go with every release.

This folder is only the ViPER4Android part of the ExpressiveOS kit. It works on the ExpressiveOS tree
(`~/expressiveos`), and only for a phone whose `../devices/<device>.conf` has `EOS_V4A=1`: cheetah
alone ("Other phones", below). **None of it applies to the Evolution X tree**
(`~/evolution`, which also builds kodiak and husky): `apply-v4a.sh` refuses any tree whose path ends
in `/evolution` or that is `~/evolution`, and any `vendor/extra` or `frameworks/av` that leads out of
the tree or into `~/evolution` through a symlink; `tools/v4a-check.sh tree` fails on the same.

## What ships

| On the phone | What it is | Source |
|---|---|---|
| `/system_ext/priv-app/ViPER4Android/ViPER4Android.apk` | ViPER4Android 2.1.1 (`com.llsl.viper4android`), byte for byte, signed by upstream | [likelikeslike/ViPER4Android](https://github.com/likelikeslike/ViPER4Android) release `2.1.1` |
| `/system_ext/etc/permissions/privapp-permissions-com.llsl.viper4android.xml` | Grants `MODIFY_AUDIO_ROUTING`, the app's only privileged permission | this kit |
| `/system_ext/etc/sysconfig/hiddenapi-com.llsl.viper4android.xml` | Lifts hidden-API restrictions for the app | this kit |
| `/vendor/lib64/soundfx/libv4a_re.so` | The driver, `common/files/libv4a_re_arm64-v8a.so` from the **non-AIDL** module zip, unstripped | [likelikeslike/ViPERFX_RE](https://github.com/likelikeslike/ViPERFX_RE) release `v2.1.1` |
| Licence texts in the vendor and system_ext NOTICE files | GPL-3.0 (app), the zip's GPL-2.0, `NOTICE.viperdsp`, `NOTICE.pffft` | `tree/Android.bp` license modules |

Why it is put together this way:

- **No `audio_effects.xml` change.** Evolution X's `frameworks/av` (`cnb`, commit 468ace0 by rmp22)
  loads ViPER by itself: `loadViperEffect()` in `media/libeffects/factory/EffectsFactory.c` (paths at
  lines 71-77, called from `init()` at 492, body at 642-748) dlopens
  `/vendor/lib64/soundfx/libv4a_re.so` after the XML config and registers library `v4a_re` with effect
  `90380da3-8536-4744-a6a3-5731970e640f`. libeffects is a vendor library that cheetah builds from
  source and the HIDL effect HAL links. Adding the module's XML lines too would register it twice.
- **The non-AIDL driver.** cheetah's effect HAL is HIDL `android.hardware.audio.effect@7.0`
  (gs201 `vintf/manifest.xml`), and nothing in the gs201, pantah or vendor trees declares the AIDL
  `IFactory`.
- **64-bit only.** `android.hardware.audio.service` is arm64, so only the lib64 path is ever loaded.
  That is not because of `core_64_bit_only.mk` (it only makes zygote and apps 64-bit; gs201 still
  has `TARGET_2ND_ARCH := arm`), and the service's own defaults ask for `prefer32`
  (`android_hardware_audio_config_defaults` in hardware/interfaces, unless `android_hardware_audio`
  `run_64bit` is set). It is because gs201's `BoardConfig-common.mk:20` sets
  `IGNORE_PREFER32_ON_DEVICE := true`, which turns `prefer32` into the first (arm64) arch (Soong
  `android/arch.go:995-999`). `tree` fails if that flag goes.
- **A presigned system_ext priv-app.** The APK targets SDK 37 and is v2-signed, so Soong takes it
  `preprocessed` and copies it unchanged (`java/app_import.go:510-520`). Users can install newer
  GitHub releases over it (same certificate). `privileged` + the privapp XML give it
  `MODIFY_AUDIO_ROUTING`, which makes the default Per-App mode work without root.
- **The hidden-API sysconfig.** The app uses a `@hide` `AudioEffect` constructor and `@SystemApi`
  playback getters. On the `hidden-api-whitelisted-app` list it has no hidden-API restrictions at all,
  whatever its own unsealing does on Android 17.
- **Wired in through `vendor/extra/product.mk`.** Evolution X checks its `vendor_evolution` out at
  `vendor/lineage` (manifest `snippets/evolution.xml:146`), and its `config/common.mk` line 2 (`cnb`
  e717ec3), so `vendor/lineage/config/common.mk`, is
  `$(call inherit-product-if-exists, vendor/extra/product.mk)`, for every product in the tree
  (`lineage_cheetah.mk` inherits `vendor/lineage/config/common_full_phone.mk`, which leads there). In the ExpressiveOS tree that is every phone it builds, and `vendor/extra` isn't a repo
  project, so `repo sync` leaves it alone. `tree/viper4android.mk` adds the namespace and the two
  packages, for `lineage_cheetah` only.
- **No sepolicy.** The library gets `vendor_file` from the generic `/vendor(/.*)?` rule, has no
  TEXTREL or writable-executable segment, and the HIDL path needs no binder service.

## Other phones

The ExpressiveOS tree builds every phone in `../devices/` (`EOS_DEVICE`, cheetah unless set), and
`vendor/extra/product.mk` is read for all of them, so after one cheetah run every product inherits
`viper4android.mk`. Only cheetah has `EOS_V4A=1`: the non-AIDL driver needs gs201's HIDL effect HAL,
husky's effect HAL is AIDL, and the Pixel 11s' stock vendor images have no HIDL one. So:

- `tree/viper4android.mk` adds its namespace and packages only when `TARGET_PRODUCT` is
  `lineage_cheetah`. The other products get nothing from it, whatever a cheetah run staged in
  `vendor/extra` (`../tools/eos-images.sh` checks their `PRODUCT_PACKAGES` before building, and
  `../tools/eos-verify.sh` that none of the files shipped).
- `apply-v4a.sh` for a phone with `EOS_V4A=0` touches nothing and ends with
  `V4A_APPLY=OK skipped (ViPER4Android is off for <device>)` (`eos-images.sh` doesn't run it then).
- `tools/v4a-check.sh` is only for an `EOS_V4A=1` phone. `tree` checks gs201 and the phone's own
  `EOS_DEVICE_TREE` and `EOS_VENDOR_DIR`, `device` wants the phone's own `ro.product.device`, and
  `out` checks the product out it's given; for cheetah that's device/google/pantah,
  vendor/google/cheetah and cheetah, as always.
- A phone with gs201's HIDL effect HAL may be added: `EOS_V4A=1` in its devices file, its
  `lineage_<device>` in `viper4android.mk`'s filter, then the `out` and `device` checks on its first
  build (everything above was established on cheetah).

## Files

| File | What it does |
|---|---|
| `v4a.conf` | The pins (below), sourced by every script |
| `fetch-v4a.sh [--out <dir>]` | Downloads the APK, the app's LICENSE and the driver zip into `~/android-dt/v4a/` (`V4A_CACHE` overrides it) and checks them: sizes and SHA-256, the APK's package, version, v2 signer, permissions and uses-library tags (`tools/apk-info.py`, no build tools needed), then extracts only the arm64 library and LICENSE (`unzip -j`) into a fresh temporary folder and checks those. A download is renamed into the cache only once it matches; a cached file that doesn't match is deleted. `V4A_OFFLINE=1` never downloads. With `--out`, the four verified files appear in `<dir>` only when everything passed. Last line `V4A_FETCH=OK app=2.1.1 fx=v2.1.1` |
| `apply-v4a.sh [top]` | Default `~/expressiveos`. Fetches, stages `tree/` and the verified files into `vendor/extra/viper4android` (removes `Android.bp` first, copies the rest, writes `Android.bp` last only when every copy worked, and removes files the kit no longer ships), adds `$(call inherit-product, vendor/extra/viper4android/viper4android.mk)` to `vendor/extra/product.mk` if that line isn't there at the top level (creating the file if needed; it fails if the line is only inside an `ifeq`/`ifdef`/`define` block), puts `patches/frameworks_av/` in with `lib.sh`'s `am_patches`, as `apply.sh` does the tree's own patches (on ExpressiveOS's manifest, frameworks/av is ExpressiveOS's `frameworks_av` fork, which has both as commits: they're only checked, and a missing one or one changed in place fails; on another manifest they're local commits, `git am --3way`, skipping a patch whose subject is already in the log; it refuses to start while frameworks/av has a `git am` or rebase in progress, aborts only its own `am` on a conflict, and fails if `git am` makes no commit because the change is already there), then runs `tools/v4a-check.sh tree`. A second run changes nothing. Last line `V4A_APPLY=OK ...` |
| `tree/` | What lands in `vendor/extra/viper4android`: `Android.bp`, `viper4android.mk`, the two XMLs, `NOTICE.viperdsp`, `NOTICE.pffft` and a `README.md` with the sources and credits |
| `patches/frameworks_av/` | The two fixes below |
| `tools/v4a-check.sh` | `tree`, `out` and `device` checks (below). Every check prints `PASS`, `FAIL` or `INFO`; all of them run; exit 1 on any `FAIL`; last line `V4A_CHECK=OK` or `V4A_CHECK=FAIL` |
| `tools/apk-info.py`, `tools/v4a-xml.py`, `tools/mk-line.awk` | Helpers for the scripts above (the Python ones run with `python3 -I`; `mk-line.awk` says whether `product.mk` has the inherit line at the top level) |

## How to run

On the build server, with the kit copied to `~/expressiveos-cheetah` (the KernelSU Next part sits next
to it in `ksu/`):

```bash
K=~/expressiveos-cheetah/viper4android
$K/fetch-v4a.sh                          # after every change to v4a.conf (downloads once, then uses the cache)
$K/apply-v4a.sh ~/expressiveos           # every build: after repo sync and the tree's own patches, before lunch
# build as usual, then, before packing anything:
$K/tools/v4a-check.sh out ~/expressiveos/out/target/product/cheetah ~/expressiveos/out/host/linux-x86
# on a test phone with the build flashed, after a reboot:
$K/tools/v4a-check.sh device
```

`apply-v4a.sh` has to run on every build: it stages the files and checks the frameworks/av commits (on a
tree with them as local commits, `repo sync` drops them and it puts them back). `git am` needs a committer identity in `~/expressiveos/frameworks/av` (as `evolution-cheetah/apply.sh`
does on the Evolution X tree).

`../tools/eos-images.sh` runs `apply-v4a.sh` on every build, and `../tools/eos-verify.sh` (which the
build and `eos-pack.sh` both run) runs `tools/v4a-check.sh out <product_out> <host_out>` and stops unless
its last line is `V4A_CHECK=OK`.
`device` is the release gate for the first build that ships V4A, and for any build that bumps a pin.

### What the checks cover

- `tree <top>` (pre-build): the tree isn't `~/evolution`, and `vendor/extra`, `vendor/extra/product.mk`,
  `vendor/extra/viper4android`, `frameworks/av` and its git folder don't lead out of it or into
  `~/evolution`; Evolution X's loader is still in `EffectsFactory.c` (the library path, and the
  `loadViperEffect();` call inside `init()`); gs201's VINTF manifest still declares
  `@7.0::IEffectsFactory/default`; gs201 still sets `IGNORE_PREFER32_ON_DEVICE := true` (or something
  sets `android_hardware_audio` `run_64bit`), so the audio HAL is 64-bit; no AIDL effect HAL anywhere in gs201, pantah or
  cheetah's vendor VINTF (the `android.hardware.audio.effect.IFactory` service name, an
  `android.hardware.audio.effect.service*` package, or a `<hal format="aidl">` named
  `android.hardware.audio.effect`); no `v4a` or `90380da3` line in cheetah's `audio_effects.xml` (and
  none in any other `audio_effects*` file in those trees); no `packages/apps/ViPER4AndroidFX`; no
  `TARGET_INCLUDE_VIPERFX`; both kit patches in frameworks/av (by subject, and by their code);
  `vendor/extra/viper4android` matches the kit and the pins; `vendor/extra/product.mk` inherits
  `viper4android.mk` outside any conditional; `vendor/lineage/config/common.mk` still inherits
  `vendor/extra/product.mk`.
- `out <product_out> [host_out]` (post-build): `vendor/lib64/soundfx/libv4a_re.so` has the pinned
  sha256 and is the only `libv4a_re*` in the images (no 32-bit copy); `vendor/lib64/libeffects.so`
  contains the loader's path and patch 0001's log string; the audio HAL is an ELF64 AArch64 binary and
  the HIDL `@7.0-impl` is built; the built VINTF declares `IEffectsFactory/default` and no AIDL effect
  HAL; `vendor/etc/audio_effects.xml` is the only effects config in vendor, odm, system, system_ext and
  product, with no v4a lines; the APK's sha256 is unchanged (and, when `host_out/bin/apksigner`
  exists, it verifies with the pinned certificate); one ViPER4Android app dir; the privapp XML grants
  exactly `MODIFY_AUDIO_ROUTING` and no other permissions XML names the package; the hidden-API
  sysconfig lists it; no `libviperaidl` or `ViPER4AndroidFX`; MusicFX reported as INFO; and
  `vendor/etc/NOTICE.xml.gz` and `system_ext/etc/NOTICE.xml.gz` exist (a build with
  `DISABLE_NOTICE_XML_GENERATION` fails) and carry the ViPERDSP and PFFFT notices and the driver's
  GPL-2.0, and the app's GPL-3.0.
- `device` (adb, read-only; `ANDROID_SERIAL` picks the phone): it is cheetah; the library is labelled
  `vendor_file`, has the pinned sha256, and has no 32-bit twin; the audio HAL is 64-bit; no AIDL
  `IFactory` service; `audio_effects.xml` has no v4a lines. Whether libeffects loaded the driver:
  `dumpsys media.audio_flinger --effects` lists `Library v4a_re` once under `Libraries loaded:`,
  with ViPER's effect (`V4A_FX_UUID`), not under `Libraries NOT loaded:`, and no other library
  with that uuid (a module's); logcat's `loadViperEffect: loaded ViPER library from
  /vendor/lib64/soundfx/libv4a_re.so` and `successfully registered ViPER4Android effect: ViPERDSP`
  pass when they're there (on the first build the audio HAL's startup lines weren't in logcat at
  all, so their absence is INFO), and `already registered` or a loader error fails. With neither
  the dump nor those lines, it fails. Then: the app is the `/system_ext/priv-app` copy (INFO if a
  user update replaced it) with `MODIFY_AUDIO_ROUTING: granted=true`; no privapp allowlist
  violation; the hidden-API sysconfig is installed; no `avc: denied` for `hal_audio_default` or
  the app. Driver Status in the app is checked by hand.

## Pins (`v4a.conf`)

| What | Value |
|---|---|
| App release | ViPER4Android `2.1.1`, tag `2.1.1` = `dfcbda7bceb01b7f3a77e092083311181768278c` |
| App URL | https://github.com/likelikeslike/ViPER4Android/releases/download/2.1.1/ViPER4Android-2.1.1.apk |
| App sha256 / size | `b60a8e38c4abf00b5e3f0d4802732bf1dc8679047cc9471fb36bf74a9c572cba` / 3,845,789 bytes |
| App signer (v2 only) | certificate sha256 `0edfb18ea10326bded7d15d84b919b0c75a610554b394aa955f345dfdc14c35f` (CN=ViPER4Android, O=LLSL) |
| App package / version | `com.llsl.viper4android`, versionName 2.1.1, versionCode 1 |
| App LICENSE | https://raw.githubusercontent.com/likelikeslike/ViPER4Android/2.1.1/LICENSE, sha256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` (GPLv3) |
| App permissions | `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `MODIFY_AUDIO_SETTINGS`, `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS`, `MODIFY_AUDIO_ROUTING`, `INTERNET`, `REQUEST_INSTALL_PACKAGES`, `QUERY_ALL_PACKAGES`, `com.llsl.viper4android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; only `MODIFY_AUDIO_ROUTING` is privileged |
| App uses-library | `androidx.window.extensions`, `androidx.window.sidecar`, both `required="false"` |
| Driver release | ViPERFX_RE `v2.1.1`, tag = `32587b138eb915d6252ccbebd8a86d05af778957`, ViPERDSP submodule [likelikeslike/ViPERDSP](https://github.com/likelikeslike/ViPERDSP) at `6fc1f1b8b2123c8cc49f3b3c7c7d5fbbf8a60933` |
| Driver zip URL | https://github.com/likelikeslike/ViPERFX_RE/releases/download/v2.1.1/ViPER4Android-RE-v2.1.1.zip |
| Driver zip sha256 / size | `c8f769f9d9f470e47f8278d69615c899d54af3916d10291d853fbd299ee847a2` / 618,433 bytes |
| Library | member `common/files/libv4a_re_arm64-v8a.so`, sha256 `79d058309902ec3a7ac96e225cf052aefe950d8a904a7f405e633916284cd31b`, 653,400 bytes, reports version code 20261009 |
| Zip LICENSE | sha256 `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643` (GPLv2) |

To move to a new release, change a whole block in `v4a.conf` from the release page and the tag, run
`fetch-v4a.sh` (it refuses an APK that asks for a permission not in `V4A_APP_PERMS`: add a new
privileged one to the privapp XML deliberately), then `apply-v4a.sh` and the `out` and `device` checks.
Keep the app and the driver at matching releases: a newer app may expect a newer driver.

## The two frameworks_av fixes

Both are commits on ExpressiveOS's `frameworks_av` fork (branch `expressiveos`, on top of Evolution X's
`cnb` 8e6f34b6ba, the commit of the 1.0 builds), made from the patches here, which stay as their record:

| Patch | Fix |
|---|---|
| `0001-libeffects-don-t-register-ViPER-twice` | `loadViperEffect()` never checked whether the effect was already registered. If a user flashes the ViPER4Android RE module anyway, its lines in `audio_effects.xml` register the effect first and the built-in loader added a second library with the same uuid. Now it calls `findEffect(NULL, &kViperImplUuid, &registeredLib, NULL)` first and returns with `ALOGI("loadViperEffect: ViPER effect already registered by library %s, skipping", ...)` |
| `0002-audioflinger-exempt-ViPER-from-suspend-by-uuid` | Evolution X's "don't suspend ViperFx" exemption (commit 61dd835e5a) compares `SL_V4A_RE`, the effect's implementation uuid, with `desc.type`. The v2.1.1 descriptor's type is `EFFECT_UUID_NULL`, so it never matched, and Global mode (the output-mix effect) was suspended whenever another app turned on an effect on its own session. It now compares `desc.uuid` |

To change either fix, commit the change to the fork's `expressiveos` branch and move frameworks/av's
revision in ExpressiveOS's manifest (`../README.md`, "Sources"). Never edit a patch here for it:
`apply-v4a.sh` then fails, as `apply.sh` does for the tree's own patches. On a tree from another manifest
they're local commits again, and if that code changed and `git am` stops, `apply-v4a.sh` aborts the `am`
and fails.

### If Evolution X drops its loader

`tree` and `out` fail when `EffectsFactory.c` or `libeffects.so` no longer carries
`/vendor/lib64/soundfx/libv4a_re.so`. The fallback is to register the effect in cheetah's
`vendor/google/cheetah/proprietary/vendor/etc/audio_effects.xml` with a vendor_google_cheetah patch
(after the `spatializer` library: `<library name="v4a_re" path="libv4a_re.so"/>`; after the
`spatializer` effect: `<effect name="v4a_standard_re" library="v4a_re"
uuid="90380da3-8536-4744-a6a3-5731970e640f"/>`) and to change the `audio_effects.xml` checks to expect
exactly one v4a library line. Not done, because it isn't needed today.

## Notes for the XDA post

- ViPER4Android is built in. The app is in `/system_ext/priv-app` and the driver in
  `/vendor/lib64/soundfx`, and Android's audio framework loads the driver itself.
- Don't flash the ViPER4Android RE Magisk/KernelSU module, its AIDL variant, or any ViPER4AndroidFX
  module. If you installed one, remove it in KernelSU Next and reboot. ExpressiveOS ignores its second
  registration, but under KernelSU the module still remounts the effects config and restarts audio at
  every boot. The AIDL zip refuses to install on this phone anyway. Quick check that nothing patches the
  config: `adb shell grep -c v4a /vendor/etc/audio_effects.xml` should print `0`.
- Is the driver working? Open ViPER4Android, then menu > Driver Status: it should show Version v2.1.1,
  Version Code 20261009, an Architecture, and Streaming: Active while something plays. "Driver not
  found" means the library didn't load; report it with `adb logcat -b all -d -s EffectsFactory`.
- Nothing is processed until you turn on the master switch in the app (it's off at first). After that
  the app starts itself at boot.
- Per-App mode (the default) works without root, because the ROM grants the app
  `MODIFY_AUDIO_ROUTING`. Global mode processes everything on one output. ExpressiveOS fixes Android
  pausing Global mode whenever another app turns on its own effect; still, turn off other equalizers
  (MusicFX, in-app EQs), or the sound gets equalized twice.
- Not processed: Spatial Audio multichannel content (the driver only takes stereo), AAudio low-latency
  or MMAP output (some games and music-making apps), and direct or bit-perfect USB output. While
  ViPER4Android is on, Android won't use compressed offload, so music decodes on the CPU and uses a bit
  more battery.
- Updates: newer ViPER4Android APKs from GitHub install over the built-in one (same signature); the
  in-app updater needs the "Install unknown apps" permission for ViPER4Android. Once you update from
  GitHub, ROM updates keep your copy, because upstream always uses versionCode 1. Settings > Apps >
  ViPER4Android > Uninstall updates goes back to the ROM's version. A newer app may expect a newer
  driver than the ROM ships.
- The app's debug driver-log view needs root: allow ViPER4Android in KernelSU Next if you want it.
  Everything else works without root.
- Credits and licence: the app is GPL-3.0 (likelikeslike). The driver is the reverse-engineered ViPER
  DSP (pittvandewitt, MrWhite214, Zackptg5, Martmists, Iscle, llsl; original work by Zhuhang and
  ViPER520); upstream says it is for personal, non-commercial use. Sources for the shipped versions are
  linked next to each release.

## Licence and credits

- **App:** ViPER4Android by likelikeslike, GPL-3.0 (its `LICENSE` is the GPLv3 text, with no "only"
  or "or later" statement; `SPDX-license-identifier-GPL-3.0` in `tree/Android.bp`).
- **Driver:** the zip's `LICENSE` is GPL-2.0 (identical to ViPERFX_RE's `module/LICENSE`), but the
  DSP compiled into `libv4a_re.so` is ViPERDSP. Its README (lines 5-10, shipped verbatim as
  `NOTICE.viperdsp`) says the original intellectual property is Zhuhang's and ViPER520's, that
  AndroidAudioMods/ViPERFX_RE carries no licence and is treated as All Rights Reserved, and that the
  project is for personal use only and must not be used for any commercial purpose. ViPERFX_RE's
  README (line 43) also says "Not for commercial use". The library also contains PFFFT (Julien
  Pommier) under the FFTPACK licence, whose binary redistributions must reproduce its notice:
  `NOTICE.pffft` is `pffft.c` lines 1-53, verbatim. `tree/Android.bp` labels the driver
  `legacy_restricted` and ships all three texts.
- **Decision:** knowing those terms, Daryl chose on 2026-10-26 to ship it built in, in public builds.
  Keep the feature away from donations or any other monetization.
- **Credits:** pittvandewitt, MrWhite214, Zackptg5, Martmists, Iscle and llsl (ViPER4Android RE);
  likelikeslike (the app, ViPERFX_RE and ViPERDSP); Zhuhang and ViPER520 (the original ViPER4Android).
- **Sources with every release:** host, next to each release on SourceForge, the app's source at tag
  `2.1.1` and ViPERFX_RE at tag `v2.1.1` with its ViPERDSP submodule at `6fc1f1b`, plus this kit (the
  frameworks/av patches). Don't rely on links to upstream alone: upstream can disappear.

## Risks

- **Licence terms:** see above. Not legal advice.
- **No way out for users:** the driver is dlopened into the audio HAL at every start. If it misbehaved
  on cheetah with Android 17 (upstream tested non-AIDL only on a Pixel 8 Pro with Android 14), the
  result would be an audio HAL crash loop that users can't remove the way they'd remove a module. The
  `device` checks on a test phone come before the first public build.
- **Evolution X dependency:** if Evolution X reverts or changes its loader, the effect silently
  disappears (a missing library is logged only at `ALOGV`). `tree` and `out` catch it.
- **A future AIDL effect HAL** on gs201 would need the AIDL driver, its sepolicy, and no Evolution X
  loader. `tree` and `out` catch the switch.
- **App/driver drift:** the in-app updater and upstream's versionCode 1 mean a user's app can get
  newer than the ROM's driver, and ROM updates can't replace a user-updated app.
- **Hidden APIs:** whether Android 17 adds checks the sysconfig doesn't lift is untested.
- **Behaviour:** offload is refused while V4A is on; spatializer, multichannel, FAST/MMAP/DIRECT,
  Bluetooth and call paths are unprocessed or untested.

## Untested

Everything here was tested offline only: on copies of the Evolution X `cnb` sources, with fake trees
and fake build outputs, never with a download, a real build or a phone.

- [ ] A real Soong build of `tree/Android.bp`: the namespace, the license modules, the presigned
      `android_app_import` (its uses-library check and dexpreopt), the two `prebuilt_etc`, and
      `cc_prebuilt_library_shared` with `check_elf_files` at its default. Every property used exists in
      Soong `cnb` 541d7c2, but no `m` was run.
- [ ] Building libeffects and libaudioflinger with the two patches. `EffectsFactory.c` was only
      syntax-checked with gcc and clang against stub headers; `Effects.cpp` wasn't compiled.
- [ ] That the GitHub URLs still serve the pinned bytes (only the local copies were checked).
- [ ] `out` against a real `out/target/product/cheetah`: the real libeffects, the NOTICE.xml.gz files'
      layout, and a real apksigner's output.
- [ ] `device` against a real phone (exercised only with a canned adb stand-in): the dumpsys format,
      whether `adb shell` can read `/vendor/etc/audio_effects.xml` on a user build, toybox `file`.
- [ ] At runtime: the driver loads in `hal_audio_default` with no denials, it is registered once,
      Per-App mode finds sessions without root on Android 17, Global mode keeps processing when MusicFX
      or an in-app EQ turns on (patch 0002), speaker, wired, A2DP/LE Audio and USB, calls, Spatial
      Audio, battery, Play Integrity and banking apps, installing the GitHub 2.1.1 APK over the built-in
      copy, and a module flashed on top being registered only once (patch 0001).
- [ ] Whether anything else in `~/expressiveos` defines a module named `ViPER4Android` or `libv4a_re`
      (only the cheetah trees and `packages/apps/ViPER4AndroidFX` are checked).
