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
