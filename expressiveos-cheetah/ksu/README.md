# SukiSU for ExpressiveOS

**Rooted out of the box since 2026-11-14 (Daryl):** every phone's `../devices/<device>.conf` says
`EOS_KSU=lkm`, which ships [SukiSU](https://github.com/SukiSU-Ultra/SukiSU-Ultra) (SukiSU-Ultra) in
`init_boot`, in the fastboot zip and in every OTA, and installs its manager on the first boot. SukiSU
only: no susfs and no Zygisk provider are preinstalled; users add the modules they want. `EOS_KSU=none`
ships the build's stock `init_boot` instead. (KernelSU Next with susfs and NeoZygisk was here until
2026-11-03, when root out of the box was dropped; this folder is that kit, moved to SukiSU.)

## How it works

- **LKM over Google's kernel.** The kernel stays Google's signed GKI. SukiSU's `ksuinit` becomes
  `init_boot`'s `/init`, the build's own init moves to `/init.real`, and `kernelsu.ko` sits beside them:
  `ksuinit` loads the module, then runs the real init. That's the ramdisk SukiSU's `ksud boot-patch`
  makes with a module given; `tools/ramdisk-ksu.py` makes it on the build server (SukiSU publishes no
  Linux `ksud`), and `tools/cheetah-ksu.sh` packs it with the tree's `mkbootimg`, the stock image's own
  header arguments, and checks the result.
- **Which module.** cheetah and husky build their kernel from source (`EOS_KERNEL=gs-6.1`), so
  `tools/ksu-module.sh` builds `kernelsu.ko` from SukiSU's release source (`ksu.conf`'s `src_commit`,
  unmodified) against it, with the kernel tree's own clang and pahole, as SukiSU's release CI does
  (`CONFIG_KSU=m CONFIG_KPM=y`, `ksu.conf`'s `version_code`). The Pixel 11s run Google's prebuilt
  android16-6.12 GKI, so they take SukiSU's release module for that KMI (`ko_android16-6.12_*`). Either
  way `cheetah-ksu.sh` checks the module is built for the kernel's `struct module` (the size of the
  first-stage modules' in `vendor_kernel_boot`): 6.1 and 6.12 load a module built for another one and
  crash reading past it (`../tools/ko-info.py`).
- **Two make passes.** `../tools/eos-make.sh` builds `boot`, `init_boot` and `vendor_kernel_boot` first,
  `cheetah-ksu.sh` patches that `init_boot`, and pass 2 builds everything with `CHEETAH_KSU_INIT_BOOT`
  (cheetah) or `EOS_KSU_INIT_BOOT` (the others) naming it: each device tree's SukiSU commit takes it as
  `BOARD_PREBUILT_INIT_BOOT_IMAGE`, signed with the tree's `init_boot` AVB key like a built one, and only
  then adds `eos-sukisu` to the product. A build without the variable installs no SukiSU at all.
- **The manager.** SukiSU's kernel crowns only a manager installed under `/data/app` with its package
  name (`com.sukisu.ultra`) and signer, so it isn't a system app: `eos-sukisu` (`tree/Android.mk`) ships
  the release APK unmodified as `/product/etc/eos/sukisu-manager.apk`, and `tree/eos-ksu-firstboot.rc`
  runs `tree/ksu-firstboot.sh` at boot completed, in SukiSU's `ksu` domain (which exists only while
  `kernelsu.ko` is loaded), to `pm install` it for the owner. It's tried on at most three boots and never
  again once done, so a manager the user uninstalls stays gone; `/data/adb/eos/log` says what happened.
  The manager sets up `ksud` itself the first time it's opened. No app gets root until the user grants it
  there.
- **No root for those who don't want it.** Each candidate and release keeps the build's stock `init_boot`
  beside the zip (`<name>-init_boot-stock.img`, verified and signed with the tree's key); flashing it
  gives the same build without root, and the first-boot service then never runs.

## Files

| File | What |
|---|---|
| `ksu.conf` | The pinned release: version and version code, the manager APK, `ksuinit` and the 6.12 module (SHA-256 each), the manager's signer, the source commit |
| `fetch-ksu.sh` | Downloads them to `~/android-dt/ksu/<version>/`, checks every hash, the signer and the source's version code |
| `apply-ksu.sh` | The phone's SukiSU device tree patches as local commits, and `vendor/extra/ksu` (APK, licence, first-boot setup, `Android.mk` last) |
| `tools/ksu-module.sh` | Our `kernelsu.ko` for a kernel built from source |
| `tools/cheetah-ksu.sh`, `tools/ramdisk-ksu.py` | The SukiSU `init_boot` |
| `tools/ksu-check.sh` | `manager`, `images` and `device-ok` checks for verify and pack |
| `tools/apk-cert.py` | The SHA-256 of an APK's v2 signing certificate |
| `patches/device_google_pantah/` | cheetah's device tree commits (the pantah fork carries them); the other phones' are `../devices/<device>/ksu-patches/` |

ExpressiveOS's own device forks (pantah, kodiak, grizzly, cubs, yogi) carry these commits themselves
(`../README.md`, "Sources"); husky's shusky tree is LineageOS's, so its two patches are applied at build
time.

## Moving to a new SukiSU release

1. In `ksu.conf`: `version`, `version_code`, `release_url`, each `*_file` and `*_sha256` from the release
   page, and `src_commit` (the tag's commit). Check `manager_cert_sha256` and `manager_package` against
   `kernel/Kbuild`'s `KSU_EXPECTED_HASH` and `KSU_PACKAGE_NAME`.
2. Run `fetch-ksu.sh`; it refuses anything that doesn't match.
3. Check `kernelsu.ko` still runs `/data/adb/ksud` in `u:r:ksu:s0` (`ksu-check.sh images` does), that
   `boot_patch.rs` still makes the ramdisk `ramdisk-ksu.py` makes, and build and test on a phone of each
   kernel (cheetah or husky, and a Pixel 11).

## Licences

SukiSU's kernel module is GPL-2.0 and its userspace and manager GPL-3.0 (`LICENSE`, `kernel/LICENSE`).
The manager ships unmodified, with `LICENSE` as its notice; the module's source is `ksu.conf`'s
`src_commit`, and `eos-images.sh` records it in each build's `sources.txt`.
