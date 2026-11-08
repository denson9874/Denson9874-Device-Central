# Expressive Launcher for ExpressiveOS (every phone)

Every ExpressiveOS phone ships Daryl's Expressive Launcher as its Home and Recents app, in Pixel
Launcher's place (Daryl, 2026-10-30: "Let's hold off on building for the other devices until we
replace Pixel Launcher with Expressive Launcher", and "Might be better to target the latest QA
build because it is way ahead on 2.0.8"). It is the unmodified QA release APK, signed with
Expressive's own release key, as a privileged system_ext app: nothing is rebuilt or re-signed, so
newer releases from GitHub or the launcher's own updater install over the built-in copy.

## Launcher switch (Expressive Studio)

Pixel Launcher ships next to Expressive Launcher, and a switch in Expressive Studio (the Themes
page, Home screen > Launcher; packages_apps_Evolver `LauncherSwitch.kt`) makes it the Home and the
Recents app after a restart (Daryl, 2026-11-06; in 1.1.2, Daryl, 2026-11-08). A plain Home app pick doesn't
work: Pixel Launcher only gets the permissions it needs (`INTERNAL_SYSTEM_WINDOW`,
`MANAGE_ACTIVITY_TASKS`, `READ_FRAME_BUFFER`, `STATUS_BAR_SERVICE`) as the Recents app, and its Home
activity is direct-boot aware while Expressive Launcher's isn't, so it ran before the first unlock and
crashed at every unlock (7 Pro, 2026-11-05).

- `persist.sys.expressiveos.launcher=pixel` at boot scans `ExpressiveLauncherPixelModeOverlay`
  (`requiredSystemPropertyName`, priority 101 over this kit's 100), which names Pixel Launcher's
  `RecentsActivity` as the Recents app. Unset or anything else: Expressive Launcher's mode.
- `pixel-launcher-home-off.xml` (a sysconfig `component-override`) turns Pixel Launcher's Home
  activity off by default, so it can't start before the first unlock or be picked in Expressive
  Launcher's mode. Pixel Launcher mode needs it on (its Recents code looks it up and crashes without
  it); a user setting wins over this default.
- ExpressiveOS/frameworks_base doesn't cache static overlays (`PackageCacher`, PR #9), or a cached
  parse would keep the overlay after the property turns it off.
- The switch (Settings, the system uid) sets the property, turns the chosen launcher's Home activity
  on, makes that launcher the Home role holder, then turns the other one's Home activity off (Pixel
  Launcher's back to its sysconfig default, Expressive Launcher's disabled) and restarts the phone; a
  failed role change puts everything back. Expressive Launcher's has to go off because its Home
  priority (1) beats the Home role: Android takes the highest-priority Home activity before it looks
  at the role, so with it on, Pixel Launcher was Home only until the first unlock (7 Pro, 1.1.2 test,
  2026-11-08). The shell can do none of the component changes on a user build, so there is no adb way
  to switch; `tools/launcher-check.sh device` checks either mode.

The proof build (2026-11-06, a quick cheetah build on the 7 Pro, switched by hand with an init
property bridge this kit no longer ships) showed the overlay on and off across restarts, the
`PackageCacher` fix, Pixel Launcher's Recents permissions and SystemUI binding its quickstep service.

## Status: 5.1.3; 5.0.8 was the first Android 17 build that works as the Recents app

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

