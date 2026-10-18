# BCR in DerpFest for kodiak: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** plan only, written 2026-10-18. Nothing has been built, synced or changed on the server, in the device
trees or on the phone. **Waiting for Daryl's approval and his answers to the open questions at the end.**

**Goal:** Ship Basic Call Recorder (BCR, https://github.com/chenxiaolong/BCR) as a privileged system app in
Daryl's unofficial DerpFest builds for the Pixel 11 Pro XL (kodiak), without touching Evolution X or the public
device trees.

**Architecture:** BCR's signed upstream release (v3.11) is checked (zip checksum, SSH signature, APK certificate)
and its APK goes, unmodified and presigned, into `~/derpfest/vendor/extra/`. DerpFest's
`vendor/lineage/config/common.mk` already inherits `vendor/extra/product.mk` when it exists. That directory isn't
a repo project, so `repo sync` leaves it alone, and it doesn't exist in `~/evolution`. An `android_app_import`
installs it to `/system_ext/priv-app/BCR`, with BCR's privapp allowlist XML next to it. The repo keeps the text
files and the fetch script; the APK is fetched again from the pinned release, never committed.

**Tech Stack:** Soong (`android_app_import`, `prebuilt_etc`), product makefiles, bash, `ssh-keygen -Y verify`,
`apksigner`, Python 3 (`unittest`) for the release-notes change.

**Spec:** the task brief from the planning session of 2026-10-18, summarized under "Findings" below. Sources: `HANDOFF.md` (sections 2f, 2g, 2l, 2ac, 2af, 4, 9), read-only SSH
inspection of `~/derpfest` on the build server, and BCR's README, `app/build.gradle.kts`,
`app/src/main/AndroidManifest.xml`, `app/magisk/*` and `CHANGELOG.md` at tag `v3.11`.

## Global Constraints

- BCR version: **3.11** (released 2026-10-15). Zip `BCR-3.11-release.zip`, 2,787,358 bytes, SHA-256
  `a5c8c2cf611891992c072d28cf85ec275da27a77b5dbf2408c6398d5bccee918` (GitHub's asset digest).
- Zip signature key (chenxiaolong's `VERIFY_SSH_SIGNATURES.md`):
  `chenxiaolong ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4`, principal
  `chenxiaolong`, namespace `file`. Good output: `Good "file" signature for chenxiaolong with ED25519 key SHA256:Ct0HoRyrFLrnF9W+A/BKEiJmwx7yWkgaW/JvghKrboA`.
- APK signing certificate SHA-256 (BCR README): `d16f9b375df668c58ef4bb855eae959713d6d02e45f7f2c05ce2c27ae944f4f9`.
- Package name `com.chiller3.bcr`. Soong module name `BCR`. Install path `/system_ext/priv-app/BCR/BCR.apk`.
  Allowlist `/system_ext/etc/permissions/privapp-permissions-com.chiller3.bcr.xml`.
- **DerpFest only.** No change to `~/evolution`, `~/android-dt/trees/device_google_kodiak`,
  `evolution-kodiak/device_google_kodiak` or the public `denson9874/device_google_*` mirrors.
- The APK is never re-signed (presigned), so users can update BCR from upstream GitHub releases over the ROM copy.
- No BCR binaries in this repo (HANDOFF section 9: tree files only). `bcr/BCR.apk` and `bcr/LICENSE` are
  gitignored; `bcr/BCR.apk.sha256` and `bcr/VERSION` are committed as the record of what ships.
- Server work only when no other build is running: `~/.evolution-tree.lock` absent and
  `pgrep -f '[s]oong_ui'` empty (the brackets stop pgrep matching the ssh command line itself). Today the
  Evolution X release chain holds the lock (load about 28).
- `ssh …` in the steps below means `ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152`.
- No sudo, no `repo sync`, no `~/derp-sync.sh` for this work. No upload to Drive and no posting to XDA or
  Telegram without Daryl reviewing first. Nothing on the phone without Daryl's go-ahead. Never type his PIN.
- BCR is off until the user turns it on. No pre-granted runtime permissions.

## Findings

### How DerpFest for kodiak is built today

| | Evolution X | DerpFest |
|---|---|---|
| Source tree | `~/evolution` (branch `cnb`) | `~/derpfest`: `DerpFest-AOSP/android_manifest`, branch `17` (merged `lineage-24.0` on 2026-10-04). Uses `vendor/lineage`, so it's LineageOS-based |
| Sync | runner `sync` / `p11-routine.sh` | `~/derp-sync.sh`: `repo sync -c -n -j4 …` then `repo sync -c -l -j16` (last run 2026-10-16) |
| Build | `~/kodiak-build.sh`, `p11-routine.sh` | `~/derp-build.sh`: `lunch lineage_kodiak-cp2a-user`, `m -j16 derp`, `DERPFEST_BUILD_TYPE=Unofficial`. Last build 2026-10-17, 7:49 incremental |
| Device tree | `device/google/kodiak`: `git pull` from `~/android-dt/trees/device_google_kodiak`, HEAD `8ea61d5` | same origin, HEAD `6e108f1` (older), plus **3 uncommitted DerpFest-only edits**: `BoardConfig.mk` (`--flags 3` for `vbmeta_system` and `vbmeta_vendor`), `lineage_kodiak.mk` (`PRODUCT_BUILD_IGNORE_APEX_CONTRIBUTION_CONTENTS := true`), `proprietary-files.txt` (`TrafficLightFaceOverlay` commented out) |
| Vendor trees | `vendor/google/kodiak`, `kodiak-images` (local git) | own copies: `vendor/google/kodiak` (`4833f69`), `kodiak-images` (`398cf19`), `espada-kernel` (not git). No remotes |
| GMS | `vendor/gms` | `vendor/pixel/gms` (`PixelOS-AOSP/proprietary_vendor_pixel_gms-17`) |
| Keys | `vendor/evolution-priv` | `vendor/lineage-priv`; `vendor/evolution-priv` is a symlink to it |
| Local manifests | none for kodiak | none: `.repo/local_manifests/` is empty. Every kodiak directory is unmanaged, which `repo sync` leaves alone |
| Output | SourceForge + `evolution_ota` | `out/target/product/kodiak/DerpFest-v17-<date>-kodiak-Unofficial-Stable.zip` (OTA, sha256 printed by the build) and `kodiak.json`, then `~/kodiak-imgzip.sh` (`KODIAK_ROOT=none`) builds the fastboot zip, then `~/upload-to-drive.sh DerpFest kodiak …` (`~/bin/rclone` to `gdrive:DerpFest/kodiak`) |
| privapp allowlist | `ro.control_privapp_permissions=log` | also `log` (`vendor/lineage/config/common.mk:105`, despite its "Enforce" comment) |
| Backed up in this repo | `tools/`, HANDOFF | **nothing**: `derp-build.sh` and `derp-sync.sh` aren't in `tools/`, and HANDOFF.md has no DerpFest section |

Problems found in `derp-build.sh` (fixed in Task 2 because the BCR release goes through it):
- The fastboot zip name is hard-coded: `DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip`. The next build
  would reuse that name and `rclone copy` would overwrite the 2026-10-17 file on Drive with a different build.
- It uploads straight after a successful build, so there's no way to make a test build without publishing it
  to the Drive folder that the release notes point users to.
- The upload glob `DerpFest-v17*.zip` re-sends every older zip still in `out/`.

### What BCR needs on Android 17

- **Android 17 support:** v3.3 moved to target API 37 (Android 17). v3.11 builds with `compileSdk = 37`,
  `targetSdk = 37`, `minSdk = 28`.
- **Why it must be a privileged system app:** `CAPTURE_AUDIO_OUTPUT` (the `VOICE_CALL` audio source) and
  `CONTROL_INCALL_EXPERIENCE` (Telecom binds BCR's `RecorderInCallService` without BCR being the dialer) are
  `signature|privileged`. A user-installed app can't get them.
- **What the module zip installs** (from `app/build.gradle.kts`): `system/priv-app/com.chiller3.bcr/app-release.apk`,
  `system/etc/permissions/privapp-permissions-com.chiller3.bcr.xml` (the two permissions above),
  `system/addon.d/51-com.chiller3.bcr.sh`, Magisk scripts, `LICENSE`, `README.md`. A ROM needs only the APK and the
  XML. addon.d and the Magisk scripts are for adding BCR to someone else's ROM.
- **There is no default-permissions file.** Neither the v3.11 README nor the module ships one, contrary to what the
  brief expected. The one special case is `READ_CALL_LOG`, which is hard-restricted on Android 10+. BCR's
  `service.sh` works around it for modules added after first boot. On Android 17 the permission service
  (`frameworks/base/services/permission/.../AppIdPermissionPolicy.kt`, around line 1295) starts every restricted
  permission as `UPGRADE_EXEMPT` and drops that only when an installer is recorded. A preinstalled app has no
  installer, so `READ_CALL_LOG` should be grantable from Settings. Task 5 checks this. Fallback if it isn't: the
  README's unrooted method, `adb shell pm install /system_ext/priv-app/BCR/BCR.apk`, documented for users. The
  other option, a default-permissions XML with `whitelisted="true"` (read by `DefaultPermissionGrantPolicy` from
  `/system_ext/etc/default-permissions/`), would also **pre-grant** call-log access, so it's not recommended.
- **Other things the Magisk scripts work around:** a stale package-parser cache (`post-fs-data.sh`). This doesn't
  apply here: the cache key includes `ro.build.version.incremental`, which DerpFest sets to the build time
  (`1792258424`), so every build clears it. And a mislabeled `/data/user_de` directory on OxygenOS
  (`service.sh`), which doesn't apply either.
- **Known LineageOS issue** (README): Android sometimes fails to create BCR's app data directory
  (`Failed to prepare` in logcat). The README's fix is two `adb shell` commands (Task 5).

### Prebuilt vs building from source

**Prebuilt, presigned, pinned to v3.11.** Building from source is rejected:
- BCR is a Gradle/Kotlin/AGP project, not a Soong one. The server would need a JDK and the Android SDK
  installed without sudo, plus a Gradle cache, just to rebuild a 2.7 MB app.
- We'd have to sign it with our own key. Then users couldn't update from upstream releases (signature mismatch
  on top of the system copy), and we'd lose upstream's signature as proof of where the APK came from.

The prebuilt path is verified three ways (Task 1): the pinned zip SHA-256, chenxiaolong's SSH signature, and the
APK certificate digest from the README.

### Where it lives, and why it survives `repo sync`

| Option | Verdict |
|---|---|
| Device tree `PRODUCT_PACKAGES` + `Android.bp` in `device/google/kodiak` | **No.** That tree is shared with Evolution X (same origin, synced from GitHub) and mirrored publicly for downstream ROMs. Adding a call recorder there would change their builds too |
| `vendor/google/kodiak` (blob tree) | **No.** It's generated by `extract-files.py` from `proprietary-files.txt`, and BCR isn't a stock blob |
| Local manifest project | **Not needed.** It would need a git remote hosting the APK. `.repo/local_manifests/` is empty today, and adding one would make a future `repo sync` fetch that remote |
| **`~/derpfest/vendor/extra/`** | **Yes.** `vendor/lineage/config/common.mk:2` runs `$(call inherit-product-if-exists, vendor/extra/product.mk)`. It isn't in the DerpFest manifest, so `repo sync` doesn't touch it (like the kodiak trees today). It's absent from `~/evolution` and from every public tree. A local git in it records changes, as `vendor/google/kodiak` does |

Partition: **`system_ext`.** `lineage_kodiak.mk` uses `generic_system.mk` with artifact-path checks, so a device
makefile can't add to `/system` without extending the allow-list. `system_ext` is where DerpFest's own privileged
apps and the telephony stack already live. The allowlist XML must be on the same partition as the app.

Soong details: `android_app_import` supports `presigned`, `preprocessed`, `privileged` and `system_ext_specific`,
but not `privapp_allowlist` (that's `android_app` only). So the XML ships as a `prebuilt_etc` listed in `required`.
`build/soong/scripts/check_prebuilt_presigned_apk.py` sets two rules:
- A presigned APK with `targetSdkVersion >= 30` **must set `preprocessed: true`**, or the build stops ("the build
  system would wreck that signature otherwise"). BCR targets 37. With `preprocessed`, Soong also leaves the dex
  as it is instead of uncompressing it.
- A preprocessed APK must pass `zipalign -c -p 4`, store any `lib/*.so` uncompressed and, because it's privileged
  here, store its `classes*.dex` uncompressed. AGP stores dex uncompressed for `minSdk >= 28`. Task 1 runs the same
  checks before any build.

### SELinux and permissions

- BCR's certificate isn't in `mac_permissions.xml`, so it gets `seinfo=default`. With `isPrivApp=true` it runs as
  `u:r:priv_app:s0` with `privapp_data_file` data. Capture through audioserver and Telecom's InCallService binding
  are normal app paths. **No sepolicy change**, so nothing touches the "public types only if the stock vendor
  names them" rule. `check-sepolicy.sh` must still print `OK` (Task 4).
- The privapp allowlist is `log` on this build, so a missing entry would only log
  `Privileged permission … for package com.chiller3.bcr … not in privileged permission allowlist`. We ship the XML
  anyway, so the build keeps booting if DerpFest switches to `enforce`, and Task 5 checks that this line never
  appears.

### Google Phone and other call-audio users on kodiak

- DerpFest ships `GoogleDialer` (`product/priv-app/GoogleDialer`). `privapp-permissions-google-p.xml` gives
  `com.google.android.dialer` `CAPTURE_AUDIO_OUTPUT`, `CONTROL_INCALL_EXPERIENCE` and
  `BYPASS_CONCURRENT_RECORD_AUDIO_RESTRICTION`. The build also ships
  `product/etc/permissions/com.google.android.apps.dialer.call_recording_audio.features.xml`, which turns on
  Google Phone's own call recorder. That recorder announces itself and depends on the region.
- BCR doesn't need the dialer's cooperation. Telecom binds its non-UI InCallService for every call because BCR
  holds `CONTROL_INCALL_EXPERIENCE` (with `INCLUDE_SELF_MANAGED_CALLS`). The README lists the Google dialer among
  the ones that log the original number for redirected calls.
- **Conflict risk:** the README says one call can't usually be recorded by two apps, and asks users to turn off
  the dialer's AI features, which use the same APIs. On this build those include Google Phone's recorder, Call
  Screen, Call Notes/Call Assist, Scam Detection (`com.google.android.apps.pixel.psi`) and Voice Translate (both
  enabled on Daryl's phone through PCS, HANDOFF 2l). Android System Intelligence (`com.google.android.as`) also
  holds `CAPTURE_AUDIO_OUTPUT`. Task 5 tests BCR with these on and off.
- **Audio HAL:** stock enables Google Phone's call recording on this hardware, which suggests the stock audio HAL
  supports in-call capture with the MediaTek T900 modem. Whether stereo (uplink and downlink on separate channels)
  works is unverified; the README calls it Pixel-only.

### Legal notice and announcement tone (for the release notes)

- BCR **never plays an announcement or beep** into the call. Its README says so explicitly and leaves consent to
  the user. Adding a tone would mean forking BCR and re-signing it, which this plan rejects (it would break
  updates and the signature check). Google Phone's built-in recorder does announce, but it's region-limited and
  shouldn't run together with BCR.
- Many places require every party's consent to record a call (for example several US states, such as California,
  Florida and Washington, and countries such as Germany). The release notes must say that BCR is off by default,
  doesn't announce, and that users are responsible for following the law. They can also mention BCR's auto-record
  rules, which can discard recordings by default.
- BCR is GPL-3.0-only. We ship it unmodified, so the notes link the exact source tag
  (https://github.com/chenxiaolong/BCR/tree/v3.11) and `vendor/extra/bcr/` keeps `LICENSE` and `NOTICE`.

## Review Focus

Failure modes the tasks' build checks can't catch, most likely first. Each one has a step in Task 5:
1. **Silent or failed recordings while Google Phone or Pixel AI features hold the call audio** (Call Screen, Call
   Notes, Scam Detection, Voice Translate, Google Phone's recorder). Expected: BCR records with them off; with
   them on, either it still records or the release notes tell users which ones to turn off (Task 5, step 7).
2. **Dirty upgrade from the 2026-10-17 build** (BCR appears as a new system app on an existing `/data`).
   Expected: `READ_CALL_LOG` is exempt and the app data directory exists, the same as on a clean install
   (Task 5, step 9).
3. **Wi-Fi calling (Iwlan) and VoNR calls** take different audio paths than VoLTE. Expected: both record
   (Task 5, step 6).
4. **Calls before the first unlock after a reboot.** Expected: recorded, then moved to the output directory after
   unlock (Task 5, step 8).
5. **A future BCR bump that adds a privileged permission.** Expected: `bcr-fetch.sh` refuses the update until our
   allowlist XML matches upstream's, so `log` mode never hides a missing entry (Task 1, step 2).

---

### Task 1: Pinned fetch-and-verify script

**Files:**
- Create: `evolution-kodiak/tools/bcr-fetch.sh` (run on the server as `~/bcr-fetch.sh`)

**Interfaces:**
- Produces: `bcr-fetch.sh <dest-dir>`. Requires `<dest-dir>/privapp-permissions-com.chiller3.bcr.xml` to exist
  (from Task 3). On success it writes `<dest-dir>/BCR.apk`, `<dest-dir>/BCR.apk.sha256` (a `sha256sum` line
  naming `BCR.apk`), `<dest-dir>/VERSION` (`3.11`) and `<dest-dir>/LICENSE`, prints `BCR_FETCH=OK version=3.11`
  and exits 0. On any failure it prints `BCR_FETCH=FAIL <reason>`, exits 1 and leaves `<dest-dir>` unchanged.
- Pins at the top, each overridable from the environment for the negative test: `BCR_VERSION=3.11`,
  `BCR_ZIP_SHA256` and `BCR_CERT_SHA256` (Global Constraints values), and the trusted-key line. Tools:
  `APKSIGNER` defaults to `~/derpfest/out/host/linux-x86/bin/apksigner`; `curl`, `unzip`, `ssh-keygen`,
  `sha256sum` are on the server.

The checks run in this order, all inside a fresh `mktemp -d` that's removed on exit:
1. Download `https://github.com/chenxiaolong/BCR/releases/download/v${BCR_VERSION}/BCR-${BCR_VERSION}-release.zip`
   and the same URL with `.sig` (`curl -fL`).
2. Zip SHA-256 equals `BCR_ZIP_SHA256`. Reason on failure: `zip checksum mismatch`.
3. `ssh-keygen -Y verify -f <trusted_keys> -I chenxiaolong -n file -s <zip>.sig < <zip>` exits 0. Reason:
   `bad zip signature`.
4. Extract `system/priv-app/com.chiller3.bcr/app-release.apk`, `system/etc/permissions/privapp-permissions-com.chiller3.bcr.xml`
   and `LICENSE`.
5. The build's preprocessed-APK rules: `zipalign -c -p 4 app-release.apk` exits 0 (reason: `bad zip alignment`),
   and `unzip -v app-release.apk` shows method `Stored` for every `classes*.dex` and every `lib/*.so` (reason:
   `dex or JNI compressed`). `ZIPALIGN` defaults to `~/derpfest/out/host/linux-x86/bin/zipalign`.
6. `apksigner verify --print-certs app-release.apk` prints `certificate SHA-256 digest: ${BCR_CERT_SHA256}`.
   Reason: `apk certificate mismatch`.
7. The sorted `permission name="…"` values in upstream's XML equal those in `<dest-dir>`'s XML. Reason:
   `privapp permissions changed upstream`.
8. Only now copy the outputs into `<dest-dir>`.

- [ ] **Step 1: Write the script and syntax-check it**

Run: `bash -n evolution-kodiak/tools/bcr-fetch.sh`
Expected: no output, exit 0.

- [ ] **Step 2: Negative tests (server, scratch dir, no build needed)**

```bash
scp -i ~/.ssh/voltage_build_ed25519 evolution-kodiak/tools/bcr-fetch.sh build@157.180.50.152:bcr-fetch.sh
scp -i ~/.ssh/voltage_build_ed25519 evolution-kodiak/derpfest_vendor_extra/bcr/privapp-permissions-com.chiller3.bcr.xml build@157.180.50.152:/tmp/bcrtest/
```
(Task 3 creates the XML. Write it first if you run Task 1 alone, and `mkdir /tmp/bcrtest` on the server.)

Run: `ssh … 'BCR_ZIP_SHA256=0000000000000000000000000000000000000000000000000000000000000000 ~/bcr-fetch.sh /tmp/bcrtest; echo rc=$?; ls /tmp/bcrtest'`
Expected: `BCR_FETCH=FAIL zip checksum mismatch`, `rc=1`, and only the XML in `/tmp/bcrtest`.

Run: `ssh … 'BCR_CERT_SHA256=00 ~/bcr-fetch.sh /tmp/bcrtest; echo rc=$?'`
Expected: `BCR_FETCH=FAIL apk certificate mismatch`, `rc=1`.

Run (after removing `CONTROL_INCALL_EXPERIENCE` from the `/tmp/bcrtest` copy of the XML): `ssh … '~/bcr-fetch.sh /tmp/bcrtest; echo rc=$?'`
Expected: `BCR_FETCH=FAIL privapp permissions changed upstream`, `rc=1`. Restore the XML afterwards.

- [ ] **Step 3: Positive run**

Run: `ssh … '~/bcr-fetch.sh /tmp/bcrtest && cat /tmp/bcrtest/BCR.apk.sha256 /tmp/bcrtest/VERSION'`
Expected: `BCR_FETCH=OK version=3.11`, a SHA-256 line for `BCR.apk`, and `3.11`. Then `rm -r /tmp/bcrtest`.

- [ ] **Step 4: Commit**

```bash
git add evolution-kodiak/tools/bcr-fetch.sh
git commit -m "evolution-kodiak: bcr-fetch.sh fetches BCR 3.11 and checks its checksum, signature and certificate"
```

### Task 2: `derp-build.sh`: test builds without upload, dated names, BCR check

**Files:**
- Create: `evolution-kodiak/tools/derp-build.sh` (start from the server's current `~/derp-build.sh`, then change it)
- Create: `evolution-kodiak/tools/derp-sync.sh` (verbatim copy of `~/derp-sync.sh`, unchanged)
- Server: `~/derp-build.sh` (keep the old one as `~/derp-build.sh.bak-<YYYYMMDD>`)

**Interfaces:**
- Consumes: `vendor/extra/bcr/BCR.apk.sha256` and `vendor/extra/bcr/VERSION` (Tasks 1 and 3).
- Produces: `derp-build.sh [--no-upload] [--check-only]`.
  - `check_extras` (function): passes only if `$O/system_ext/priv-app/BCR/BCR.apk` exists, its SHA-256 equals the
    hash in `vendor/extra/bcr/BCR.apk.sha256`, and `$O/system_ext/etc/permissions/privapp-permissions-com.chiller3.bcr.xml`
    exists. Prints `BCR_CHECK=OK version=<VERSION>` or `BCR_CHECK=MISSING <what>`.
  - `--check-only`: runs `check_extras` on the existing `out/` and exits 0 or 3. No lunch, no build.
  - After a successful `m derp`: `DATE` comes from the newest `$O/DerpFest-v17-*-kodiak-Unofficial-Stable.zip`
    (the 8 digits after `v17-`). The fastboot zip becomes `DerpFest-v17-${DATE}-kodiak-Unofficial-fastboot.zip`.
    The upload sends only `$O/DerpFest-v17-${DATE}-*` and `$O/kodiak.json`.
  - A failing `check_extras` skips packaging and upload and exits 3. `--no-upload` skips only the upload and
    prints `UPLOAD=SKIPPED (--no-upload)`. The last line is always `=== DerpFest Build Finished: … (EXIT=<n>) ===`.

- [ ] **Step 1: Copy both scripts into the repo unchanged and commit** (so the diff of Step 2 is reviewable)

```bash
scp -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152:derp-build.sh build@157.180.50.152:derp-sync.sh evolution-kodiak/tools/
git add evolution-kodiak/tools/derp-build.sh evolution-kodiak/tools/derp-sync.sh
git commit -m "evolution-kodiak: back up the server's DerpFest build and sync scripts"
```

- [ ] **Step 2: Make the changes above, then syntax-check**

Run: `bash -n evolution-kodiak/tools/derp-build.sh`
Expected: exit 0.

- [ ] **Step 3: Check that the check fails today** (server; `out/` is the 2026-10-17 build, which has no BCR)

Install it with `scp` (after backing up `~/derp-build.sh`), then run: `ssh … '~/derp-build.sh --check-only; echo rc=$?'`
Expected: `BCR_CHECK=MISSING …`, `rc=3`, and no build output.

- [ ] **Step 4: Commit**

```bash
git add evolution-kodiak/tools/derp-build.sh
git commit -m "evolution-kodiak: derp-build.sh: --no-upload, dated fastboot zip, BCR check before upload"
```

### Task 3: `vendor/extra` with BCR in the DerpFest tree

**Files:**
- Create: `evolution-kodiak/derpfest_vendor_extra/product.mk`
- Create: `evolution-kodiak/derpfest_vendor_extra/bcr/Android.bp`
- Create: `evolution-kodiak/derpfest_vendor_extra/bcr/privapp-permissions-com.chiller3.bcr.xml`
- Create: `evolution-kodiak/derpfest_vendor_extra/bcr/NOTICE`
- Create: `evolution-kodiak/derpfest_vendor_extra/.gitignore` (`bcr/BCR.apk`, `bcr/LICENSE`)
- Create: `evolution-kodiak/derpfest_vendor_extra/README.md` (what this is; deploy = Step 2 below; bump = re-run
  `bcr-fetch.sh` with new pins, rebuild, and commit `BCR.apk.sha256` and `VERSION`)
- Server: `~/derpfest/vendor/extra/` (new local git, never pushed)

**Interfaces:**
- Consumes: `bcr-fetch.sh <dest-dir>` (Task 1).
- Produces: Soong modules `BCR` and `privapp-permissions-com.chiller3.bcr.xml`. `PRODUCT_PACKAGES += BCR`
  through `vendor/extra/product.mk`. Task 2's `check_extras` passes after this task.

`product.mk`:
```make
# DerpFest-only additions for kodiak. vendor/lineage/config/common.mk inherits this file when it exists.
# Not a repo project, so `repo sync` leaves it alone. Backup: ExpressiveOS evolution-kodiak/derpfest_vendor_extra/

# Basic Call Recorder (chenxiaolong/BCR), prebuilt and presigned. bcr/README.md has the details.
PRODUCT_PACKAGES += \
    BCR
```

`bcr/Android.bp`:
```
// Basic Call Recorder (GPL-3.0-only), https://github.com/chenxiaolong/BCR
// BCR.apk is the unmodified upstream release APK, fetched and verified by tools/bcr-fetch.sh.
android_app_import {
    name: "BCR",
    apk: "BCR.apk",
    // targetSdkVersion 37: the build requires preprocessed for presigned APKs targeting 30+, and then keeps
    // the APK byte-for-byte (its v2/v3 signature stays valid).
    preprocessed: true,
    presigned: true,
    privileged: true,
    system_ext_specific: true,
    // Added during implementation: the first build failed the uses-library check without it.
    optional_uses_libs: ["androidx.window.extensions", "androidx.window.sidecar"],
    required: ["privapp-permissions-com.chiller3.bcr.xml"],
}

prebuilt_etc {
    name: "privapp-permissions-com.chiller3.bcr.xml",
    src: "privapp-permissions-com.chiller3.bcr.xml",
    sub_dir: "permissions",
    system_ext_specific: true,
}
```

`bcr/privapp-permissions-com.chiller3.bcr.xml` (the same permissions BCR's own build generates):
```xml
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="com.chiller3.bcr">
        <permission name="android.permission.CAPTURE_AUDIO_OUTPUT" />
        <permission name="android.permission.CONTROL_INCALL_EXPERIENCE" />
    </privapp-permissions>
</permissions>
```

`bcr/NOTICE`: one paragraph: BCR by Andrew Gunnerson (chenxiaolong), GPL-3.0-only, shipped unmodified;
corresponding source https://github.com/chenxiaolong/BCR/tree/v3.11; full license in `LICENSE`.

- [ ] **Step 1: Write the files and commit**

```bash
git add evolution-kodiak/derpfest_vendor_extra
git commit -m "evolution-kodiak: DerpFest vendor/extra with BCR as a presigned system_ext priv-app"
```

- [ ] **Step 2: Deploy to the server and fetch the APK** (only when the constraints' "no other build" check passes)

```bash
rsync -a --exclude .git -e "ssh -i ~/.ssh/voltage_build_ed25519" evolution-kodiak/derpfest_vendor_extra/ build@157.180.50.152:derpfest/vendor/extra/
```
```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 '~/bcr-fetch.sh ~/derpfest/vendor/extra/bcr && cd ~/derpfest/vendor/extra && git init -q && git add -A && git commit -qm "BCR 3.11 (presigned, verified by bcr-fetch.sh)" && git log --oneline -1'
```
Expected: `BCR_FETCH=OK version=3.11` and one commit line. Copy `bcr/BCR.apk.sha256` and `bcr/VERSION` back into
the repo copy and commit them.

- [ ] **Step 3: Build only the two modules** (Soong re-analyses the tree for the new `Android.bp`: several minutes of high CPU and RAM)

```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'cd ~/derpfest && source build/envsetup.sh >/dev/null && lunch lineage_kodiak-cp2a-user >/dev/null && m BCR privapp-permissions-com.chiller3.bcr.xml 2>&1 | tail -3'
```
Expected: `#### build completed successfully`. A failure in `check_prebuilt_presigned_apk.py` means alignment or
compressed dex/JNI, which Task 1 step 5 should have caught.

- [ ] **Step 4: Check that the installed files are untouched**

Run: `ssh … '~/derp-build.sh --check-only; echo rc=$?'`
Expected: `BCR_CHECK=OK version=3.11`, `rc=0` (the installed APK's SHA-256 equals the fetched one, so the build
didn't rewrite the presigned APK).

Run: `ssh … 'ls ~/evolution/vendor/extra 2>&1'`
Expected: `No such file or directory` (Evolution X unaffected).

### Task 4: Full DerpFest build without upload, image checks

**Files:** none (build and checks only).

**Interfaces:**
- Consumes: `derp-build.sh --no-upload` (Task 2), `vendor/extra` (Task 3).
- Produces: `out/target/product/kodiak/DerpFest-v17-<date>-kodiak-Unofficial-{Stable,fastboot}.zip` for Task 5.

- [ ] **Step 1: Start the build detached** (constraints' "no other build" check first)

```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'test ! -e ~/.evolution-tree.lock && ! pgrep -f "[s]oong_ui" && (nohup ~/derp-build.sh --no-upload > ~/derp-build.out 2>&1 &)'
```

- [ ] **Step 2: Wait for the result**

Run: `ssh … 'grep -E "EXIT=|BCR_CHECK=|UPLOAD=|FAILED:" ~/derp-build.out | tail -5'`
Expected: `BCR_CHECK=OK version=3.11`, `UPLOAD=SKIPPED (--no-upload)`, `(EXIT=0)`, and a fastboot zip named with
today's date.

- [ ] **Step 3: Check the target files (what actually goes into the image)**

Run: `ssh … 'ls ~/derpfest/out/target/product/kodiak/obj/PACKAGING/target_files_intermediates/*/SYSTEM_EXT/priv-app/BCR/BCR.apk ~/derpfest/out/target/product/kodiak/obj/PACKAGING/target_files_intermediates/*/SYSTEM_EXT/etc/permissions/privapp-permissions-com.chiller3.bcr.xml'`
Expected: both paths listed.

- [ ] **Step 4: SELinux check unchanged**

Run: `ssh … 'cd ~/derpfest && device/google/kodiak/check-sepolicy.sh out/host/linux-x86/bin/secilc out/target/product/kodiak ~/android-dt/dumps/kodiak/vendor | tail -2'`
Expected: `OK`.

- [ ] **Step 5: Copy the fastboot zip to the Mac and compare checksums** (HANDOFF section 6, step 2)

Expected: the `shasum -a 256` of `~/Downloads/kodiak-evox/DerpFest-v17-<date>-kodiak-Unofficial-fastboot.zip`
equals the server's `sha256sum`.

### Task 5: On-phone verification (needs Daryl)

**Files:**
- Modify: `evolution-kodiak/HANDOFF.md` (record the results in the section Task 6 adds)

**Interfaces:**
- Consumes: Task 4's zips. Flashing method and device per open question 1. **Ask Daryl first**: going from his
  Evolution X personal build to DerpFest is a ROM switch, which likely needs a wipe, and HANDOFF section 9 requires
  asking before wipes. Daryl unlocks the phone, places the test calls and picks who he calls. Never type his PIN.

- [ ] **Step 1: Installed as a privileged system app**

Run: `adb -s 66020DLDV0049F shell pm list packages -f com.chiller3.bcr`
Expected: `package:/system_ext/priv-app/BCR/BCR.apk=com.chiller3.bcr`

- [ ] **Step 2: Privileged permissions granted, allowlist complete**

Run: `adb -s 66020DLDV0049F shell dumpsys package com.chiller3.bcr | grep -E "versionName|CAPTURE_AUDIO_OUTPUT|CONTROL_INCALL_EXPERIENCE|READ_CALL_LOG"`
Expected: `versionName=3.11`; both privileged permissions `granted=true`; `READ_CALL_LOG` flags include an
`…EXEMPT` flag and not `APPLY_RESTRICTION`.

Run: `adb -s 66020DLDV0049F logcat -d -b all | grep -E "not in privileged permission allowlist|Failed to prepare" | grep chiller3`
Expected: no lines.

- [ ] **Step 3: Set up BCR** (Daryl, on the phone)

Open BCR (launcher, or `*#*#227#*#*`), turn on **Call recording**, grant microphone and notifications (also call
log, contacts and phone, to test those), pick an output directory, turn on **Write metadata file**, and turn on
debug mode by long-pressing the version. If the app crashes with `Failed to prepare`, apply the README fix:
`adb shell mkdir -p /sdcard/Android/data/com.chiller3.bcr/files` and
`adb shell chmod -R 777 /sdcard/Android/data/com.chiller3.bcr`.

- [ ] **Step 4: Start a log capture before the first call**

Run: `adb -s 66020DLDV0049F logcat -b all -v monotonic > ~/Downloads/kodiak-evox/bcr-test-logcat.txt` (leave it running)

- [ ] **Step 5: Outgoing and incoming VoLTE call with Google Phone** (about 30 s each, with the other party's consent)

Expected: each call leaves an `.oga` file, a `.json` and a debug `.log` in the output directory. The JSON has
`package_name` `com.android.phone`, `duration_secs_total` within a second or two of `duration_secs_wall`, and
`buffer_overruns` `0`. Playback has both voices.

Run during a call: `adb -s 66020DLDV0049F shell dumpsys telecom | grep -i chiller3`
Expected: `com.chiller3.bcr/.RecorderInCallService` is listed as bound.

Run: `adb -s 66020DLDV0049F shell ps -AZ | grep com.chiller3.bcr`
Expected: `u:r:priv_app:s0:…` while a call is active.

- [ ] **Step 6: Wi-Fi calling and VoNR** (Review Focus 3)

Repeat one call with Wi-Fi calling on and mobile data off, then one on 5G SA if the carrier gives VoNR. Expected:
both recorded, same JSON checks as Step 5.

- [ ] **Step 7: Call-audio conflicts** (Review Focus 1)

One call each with these features on, then off: Call Screen (incoming), Scam Detection, Call Notes/Call Assist if
offered, Voice Translate. Don't press Google Phone's own **Record**. Expected: write down which combinations give
a silent or failed BCR recording; they go into the release notes as "turn off X".

- [ ] **Step 8: Before first unlock** (Review Focus 4)

Reboot, don't unlock, take a short incoming call, then unlock. Expected: the recording appears in the output
directory a few moments after unlock.

- [ ] **Step 9: Dirty upgrade path** (Review Focus 2; only if open question 1 gives a device on the 2026-10-17 build)

Update a 2026-10-17 install to the new build without wiping, then repeat Steps 1 to 3. Expected: same results as a
clean install.

- [ ] **Step 10: SELinux**

Stop the capture, then run: `grep -E "avc: +denied" ~/Downloads/kodiak-evox/bcr-test-logcat.txt | grep -E "priv_app|chiller3"`
Expected: no lines.

- [ ] **Step 11: Record the results in HANDOFF.md and commit**

```bash
git add evolution-kodiak/HANDOFF.md
git commit -m "evolution-kodiak: BCR verified on kodiak (DerpFest <date>)"
```

### Task 6: Release notes and documentation

**Files:**
- Modify: `tools/community_monitor/release_publisher.py` (`main()`, `publish_release()`, new `format_changelog_items`)
- Test: `tools/community_monitor/tests/test_release_publisher.py`
- Create: `evolution-kodiak/community/notes/DerpFest_kodiak_BCR.txt`
- Modify: `evolution-kodiak/HANDOFF.md` (new section `2ag. DerpFest for kodiak, and BCR`: the Findings table,
  `vendor/extra`, the scripts, the release steps below; plus a line in the "Current state" header)

**Interfaces:**
- Produces: `format_changelog_items(items: List[str], style: str) -> str` (module level; `style` is `"bbcode"` or
  `"telegram"`). `publish_release(..., changelog_items: Optional[List[str]] = None)` passes
  `format_changelog_items(items, "bbcode")` and `format_changelog_items(items, "telegram")` as the existing
  `changelog_extra` arguments. New CLI flag `--changelog-extra-file PATH`: one item per non-empty line; lines
  starting with `#` are skipped.

- [ ] **Step 1: Write the failing tests** (in `TestReleasePublisher`)

```python
def test_format_changelog_items(self):
    self.assertEqual(format_changelog_items(["A", "B"], "bbcode"), "[*] A\n[*] B")
    self.assertEqual(format_changelog_items(["A"], "telegram"), "• A")
    self.assertEqual(format_changelog_items([], "bbcode"), "")

def test_dry_run_includes_changelog_items(self):
    res = self.publisher.publish_release(rom="DerpFest", device="kodiak", dry_run=True,
                                         changelog_items=["Basic Call Recorder (BCR) 3.11 built in"])
    draft = Path(res["draft_file"]).read_text(encoding="utf-8")
    self.assertIn("[*] Basic Call Recorder (BCR) 3.11 built in", draft)
    self.assertIn("• Basic Call Recorder (BCR) 3.11 built in", draft)
```
(Import: `from release_publisher import ReleasePublisher, format_changelog_items`.)

- [ ] **Step 2: Run them and see them fail**

Run: `./tools/community_monitor/venv/bin/python -m unittest tools.community_monitor.tests.test_release_publisher -v`
(or `python3 -m unittest discover -s tools/community_monitor/tests -p test_release_publisher.py -v` without the venv)
Expected: FAIL with `ImportError: cannot import name 'format_changelog_items'`.

- [ ] **Step 3: Implement `format_changelog_items`, the `publish_release` parameter and `--changelog-extra-file`**

- [ ] **Step 4: Run the whole suite**

Run: `./tools/community_monitor/venv/bin/python -m unittest discover -s tools/community_monitor/tests`
Expected: `OK`, including the existing tests.

- [ ] **Step 5: Write `evolution-kodiak/community/notes/DerpFest_kodiak_BCR.txt`** (fixed text; adjust the
"turn off" line with Task 5 step 7's results)

```text
# DerpFest kodiak: BCR items for the release notes (release_publisher.py --changelog-extra-file)
Basic Call Recorder (BCR) 3.11 by chenxiaolong is built in as a system app (GPL-3.0, source: https://github.com/chenxiaolong/BCR/tree/v3.11)
BCR is off until you open it and turn on Call recording. It asks for microphone and notification access
BCR plays no announcement or beep: the other party is not told that the call is being recorded
Many places require every party's consent to record a call. You are responsible for following the law where you and the other party are
While BCR records, don't use Google Phone's own Record button, and turn off Call Screen and the other call AI features listed in the notes
Newer BCR releases from GitHub install over the built-in copy (same signature)
```

- [ ] **Step 6: Write the HANDOFF section and commit**

```bash
git add tools/community_monitor/release_publisher.py tools/community_monitor/tests/test_release_publisher.py evolution-kodiak/community/notes/DerpFest_kodiak_BCR.txt evolution-kodiak/HANDOFF.md
git commit -m "evolution-kodiak: DerpFest release notes take extra changelog items; document DerpFest and BCR"
```

- [ ] **Step 7: Release** (Daryl's call, after Task 5 passes)

Upload only this build:
```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 '~/upload-to-drive.sh DerpFest kodiak ~/derpfest/out/target/product/kodiak/DerpFest-v17-<date>-* ~/derpfest/out/target/product/kodiak/kodiak.json'
```
Draft the announcement for Daryl to review (no posting):
```bash
python3 tools/community_monitor/release_publisher.py --device kodiak --rom DerpFest --changelog-extra-file evolution-kodiak/community/notes/DerpFest_kodiak_BCR.txt --dry-run
```
Expected: a draft in `evolution-kodiak/community/replies/RELEASE_DerpFest_kodiak_<date>.md` that contains the BCR
items. Daryl posts it himself.

## Rollback

- Remove BCR from the next build: delete the `BCR` line in `~/derpfest/vendor/extra/product.mk` (or move
  `vendor/extra` away) and rebuild. An update to a build without BCR removes the system app. Its data stays in
  `/data/data/com.chiller3.bcr` until the user clears it, and recordings stay in the user's output directory.
- `~/derp-build.sh.bak-<date>` restores the old build script.

## Open questions for Daryl

1. **Which phone, and when?** According to HANDOFF, your kodiak runs the rooted Evolution X personal build. Testing DerpFest on it is a ROM
   switch, which likely needs a wipe. Is there a second kodiak or a tester on DerpFest? Alternatively, as a cheap
   first check of the audio path, you could flash BCR's own Magisk module on your current rooted Evolution build,
   make one test call, then remove the module. That tests the hardware, not the DerpFest integration.
2. **Public or test-only?** Ship BCR in the public DerpFest builds on Drive, or only in test builds? Recording
   laws are the main exposure; the notes above cover them, but it's your release.
3. **Release-notes wording.** Is the legal line in `DerpFest_kodiak_BCR.txt` enough, or do you want it in the XDA
   first post too?
4. **Pre-granted permissions.** The plan grants nothing by default, so users approve the microphone and other
   permissions themselves. Do you want call-log access pre-granted instead (a default-permissions file)?
   Recommended: no.
5. **Evolution X too?** Out of scope here. `vendor/extra` would work the same way in `~/evolution`, but it would
   need its own decision, especially for official maintainership (HANDOFF 2ac).
6. **Updating BCR.** Bump the pin when upstream releases (re-run `bcr-fetch.sh` with new pins, rebuild), or stay on
   3.11 until something breaks?

## Follow-ups (outside this plan)

- The 3 uncommitted DerpFest-only edits in `~/derpfest/device/google/kodiak` (Findings table) exist only on the
  server. A `git reset` or a conflicting `git pull` would lose them. They should be committed on a DerpFest branch
  or saved as a patch in this repo.
- `~/derpfest/device/google/kodiak` is at `6e108f1`, older than Evolution's `8ea61d5`. Decide whether DerpFest
  builds should follow the tree's HEAD.
- `vendor/lineage/config/common.mk` in DerpFest says "Enforce privapp-permissions whitelist" but sets `log`.
  Switching to `enforce` would turn any missing allowlist entry (not just BCR's) into a bootloop, so it would need
  a full `not in privileged permission allowlist` sweep first.
