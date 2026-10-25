# KernelSU Next for ExpressiveOS (cheetah)

ExpressiveOS's cheetah (Pixel 7 Pro) builds ship [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next)
with susfs in `init_boot`, in the fastboot zip and in every OTA, with the manager preinstalled
(Daryl, 2026-10-25). This folder is only the KernelSU Next part of the ExpressiveOS kit; the tree,
keys, names and OTA feed are the kit's own. **None of it applies to the Evolution X cheetah build**
(`evolution-cheetah/`), which stays unrooted: `apply-ksu.sh` and `ksu-images.sh` refuse
`~/evolution`.

## How it works

- **LKM over Google's kernel.** The kernel stays Google's signed GKI (android14-6.1). `kernelsu.ko`
  (for the android14-6.1 KMI) and `ksuinit` go into `init_boot`'s ramdisk, as the manager's own
  "patch a file" does. susfs is KernelSU Next's `susfs_guard_lkm.ko`, which `ksud` loads at boot
  **only once the user turns on SUSFS auto-load in the manager**: root hiding is off by default.
  If KernelSU Next breaks on a Google kernel update, a source-built GKI with the driver and susfs
  v2.3.0 built in (as Espada does on 6.12) is the fallback.
- **Pinned release** (`ksu.conf`): the version, the host `ksud` (`ksud-x86_64-unknown-linux-musl`)
  and the manager APK, each with its SHA-256, plus the manager's signing certificate. `fetch-ksu.sh`
  downloads them to `~/android-dt/ksu/<version>/` and refuses anything that doesn't match; the
  certificate must be the one KernelSU Next's kernel module trusts (`KSU_NEXT_MANAGER_HASH` in its
  `kernel/Kbuild`). To update KernelSU Next, change every line together.
- **Tree patches** (`patches/device_google_pantah/`, applied by `apply-ksu.sh` after the tree's own
  patches, with the manager APK copied in). They sit on top of `evolution-cheetah`'s pantah patches
  `0001`-`0009` (tested on Evolution-X-Devices `cnb`); if ExpressiveOS's own patches change
  `device-cheetah.mk`'s tail, regenerate `0001`:

  | Patch | Change |
  |---|---|
  | `0001` | Preinstalls the manager (`ksu/Android.bp`: presigned, unprivileged product app) |
  | `0002` | With `CHEETAH_KSU_INIT_BOOT` set, `BOARD_PREBUILT_INIT_BOOT_IMAGE` is that image: the build re-signs it with the tree's init_boot AVB key and ships it in target-files, so in the images and the OTA |

- **Two make passes** (`tools/ksu-images.sh <lunch target> [top]`): lunch, `build_kernel`, pass 1
  with a stock init_boot, then `tools/cheetah-ksu.sh` checks `boot.img`'s kernel is the KMI in
  `ksu.conf`, patches that init_boot with `ksud boot-patch --kmi android14-6.1` into
  `out/ksu/init_boot-ksu.img` (the unpatched one stays as `out/ksu/init_boot-stock.img`) and checks
  the patched ramdisk (ksuinit as `init`, this build's `init` as `init.real`, `kernelsu.ko`); pass 2
  runs with `CHEETAH_KSU_INIT_BOOT`. Both passes share `BUILD_DATETIME` and `BUILD_NUMBER`.
- **Release checks** (`tools/ksu-check.sh`, for the kit's pack and OTA scripts):
  - `images <dir> --avb-key <pem>`: init_boot carries `kernelsu.ko`; `avbtool verify_image
    --follow_chain_partitions` passes; vbmeta's public key is ExpressiveOS's, and that key is
    neither an AOSP test key nor Evolution X's.
  - `manager`: the manager is in the build.
  - `device-ok <zip>`: `<zip>.device-ok` names the zip's sha256. Publishing (zip and OTA JSON)
    must stop without it, as on husky.

## Install notes (for the release post and changelog)

- ExpressiveOS is a clean install: unlock, flash the latest stock firmware, then the fastboot zip,
  and wipe data. It doesn't update from Evolution X or other ROMs.
- Root: KernelSU Next with susfs ships in the ROM and its manager is preinstalled. No app gets root
  until you allow it in KernelSU Next. Root stays across updates.
- susfs (root hiding) is off until you turn on SUSFS auto-load in KernelSU Next and restart.
- Don't install Magisk: it and KernelSU Next can't both be installed.
- No root: flash the build's `<build>-init_boot-stock.img` to both slots (`fastboot flash
  init_boot_a ...` and `init_boot_b ...`). The next update brings KernelSU Next back.

## Open before the first release

- [ ] **Manager recognition.** KernelSU Next v3.4.2's kernel module looks for the manager only under
      `/data/app` (`kernel/manager/throne_tracker.c`: `search_manager("/data/app", ...)`), so a copy
      in `/product/app` isn't recognised. Daryl to choose: build our own `kernelsu.ko` that also
      checks `/product/app`, drop the preinstall, or keep it with a one-time install.
- [ ] The kit's OTA script (modelled on `derpfest-husky/tools/derp-ota.sh`: its own feed, R2 prefix
      `expressiveos/cheetah/` and SourceForge folder) calls `ksu-check.sh images` and `device-ok`
      before publishing.
- [ ] Compare `ksud_sha256` with the release page.
- [ ] GPL source links for KernelSU Next and susfs in the release post.
- [ ] On a real cheetah: KSU active with no module load errors, MEETS_STRONG_INTEGRITY with the
      manager installed, Wallet tap-to-pay, an OTA from one build to the next keeping root.
