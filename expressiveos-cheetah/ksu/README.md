# KernelSU Next for ExpressiveOS (cheetah)

ExpressiveOS's cheetah (Pixel 7 Pro) builds ship [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next)
with susfs in `init_boot`, in the fastboot zip and in every OTA, with the manager preinstalled
(Daryl, 2026-10-25). This folder is only the KernelSU Next part of the ExpressiveOS kit; the tree,
keys, names and OTA feed are the kit's own. **None of it applies to the Evolution X cheetah build**
(`evolution-cheetah/`), which stays unrooted: every script here refuses
`~/evolution` and `~/derpfest`.

## How it works

- **LKM over Google's kernel.** The kernel stays Google's signed GKI (android14-6.1). Our own
  `kernelsu.ko` and `ksuinit` go into `init_boot`'s ramdisk, as the manager's own "patch a file"
  does. susfs is KernelSU Next's `susfs_guard_lkm.ko`, which `ksud` loads at boot when SUSFS
  auto-load is on. **It is on from a new phone's first boot** (Daryl, 2026-10-27; first-boot setup,
  below), and the user can turn it off in the manager. If KernelSU Next breaks on a Google kernel
  update, a source-built GKI with the driver and susfs v2.3.0 built in (as Espada does on 6.12) is
  the fallback.
- **Zygisk: NeoZygisk, preinstalled** (Daryl, 2026-10-27). `ksu.conf` pins NeoZygisk v2.4
  (JingMatrix, GPL-3.0, with LSPlt, LGPL-3.0): its release zip's sha256, module id and versionCode,
  and its source commit and LSPlt's. It's the provider whose stable release hooks cnb's Android 17
  `Zygote.nativeForkAndSpecialize` with the right arguments, it speaks KernelSU Next v3.4.2's
  interface, and it needs no metamodule; ReZygisk v1.0.0 hooks cnb only through its Samsung entry,
  which hands modules the wrong argument. `fetch-ksu.sh` downloads the zip and its source
  (`~/android-dt/ksu/zygisk-<version>/`), and `tools/zygisk-zip.py` checks the zip without running
  any of it: module.prop, every file against its `.sha256`, and none of KernelSU Next's risk rules
  matching (a match would stop the install on the phone). The ROM carries it unmodified as
  `/product/etc/eos/zygisk-provider.zip`, with both licences and the source link in
  `NOTICE-NeoZygisk`. Re-pin only after a phone test: v2.5 rewrites the boot stages. Check the
  pin again whenever KernelSU Next moves or a tree sync changes `Zygote.java`.
- **First-boot setup** (`tree/eos-ksu-firstboot.rc`, `tree/ksu-firstboot.sh`). A wiped phone has no
  `/data/adb/ksud`, so the lines our `kernelsu.ko` adds to `init.rc` find nothing to run until the
  manager is opened once. Two init services from `/product` run the ROM's own `libksud.so` in the
  `ksu` domain those lines use, so only `ksud` writes `ksud`'s state:
  - at post-fs-data, `ksud install` when `/data/adb/ksud` is missing or an OTA changed the ROM's
    `libksud.so` (never just because `/data/adb/ksud` differs: that is a manager update the user
    took). On a new `/data` only (no `packages.xml` yet), `susfs autoload enable --kmi
    android14-6.1`; `ksud`'s own post-fs-data loads susfs from the second boot on (the first had no
    `ksud` yet to do it), honouring the user's switch and KernelSU safe mode;
  - at boot_completed, on a new `/data` only, `ksud module install` of the provider zip, unless a
    Zygisk is already there (one the user installed, a NeoZygisk they updated, or one turned off)
    or the phone is in Android's safe mode. A NeoZygisk a failed or cut-off try of ours left
    behind is installed again, unless safe mode or the user has turned it off since.
    **susfs and Zygisk are both active from the second boot**, like any KernelSU module.

  Each one-time step has a marker in `/data/adb/eos`, is tried on at most three boots if it fails,
  and never runs again once done, so nothing the user turns off or removes comes back; what
  happened is in `/data/adb/eos/log`. A `/data` that has booted before (an older build, a no-root
  user an OTA re-rooted) gets `ksud` and nothing else. On a stock init_boot the `ksu` domain doesn't exist:
  both services fail to start (two lines in the log each boot) and nothing else happens.
