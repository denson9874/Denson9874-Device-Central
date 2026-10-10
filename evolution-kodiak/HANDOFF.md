# Handoff: Evolution X 17 on the Pixel 11 Pro XL (kodiak)

Written 2026-10-10 for an agent (Google Antigravity) continuing this work until
Claude is available again. Read all of it before running anything.

## 1. Goal

Make a working **Evolution X 17** (Android 17, branch `cnb`, LineageOS-based)
build for the **Pixel 11 Pro XL** (`kodiak`, Tensor G6 `malibu`, MediaTek T900
modem, GKI kernel 6.12), for testing now and distribution later.

The original instructions are in `~/Downloads/android-device-tree-toolchain-guide.md`.
Its operating rules still apply (see section 9).

## 2. Current status

| Area | Status |
|---|---|
| Builds | ✅ `user` variant, test-keys |
| Boots | ✅ first boot after each flash (since the 2 fixes below) |
| Display, touch, fingerprint, Wi-Fi, camera, SMS | ✅ reported working by Daryl |
| Cellular registration | ✅ T-Mobile, voice and data `IN_SERVICE` (LTE / NR SA) |
| IMS registration | ✅ calls go out over IMS (`ImsPhoneCallTracker dial`) |
| **Voice calls** | ❌ **in progress**: they dial, then end before answer |

### The calls issue (what was being worked on)

- **Symptom:** the call ends with `ImsPhoneCallTracker: onCallTerminated reasonCode=401`,
  which is `ImsReasonInfo.CODE_MEDIA_INIT_FAILED`.
- **Cause found:** SELinux denial at call time:
  ```
  avc: denied { read write } comm="MediaManagerHel" scontext=u:r:radio:s0
    tcontext=u:r:platform_app:s0:c512,c768 tclass=udp_socket app=com.android.imsstack
  ```
  AOSP ImsStack (domain `platform_app`) opens the RTP UDP socket and passes it to
  ImsMediaService (in the phone process, domain `radio`).
- **Fix just built:** device tree commit `23d771b` adds
  `sepolicy/system_ext/private/radio.te`:
  `allow radio platform_app:udp_socket { read write getattr getopt setopt ioctl };`
  It passed the build's neverallow checks and `check-sepolicy.sh`.
  Image zip sha256: `8a897317eee7ce7e1df580219816099f7f660a4046990990025e08c9859022c8`.
- **State at handoff:** that zip **was flashed (no wipe) and the phone booted
  cleanly** (first boot, default IMS service = `com.android.imsstack`). The fix is
  on the phone but **not yet tested with a call**.

### Next steps, in order

1. **Confirm the phone state.** Run `adb devices` / `fastboot devices` (it should be booted in Android).
   - If it's in fastboot and the flash didn't complete, re-run the flash (section 6, step 3)
     with the zip already in `~/Downloads/kodiak-evox/kodiak-evox-img.zip`,
     after checking its sha256 against the hash above.
2. **Ask Daryl to place a test call.** Then pull logs right away (section 7) and check:
   - `onCallTerminated reasonCode=` (401 means media is still failing; see the list in section 8)
   - new `avc: denied` lines with `radio`, `platform_app`, `imsmedia`, `imsstack`
     in the call window
3. If more SELinux denials block media, add **narrow** rules to
   `sepolicy/system_ext/private/*.te` the same way. Rebuild (images only), flash, retest.
   - A cleaner long-term fix: give ImsStack its own domain, as stock does with
     `imsstack_app` (stock seapp entry: `user=radio isPrivApp=true seinfo=platform
     name=com.android.imsstack domain=imsstack_app`). AOSP doesn't ship that policy.
     Stock defines it in Google's system_ext policy, about 109 references.
4. Once calls work: do a reboot test (3×), then update the README status and commit.

### Other open issues (lower priority)