QA 5.0.9 (71, source `84a81fd`, 2026-11-01) keeps 5.0.8's Android 17 code and adds two things: Pro
is included on ExpressiveOS (the launcher checks the `android` package's signing certificate against
ExpressiveOS's platform certificate, so no key or trial is needed), and work-profile badges in the
app pickers. Its permissions, uses-library tags and licence files are the same as 5.0.8's.

QA 5.1.1 (73, source `a1e2796`, 2026-11-05) is the first with Home priority 1 (the launcher switch
section above), and fixes the drawer's blur after switching drawer styles, Smartspacer cards losing
their first letters, the 3-button order switch and renaming small folders. Same permissions,
uses-library tags and licence files again.

QA 5.1.3 (75, source `8d9519b`, Jenkins build 28, 2026-11-08) is a one-fix release for ExpressiveOS
1.1.2 (Daryl's card: "EL 5.1.3 tonight, this fix only"). It asks for `ACCESS_CONTEXTUAL_SEARCH`, so
holding the navigation handle opens Circle to Search with Expressive Launcher too. The permission is
`signature|privileged`: the privapp XML grants it, and Android grants it nowhere else. The ROM's
half is frameworks_base's SettingsProvider writing `search_all_entrypoints_enabled`'s default, since
Pixel Launcher reads it unset as off. Same uses-library tags and licence files.

This folder is only the launcher part of the ExpressiveOS kit. It works on the ExpressiveOS tree
(`~/expressiveos`), for every phone in `../devices/`. `apply-launcher.sh` refuses any `vendor/extra`
that leads out of the tree through a symlink; `tools/launcher-check.sh tree` fails on the same.

## What ships

| On the phone | What it is | Source |
|---|---|---|
| `/system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk` | Expressive Launcher QA 5.1.3 (`dev.launcher.expressive.l3`, versionCode 75), byte for byte | [denson9874/ExpressiveLauncher](https://github.com/denson9874/ExpressiveLauncher) release `qa-v5.1.3-75`, source revision `8d9519b` |
| `/system_ext/etc/permissions/privapp-permissions-dev.launcher.expressive.l3.xml` | Grants the 10 privileged permissions it asks for (Pixel Launcher holds them too) | this kit |
| `/system_ext/etc/sysconfig/hiddenapi-dev.launcher.expressive.l3.xml` | Lifts hidden-API restrictions, as Google's list does for Pixel Launcher | this kit |
| `/system_ext/etc/sysconfig/preinstalled-packages-dev.launcher.expressive.l3.xml` | Installs it for the phone's own users (`SYSTEM`, `FULL`) only, as Google's list does Pixel Launcher; without it the build's user-type mode would put it in work profiles, clones and the private space too | this kit |
| `/system_ext/overlay/ExpressiveLauncherFrameworkOverlay.apk` | The framework config below | this kit |
| `/system_ext/overlay/ExpressiveLauncherSetupWizardOverlay.apk` | Pixel's setup wizard ends on Expressive Launcher's "All set" page and knows it as the launcher | this kit |
| The licence texts in the system_ext NOTICE file | Apache-2.0 (AOSP Launcher3, Lawnchair), MIT (the calculator), OFL-1.1 (Google Sans Flex) | `LICENSE.txt` and the calculator's `LICENSE` at `8d9519b`; Google Sans Flex's `OFL.txt` at `6cffd50` |

What stays: Pixel Launcher (vendor/gms's `NexusLauncherRelease`, `/system_ext/priv-app`) and its two
overlays (`PixelLauncherNoGestureHintOverlay`, `PixelLauncherOverlayCustom`), for the launcher switch,
with `ExpressiveLauncherPixelModeOverlay` (system_ext overlay) and `pixel-launcher-home-off.xml`
(system_ext sysconfig) from this kit. What goes: AOSP's `Launcher3QuickStep` (build/make's `handheld_system_ext.mk`), through
`ExpressiveLauncher`'s `overrides` and Pixel Launcher's own (with the other launcher names they
override, as no-ops).

### Framework config

Pixel's config names Pixel Launcher in several places. `ExpressiveLauncherFrameworkOverlay` is on
system_ext, and the platform applies static overlays partition by partition (system, vendor, odm, oem,
product, system_ext: frameworks/base `OverlayConfig`, `PackagePartitions`), so its values win over every
product overlay whatever their priorities. Each list is the one the build uses today with Expressive
Launcher added at the end (Pixel Launcher keeps its place, as it still ships);
`tools/launcher-check.sh tree` recomputes them from the tree and fails when one drifts.

| Value | Why | The build's value it replaces |
|---|---|---|
| `config_recentsComponentName` = `dev.launcher.expressive.l3/com.android.quickstep.RecentsActivity` | SystemUI binds this package's quickstep service (`TouchInteractionService`) for gestures, Overview and the taskbar; Settings offers gesture navigation only when it resolves; the platform grants it the permissions marked "recents" | Pixel Launcher's (vendor/pixel-style `PixelConfigOverlayCommon`, priority 1) |
| `config_defaultListenerAccessPackages` | Notification access by default (notification dots), for both launchers | `PixelConfigOverlay2019`'s (priority 6, the highest of the five that set it) |
| `config_launcherPackages` | Evolution X's launchers: the task and permission checks `PixelPropsUtils` lets them skip, as it does for Pixel Launcher | framework-res's (`evolution_arrays.xml`) |
| `vendor_required_apps_managed_device`, `vendor_required_apps_managed_user` | Apps a fully managed (work) phone or managed user keeps. Expressive Launcher's Home activity is also in the app drawer (Pixel Launcher's isn't), so provisioning would disable it otherwise | `vendor/lineage/overlay/common`'s (the build makes it a product overlay, priority 1, which beats Google's) |

`ExpressiveLauncherSetupWizardOverlay` sets Pixel's setup wizard's `exit_to_action_in_initial_setup` (the
page it opens when it ends: the APK's own default and `PixelSetupWizardOverlayExpressive` both name Pixel
Launcher's) and `launcher_package`. The setup wizard APK declares no overlayables, so a system_ext
overlay may change them.

Home itself needs no config: the Home role's default is the highest-priority system Home app
(PermissionController), and the pinned release's Home priority (1) puts Expressive Launcher above Pixel
Launcher (0), and Pixel Launcher's Home activity is off anyway until the launcher switch turns it on.
The same priority is why the switch turns Expressive Launcher's Home activity off in Pixel Launcher mode.

## Files

| File | What it does |
|---|---|
| `launcher.conf` | The pins (below), sourced by every script |
| `fetch-launcher.sh [--out <dir>]` | Downloads the APK, its LICENSE and the two notices into `~/android-dt/launcher/` (`EL_CACHE` overrides it) and checks them: SHA-256 (and the APK's size), then the APK's package, version, signer (its v3.1, v3 or v2 block), permissions and uses-library tags (`tools/apk-info.py`, no build tools needed). A download is renamed into the cache only once it matches; a cached file that doesn't match is deleted. `EL_OFFLINE=1` never downloads. With `--out`, the verified `ExpressiveLauncher.apk`, `LICENSE`, `NOTICE.calculator` and `NOTICE.font` appear in `<dir>` only when everything passed. Last line `LAUNCHER_FETCH=OK dev.launcher.expressive.l3 5.0.8 (70)` |
| `apply-launcher.sh [top]` | Default `~/expressiveos`. Fetches, stages `tree/` and the verified files into `vendor/extra/launcher` (removes `Android.bp` first, copies the rest, writes `Android.bp` last only when every copy worked, and removes files the kit no longer ships), adds `$(call inherit-product, vendor/extra/launcher/launcher.mk)` to `vendor/extra/product.mk` if that line isn't there at the top level (creating the file if needed; it fails if the line is only inside an `ifeq`/`ifdef`/`define` block), then runs `tools/launcher-check.sh tree`. A second run changes nothing. Last line `LAUNCHER_APPLY=OK ...` |
| `tree/` | What lands in `vendor/extra/launcher`: `Android.bp`, `launcher.mk` (every ExpressiveOS phone's `lineage_<device>` product), the four XMLs (privapp permissions, hidden-API and user-type sysconfig, Pixel Launcher's Home activity off), the three overlays (framework, setup wizard, Pixel Launcher mode) and a `README.md` |
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
`expressiveos-build` with installclean, or `EOS_INSTALLCLEAN=1`), so no launcher an earlier build
installed is left in `out/`: `out` fails if the launcher apps aren't exactly Expressive Launcher and
Pixel Launcher.

### What the checks cover

- `tree <top>` (pre-build): nothing the kit writes leads out of the tree; `vendor/extra/launcher` matches the kit and the pins (nothing else in it);
  `vendor/extra/product.mk` inherits `launcher.mk` outside any conditional, and
  `vendor/lineage/config/common.mk` still inherits `vendor/extra/product.mk`; `launcher.mk` names every
  `../devices/<device>.conf` phone; every permission the APK asks for that this tree's frameworks/base
  marks `privileged` is in `EL_PRIVAPP_PERMS` and the privapp XML grants exactly those (a missing one
  stops a clean flash at boot under `ro.control_privapp_permissions=enforce`; the build sets `log` today,
  vendor/lineage's `config/common.mk`, which only logs it); the pinned APK's Home activity has a
  priority above 0 (Pixel Launcher's); each framework list above is still the build's own with Expressive
  Launcher added at the end; Pixel's setup wizard overlay still sets the exit action on
  `com.google.android.pixel.setupwizard`; no `partition_order.xml` in `device/` or `vendor/`; vendor/gms
  still builds Pixel Launcher as `NexusLauncherRelease`.
- `out <product_out> [host_out]` (post-build): the APK's sha256 is unchanged (and, when
  `host_out/bin/apksigner` exists, it verifies with the pinned certificate); the launcher apps are it
  and Pixel Launcher's `NexusLauncherRelease`, both in `system_ext/priv-app` (no `Launcher3*`,
  `Trebuchet`, `Lawnchair` or `QuickSearchBox`); Pixel Launcher's overlays (INFO); the privapp XML grants exactly `EL_PRIVAPP_PERMS` and no other permissions XML
  names the package; the hidden-API sysconfig lists it; the user-type sysconfig installs it for
  `SYSTEM` and `FULL` users and no other sysconfig names it; its Home activity's priority is above
  every other enabled one's (the Home role has no default holder, so the highest priority wins and a
  tie brings up the chooser), and at least one other (Pixel Launcher's) ships for the launcher
  switch, while a setup wizard's must stay above it (INFO for the setup wizard's, the ones that ship
  turned off and any APK it can't read); no `system_ext/overlay/config/config.xml` or
  `product/overlay/partition_order.xml`, which could reorder the overlays; the three overlays (framework,
  setup wizard, Pixel Launcher mode) are on system_ext with their packages, targets and values, and
  `pixel-launcher-home-off.xml` is the kit's; `system_ext/etc/NOTICE.xml.gz` names the APK and
  carries all three licence texts. Dexpreopt is INFO.
- `device` (adb, read-only; `ANDROID_SERIAL` picks the phone): an ExpressiveOS phone; the launcher is
  the built-in copy (INFO when an update from GitHub runs over it), Pixel Launcher is built in; in the
  mode `persist.sys.expressiveos.launcher` names (Expressive Launcher's unless `pixel`): Pixel
  Launcher's Home activity is on only in Pixel Launcher mode and Expressive Launcher's only outside it,
  the Pixel mode overlay is on only then,
  the Home role holder is the mode's launcher (the other one fails: neither can be picked in Default
  apps in the other's mode, so it means a switch didn't finish; nobody
  fails, as a chooser would come up) and Home resolves to that holder, the recents component is the
  mode's, and SystemUI is bound to that launcher's `TouchInteractionService`; `cmd overlay lookup` shows
  the listener list, Evolution X's launcher list and the setup wizard's two values; the 10 privileged
  permissions are granted with no allowlist violation; neither launcher nor SystemUI crashed since
  logcat began; no binder call into it failed (Binder's "Caught a
  RuntimeException from the binder stub implementation" in its process: the Status section's mismatch);
  notification access (INFO). Gestures, Overview and the taskbar are checked by hand, then `device` runs
  again; so is the switch to Pixel Launcher in Expressive Studio and back, with `device` after each
  restart.

## Pins (`launcher.conf`)

| What | Value |
|---|---|
| Release | QA `5.1.3`, versionCode 75, tag `qa-v5.1.3-75` (Jenkins build 28), source revision `8d9519b9706e43efc9ae876e8cf9b397cc2f577c` |
| URL | https://github.com/denson9874/ExpressiveLauncher/releases/download/qa-v5.1.3-75/ExpressiveLauncherL3-5.1.3-Android17-QPR2-Beta5-Jenkins-QA-release-signed.apk |
| sha256 / size | `63f2d91ed86d6192274ed6a1a08c781407fca6efb6ab6cf2c976723e46da9837` / 24,441,842 bytes |
| Signer | certificate sha256 `c14160306d5c059b3d119f15fb74e08c57cc272316e80b36e192c71dc9e4d0d2`, the same for Stable and QA |
| Package | `dev.launcher.expressive.l3`, minSdk 31, targetSdk 37 |
| LICENSE | `LICENSE.txt` at `8d9519b`, sha256 `4bb3ad323fe4c27f06a47b39c0ae6ad35315f15c40e46c81a5211f7f519286ab` (Apache-2.0) |
| Notices | the calculator's `LICENSE` at `8d9519b`, sha256 `6f1b3f6fecde974467f78fec9fdad2614c1652ec2bda13206b83c2f9f083a0c9` (MIT); Google Sans Flex's `OFL.txt` at `6cffd50d9ff4ead23eda9dc7864eb9aed9fe304c`, sha256 `831b6e041705873c3e6efb18c4c96202bc41c8be42a456d3d26c47abf14816d0` (OFL-1.1). The launcher's own `docs/licenses/GoogleSansFlex-OFL.txt` is empty at `8d9519b`, so the font's repository is the source |
| Permissions | 47 (`EL_PERMS`); privileged: `PACKAGE_USAGE_STATS`, `BROADCAST_CLOSE_SYSTEM_DIALOGS`, `CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS`, `START_TASKS_FROM_RECENTS`, `WRITE_SECURE_SETTINGS`, `STATUS_BAR`, `STOP_APP_SWITCHES`, `ALLOW_SLIPPERY_TOUCHES`, `ACCESS_HIDDEN_PROFILES_FULL`, `ACCESS_CONTEXTUAL_SEARCH` |
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
https://github.com/denson9874/ExpressiveLauncher/tree/8d9519b9706e43efc9ae876e8cf9b397cc2f577c.

## Not covered, and follow-ups

- **SettingsGoogle's Simple View** (Accessibility) sets the launcher grid through Pixel Launcher's
  `grid_control` provider, unguarded on a background thread: with Pixel Launcher gone, turning Simple
  View on would crash Settings. The fix is a commit in ExpressiveOS's `vendor_packages_SettingsGoogle`
  (use the Home app's own grid provider, and never crash when there's none: its draft PR #1) and a
  manifest pin bump, both before this kit ships.
- **External displays** (husky and the Pixel 11s): `config_secondaryHomePackage` names Pixel Launcher,
  which ships again, so a second display should get Pixel Launcher's home screen (untested).
  Expressive Launcher has no `SECONDARY_HOME` activity. cheetah has no display output.
- **Pixel Launcher hooks that Expressive Launcher doesn't get:** Settings' gesture-pill switch toggles
  only Pixel Launcher's and Launcher3's no-hint overlays; Expressive Studio's navigation-bar icon styles
  target Pixel Launcher; SystemUIGoogle's and the wallpaper picker's `launcher_overlayable_package` name
  Pixel Launcher (launcher icon theming, the glanceable hub's widget picker, app-grid option icons);
  Google Restore can't restore a Pixel Launcher layout into it. They work again in Pixel Launcher mode.
- **The switch and other users:** the property is phone-wide, but the switch sets the Home role and
  both launchers' Home activities only for the user who flips it. Another full user then gets Pixel
  Launcher's Recents with its own Home app (Expressive Launcher, whose Home activity is still on there).
  The reverse also holds: if another user switches to Pixel Launcher and this one switches back, the
  other user keeps Expressive Launcher's Home activity off while Expressive Launcher is the Recents app
  again, and its quickstep service can't start without its own Home activity. In Pixel Launcher mode
  Expressive Launcher isn't offered in Default apps > Home app and its drawer icon goes too (one
  activity carries both); the switch is the way back. Disabling Expressive Launcher in App info there
  makes the switch back fail ("Nothing was changed") until it's enabled again.
- **No reconciler at boot:** only the switch sets the components. A build that drops Pixel Launcher
  must turn Expressive Launcher's Home activity back on for phones left in Pixel Launcher mode (Studio
  hides the switch without both launchers, and the shell can't), or they boot to no Home app. A
  launcher update that renames or adds a Home activity while in Pixel Launcher mode comes up on and
  wins Home again until the switch is run twice. A boot-time check in Settings would cover all of
  these (a follow-up).
- **Dexpreopt:** Evolution X sets `DONT_DEXPREOPT_PREBUILTS := true`; Pixel Launcher wasn't compiled
  ahead of time either.

## Untested

Tested offline only, on fake trees and fake build outputs built from copies of ExpressiveOS's sources
at the manifest's pins, with the real pinned APK; never with a real build or a phone.

- [ ] A real Soong build of `tree/Android.bp`: the namespace, the presigned `android_app_import` (its
      uses-library check), the four `prebuilt_etc` and the three `runtime_resource_overlay` modules, and that
      the overrides drop `Launcher3QuickStep`.
- [ ] `out` against a real product out (the overlays' resources.arsc, NOTICE.xml.gz, apksigner).
- [ ] `device` against a real phone (exercised with a canned adb stand-in only): `cmd overlay lookup`
      for an array, `cmd role`, the dumpsys formats.
- [ ] At runtime, with a release built for Android 17 (Status): gestures, Overview, the taskbar and
      3-button Recents with Expressive Launcher as the Recents app, the setup wizard's end on a clean
      install, notification dots, a clean flash's privapp allowlist, and an in-app update installing over
      the built-in copy.
- [ ] The launcher switch (December), on a build with frameworks_base's `PackageCacher` fix and
      Evolver's switch: a clean flash or a new user gets Expressive Launcher as Home with no chooser and
      Pixel Launcher's Home activity off; the setup wizard still runs first; switching to Pixel Launcher
      in Expressive Studio restarts into its home screen, At a Glance and the Google feed, with swipe up,
      Overview and quick switch through Pixel Launcher and no crash before or after the first unlock;
      switching back restores Expressive Launcher's layout; a phone updating from 1.1 stays on Expressive
      Launcher.
- [ ] The new `tree` priority check, the `out` Home comparison and the `device` role checks, run against
      a real tree, build and phone.