- **Pinned release** (`ksu.conf`): the version, the host `ksud` (`ksud-x86_64-unknown-linux-musl`)
  and the manager APK, each with its SHA-256, plus the manager's signing certificate. `fetch-ksu.sh`
  downloads them to `~/android-dt/ksu/<version>/` and refuses anything that doesn't match; the
  certificate must be the one KernelSU Next's kernel module trusts (`KSU_NEXT_MANAGER_HASH` in its
  `kernel/Kbuild`). It also checks out the release's source at `src_commit` for our module. To
  update KernelSU Next, change every line together and check `kernel-patches/` still applies.
- **Our own `kernelsu.ko`** (`tools/ksu-module.sh [top]`, Daryl, 2026-10-25). KernelSU Next v3.4.2
  only looks for the manager under `/data/app` (`search_manager()` in
  `kernel/manager/throne_tracker.c`), and a preinstalled system app isn't there until it's updated.
  `kernel-patches/0001` adds a fallback: when the `/data/app` search finds nobody, the kernel checks
  `/product/app/KernelSUNext/KernelSUNext.apk` and crowns it only if its signature passes the same
  `is_manager_apk()` check and `com.rifsxd.ksunext` is in `packages.list`. The script builds the
  module from the pinned source against the GKI source `build_kernel` synced
  (`out-kernel/google/gs-6.1/common/gki`, the tag Google's prebuilt GKI comes from) with that tree's
  own clang (`CLANG_VERSION` in `build.config.constants`) and pahole
  (`prebuilts/kernel-build-tools/linux-x86/bin/pahole`, v1.23 like Google's): `gki_defconfig`,
  `modules_prepare`, `CONFIG_KSU=m`. pahole matters: its version turns on
  `CONFIG_DEBUG_INFO_BTF_MODULES`, which adds 64 bytes to `struct module`. The first build
  (2026-10-26) had no pahole, so its module was built for a 1,024-byte `struct module` where the
  kernel's is 1,088. The module has no symbol versions, so 6.1 loaded it anyway, and the phone
  panicked in `load_module` on every boot. The patch isn't committed, so the module keeps the release's version (33355, the
  manager's); debug info is stripped (about 430 KB). `ksuinit` loads it by resolving symbols from
  `/proc/kallsyms`, so it needs the same struct layout as Google's kernel, not a matching build ID:
  `cheetah-ksu.sh` checks its sublevel against `boot.img`'s kernel, its `struct module` against
  the first-stage modules of the same build (`vendor_kernel_ramdisk/lib/modules`), and its whole
  `.config` against the one built into `boot.img`'s kernel (`tools/ko-info.py`; only options that
  describe Google's build host are left out). Tested here by building it against
  android14-6.1-2025-09_r9 (6.1.145) with clang 18.
- **Tree patches** (`patches/device_google_pantah/0101`-`0102`, applied by `apply-ksu.sh` after the
  kit's own pantah patches `0001`-`0010`, which `../prepare.sh` puts in first):

  | Patch | Change |
  |---|---|
  | `0101` | Adds `KernelSUNext` to `PRODUCT_PACKAGES` and `ksu/config.fs` to `TARGET_FS_CONFIG_GEN`, so `libksud.so` is installed root:root 0755 (the manager runs it as a program) |
  | `0102` | With `CHEETAH_KSU_INIT_BOOT` set, `BOARD_PREBUILT_INIT_BOOT_IMAGE` is that image: the build re-signs it with the tree's init_boot AVB key and ships it in target-files, so in the images and the OTA |

- **The manager module** (`tree/Android.mk`, staged by `apply-ksu.sh` as `vendor/extra/ksu` with the
  APK `fetch-ksu.sh` verified, its LICENSE and the APK's four arm64 libs; the first-boot rc comes
  with it through `LOCAL_INIT_RC`, and the script and the provider zip through
  `LOCAL_REQUIRED_MODULES`). A Make prebuilt, not Soong:
  `android_app_import` can't install an app's JNI libs, and it rewrites a presigned APK's libs, which
  drops the v2 signature the kernel checks. Android never unpacks native libs for a system app it
  hasn't updated, so the libs go in the app's own `lib/arm64`. Make files aren't allowed under
  `device/google/`, hence `vendor/extra`, which `repo sync` leaves alone. `Android.mk` is removed
  first and written last, so make never sees it without its files.
- **Two make passes** (`tools/ksu-images.sh [top]`, which `../tools/eos-images.sh` runs; the lunch
  target is `EOS_LUNCH` in `../eos.conf`): lunch, `build_kernel`, `ksu-module.sh`, pass 1 with a stock
  init_boot (only `bootimage initbootimage vendorkernelbootimage`, the images `cheetah-ksu.sh` reads:
  pass 2's init_boot changes the board config, so it builds and packages everything anyway), then
  `tools/cheetah-ksu.sh` checks `boot.img`'s kernel is the KMI in `ksu.conf` and our
  module's sublevel, patches that init_boot with
  `ksud boot-patch --kmi android14-6.1 -m out/ksu/kernelsu.ko` into
  `out/ksu/init_boot-ksu.img` (the unpatched one stays as `out/ksu/init_boot-stock.img`) and checks
  the patched ramdisk (ksuinit as `init`, this build's `init` as `init.real`, our `kernelsu.ko`); pass 2
  runs with `CHEETAH_KSU_INIT_BOOT`. Both passes share `BUILD_DATETIME` and `BUILD_NUMBER`, and
  older builds' packages are deleted first, so `out/` holds only this build's. The last line is
  `MAKE_EXIT=0` only if pass 2 shipped the patched init_boot (`ksu-check.sh images`). `TOP`, `OUT`
  and the other variables a shell set up for another tree are cleared first, and lunch must land in
  `~/expressiveos`. The kernel source follows branch heads, so it is synced once (lunch runs
  `build_kernel`), then `SKIP_KERNEL_SYNC=1`; its `repo manifest -r` goes to
  `out/eos/kernel-manifest.xml` for the GPL source offer.
- **Release checks** (`tools/ksu-check.sh`; the last line is `KSU_CHECK=OK` or `KSU_CHECK=FAIL`):
  - `manager [top]`: the APK in the build is `ksu.conf`'s byte for byte (so it keeps the signature
    the kernel trusts), its four arm64 libs are installed unchanged, and the build's fs_config makes
    `libksud.so` root:root 0755 (`tools/fs-config.py` reads `fs_config_files`). The first-boot rc
    and script are the kit's, the provider zip is the pinned one and passes `zygisk-zip.py`, and
    the susfs guard module inside `libksud.so` (`tools/ko-info.py embedded`) is built for the
    kernel's `struct module`: ksud loads it at every boot with auto-load on, so a mismatch would
    crash every boot, as our first `kernelsu.ko` did.
  - `images <dir> [top]`: init_boot carries our `kernelsu.ko` (with the `/product/app` fallback, not
    `ksud`'s built-in one), built for the same `struct module` as `vendor_kernel_boot`'s modules,
    still running `/data/adb/ksud` in `u:r:ksu:s0` (what the first-boot setup relies on), and
    `init.real`; `avbtool verify_image --follow_chain_partitions` passes and
    vbmeta covers init_boot; vbmeta is signed by the tree's own AVB key and nobody else's
    (`../tools/eos-keys-check.sh vbmeta`).
  - `device-ok <zip>`: `<zip>.device-ok` names the zip's sha256. `eos-pack.sh --release` stops
    without it, as on husky.

  `ksu-images.sh` runs `images` on out/, `../tools/eos-verify.sh` runs `manager` and `images`, and
  `../tools/eos-pack.sh` runs `images` on the unpacked fastboot zip and `device-ok` before a release.

## Install notes (for the release post and changelog)

- ExpressiveOS is a clean install only: unlock, flash the latest stock firmware, then the fastboot
  zip with a data wipe (`fastboot -w update <zip>`). The zip writes every partition, init_boot
  included, so whatever was on the phone before (another ROM, Magisk) is simply replaced; there's
  nothing to remove first. Updates from other ROMs aren't supported.
- Root: KernelSU Next with susfs ships in the ROM and its manager is preinstalled. No app gets root
  until you allow it in KernelSU Next. Root stays across updates.
- susfs (root hiding) and Zygisk (NeoZygisk) are switched on during the first boot and work from the
  second: restart once after setup, before signing in to banking or payment apps. Turn off SUSFS
  auto-load in KernelSU Next if you don't want it. Zygisk modules such as LSPosed (Vector) work with
  NeoZygisk. Don't install Zygisk Next (it replaces NeoZygisk, same module id) or ReZygisk (a second
  Zygisk) alongside it. NeoZygisk's install log warns "KernelSU version too large"; that's expected.
  If you disable or remove NeoZygisk, turn KernelSU Next's "Umount modules" back on.
- If a module stops the phone booting: press volume down three times or more, one press at a time,
  between the Google logo and the boot animation (don't hold it at power-on: on a Pixel that opens
  the bootloader). That's KernelSU safe mode, which skips susfs and
  turns every module off for good, NeoZygisk included: remove the bad module in the manager, then
  turn NeoZygisk (and any other module you want) back on and restart.
- Flashing over a phone that already ran an older build (no data wipe) doesn't turn susfs on or
  install NeoZygisk; turn them on in the manager, or allow Shell in KernelSU Next's Superuser list
  (adb shell gets no root until then), run
  `adb shell "su -c 'rm -f /data/adb/eos/done; touch /data/adb/eos/pending'"` (quoted once, so `su` runs both) and restart twice.
  Turn Shell off again afterwards if you don't use root over adb.
- Don't install Magisk afterwards: it and KernelSU Next can't both be installed.
- KernelSU Next updates come with ExpressiveOS updates. Don't use the manager's "Install" to patch
  init_boot yourself: it puts back the stock module, which doesn't see the preinstalled manager.
- No root: flash the build's `<build>-init_boot-stock.img` to both slots (`fastboot flash
  init_boot_a ...` and `init_boot_b ...`). The next update brings KernelSU Next back.

## Open before the first release

- [ ] First real `ksu-module.sh` run on the build server against the synced
      android14-6.1-2026-03_r24 source and its clang (flex, bison, libssl-dev and libelf-dev are
      installed; the script checks).
- [ ] The kit's OTA publish script for the Updater feed (modelled on `evolution-kodiak/tools/p11-ota.sh`,
      Evo's feed format, with its own feed, R2 prefix `expressiveos/cheetah/` and SourceForge folder).
      `eos-verify.sh` already checks the package and the init_boot inside its payload.
- [ ] Compare `ksud_sha256` with the release page.
- [ ] GPL source links for KernelSU Next (the pinned commit plus `kernel-patches/`) and susfs in the
      release post, and NeoZygisk's (the text in `NOTICE-NeoZygisk`); mirror NeoZygisk's source (the
      tag with its LSPlt submodule, `~/android-dt/ksu/zygisk-<version>/src`) in the release folder
      while the ROM is offered: upstream doesn't commit Cargo.lock, so the tag alone may not rebuild it.
- [ ] On a real cheetah, fresh install: boot 1 has susfs auto-load on and NeoZygisk staged,
      `/data/adb/eos/done` is there and `/data/adb/eos/log` says so; boot 2 has susfs loaded
      (`ksud susfs version`) and NeoZygisk active (logcat: its hooks
      resolved, no avc denials for zygote against ksu); turning SUSFS off sticks; safe mode skips
      susfs; an OTA refreshes `/data/adb/ksud`; the stock init_boot boots clean. If the services'
      order misbehaves, the fallback is a `kernel-patches/0002` line running `ksu-firstboot.sh
      post-fs-data` synchronously just before the kernel's own ksud line.
- [ ] On a real cheetah: KSU active with no module load errors, the preinstalled manager shows
      "Working" on a fresh install, MEETS_STRONG_INTEGRITY with the
      manager installed, Wallet tap-to-pay, an OTA from one build to the next keeping root.
