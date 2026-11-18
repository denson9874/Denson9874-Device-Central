# ExpressiveOS on AOSP, without LineageOS (experiment, cheetah only)

Branch `eos/aosp` only (Daryl, 2026-11-18: "make a separate branch to work on Lineage being taken
out of the equation"). Nothing here touches `main`, the release branches, the kit's builds or any
shipped build. No sync, build, flash or upload happens without Daryl's go for that step.

## Can we take Google's platform source the way Lineage does?

Yes. AOSP is public: anyone can `repo init` Google's platform manifest, and Lineage does exactly
that. Our tree already gets 945 of its 1,257 projects straight from Google at `android-17.0.0_r1`
(measured: `../sources/eos-1.0-base/manifest.xml`, `remote="aosp"`).

What Lineage adds on top is the part we would have to carry ourselves:

1. **The Pixel device side.** Google stopped publishing Pixel device trees and kernel source in
   AOSP in 2025 (public reporting, not re-checked here). Lineage keeps them going; our cheetah
   trees are forks of those.
2. **Its own copies of about 90 AOSP projects**, with fixes for real phones.
3. **Lineage-only code** our features stand on: lineage-sdk, the Lineage health HAL (charge
   limit), the Updater, LineageParts, `vendor/lineage` (product config, version, `m bacon`, OTA
   packaging).
4. **The monthly security merge.** Our `sources/update.py` merges Lineage's branches; on AOSP we
   would merge Google's security releases ourselves.

Two limits stay the same whichever base we pick: AOSP has no Android 17 QPR2 source yet (Google
publishes in Q2 and Q4, so about December), and Google's apps still come from `vendor_gms` and
stock blobs, not from AOSP.

## The map: what in ExpressiveOS comes from Lineage today

Counts are measured from the 1.0 record manifest (`../sources/eos-1.0-base/manifest.xml`,
1,257 projects plus `cheetah.xml`). What breaks is inferred unless it says measured.

| Part | Today | Without Lineage | Size |
|---|---|---|---|
| Google platform projects | 945 from AOSP `android-17.0.0_r1` | Same, unchanged | none |
| Lineage copies of AOSP projects (`external/*`, `system/netd`, `system/security`, Contacts, Dialer, DocumentsUI, Launcher3, LatinIME, providers, `packages/modules/Telephony` and others) | about 90 of the 241 Lineage projects | Swap back to Google's version. Risk: Lineage fixes for real Pixels drop out (`hardware/google/camera`, `hardware/google/pixel-sepolicy`, `system/netd`) | small per project, many projects |
| Lineage-only apps (18: Aperture, Glimpse, Twelve, Etar, Jelly, Recorder, ThemePicker, Seedvault, ...) | Lineage | Drop, or keep as plain apps where we ship them | small |
| Other-vendor, TV and car projects (qcom, samsung, sony, ...; about 130, a few Lineage-only ones counted below) | Lineage | Not needed on a Pixel: drop | none |
| `vendor/lineage` (our `vendor_evolution` fork): product config, version, `m bacon`, OTA package, signing hooks | Lineage-based fork | Rewrite as our own `vendor/expressiveos` on AOSP's build | large |
| `lineage-sdk`, `hardware/lineage/interfaces`, `device/lineage/sepolicy`, LineageParts | Lineage / our Lineage-based forks | Port each feature that uses them (charge limit, LiveDisplay-style settings, LineageSettings keys read by Studio/Evolver) | large |
| Our 70 forks of core repos (`frameworks/base`, `build/make`, `build/soong`, Settings, `system/core`, Updater, SystemUIGoogle, ...) | Evolution X forks that sit on Lineage branches | Rebase only our own commits onto AOSP in each fork; Lineage's commits underneath drop out | largest: this is most of the 6-10 weeks |
| cheetah device trees (`device/google/pantah`, `gs201`) | our forks of Lineage's trees | Keep the forks, add an AOSP product (`aosp_cheetah` style) that doesn't inherit `vendor/lineage` | medium |
| Kernel | Lineage's gs-6.1 manifest (`eos.conf`), BakaSU boot on top | Prototype: Google's stock kernel and modules from the factory image. Later: Google's kernel source by request form, or keep Lineage's kernel only | medium |
| Blobs, `vendor_gms`, firmware | ours (`vendor_google_cheetah`, `vendor_gms`) | Same | none |
| Kit scripts | `lunch lineage_<device>` (`lib.sh:60` refuses anything else), `m bacon`, `update.py` merges Lineage | Need an AOSP mode: product name, build goal, packaging, monthly update | medium |
| Expressive Launcher, web installer, OTA feed format | ours | Same (the feed is the Updater's format, and the Updater is our fork) | none |

## Steps (cheetah only)

1. **Done on this branch:** this map and `local_manifests/eos-aosp-cheetah.xml`, Google's platform
   manifest at `android-17.0.0_r1` plus only the cheetah device trees and blobs.
2. **Needs Daryl's go (server time and disk):** sync it into its own folder on the build server,
   never `~/expressiveos`, then try the first build and keep the log:
   ```
   mkdir -p ~/eos-aosp && cd ~/eos-aosp
   repo init -u https://android.googlesource.com/platform/manifest -b android-17.0.0_r1 --depth=1
   mkdir -p .repo/local_manifests
   cp <kit>/expressiveos-cheetah/aosp/local_manifests/eos-aosp-cheetah.xml .repo/local_manifests/
   repo sync -c -j8 --no-tags
   source build/envsetup.sh && lunch aosp_cheetah-cp2a-userdebug
   ```
   Expected: lunch or the first make fails where the trees inherit `vendor/lineage`. That failure
   list is the first real measurement of the device side. The folder is deleted when the step
   ends (nothing stays on the server).
3. Fix the device side until a plain AOSP image builds and boots on the 7 Pro (flash needs his go,
   and a clean flash: it is a different platform from his installed build).
4. Add ExpressiveOS one layer at a time, each with what it breaks: `vendor_gms`, boot animation,
   Expressive Launcher, Updater, then our framework forks rebased onto AOSP.

## Running it on the build server

The runner's `aosp-proto` action, dispatched on `eos/aosp` (it runs that branch's
`aosp-proto.sh`): query `status` (read-only), `sync`, `build` or `clean`. Sync and build run in
the `eos-aosp` tmux session and refuse while an ExpressiveOS build, pack or setup runs; their
logs stay in `~/expressiveos-jobs/aosp/`. `clean` removes `~/eos-aosp` when the step ends.

## First build attempt (2026-11-18, measured)

Sync: SYNC=OK 2:23 PM ET, 1,087 projects, 137 GB (`~/expressiveos-jobs/aosp/sync-20261118-1407.log`).
Build: `lunch aosp_cheetah-trunk_staging-userdebug` stopped in product config after 1 second
(`build-20261118-1440.log`). The trees do offer an `aosp_cheetah` product, and AOSP
`android-17.0.0_r1` has a `cp2a` release config too. The first two things missing:

1. `find: 'device/google/pantah-kernels/6.1': No such file or directory`: the kernel and its
   modules come from Lineage's `pantah-kernels`, left out on purpose. Next: stand in Google's
   stock kernel and modules from the cheetah factory image.
2. `device/google/gs201/common.mk:125: error: hardware/google/pixel/rebalance_interrupts/rebalance_interrupts.mk: No such file or directory`:
   AOSP's `hardware/google/pixel` lacks the Pixel parts that Lineage's copy (now our
   `hardware_google_pixel` fork) carries. Next: use our fork there.

The make stops at the first product-config error, so later errors only show once these two are
fixed.

## Round 2 (2026-11-18 3:10 PM ET, measured)

With our `hardware_google_pixel` fork added (AOSP 17 has no `hardware/google/pixel` at all), the
product config passes. The board config stops next:
`device/google/pantah/cheetah/BoardConfig.mk:22: error: /BoardConfigCommon.mk: No such file or directory`
(a path whose folder variable is empty without Lineage). The kernel folder is still missing too.

## Round 3 (2026-11-18, measured)

`DEVICE_CODENAME`, `DEVICE_PATH` and `VENDOR_PATH` are set only in
`device/google/pantah/lineage_cheetah.mk:11-13` (and `lineage_panther.mk`); `aosp_cheetah.mk`
doesn't set them. The cheetah BoardConfig carries LineageOS and Calyx copyright lines: our device
tree itself is Lineage/Calyx-shaped, not Google's. `build-run` now exports the three names
before lunch.

## Round 4 (2026-11-18 3:36 PM ET, measured)

With the names set, the board config reads on to its kernel part and stops at
`$(error vendor_kernel_boot.modules.load not found or empty)` (line 250 of the board config,
`build-20261118-1536.log`): the kernel's module lists aren't there. As a stand-in only, to see
what fails after product config, the local manifest now adds Lineage's
`android_device_google_pantah-kernels` at the commit 1.0 used. Google's stock kernel replaces it
before anything boots.

## Round 5 (2026-11-18 3:40 PM ET, measured)

With the stand-in module lists, `lunch aosp_cheetah` passes for the first time: product and board
config are done. Soong's analysis then stops on the blobs:
`vendor/google/cheetah/Android.bp:802:1: unrecognized module type "rust_prebuilt_binary"` (and
line 827): `dump_modem` and `gpuflag` use a module type only Lineage's `build/soong` has
(`round-20261118-1539.log`). Stand-in for the next round, in the throwaway tree only:
`build-run` declares both as `cc_prebuilt_binary` without their Rust library links.

## Round 6 (2026-11-18 3:47 PM ET, measured)

Past the two binaries, Soong stops on the third Rust blob:
`vendor/google/cheetah/Android.bp:7764:1: module "libgpuflag_aconfig_rust" ...: Rust prebuilt modules not supported for non-system images.`
Lineage's `build/soong` allows Rust prebuilts on vendor; AOSP's doesn't. The stand-in now covers
it too (as a plain shared library). These three are Google's own vendor blobs, so a real AOSP
port needs either that Soong change carried in our own `build/soong` or the blobs packaged
another way.

## Round 7 (2026-11-18 3:56 PM ET, measured)

Past the Rust blobs, Soong stops on our own device tree:
`device/google/gs201/parts/Android.bp:7:1: "GoogleParts" depends on undefined module "org.lineageos.settings.resources"`.
Soong stops at the first such module, so from here `build-run` sets `ALLOW_MISSING_DEPENDENCIES=true`
and lists every missing module in one round. `build` now runs analysis only (`m -k nothing`, no
compiling); the new `full` query runs `m -k droid`, which takes hours and holds the server.
