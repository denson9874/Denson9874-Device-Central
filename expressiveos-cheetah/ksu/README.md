# Root for ExpressiveOS: Wild Kernels' BakaSU kernel

**On every phone since 2026-11-14** (Daryl): `EOS_KSU=wild` in each `../devices/<device>.conf` ships
[Wild Kernels](https://github.com/WildKernels/GKI_KernelSU_SUSFS)' GKI kernel with
[BakaSU](https://github.com/Baka-SU/BakaSU) and susfs built in, in `boot.img`, in the fastboot zip and
in every OTA. It replaces the SukiSU `init_boot` of the same day: no separate susfs module is needed,
and no manager ships. Users install the BakaSU APK they want, release or nightly (links below and in
the release notes). `EOS_KSU=none` ships the stock boot and no root.

## How it works

- **The kernel.** `ksu.conf` pins one Wild release (`r22`) and, per KMI, its BakaSU AnyKernel3 zip
  (SHA-256 as GitHub lists it) and the `Linux version` its `Image` must say. `fetch-ksu.sh` downloads
  them to `~/android-dt/wild/<version>/` and unpacks each `Image` to `<kmi>/Image`.
  - cheetah and husky (`android14-6.1`): `6.1.162-android14-2026-03`, the sublevel our gs-6.1 kernel
    builds, so the vendor modules from that build load into it. Booted on cheetah 2026-11-14.
  - The Pixel 11s (`android16-6.12`): `6.12.92-android16-2026-09`, booted on kodiak 2026-11-14.
    `6.12.96-android16-lts` boot-looped system_server on kodiak the same day: don't move to it
    without a phone test.
- **The boot image** (`tools/wild-boot.sh build`, run by `../tools/eos-make.sh` before the make). It
  takes the tree's own prebuilt boot (`BOARD_PREBUILT_BOOTIMAGE`: Google's GKI on a Pixel 11, the
  gs-6.1 build's on cheetah and husky), swaps its kernel for Wild's (compressed as the stock one is,
  lz4 legacy on all six phones) and packs it again with the stock header, OS version, patch level
  and cmdline: `out/ksu*/boot-wild.img`. The make takes it as `BOARD_PREBUILT_BOOTIMAGE` through
  `EOS_WILD_BOOT` (each phone's device tree patch: `patches/device_google_pantah/0101` for cheetah,
  `../devices/<device>/ksu-patches/` for the others) and signs it with the tree's boot AVB key like
  any prebuilt boot. One make pass.
- **No root wanted.** After the make, `wild-boot.sh stock` signs the stock boot exactly as the build
  signed `boot.img` (same key, algorithm, rollback index and props): `out/ksu*/boot-stock.img`, which
  `eos-pack.sh` publishes beside the zip as `<name>-boot-stock.img`. Flashing it gives the same build
  without root. `init_boot` is always the stock one.
- **Checks.** `tools/ksu-check.sh images` (eos-make, eos-verify, eos-pack): `boot.img`'s kernel is
  `ksu.conf`'s, `init_boot` is stock, the AVB chain verifies with boot in it, vbmeta is ours.
  `ksu-check.sh manager`: no manager or SukiSU first-boot setup in the build. eos-verify and
  eos-target-files check the OTA payload's and target-files' boot carry Wild's kernel too.

## The manager (for the release notes)

No manager ships. Paste this into the release notes of the first release with root:

> **Root, out of the box.** ExpressiveOS now ships with root built into its kernel (Wild Kernels'
> GKI with BakaSU and susfs). Nothing has root until you allow it. To manage it, install the BakaSU
> app yourself:
> - Release: https://github.com/Baka-SU/BakaSU/releases
> - Nightly: https://github.com/Baka-SU/BakaSU/actions (open the latest successful run and download
>   its APK artifact; needs a GitHub account)
>
> Don't want root? Flash `<name>-boot-stock.img` from the same download page to the boot partition.

The same links are `ksu.conf`'s `manager_release_url` and `manager_nightly_url`.

## Files

| File | What |
|---|---|
| `ksu.conf` | The pinned Wild release, each KMI's zip, SHA-256 and kernel version, the manager links |
| `fetch-ksu.sh` | Downloads the zips to `~/android-dt/wild/<version>/`, checks every hash, unpacks each `Image` and checks its version |
| `apply-ksu.sh` | The phone's device tree patch as a local commit; removes the SukiSU kit's `vendor/extra/ksu` |
| `tools/wild-boot.sh` | `build`: `boot-wild.img`; `stock`: the signed `boot-stock.img` |
| `tools/ksu-check.sh` | `manager`, `images` and `device-ok` checks for make, verify and pack |
| `patches/device_google_pantah/` | cheetah's device tree commit; the other phones' are `../devices/<device>/ksu-patches/` |

## Moving to a new Wild release

1. In `ksu.conf`: `version`, `release_url`, and for each KMI `zip_<kmi>`, `zip_<kmi>_sha256` (from the
   release page) and `uname_<kmi>` (the `Linux version` of its `Image`). cheetah and husky must stay on
   the sublevel our gs-6.1 kernel builds; the Pixel 11s on one tested on a phone.
2. Run `fetch-ksu.sh`; it refuses anything that doesn't match.
3. Build and boot-test a phone of each kernel (cheetah or husky, and a Pixel 11) before shipping.

## Licences

Wild Kernels' kernels are GPL-2.0, built from the Android common kernel with BakaSU (GPL-2.0 kernel
part) and susfs; their source is `ksu.conf`'s `src_url` and the release page's commit list, and
`eos-images.sh` records the release and zip in each build's `sources.txt`.
