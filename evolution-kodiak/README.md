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

**It boots.** `EvolutionX-17.0-20261010-kodiak-12.3-Unofficial` (userdebug,
test-keys, firmware and vendor from `CD1A.261005.003`) runs on the test
phone. The phone was first moved off the QPR3 beta onto stable
`CD1A.261005.003`, so its bootloader and modem match the build.

- Flashed with `fastboot update -w` from an image zip (all images from `out/`
  plus the stock `super_empty.img`).
- 3 of 3 reboots were clean: about 31 s to `sys.boot_completed`.
- Working: display (stock default 1080x2404 at 390 dpi), Wi-Fi, modem/SIM,
  no crashes in the crash buffer.
- Offline checks pass:
  - `check-sepolicy.sh`
  - kernel and dtbo are byte-identical to stock
  - recovery and its HALs are in vendor_boot
  - the payload has 40 partitions
- The first boot failure was missing USB PHY firmware in vendor_boot:
  `google-usb-phy.ko` loads it during first stage. This is now fixed.

Open issues:
- One kernel panic on the first boot after the wipe, in the DisplayPort
  bridge (`dwc_dptx` `dptx_bridge_detach`, then DRM cleanup at
  `drm_mode_put_tile_group`). It came after SELinux denials on display
  debugfs and hasn't reproduced since.
- 119 SELinux denials on the first boot, most from the camera HAL (44), so
  the camera needs checking.
- `edgetpu_vendor_service` and `hal_wlcservice` (wireless charging) are
  stopped. The TPU app service is shipped and running since 2026-10-11.
- Google's product overlays aren't shipped; signing uses test keys.
- ~~Voice calls~~ **work since 2026-10-11** (two-way audio, VoLTE). Stock
  vendor SELinux rules for Google's telephony apps never applied until ImsStack and
  friends got stock's domains; see [HANDOFF.md](HANDOFF.md) sections 2b and 2c.

## Workspace (build server)

`~/android-dt`: firmware, dumps (`dumps/kodiak`, git), trees, venv, tools.

Gotchas found:
- the `build` user has no passwordless sudo;
- dumpyara must be given the inner `image-kodiak-*.zip`;
- AIK needs the `file` command;
- releasetools crashed on prebuilt vendor (see `patches/build_make`);
- API-37 shipping drops `hwservicemanager`/HIDL allocator, which vintffm needs;
- a prebuilt-vendor product loses base_vendor.mk's recovery packages.