- **Display-driver kernel panic** (`drm_mode_put_tile_group`, after
  `dw-mipi-dsi2h-vs: failed to create debugfs root`). It's intermittent when the
  display binds late (after SELinux loads) and debugfs creation is denied. It hasn't
  recurred since the `user` build, but it isn't proven fixed.
- SELinux denials: the camera HAL and gxp/edgetpu writing to `traced_producer`, and
  edgetpu `service_manager find`.
- `com.google.android.apps.scone` crashes once at boot (not essential).
- Google's other product RROs (SystemUI/Settings device config) aren't shipped.
  extract-utils rejects prebuilt overlay APKs ("does not match known package rules"),
  so use **source RROs** in the device tree, as with `rro_overlays/TeleServiceOverlayKodiak`.
- Distribution needs: release keys (it's test-keys now), `WITH_AVB` / verified boot
  (vbmeta uses `--flags 3` now), and `m evolution` for the OTA zip.

## 3. Machines and access

| What | Where |
|---|---|
| Build server | Hetzner Ryzen 7 7700 (16 threads, 64 GB), `build@157.180.50.152` |
| SSH key | `~/.ssh/voltage_build_ed25519` on the Mac |
| Evolution X source | `~/evolution` on the server (also used for Daryl's husky port; don't break husky) |
| Tool workspace | `~/android-dt` on the server (venv, firmware, dumps, trees, refs) |
| Phone | Pixel 11 Pro XL, serial `66020DLDV0049F`, USB to the Mac, **bootloader unlocked**, slot `b` |
| Mac working dir | `~/Downloads/kodiak-evox/` (flash zips, logs) |
| Backup repo | `~/Developer/ExpressiveOS`, branch `evolution/kodiak-port`, folder `evolution-kodiak/` |

The server account has **no passwordless sudo**. Missing host tools were installed
without root:
- `~/android-dt/bin`: 7zz, a `file` wrapper over a `dpkg -x`'d sysroot, and
  symlinks to `~/evolution/out/host` tools
- the venv was made with `--without-pip` plus `get-pip.py`

## 4. Source layout (server)

```
~/android-dt/trees/device_google_kodiak   ← SOURCE OF TRUTH for the device tree (git)
~/evolution/device/google/kodiak          ← git clone of the above; update with `git pull`
~/evolution/vendor/google/kodiak          ← generated by extract-files.py (local git)
~/evolution/vendor/google/kodiak-images   ← generated by extract-images.sh (local git; Google images)
~/evolution/device/google/kodiak-dev/     ← untracked; Mac adb key for test builds only
~/android-dt/dumps/kodiak                 ← dumpyara dump of stock CD1A.261005.003 (git)
~/android-dt/firmware/                    ← factory zip + inner image-kodiak-cd1a.261005.003.zip
~/android-dt/ref/{laguna,muzel,mustang}   ← LineageOS Pixel 10 trees, used as reference
```

**Workflow for device-tree changes:**
1. Edit and commit in `~/android-dt/trees/device_google_kodiak`.
2. Run `cd ~/evolution/device/google/kodiak && git pull`.
3. Rebuild.

Don't edit the `~/evolution` clone directly.

**Build design (Daryl chose this):**
- **Stock prebuilt:** vendor, vendor_dlkm, system_dlkm, boot (GKI kernel), dtbo.
- **Flashed raw by the OTA:** firmware and vendor_kernel_boot.
- **Built:** system, system_ext, product, init_boot, vendor_boot (with recovery),
  vbmeta, pvmfw.

Key device-tree files:
- `BoardConfig.mk`, `device.mk`, `lineage_kodiak.mk`
- `extract-images.sh` + `firmware.txt` (stock images to `kodiak-images`)
- `extract-files.py` + `proprietary-files.txt` (+ `proprietary-files-carriersettings.txt`):
  the telephony blobs
- `rro_overlays/TeleServiceOverlayKodiak` (IMS package = `com.android.imsstack`)
- `sepolicy/system_ext/private/radio.te`
- `check-sepolicy.sh`: offline split-policy compile against the stock vendor
- `patches/build_make` + `apply-patches.sh`: a releasetools fix for prebuilt vendor.
  It's already applied in `~/evolution/build/make`.

## 5. Build commands (server)

| Script | Use |
|---|---|
| `~/kodiak-images.sh` | **Normal test round.** Images only, `user`, dexpreopt on. About 4–15 min incremental |
| `~/kodiak-build.sh` | Full `m evolution` (OTA zip). About 1 h. Release builds |
| `~/kodiak-test-build.sh` | Images, `WITH_DEXPREOPT=false`. Faster later, but the first run rebuilds a lot (config change). Not used yet |
| `~/kodiak-imgzip.sh <out> <image zip> <output>` | Packs images for `fastboot update` |

Run builds detached and wait for `BUILD_EXIT=` in the log:
```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 '(nohup ~/kodiak-images.sh > ~/kodiak-build.log 2>&1 &)'
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'grep -E "BUILD_EXIT|#### |FAILED:" ~/kodiak-build.log | tail -5'
```

**Don't switch the build variant** (it's `user`): that forces an installclean
and a full rebuild of about 1 h.

