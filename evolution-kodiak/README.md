# Evolution X 17 on the Pixel 11 Pro XL (kodiak)

Bring-up of Evolution X 17 (`cnb`, LineageOS-based) on the Pixel 11 Pro XL
(`kodiak`, Tensor G6 `malibu`, GKI 6.12). LineageOS and TheMuppets have no
kodiak trees, so this one started from `aospdtgen` output and was restructured
after LineageOS's Tensor G5 trees (`laguna` / `muzel` / `mustang`).

- `device_google_kodiak/` is the device tree. It goes at `device/google/kodiak`;
  its own [README](device_google_kodiak/README.md) has the build steps.
- `tools/aospdtgen-vendorfirst.py` runs aospdtgen with product/vendor props
  read before system's. Pixel 11's system image is the shared
  `generic_system_google`, so plain aospdtgen names the tree "generic".

`vendor/google/kodiak` is not in this repo. `extract-images.sh` generates it from
a Google factory zip, and it holds Google's proprietary images, so it must not
be pushed anywhere public.

## Layout

Stock vendor, vendor_dlkm, system_dlkm, kernel (boot) and dtbo; Evolution X
builds system, system_ext, product, init_boot, vendor_boot (with recovery) and
vbmeta (`--flags 3`). The OTA also flashes the stock firmware and
vendor_kernel_boot raw. Google publishes no malibu vendor sources (SELinux
policy, HAL configs), so a from-source vendor isn't possible yet.

## Status (2026-10-10)

- First build: `EvolutionX-17.0-20261010-kodiak-12.3-Unofficial.zip`
  (userdebug, test-keys, firmware and vendor from `CD1A.261005.003`).
- Offline checks pass:
  - `check-sepolicy.sh` (the split policy compiles against the stock vendor)
  - kernel and dtbo are byte-identical to stock
  - recovery and its HALs are in vendor_boot
  - the payload has 40 partitions, all of which exist on the phone
- **Not booted yet.** The test phone runs the Android 17 beta
  `DP11.260918.005` with bootloader `spacecraft-17.4-16354067`, which is newer
  than this build's `16262255`, and its bootloader is locked. Do not flash this
  build to it: the OTA would try to downgrade the bootloader.

## Workspace (build server)

`~/android-dt`: firmware, dumps (`dumps/kodiak`, git), trees, venv, tools.

Gotchas found:
- the `build` user has no passwordless sudo;
- dumpyara must be given the inner `image-kodiak-*.zip`;
- AIK needs the `file` command;
- releasetools crashed on prebuilt vendor (see `patches/build_make`);
- API-37 shipping drops `hwservicemanager`/HIDL allocator, which vintffm needs;
- a prebuilt-vendor product loses base_vendor.mk's recovery packages.
