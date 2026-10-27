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
  does. susfs is KernelSU Next's `susfs_guard_lkm.ko`, which `ksud` loads at boot
  **only once the user turns on SUSFS auto-load in the manager**: root hiding is off by default.
  If KernelSU Next breaks on a Google kernel update, a source-built GKI with the driver and susfs
  v2.3.0 built in (as Espada does on 6.12) is the fallback.
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
  APK `fetch-ksu.sh` verified, its LICENSE and the APK's four arm64 libs). A Make prebuilt, not Soong:
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
    `libksud.so` root:root 0755 (`tools/fs-config.py` reads `fs_config_files`).
  - `images <dir> [top]`: init_boot carries our `kernelsu.ko` (with the `/product/app` fallback, not
    `ksud`'s built-in one), built for the same `struct module` as `vendor_kernel_boot`'s modules, and
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
- susfs (root hiding) is off until you turn on SUSFS auto-load in KernelSU Next and restart.
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
      release post.
- [ ] On a real cheetah: KSU active with no module load errors, the preinstalled manager shows
      "Working" on a fresh install, MEETS_STRONG_INTEGRITY with the
      manager installed, Wallet tap-to-pay, an OTA from one build to the next keeping root.
