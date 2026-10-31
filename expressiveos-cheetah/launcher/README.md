# Expressive Launcher for ExpressiveOS (every phone)

Every ExpressiveOS phone ships Daryl's Expressive Launcher as its Home and Recents app, in Pixel
Launcher's place (Daryl, 2026-10-30: "Let's hold off on building for the other devices until we
replace Pixel Launcher with Expressive Launcher", and "Might be better to target the latest QA
build because it is way ahead on 2.0.8"). It is the unmodified QA release APK, signed with
Expressive's own release key, as a privileged system_ext app: nothing is rebuilt or re-signed, so
newer releases from GitHub or the launcher's own updater install over the built-in copy.

## Status: 5.0.8, the first Android 17 build that works as the Recents app

Releases up to QA 5.0.4 (66), and the current Stable 5.0.0 (62), are compiled against
android-16.0.0_r3's framework and WindowManager Shell, and the Shell's AIDL stubs are built into the
APK. ExpressiveOS is Android 17 r1, whose Shell sends `IRecentsAnimationRunner.onAnimationStart` one
`Rect` fewer than those read (Android 17 dropped `minimizedHomeBounds`), so as the Recents app every
swipe-up and Overview transition failed in the launcher's binder thread; `IHomeTransitionListener`,
`IShellTransitions.registerRemote*`, task snapshots, the input consumer and removed desktop flags
differed too. Daryl chose (2026-10-30) to rebuild Expressive Launcher for Android 17 first and then
replace Pixel Launcher completely, rather than ship it as Home only or with broken gestures.

The rebuild is still compiled against the Android 16 jars, but on Android 17 (SDK 37) it reads and
sends Android 17's layouts for each of those calls. On Daryl's 7 Pro (2026-10-30), QA 5.0.5 (67)
crashed as the Recents app (`android.companion.virtualdevice.flags.Flags`, which Android 17 moved out
of the boot classpath) and QA 5.0.6 (68) ran every gesture but left Overview's cards blank (four
`TaskContainer` functions were lambda-returning expression bodies, so they never ran). QA 5.0.7 (69)
fixed that, but the card code that now ran crashed Home on Overview's Share and Lens, so it was
never published. QA 5.0.8 (70, source `83ccf44`) fixes all three. Daryl waived the on-phone gesture
test (2026-10-30 18:09 UTC), so Overview on 5.0.8 is first tried after the cheetah flash. `tools/dex-refs.py` checks a release
against a phone's own boot jars before a flash (it would have caught 5.0.5's crash), and `device`
fails on the launcher's failed binder calls in logcat once gestures have been tried.

This folder is only the launcher part of the ExpressiveOS kit. It works on the ExpressiveOS tree
(`~/expressiveos`), for every phone in `../devices/`. **None of it applies to the Evolution X tree
(`~/evolution`) or DerpFest's (`~/derpfest`)**: `apply-launcher.sh` refuses them, and any
`vendor/extra` that leads out of the tree or into them through a symlink; `tools/launcher-check.sh
tree` fails on the same.

## What ships