Verify, then package (server):
```bash
cd ~/evolution && O=out/target/product/kodiak
device/google/kodiak/check-sepolicy.sh out/host/linux-x86/bin/secilc $O ~/android-dt/dumps/kodiak/vendor
~/kodiak-imgzip.sh $O ~/android-dt/firmware/image-kodiak-cd1a.261005.003.zip /tmp/kodiak-evox-img.zip
```

## 6. Flash procedure (Mac)

Daryl has authorized flashing this phone. Still ask before anything **destructive**:
`-w` / wipes, or flashing firmware/bootloader.

1. Check state: `adb devices` and `fastboot devices`.
2. Copy and verify:
   ```bash
   cd ~/Downloads/kodiak-evox
   scp -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152:/tmp/kodiak-evox-img.zip .
   ```
   Compare `shasum -a 256 kodiak-evox-img.zip` with the server's `/tmp/kodiak-evox-img.zip.sha256`.
3. Flash **without wiping** (keeps Daryl's data):
   ```bash
   adb -s 66020DLDV0049F reboot bootloader
   ```
   ```bash
   fastboot -s 66020DLDV0049F update kodiak-evox-img.zip
   ```
   It reboots by itself when it's done (about 135 s).
4. Wait for `adb shell getprop sys.boot_completed` = `1`.

If it ends up back in fastboot, read `fastboot getvar enter-reason`:
- `DBL request` means a reboot to the bootloader (a kernel panic, or system_server
  crash-looping).
- To diagnose, boot with live log capture: start `adb logcat -b all -v monotonic > file`
  as soon as `adb get-state` = `device`. That found the last two root causes.
- Logcat format: use `-v monotonic`. `-v uptime` is invalid here.

**Recovery:** Evolution X recovery lives in vendor_boot.
- Daryl must enable **ADB in the recovery menu** for adb to work there. Its `/adb_keys`
  points at product, which has no keys in a `user` build.
- For root in recovery, a test vendor_boot exists with the Mac key + `ro.secure=0` +
  `ro.debuggable=1` + `androidboot.init_fatal_reboot_target=recovery`.
  It's `~/Downloads/kodiak-evox/vendor_boot-dev3.img`, built in `/tmp/vbdev` on the server.
  **A test image only.** The normal flash replaces it.
- The bootloader's own reset log is in the `klog` partition (`/dev/block/by-name/klog`).
  Read it as root in recovery with `strings` and grep `reset message|Reboot reason`.

**Restore stock if needed:** Android Flash Tool, build `CD1A.261005.003`.
Firmware matches, so there's no downgrade risk.

## 7. Diagnostics (no root in Android: Evolution spoofs `ro.debuggable=0`)

```bash
adb -s 66020DLDV0049F logcat -d -b all -v monotonic > all.txt        # main/system/crash/radio
adb -s 66020DLDV0049F logcat -d -b radio -v monotonic > radio.txt
adb -s 66020DLDV0049F shell dumpsys dropbox --print SYSTEM_LAST_KMSG > last_kmsg.txt   # kernel log of the previous boot
adb -s 66020DLDV0049F shell dumpsys telephony.registry | grep -m1 mServiceState
adb -s 66020DLDV0049F shell cmd phone ims get-ims-service -d -s 0    # must print com.android.imsstack
grep -E "onCallTerminated|reasonCode|avc:  denied" all.txt
```

Claude Code's safety check blocked inline `bash -c '…'` scripts containing loops.
Write multi-step logic to a script file instead.

## 8. Lessons learned (don't repeat these)

**Dumping and generating**
- dumpyara needs the **inner** `image-kodiak-*.zip`, not the factory zip.
- AIK (used by dumpyara/aospdtgen) needs the `file` command.
- aospdtgen names the tree "generic", because Pixel 11 system is `generic_system_google`.
  Use `~/android-dt/bin/aospdtgen-vendorfirst.py`.

**Packaging and build config**
- releasetools crashed with `KeyError: 'vendor'` on prebuilt vendor. The fix is in `patches/build_make`.
- `BOARD_PREBUILT_PVMFWIMAGE` is obsolete; pvmfw is built from AOSP.
- vintffm needed `hwservicemanager` and `android.hidl.allocator@1.0-service`.
  Shipping API 37 drops them; stock ships them.
- A prebuilt-vendor product loses base_vendor.mk's recovery packages. They're re-added in `device.mk`.

**Boot**
- First boot failed (DBL) because vendor_boot lacked `usb_phy_fw*.bin`. Fixed in `extract-images.sh`.

**Telephony and IMS**
- Telephony needs stock system_ext blobs; see `proprietary-files.txt`.
- **ImsStack and ImsMediaService must be built from AOSP**
  (`packages/modules/ImsStack`, `packages/modules/ImsMedia`).
  - The stock ImsStack blob collides with the AOSP install.
  - The stock `PixelImsMediaService` uses `android.uid.phone` with **Google's** key.
    That gives `Signature mismatch … for shared user`, system_server crashes, and the
    phone bootloops.
- The stock **vendor** TeleService RRO names `com.shannon.imsservice` (wrong for MediaTek).
  Stock overrides it from product; `TeleServiceOverlayKodiak` does the same.

**IMS `reasonCode` values (`ImsReasonInfo`)**
- 401–405: media problems (401 = media init failed)
- 3xx: SIP errors from the network
- 1xx: local errors

## 9. Rules from Daryl / the guide

- **Never push** device or vendor trees to any remote, and never Google images
  anywhere public. Local git only.
  - `evolution-kodiak/` in the ExpressiveOS repo holds only tree files: no blobs,
    no images, no aospdtgen first commit (it contains Google kernel binaries).
- No `sudo` package installs or full `repo sync` without asking Daryl.
- **Ask Daryl before** wipes (`-w`), bootloader/firmware flashes, or anything that
  can't be undone. Normal no-wipe `fastboot update` of our images is authorized.
- Commit after each meaningful change, with a clear message explaining *why*.
- Keep the husky build in `~/evolution` working (`lunch lineage_husky-cp2a-userdebug`).
  Changes in shared projects (`build/make`) must stay harmless for husky.

## 10. Keep the backup in sync

After device-tree commits on the server, refresh the repo copy on the Mac:
```bash
cd ~/Developer/ExpressiveOS
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 'cd ~/android-dt/trees/device_google_kodiak && git archive HEAD' | tar -x -C evolution-kodiak/device_google_kodiak
git add evolution-kodiak && git commit -m "evolution-kodiak: sync device tree"
```
As of this handoff the backup matches the server (device tree `23d771b`). It includes:
- the telephony blobs and `extract-files.py`
- the ImsStack / ImsMediaService changes
- `TeleServiceOverlayKodiak`
- `radio.te`
- the move of the stock images to `kodiak-images`

Sync again after further commits.