| On the phone | What it is | Source |
|---|---|---|
| `/system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk` | Expressive Launcher QA 5.0.8 (`dev.launcher.expressive.l3`, versionCode 70), byte for byte | [denson9874/ExpressiveLauncher](https://github.com/denson9874/ExpressiveLauncher) release `qa-v5.0.8-70`, source revision `83ccf44` |
| `/system_ext/etc/permissions/privapp-permissions-dev.launcher.expressive.l3.xml` | Grants the 9 privileged permissions it asks for (Pixel Launcher is granted all 9 too) | this kit |
| `/system_ext/etc/sysconfig/hiddenapi-dev.launcher.expressive.l3.xml` | Lifts hidden-API restrictions, as Google's list does for Pixel Launcher | this kit |
| `/system_ext/etc/sysconfig/preinstalled-packages-dev.launcher.expressive.l3.xml` | Installs it for the phone's own users (`SYSTEM`, `FULL`) only, as Google's list does Pixel Launcher; without it the build's user-type mode would put it in work profiles, clones and the private space too | this kit |
| `/system_ext/overlay/ExpressiveLauncherFrameworkOverlay.apk` | The framework config below | this kit |
| `/system_ext/overlay/ExpressiveLauncherSetupWizardOverlay.apk` | Pixel's setup wizard ends on Expressive Launcher's "All set" page and knows it as the launcher | this kit |
| The licence texts in the system_ext NOTICE file | Apache-2.0 (AOSP Launcher3, Lawnchair), MIT (the calculator), OFL-1.1 (Google Sans Flex) | `LICENSE.txt` and the calculator's `LICENSE` at `83ccf44`; Google Sans Flex's `OFL.txt` at `6cffd50` |

What goes: Pixel Launcher (vendor/gms's `NexusLauncherRelease`) and AOSP's `Launcher3QuickStep`
(build/make's `handheld_system_ext.mk`), the two launchers the build installs, through
`ExpressiveLauncher`'s `overrides` (with the other launcher names they override, as no-ops), and Pixel
Launcher's two overlays (`PixelLauncherNoGestureHintOverlay`, `PixelLauncherOverlayCustom`).

### Framework config

Pixel's config names Pixel Launcher in several places. `ExpressiveLauncherFrameworkOverlay` is on
system_ext, and the platform applies static overlays partition by partition (system, vendor, odm, oem,
product, system_ext: frameworks/base `OverlayConfig`, `PackagePartitions`), so its values win over every
product overlay whatever their priorities. Each list is the one the build uses today, with Expressive
Launcher in Pixel Launcher's place or added at the end; `tools/launcher-check.sh tree` recomputes them
from the tree and fails when one drifts.

| Value | Why | The build's value it replaces |
|---|---|---|
| `config_recentsComponentName` = `dev.launcher.expressive.l3/com.android.quickstep.RecentsActivity` | SystemUI binds this package's quickstep service (`TouchInteractionService`) for gestures, Overview and the taskbar; Settings offers gesture navigation only when it resolves; the platform grants it the permissions marked "recents" | Pixel Launcher's (vendor/pixel-style `PixelConfigOverlayCommon`, priority 1) |
| `config_defaultListenerAccessPackages` | Notification access by default (notification dots) | `PixelConfigOverlay2019`'s (priority 6, the highest of the five that set it) |
| `config_launcherPackages` | Evolution X's launchers: the task and permission checks `PixelPropsUtils` lets them skip, as it did for Pixel Launcher | framework-res's (`evolution_arrays.xml`) |
| `vendor_required_apps_managed_device`, `vendor_required_apps_managed_user` | Apps a fully managed (work) phone or managed user keeps. Expressive Launcher's Home activity is also in the app drawer (Pixel Launcher's isn't), so provisioning would disable it otherwise | `vendor/lineage/overlay/common`'s (the build makes it a product overlay, priority 1, which beats Google's) |

`ExpressiveLauncherSetupWizardOverlay` sets Pixel's setup wizard's `exit_to_action_in_initial_setup` (the
page it opens when it ends: the APK's own default and `PixelSetupWizardOverlayExpressive` both name Pixel
Launcher's) and `launcher_package`. The setup wizard APK declares no overlayables, so a system_ext
overlay may change them.

Home itself needs no config: the Home role's default is the highest-priority system Home app
(PermissionController), and with Pixel Launcher and Launcher3 gone that's Expressive Launcher.

## Files

| File | What it does |
|---|---|
| `launcher.conf` | The pins (below), sourced by every script |
| `fetch-launcher.sh [--out <dir>]` | Downloads the APK, its LICENSE and the two notices into `~/android-dt/launcher/` (`EL_CACHE` overrides it) and checks them: SHA-256 (and the APK's size), then the APK's package, version, signer (its v3.1, v3 or v2 block), permissions and uses-library tags (`tools/apk-info.py`, no build tools needed). A download is renamed into the cache only once it matches; a cached file that doesn't match is deleted. `EL_OFFLINE=1` never downloads. With `--out`, the verified `ExpressiveLauncher.apk`, `LICENSE`, `NOTICE.calculator` and `NOTICE.font` appear in `<dir>` only when everything passed. Last line `LAUNCHER_FETCH=OK dev.launcher.expressive.l3 5.0.8 (70)` |
| `apply-launcher.sh [top]` | Default `~/expressiveos`. Fetches, stages `tree/` and the verified files into `vendor/extra/launcher` (removes `Android.bp` first, copies the rest, writes `Android.bp` last only when every copy worked, and removes files the kit no longer ships), adds `$(call inherit-product, vendor/extra/launcher/launcher.mk)` to `vendor/extra/product.mk` if that line isn't there at the top level (creating the file if needed; it fails if the line is only inside an `ifeq`/`ifdef`/`define` block), then runs `tools/launcher-check.sh tree`. A second run changes nothing. Last line `LAUNCHER_APPLY=OK ...` |
| `tree/` | What lands in `vendor/extra/launcher`: `Android.bp`, `launcher.mk` (every ExpressiveOS phone's `lineage_<device>` product), the three XMLs (privapp permissions, hidden-API and user-type sysconfig), the two overlays and a `README.md` |
| `tools/launcher-check.sh` | `tree`, `out` and `device` checks (below). Every check prints `PASS`, `FAIL` or `INFO`; all of them run; exit 1 on any `FAIL`; last line `LAUNCHER_CHECK=OK` or `LAUNCHER_CHECK=FAIL` |
| `tools/launcher-xml.py` | XML and APK reads for the checks (`python3 -I`); its privapp and hidden-API reads are copies of `../viper4android/tools/v4a-xml.py`'s |
| `tools/apk-info.py` | ViPER4Android's APK reader plus the `--home` and `--overlay` reads the `out` check uses: don't replace it with ViPER4Android's copy |
| `tools/mk-line.awk` | A copy of ViPER4Android's makefile-line finder, so this kit stands alone |
| `tools/dex-refs.py` | What a launcher release's code needs that a phone's platform lacks, read from the APK's dex files and the phone's jars (no build tools): missing classes, methods and fields with the APK methods that use them, uses that can't link (static/instance, invoke kind, access, final, instantiation, abstract or conflicting defaults; the header lists them all), APK classes that can't load or link (a final, interface or non-public supertype, the platform's or the APK's own, a final override, a non-public implementation, a supertype cycle), APK classes the platform shadows, and abstract platform methods an APK class doesn't implement. A use is marked `[caught: T]` when a handler of type T in that method keeps the error on every path, `[caught?: T]` when it may (only some paths, the error handed on, a typed handler before it that may catch it first, or code that can't be followed), and `[reads SDK_INT]` when the method reads SDK_INT, so the output is for review, not a verdict. `--mapping` turns R8 names back into source names. The output format is in the script's header. Exit 2 when a platform dex can't be read |
| `tools/tests/dex-refs-test.py` | Builds its own dex files and checks `dex-refs.py` on them (`python3 -I`); last line `DEX_REFS_TEST=OK` |

## How to run

`../tools/eos-images.sh` runs `apply-launcher.sh` on every build, for every phone, and
`../tools/eos-verify.sh` runs `tools/launcher-check.sh out <product_out> <host_out>` and stops unless
its last line is `LAUNCHER_CHECK=OK`. By hand, with the kit at `~/expressiveos-cheetah`:

```bash
K=~/expressiveos-cheetah/launcher
$K/fetch-launcher.sh                     # after every change to launcher.conf (downloads once, then uses the cache)
$K/apply-launcher.sh ~/expressiveos      # every build: after repo sync and the tree's own patches, before lunch
# build as usual, then, before packing anything:
$K/tools/launcher-check.sh out ~/expressiveos/out/target/product/cheetah ~/expressiveos/out/host/linux-x86
# on a test phone with the build flashed, after a reboot and one unlock:
$K/tools/launcher-check.sh device
```

Before a new launcher release reaches a phone, check it against that phone's platform: Expressive
Launcher is compiled against Android 16's jars, so a class Android 17 moved or removed only shows up
when the code runs (5.0.5's crash). Take the jars in the phone's boot classpath order, plus the
`<uses-library>` jars, either from the phone or from the build's `system.img` and `system_ext.img`:

```bash
mkdir jars && i=0
for j in $(adb shell 'echo $BOOTCLASSPATH' | tr -d '\r' | tr : ' ') \
         /system_ext/framework/androidx.window.extensions.jar /system_ext/framework/androidx.window.sidecar.jar; do
  i=$((i+1)); adb pull "$j" "jars/$(printf %02d $i)-$(basename "$j")"
done
python3 -I $K/tools/dex-refs.py --mapping <release>/mapping/mapping.txt <release APK> jars/*.jar > dex-refs.txt
```

Read every `missing-*`, `link-error` and `unimplemented` entry with a `super of`, `interface of` or `in`
line (an APK class that can't load, can't link or lacks a method), or a `from` line not marked
`[caught: ...]` (a `[caught?: ...]` one may still crash): if that code can run on the phone, it's a
crash. The mapping must be the release's own (`dex-refs.py` notes a `pg_map_id` that doesn't match
the APK).

The first build after this kit lands should start with `m installclean` (the runner's
`expressiveos-build` with installclean, or `EOS_INSTALLCLEAN=1`), so no Pixel Launcher from an earlier
build is left in `out/`: `out` fails if one is.

### What the checks cover

- `tree <top>` (pre-build): the tree isn't `~/evolution` or `~/derpfest`, and nothing the kit writes
  leads out of it; `vendor/extra/launcher` matches the kit and the pins (nothing else in it);
  `vendor/extra/product.mk` inherits `launcher.mk` outside any conditional, and
  `vendor/lineage/config/common.mk` still inherits `vendor/extra/product.mk`; `launcher.mk` names every
  `../devices/<device>.conf` phone; every permission the APK asks for that this tree's frameworks/base
  marks `privileged` is in `EL_PRIVAPP_PERMS` and the privapp XML grants exactly those (a missing one
  stops a clean flash at boot under `ro.control_privapp_permissions=enforce`; the build sets `log` today,
  vendor/lineage's `config/common.mk`, which only logs it); each framework list above is still the build's own with Expressive
  Launcher in Pixel Launcher's place; Pixel's setup wizard overlay still sets the exit action on
  `com.google.android.pixel.setupwizard`; no `partition_order.xml` in `device/` or `vendor/`; vendor/gms
  still names Pixel Launcher `NexusLauncherRelease`.
- `out <product_out> [host_out]` (post-build): the APK's sha256 is unchanged (and, when
  `host_out/bin/apksigner` exists, it verifies with the pinned certificate); it is the only launcher
  app (no `NexusLauncherRelease`, `Launcher3*`, `Trebuchet`, `Lawnchair` or `QuickSearchBox`); no Pixel
  Launcher overlays; the privapp XML grants exactly `EL_PRIVAPP_PERMS` and no other permissions XML
  names the package; the hidden-API sysconfig lists it; the user-type sysconfig installs it for
  `SYSTEM` and `FULL` users and no other sysconfig names it; no other app ships an enabled Home activity
  at priority 0 or more (the Home role has no default holder, so the highest priority wins and a tie
  brings up the chooser), apart from a setup wizard's above 0 (INFO, like the ones that ship turned
  off and any APK it can't read); no `system_ext/overlay/config/config.xml` or
  `product/overlay/partition_order.xml`, which could reorder the overlays; both overlays are on
  system_ext with their packages, targets and values; `system_ext/etc/NOTICE.xml.gz` names the APK and
  carries all three licence texts. Dexpreopt is INFO.
- `device` (adb, read-only; `ANDROID_SERIAL` picks the phone): an ExpressiveOS phone; the launcher is
  the built-in copy (INFO when an update from GitHub runs over it), Pixel Launcher isn't installed, it
  holds the Home role and Home resolves to it; `cmd overlay lookup` shows the recents component, the
  listener list, Evolution X's launcher list and the setup wizard's two values; SystemUI is bound to
  its `TouchInteractionService`; the 9 privileged permissions are granted with no allowlist violation;
  neither it nor SystemUI crashed since logcat began; no binder call into it failed (Binder's "Caught a
  RuntimeException from the binder stub implementation" in its process: the Status section's mismatch);
  notification access (INFO). Gestures, Overview and the taskbar are checked by hand, then `device` runs
  again.

## Pins (`launcher.conf`)

| What | Value |
|---|---|
| Release | QA `5.0.8`, versionCode 70, tag `qa-v5.0.8-70` (Jenkins build 17, release id `qa-5.0.8-70-build-17`), source revision `83ccf446736f807ff3000837dbbf38e960af39e9` |
| URL | https://github.com/denson9874/ExpressiveLauncher/releases/download/qa-v5.0.8-70/ExpressiveLauncherL3-5.0.8-Android17-QPR2-Beta5-Jenkins-QA-release-signed.apk |
| sha256 / size | `c1f3546e79910de6bc8b008e320192c54ab8a4faea664aba238bd03b4f452030` / 24,441,118 bytes |
| Signer | certificate sha256 `c14160306d5c059b3d119f15fb74e08c57cc272316e80b36e192c71dc9e4d0d2`, the same for Stable and QA |
| Package | `dev.launcher.expressive.l3`, minSdk 31, targetSdk 37 |
| LICENSE | `LICENSE.txt` at `83ccf44`, sha256 `4bb3ad323fe4c27f06a47b39c0ae6ad35315f15c40e46c81a5211f7f519286ab` (Apache-2.0) |
| Notices | the calculator's `LICENSE` at `83ccf44`, sha256 `6f1b3f6fecde974467f78fec9fdad2614c1652ec2bda13206b83c2f9f083a0c9` (MIT); Google Sans Flex's `OFL.txt` at `6cffd50d9ff4ead23eda9dc7864eb9aed9fe304c`, sha256 `831b6e041705873c3e6efb18c4c96202bc41c8be42a456d3d26c47abf14816d0` (OFL-1.1). The launcher's own `docs/licenses/GoogleSansFlex-OFL.txt` is empty at `83ccf44`, so the font's repository is the source |
| Permissions | 46 (`EL_PERMS`); privileged: `PACKAGE_USAGE_STATS`, `BROADCAST_CLOSE_SYSTEM_DIALOGS`, `CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS`, `START_TASKS_FROM_RECENTS`, `WRITE_SECURE_SETTINGS`, `STATUS_BAR`, `STOP_APP_SWITCHES`, `ALLOW_SLIPPERY_TOUCHES`, `ACCESS_HIDDEN_PROFILES_FULL` |
| uses-library | `androidx.window.extensions`, `androidx.window.sidecar`, both `required="false"` |

The full QA build, not "Core": Core leaves out the notification listener (dots) and the accessibility
service. To move to a new release, change the whole block in `launcher.conf` from the release page and
the update feed (`qa-v2/latest.json` on the launcher repo's `updates` branch for QA,
`release/latest.json` for Stable), run `fetch-launcher.sh` (it refuses an APK whose permissions,
signer or uses-library tags changed: a new privileged permission goes into the privapp XML and
`EL_PRIVAPP_PERMS` on purpose, or a clean flash won't boot under `enforce`), then `apply-launcher.sh` and the `out` and
`device` checks. Keep the versionCode rising: a phone keeps whichever copy is newer.

## On a phone that already has it

A phone with Expressive Launcher installed from GitHub (Daryl's 7 Pro: 5.0.7, versionCode 69, until the next flash, holding
the Home role) keeps its copy as an update of the built-in app when its versionCode is at least the
built-in one's; otherwise the built-in one replaces it. Its home screen and settings stay either way.
An update is not checked against the privapp allowlist, so such a phone can't show a missing
privileged permission: only a clean flash does (`tree` recomputes the list from frameworks/base for
that reason). A phone coming from Pixel Launcher loses Pixel Launcher's home screen layout.

## Licence and credits

Expressive Launcher is Daryl's, built on AOSP Launcher3 and Lawnchair. Its `LICENSE.txt` and
`docs/THIRD_PARTY_NOTICES.md` declare Apache-2.0, plus MIT for the calculator and OFL-1.1 for the Google
Sans Flex font, but 18 Lawnchair files it carries are GPL-3.0-or-later (their headers say so;
`FontCache.kt`, compiled into the APK, is one). So `tree/Android.bp` declares Apache-2.0,
GPL-3.0-or-later, MIT and OFL-1.1, and the APK's own `assets/licenses.json` also lists
`me.xdrop:fuzzywuzzy` as GPL-2.0 (whether its classes survive R8 is unchecked). This isn't legal advice;
these are what the files say.

What follows from the GPL part: every ExpressiveOS release must come with the launcher's exact source,
the release's source revision (`EL_COMMIT`, which `sources.txt` records), like the other GPL code in the
ROM. The launcher's repository has no GPL-3.0 text of its own yet; once it has one, pin it here and add
it to `license_text`. Its source at the pinned revision is public at
https://github.com/denson9874/ExpressiveLauncher/tree/83ccf446736f807ff3000837dbbf38e960af39e9.

## Not covered, and follow-ups

- **SettingsGoogle's Simple View** (Accessibility) sets the launcher grid through Pixel Launcher's
  `grid_control` provider, unguarded on a background thread: with Pixel Launcher gone, turning Simple
  View on would crash Settings. The fix is a commit in ExpressiveOS's `vendor_packages_SettingsGoogle`
  (use the Home app's own grid provider, and never crash when there's none: its draft PR #1) and a
  manifest pin bump, both before this kit ships.
- **External displays** (husky and the Pixel 11s): `config_secondaryHomePackage` still names Pixel
  Launcher and Expressive Launcher has no `SECONDARY_HOME` activity, so a second display gets no home
  screen. cheetah has no display output. Needs a launcher release with one.
- **Lost Pixel Launcher hooks:** Settings' gesture-pill switch toggles only Pixel Launcher's and
  Launcher3's no-hint overlays; Expressive Studio's navigation-bar icon styles target Pixel Launcher;
  SystemUIGoogle's and the wallpaper picker's `launcher_overlayable_package` still name Pixel Launcher
  (launcher icon theming, the glanceable hub's widget picker, app-grid option icons); Google Restore
  can't restore a Pixel Launcher layout into it.
- **Dead weight:** vendor/gms's AI Icons (`AiIconsPrebuilt`) and Pixel Search
  (`PixelSearchPrebuilt`, `com.google.android.apps.pixel.launcherconnector`) only serve Pixel Launcher
  and still ship.
- **Dexpreopt:** Evolution X sets `DONT_DEXPREOPT_PREBUILTS := true`; Pixel Launcher wasn't compiled
  ahead of time either.

## Untested

Tested offline only, on fake trees and fake build outputs built from copies of ExpressiveOS's sources
at the manifest's pins, with the real pinned APK; never with a real build or a phone.

- [ ] A real Soong build of `tree/Android.bp`: the namespace, the presigned `android_app_import` (its
      uses-library check), the three `prebuilt_etc` and the two `runtime_resource_overlay` modules, and that
      the overrides drop `NexusLauncherRelease` and `Launcher3QuickStep`.
- [ ] `out` against a real product out (the overlays' resources.arsc, NOTICE.xml.gz, apksigner).
- [ ] `device` against a real phone (exercised with a canned adb stand-in only): `cmd overlay lookup`
      for an array, `cmd role`, the dumpsys formats.
- [ ] At runtime, with a release built for Android 17 (Status): gestures, Overview, the taskbar and
      3-button Recents with Expressive Launcher as the Recents app, the setup wizard's end on a clean
      install, notification dots, a clean flash's privapp allowlist, and an in-app update installing over
      the built-in copy.
