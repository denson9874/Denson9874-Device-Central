# LineageOS 24.0 (Android 17) Pixel 8 Pro "husky": upstream source set and health, as of 2026-10-21

Method: primary sources only. I read GitHub REST API branch and commit data (`gh api`), raw files on raw.githubusercontent.com, partial clones of the device repos, the LineageOS Gerrit REST API, the LineageOS download API, and the `build-manifest.xml` of the official 2026-10-16 husky nightly. All dates are commit or committer dates as GitHub/Gerrit report them, retrieved 2026-10-21.

## 1. Which repos make up husky on lineage-24.0, their dependencies, and what a local manifest must add

### Takeaway
On lineage-24.0, husky takes four LineageOS device repos: `device/google/husky`, which is only a stub, plus `device/google/shusky`, `device/google/zuma` and `device/google/shusky-kernels`. It also needs the TheMuppets vendor repo `vendor/google/husky`. Every other Pixel dependency (`hardware/google/pixel`, `pixel-sepolicy`, `interfaces`, `camera`, `av`) is already in the stock LineageOS 24.0 manifest. `device/google/gs-common` is no longer used: it has no lineage-24.0 branch, and zuma dropped the dependency on 2026-06-28.

### Cited Findings
**Repo status, branch `lineage-24.0`** (GitHub API):
| path | repo (remote = LineageOS github) | lineage-24.0 exists? | tip commit / date | notes |
|---|---|---|---|---|
| device/google/husky | LineageOS/android_device_google_husky | yes (it is the default branch) | 58fde14a7a, 2024-11-06 "Update extract-files helper scripts" | Stub only. It holds `README`, `extract-files.py`, `setup-makefiles.py` and `lineage.dependencies`. The README says "Nothing is really here. The husky device tree files are in device/google/shusky." `extract-files.py` just runs `pushd ../shusky/husky; ./extract-files.py` — [repo](https://github.com/LineageOS/android_device_google_husky/tree/lineage-24.0) |
| device/google/shusky | LineageOS/android_device_google_shusky | yes | 21e0f8219c, 2026-10-16 "shusky: Import face unlock overlays" | Holds the real husky/shiba tree: `lineage_husky.mk`, `device-husky.mk`, `husky/` (BoardConfig, proprietary-files*, extract-files.py). Last push 2026-10-20 — [repo](https://github.com/LineageOS/android_device_google_shusky/tree/lineage-24.0) |
| device/google/zuma | LineageOS/android_device_google_zuma | yes | ab6deaa38a, 2026-10-16 "zuma: Enable face unlock" | Tensor G3 platform: `common.mk`, `BoardConfig-common.mk`, `BoardConfig-16k-common.mk`, sepolicy, vintf, `parts` — [repo](https://github.com/LineageOS/android_device_google_zuma/tree/lineage-24.0) |
| device/google/shusky-kernels | LineageOS/android_device_google_shusky-kernels | yes (branches 23.0–24.0 only) | cd4a90f656, 2026-06-25 "modules: Update to CP2A.260605.012" | Holds only module lists and `init.insmod.*.cfg` under `6.1/`. Images, dtbs and `.ko` files are git-ignored (see section 3) — [repo](https://github.com/LineageOS/android_device_google_shusky-kernels/tree/lineage-24.0) |
| device/google/gs-common | LineageOS/android_device_google_gs-common | **NO** (branches stop at lineage-23.2; default branch lineage-23.2) | n/a | Not needed. zuma commit 94851f1 (2026-06-28) is "zuma: Remove dependency on gs-common" — [branches](https://github.com/LineageOS/android_device_google_gs-common/branches), [zuma log](https://github.com/LineageOS/android_device_google_zuma/commits/lineage-24.0) |
| hardware/google/pixel | LineageOS/android_hardware_google_pixel | yes | 8bd3c71cf2, 2026-08-12 "power-libperfmgr: Disable AUDIO_PERFORMANCE session mode" | Already in the stock manifest — [repo](https://github.com/LineageOS/android_hardware_google_pixel/tree/lineage-24.0) |
| (kernel source) | LineageOS/android_kernel_google_gs-6.1_manifest, _devices, _google-modules | yes | manifest 2026-10-16; devices 2026-08-27; google-modules 2026-07-12 | **Not** a project in the Android manifest. `build_kernel` syncs it into a nested repo (section 3) |
| — | LineageOS/android_kernel_google_zuma, LineageOS/android_device_google_zuma-kernels | do not exist (HTTP 404) | — | — |

**`lineage.dependencies` chain on lineage-24.0** (this is what `breakfast` / roomservice uses):
- husky: `[{"repository":"android_device_google_shusky","target_path":"device/google/shusky"}]` — [raw](https://raw.githubusercontent.com/LineageOS/android_device_google_husky/lineage-24.0/lineage.dependencies)
- shusky: `android_device_google_zuma → device/google/zuma`, and `android_device_google_shusky-kernels → device/google/shusky-kernels` — [raw](https://raw.githubusercontent.com/LineageOS/android_device_google_shusky/lineage-24.0/lineage.dependencies)
- zuma and shusky-kernels have no `lineage.dependencies` file (HTTP 404), so the chain ends there — [zuma raw](https://raw.githubusercontent.com/LineageOS/android_device_google_zuma/lineage-24.0/lineage.dependencies)
- The download API for husky lists the same dependencies: `["android_device_google_husky","android_device_google_shusky","android_device_google_shusky-kernels","android_device_google_zuma"]` — [download API](https://download.lineageos.org/api/v2/devices/husky)
- The vendor repo is not in `lineage.dependencies`. Official builds use private vendor repos, and the official `build-manifest.xml` has no `vendor/google/husky` project. It does define a `remote name="private" fetch="ssh://git@github.com"` — [build-manifest.xml 20261016](https://mirrorbits.lineageos.org/full/husky/20261016/build-manifest.xml)

**Already in the stock LineageOS 24.0 manifest, so do not duplicate.** `LineageOS/android` lineage-24.0 has `default.xml` plus `snippets/lineage.xml`, `kernel-5.15.xml`, `kernel-6.6.xml`, `kernel-6.12.xml` and `kernel-6.18.xml`. There is no `pixel.xml` snippet. Manifest tip: 2026-10-14 "manifest: Fork external/selinux". Default revision `refs/heads/lineage-24.0`. The aosp remote is `refs/tags/android-17.0.0_r1` — [manifest](https://github.com/LineageOS/android/tree/lineage-24.0).
- `snippets/lineage.xml`: `hardware/google/pixel` (LineageOS/android_hardware_google_pixel) and `hardware/google/pixel-sepolicy` (LineageOS/android_hardware_google_pixel-sepolicy). It also has `prebuilts/kernel-build-tools` (aosp `kernel/prebuilts/build-tools`, rev `main-kernel-2025`) — [lineage.xml](https://github.com/LineageOS/android/blob/lineage-24.0/snippets/lineage.xml)
- `default.xml`: `hardware/google/camera` (LineageOS), `hardware/google/interfaces` (LineageOS), `hardware/google/av` (aosp), `hardware/google/apf` (aosp), `hardware/google/gfxstream` (aosp), and `device/google/atv`, `device/google_car` and the other AOSP `device/google/*` virtual devices. It also has `kernel/prebuilts/6.1/arm64` (aosp, clone-depth 1) — [default.xml](https://github.com/LineageOS/android/blob/lineage-24.0/default.xml)
- What the trees reference: soong namespace imports are `hardware/google/av`, `hardware/google/interfaces` and `hardware/google/pixel` (husky `extract-files.py`; zuma `Android.bp` imports interfaces and pixel). zuma `common.mk` also includes `hardware/google/pixel/lineage_health/device.mk` and `vendor/lineage/config/BoardConfigReservedSize.mk`. A grep of all `*.mk/*.bp/*.py` path references in shusky and zuma found only `device/google/{zuma,shusky}`, `hardware/google/{pixel,pixel-sepolicy,interfaces,av,camera}`, `vendor/lineage/config` and `vendor/google/husky` (also `vendor/google/shiba`) — [shusky tree](https://github.com/LineageOS/android_device_google_shusky/tree/lineage-24.0), [zuma common.mk](https://github.com/LineageOS/android_device_google_zuma/blob/lineage-24.0/common.mk)

**Pinned revisions used by the official 2026-10-16 nightly** (`build-manifest.xml`; the husky projects carry `groups="local::roomservice"`):
- device/google/husky 58fde14a7aebbf9608f9cdc0cfb1d0cec4016eb9
- device/google/shusky bf3858753d35531e70f79c6dca18718092be289d (2026-10-02 "Copy missing fingerprint permission xml"; one commit behind today's tip)
- device/google/shusky-kernels cd4a90f656c18677b6171cef35c5b5573ed537ca
- device/google/zuma f085107fa7d119210764a83ecab92d5dbff1cbef (2026-07-11; before the 2026-10-16 face-unlock commits)
- hardware/google/pixel 8bd3c71cf2be40cfbe8f5a4b9bf5574ee9fbc624; pixel-sepolicy 618c420806475f60aa8cf8a860fdfff906a50e74; interfaces a36774a8665b72a64cb495501984e8fa0cbb0e53; camera 02ce1b699c02dc02f1360bcf921992a7e0d35f37
- vendor/lineage 87daf527b0288b60c9cc07c05a5f5aad1660c234 — [build-manifest.xml](https://mirrorbits.lineageos.org/full/husky/20261016/build-manifest.xml)

### Inferences
- Minimal local manifest for a LineageOS-24.0-based ROM whose manifest already carries the LineageOS `hardware/google/*` projects. This is derived from the findings above and has not been test-synced:
```xml
<remote name="lineage" fetch="https://github.com/LineageOS" />   <!-- omit if ROM's "github" remote already = ..  under github.com -->
<remote name="muppets" fetch="https://github.com/TheMuppets" />
<project path="device/google/husky"          name="android_device_google_husky"          remote="lineage" revision="lineage-24.0" />
<project path="device/google/shusky"         name="android_device_google_shusky"         remote="lineage" revision="lineage-24.0" />
<project path="device/google/zuma"           name="android_device_google_zuma"           remote="lineage" revision="lineage-24.0" />
<project path="device/google/shusky-kernels" name="android_device_google_shusky-kernels" remote="lineage" revision="lineage-24.0" />
<project path="vendor/google/husky"          name="proprietary_vendor_google_husky"      remote="muppets" revision="lineage-24.0" clone-depth="1" />
```
- `device/google/husky` is optional for building. `lineage_husky.mk` and `AndroidProducts.mk` live in shusky, and `DEVICE_PATH := device/google/shusky`. Including it keeps `breakfast husky` / roomservice from trying to add it again.
- To reproduce the known-good official build exactly, pin zuma to f085107 and shusky to bf38587. Today's tips add only small face-unlock changes (a framework permission xml copy and overlay values), and those look low-risk.
- If DerpFest's manifest dropped `hardware/google/pixel-sepolicy` or `hardware/google/camera`, add them from LineageOS lineage-24.0. Check the DerpFest manifest for this; this note does not cover it.

### Gaps
- The DerpFest 17 manifest contents were not checked here, so I could not confirm which `hardware/google/*` projects it keeps or overrides.
- No upstream local manifest for husky exists. The XML above is derived, not copied.

## 2. TheMuppets vendor blobs: branch, stock build ID, firmware, git-lfs

### Takeaway
`TheMuppets/proprietary_vendor_google_husky` on GitHub has a `lineage-24.0` branch, last updated 2026-08-21. Its blobs come from stock **CP2A.260805.005** (Android 17 August 2026). The repo includes the bootloader/radio firmware (`radio/*.img`, sha1-checked in `Android.mk`), stored with **git-lfs on a non-GitHub LFS server**. Separate `shusky` or `zuma` Muppets repos do not exist.

### Cited Findings
- Branches: lineage-21, lineage-22.0 through 22.2, lineage-23.0 through 23.2, and lineage-24.0. The lineage-24.0 tip is 7085ddc0, 2026-08-21, "husky: Mark NowPlayingPrebuilt.apk as PRESIGNED". GitHub `size` is 3,602,412 KB (about 3.4 GiB of git objects, not counting the LFS objects) — [repo](https://github.com/TheMuppets/proprietary_vendor_google_husky/tree/lineage-24.0)
- Update history on lineage-24.0:
  - 2026-08-06 "husky: Update to CP2A.260805.005"
  - 2026-07-09 CP2A.260705.006
  - 2026-06-27 CP2A.260605.012
  - Older, carried over from 23.x as historical: BP4A.260205.001, BP4A.260105.004.E1, BP4A.251205.006, BP3A.251105.015, BP2A.250805.005 — [commits](https://github.com/TheMuppets/proprietary_vendor_google_husky/commits/lineage-24.0)
- The device tree targets the same build. `lineage_husky.mk` sets `BuildFingerprint=google/husky/husky:17/CP2A.260805.005/15828068:user/release-keys` and `BuildDesc="husky-user 17 CP2A.260805.005 15828068 release-keys"`. Shusky commit 7c8e4b1 (2026-08-06) is "shusky: Update to CP2A.260805.005" — [lineage_husky.mk](https://github.com/LineageOS/android_device_google_shusky/blob/lineage-24.0/lineage_husky.mk)
- Blob list headers:
  - `proprietary-files.txt` (230 lines): "All blobs are extracted from Google factory images for each new ASB"
  - `proprietary-files-vendor.txt` (2,271 lines): "All blobs below are extracted from the release mentioned in proprietary-files.txt". This is the whole vendor partition, e.g. `vendor/apex/com.google.android.widevine-15027108-cp2a.apex`
  - Also `proprietary-files-carriersettings.txt` (621 lines) — [shusky/husky](https://github.com/LineageOS/android_device_google_shusky/tree/lineage-24.0/husky)
- `extract-files.py` supports factory images directly: `extract_fns = {pixel_factory_image_regex: extract_pixel_factory_image, pixel_firmware_regex: extract_pixel_firmware}`, plus `add_firmware_proprietary_file=True` and `add_generated_carriersettings_file=True` — [extract-files.py](https://github.com/LineageOS/android_device_google_shusky/blob/lineage-24.0/husky/extract-files.py)
- Firmware is included. `proprietary-firmware.txt` lists `abl, bl1, bl2, bl31, gcf, gsa, gsa_bl1, ldfw, modem, pbl, tzsw` (`.img;AB`). In the Muppets repo, `radio/` holds those 11 images and `Android.mk` has `add-radio-file-sha1-checked` entries guarded by `ifeq ($(TARGET_DEVICE),husky)`, e.g. `radio/modem.img,02d0535c62fecfaf84d5ede2fafed391fd67ff19`. `BoardConfigVendor.mk` adds all 11 to `AB_OTA_PARTITIONS` — [Android.mk](https://github.com/TheMuppets/proprietary_vendor_google_husky/blob/lineage-24.0/Android.mk), [BoardConfigVendor.mk](https://github.com/TheMuppets/proprietary_vendor_google_husky/blob/lineage-24.0/BoardConfigVendor.mk)
- git-lfs is required. `.gitattributes` puts `radio/*`, `PixelCameraServices.apk`, `DevicePersonalizationAiAiPrebuiltPixel*.apk` and `vendor/apex/com.google.pixel.camera.hal.apex` on LFS. `.lfsconfig` sets `url = "https://lfs.undocumented.software/lfs/blobs.git/info/lfs"`, so this is not GitHub LFS. The files in git are ~130-byte pointers. Real sizes from the pointers: `modem.img` 112,988,160 B, `abl.img` 1,802,240 B, `com.google.pixel.camera.hal.apex` 271,134,720 B. The LFS host returned HTTP 200 on 2026-10-21 — [.lfsconfig](https://github.com/TheMuppets/proprietary_vendor_google_husky/blob/lineage-24.0/.lfsconfig), [.gitattributes](https://github.com/TheMuppets/proprietary_vendor_google_husky/blob/lineage-24.0/.gitattributes)
- The LineageOS wiki build guide says some repos use LFS. It tells you to run `git lfs install` and use `repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --no-clone-bundle` — [wiki build guide](https://wiki.lineageos.org/devices/husky/build/)
- Generated vendor makefiles: `husky-vendor.mk` sets `PRODUCT_SOONG_NAMESPACES += vendor/google/husky`, and `Android.bp` has about 419 `name:` modules — [husky-vendor.mk](https://github.com/TheMuppets/proprietary_vendor_google_husky/blob/lineage-24.0/husky-vendor.mk)
- Face unlock blob: `proprietary/vendor/apex/com.google.android.hardware.biometrics.face.apex` is in the Muppets lineage-24.0 tree, so the 2026-10-16 "zuma: Enable face unlock" change has its blob available — [tree](https://github.com/TheMuppets/proprietary_vendor_google_husky/tree/lineage-24.0/proprietary/vendor/apex)
- `TheMuppets/proprietary_vendor_google_shusky` and `TheMuppets/proprietary_vendor_google_zuma` return 404 on GitHub. `TheMuppets/proprietary_vendor_google_shiba` exists, with lineage-24.0 tip 2026-08-21 — GitHub API
- GitLab: the GitLab API call for `the-muppets/proprietary_vendor_google_husky` returned "404 Project Not Found", and the web URL returned a 302 redirect. Husky is not publicly on gitlab.com/the-muppets; GitHub is the source — [gitlab API](https://gitlab.com/api/v4/projects/the-muppets%2Fproprietary_vendor_google_husky)

### Inferences
- The Muppets repo was pushed on 2026-10-15, but the lineage-24.0 tip is still dated 2026-08-21. The push was probably to another branch, likely lineage-23.2.
- The device tree and the blobs are consistent today: both are CP2A.260805.005.
- When the open CP3A changes merge (section 5), the Muppets repo has to move to CP3A at the same time, or the tree and the blobs will be out of sync. Pin both together, or track both at the tip and re-sync together.
- `clone-depth="1"` in the local manifest saves several GB of history. LFS still has to fetch the real objects from lfs.undocumented.software. Without git-lfs, the radio sha1 checks in `Android.mk` fail, because the pointer files do not match the sha1s.

### Gaps
- I did not measure the total LFS payload. The three sampled objects add up to about 386 MB. No total clone size is published anywhere.

## 3. Kernel: prebuilt or built from source?

### Takeaway
The kernel is **built from source automatically during `lunch`/`breakfast`** by vendor/lineage's `build_kernel` function. That function runs a nested `repo init` of `LineageOS/android_kernel_google_gs-6.1_manifest` (branch `lineage-<MAJOR>.<MINOR>`) under `out-kernel/google/gs-6.1`, runs `build_shusky.sh`, and copies the dist output into `device/google/shusky-kernels/6.1`. The kernel is GKI android14-**6.1**, synced to tag `android14-6.1-2025-12_r30`.

### Cited Findings
- `device-husky.mk` sets `TARGET_LINUX_KERNEL_VERSION := 6.1`, `TARGET_KERNEL_DEVICE := shusky`, `TARGET_KERNEL_DIR := device/google/$(TARGET_KERNEL_DEVICE)-kernels/$(TARGET_LINUX_KERNEL_VERSION)` and `TARGET_KERNEL_PLATFORM_SOURCE := google/gs-$(TARGET_LINUX_KERNEL_VERSION)` — [device-husky.mk](https://github.com/LineageOS/android_device_google_shusky/blob/lineage-24.0/device-husky.mk)
- zuma `BoardConfig-common.mk` sets:
  - `TARGET_NO_KERNEL := true`
  - `BOARD_PREBUILT_BOOTIMAGE := $(wildcard $(TARGET_KERNEL_DIR)/boot.img)`
  - `BOARD_PREBUILT_DTBOIMAGE := .../dtbo.img`
  - `KERNEL_MODULE_DIR := $(TARGET_KERNEL_DIR)`
  - `$(error vendor_kernel_boot.modules.load not found or empty)` if the module list is missing
  - It also includes the 16k config when `$(TARGET_KERNEL_DIR)/16kb/` exists — [BoardConfig-common.mk](https://github.com/LineageOS/android_device_google_zuma/blob/lineage-24.0/BoardConfig-common.mk)
- LineageOS `build/envsetup.sh` `lunch`: if `TARGET_NO_KERNEL == true` or `TARGET_PREBUILT_KERNEL` is set, and `TARGET_KERNEL_PLATFORM_SOURCE` is non-empty, it calls `build_kernel` — [android_build envsetup.sh](https://github.com/LineageOS/android_build/blob/lineage-24.0/envsetup.sh)
- vendor/lineage `build_kernel()`:
  - Skips when `SKIP_KERNEL_BUILD=true|1` and skips the sync when `SKIP_KERNEL_SYNC=true|1`
  - Sets `lineage_version="lineage-$(PRODUCT_VERSION_MAJOR).$(PRODUCT_VERSION_MINOR)"`
  - Builds in `KERNEL_BUILD_TOP=${ANDROID_BUILD_TOP}/out-kernel/${target_kernel_source}` and copies `.repo/repo` there
  - Runs `repo init -u https://github.com/LineageOS/android_kernel_google_gs-6.1_manifest.git -b ${lineage_version}`, with optional `--reference ${LINEAGE_MIRROR}`, then `repo sync --detach --force-sync`
  - Runs `./build_shusky.sh`, deletes the old prebuilts in `TARGET_KERNEL_DIR`, and copies `out/shusky/dist/*` in
  - Supports `KERNEL_REPO_PROJECT_OBJECTS_DIR` and `KERNEL_REPO_PROJECTS_DIR` — [vendor/lineage envsetup.sh](https://github.com/LineageOS/android_vendor_lineage/blob/lineage-24.0/build/envsetup.sh)
- vendor/lineage `config/version.mk` sets `PRODUCT_VERSION_MAJOR = 24` and `PRODUCT_VERSION_MINOR = 0`, so the kernel manifest branch is `lineage-24.0` — [version.mk](https://github.com/LineageOS/android_vendor_lineage/blob/lineage-24.0/config/version.mk)
- `shusky-kernels/.gitignore` ignores `*.dtb, *.dtbo, *.img, *.ko, Image*, vendor_kernel_boot.img, system_dlkm.img, vendor_dlkm.img`, the header tarballs and more. Only `6.1/{modules.load, vendor_kernel_boot.modules.load, vendor_dlkm.modules.load/blocklist, system_dlkm.modules.load/blocklist, init.insmod.husky.cfg, init.insmod.shiba.cfg}` are tracked — [shusky-kernels](https://github.com/LineageOS/android_device_google_shusky-kernels/tree/lineage-24.0)
- The gs-6.1 kernel manifest (lineage-24.0):
  - `common/gki` = aosp `kernel/common` at `refs/tags/android14-6.1-2025-12_r30`
  - `build/kernel` = aosp `kernel/build`, with remote default revision `refs/heads/main-kernel-build-2023`
  - `private/devices` = LineageOS/android_kernel_google_gs-6.1_devices, which links `build_shusky.sh` from `google/shusky/build_shusky.sh`
  - `private/google-modules` = LineageOS/android_kernel_google_gs-6.1_google-modules
  - Bazel and clang prebuilts come from aosp — [gs-6.1 manifest default.xml](https://github.com/LineageOS/android_kernel_google_gs-6.1_manifest/blob/lineage-24.0/default.xml)
- Kernel repo activity:
  - manifest: 2026-08-27 "Sync android14-6.1-2025-12_r30 kernel"; 2026-10-16 "Track custom build/kernel revision", reverted the same day
  - devices: 2026-08-27 "common: Download android14-6.1-2025-12_r30 GKI" (the GKI boot image is downloaded, not compiled)
  - google-modules: 2026-07-12 bms changes — GitHub API commits
- The wiki device data says `kernel: {repo: android_kernel_google_gs-6.1_manifest, version: '6.1'}` — [husky.yml](https://github.com/LineageOS/lineage_wiki/blob/main/_data/devices/husky.yml)
- Historical: `LineageOS/android_kernel_google_gs201` (lineage-21) and `gs101` (lineage-20) are older monolithic kernel repos and are not used on 24.0 — GitHub search

### Inferences
- **High-risk item for DerpFest.** The kernel step works only if the ROM's `build/envsetup.sh` `lunch` still calls `build_kernel`, the ROM's vendor envsetup still defines it, and `PRODUCT_VERSION_MAJOR.MINOR` expands to `24.0`. If DerpFest's vendor config redefines those version variables, `build_kernel` will `repo init -b lineage-<derp version>`, and that branch does not exist. If `build_kernel` is missing, `shusky-kernels/6.1` will have no `Image.lz4`, `boot.img`, `dtbo.img` or `.ko` files. The build then fails at the zuma `$(error ...)`, or produces an image without a boot image. The workaround is to run `build_kernel` by hand, or pre-populate `device/google/shusky-kernels/6.1` (for example from a stock factory image or a LineageOS build's dist), then set `SKIP_KERNEL_BUILD=1`.
- The build host needs `repo` network access and about 10–20 GB extra under `out-kernel/` for the Bazel kernel build. This is an estimate from typical Pixel GKI builds, not from a published number.
- The exact 6.1 sublevel (6.1.x) was not read. The `android14-6.1-2025-12_r30` tag implies the December 2025 GKI branch, which is roughly 6.1.15x, but I did not verify that.

### Gaps
- I did not read `build_shusky.sh` or check whether it emits the `16kb/` subdir (needed only for the 16k developer option).
- Exact 6.1.x sublevel: not checked.

## 4. Official status, wiki build steps, lunch target / release config

### Takeaway
Husky is an official LineageOS 24.0 device, built weekly. The maintainer is mikeioannina (Michael Bestas), and the latest nightly is lineage-24.0-20261016. The release config on lineage-24.0 is **`cp2a`**, so the lunch target is **`lineage_husky-cp2a-userdebug`** (or `-user`/`-eng`).

### Cited Findings
- The hudson target list has `husky userdebug lineage-24.0 W` (weekly), as do `shiba` and `cheetah` — [lineage-build-targets](https://github.com/LineageOS/hudson/blob/main/lineage-build-targets)
- Wiki data: `current_branch: 24.0`, `maintainers: [mikeioannina]`, `versions: [21, 22.1, 22.2, 23.0, 23.2, 24.0]`, `tree: android_device_google_husky`, `before_install: {instructions: 'needs_specific_android_fw', ships_fw: true, version: '17'}`, and `before_recovery_install: boot_stack [boot, dtbo, vendor_kernel_boot]`. The recovery partition is `vendor_boot` — [husky.yml](https://github.com/LineageOS/lineage_wiki/blob/main/_data/devices/husky.yml)
- Download portal builds:
  - `lineage-24.0-20261016-nightly-husky-signed.zip` (1,510,273,464 B), with boot.img, dtbo.img, init_boot.img, super_empty.img, vbmeta.img, vendor_boot.img, vendor_kernel_boot.img and build-manifest.xml
  - `lineage-24.0-20261012-nightly`
  - `lineage-23.2-20261009` (historical)
  - The portal lists versions 23.2 and 24.0 — [download API builds](https://download.lineageos.org/api/v2/devices/husky/builds), [download.lineageos.org/devices/husky](https://download.lineageos.org/devices/husky)
- Wiki build guide (lineage-24.0):
  - `repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --no-clone-bundle`, with the `git-lfs` and `erofs-utils` packages listed
  - `source build/envsetup.sh`, `breakfast husky` ("will download your device's device specific configuration and kernel")
  - Extract blobs from a device running LineageOS with `./extract-files.py` in `device/google/husky`, or use the "Extracting proprietary blobs from installable zip" alternative
  - `brunch husky` produces `lineage-24.0-<date>-UNOFFICIAL-husky.zip` — [wiki build guide](https://wiki.lineageos.org/devices/husky/build/)
- Release config:
  - `vendor/lineage/vars/aosp_target_release` is `aosp_target_release=cp2a` ("# Updated manually")
  - `breakfast` runs `lunch lineage_$target-$aosp_target_release-$variant`
  - `vendor/lineage/release/release_config_map.textproto` defines only `release_config { name: "cp2a" }` and `build_config { name: "cp2a" }`. The `release_configs/` directory contains only `cp2a.textproto` — [aosp_target_release](https://github.com/LineageOS/android_vendor_lineage/blob/lineage-24.0/vars/aosp_target_release), [release_config_map.textproto](https://github.com/LineageOS/android_vendor_lineage/blob/lineage-24.0/release/release_config_map.textproto)
- Product: `AndroidProducts.mk` lists `aosp_husky.mk`, `aosp_shiba.mk`, `lineage_husky.mk` and `lineage_shiba.mk`. `lineage_husky.mk` inherits `vendor/lineage/config/common_full_phone.mk`, then `device/google/shusky/aosp_husky.mk`, then `vendor/google/husky/husky-vendor.mk`. It sets `PRODUCT_NAME := lineage_husky` and boot animation 1344x2992 — [lineage_husky.mk](https://github.com/LineageOS/android_device_google_shusky/blob/lineage-24.0/lineage_husky.mk)

### Inferences
- For DerpFest, a `derp_husky.mk` (or whatever the ROM's prefix is) has to be added to `AndroidProducts.mk`, swapping the `vendor/lineage/config/common_full_phone.mk` inherit for the ROM's equivalent. The lunch target is then `<rom>_husky-cp2a-userdebug`, provided DerpFest also ships the `cp2a` release config. If DerpFest uses a different release name (e.g. `bp4a`, or a CP3A-era name), the lunch target must match the ROM's `release_config_map`.
- zuma is coupled to LineageOS in several places: `hardware/google/pixel/lineage_health`, `vendor/lineage/config/BoardConfigReservedSize.mk` (an `-include`, so its absence is tolerated), and the `GoogleParts`, `FrameworkResOverlayLineageZuma` and `LineageSdkOverlayZuma` packages. All of these need LineageOS SDK and hardware/google/pixel, which a LineageOS-based ROM should have.

### Gaps
- I did not verify that DerpFest 17 keeps `cp2a` as its release config.

## 5. Recent Gerrit changes (lineage-24.0, about the last 2 months) and build health

### Takeaway
I found no recent change that reverts or fixes a build breakage in husky, shusky, zuma or shusky-kernels. Merged work since August is small: the PRESIGNED fix, the fingerprint permission xml, and face unlock. A large **CP3A update is open and unmerged**: CP3A.260905.009 sepolicy, properties, vintf and overlays, plus "shusky: Update to CP3A.261005.005". A matching new GKI (`android14-6.1-2026-03_r24`) is also pending. Today's branch tips are therefore internally consistent at CP2A.260805.005.

### Cited Findings (Gerrit REST, `branch:lineage-24.0 after:2026-08-15`)
- **android_device_google_zuma.**
  - MERGED: 507571 "zuma: Import face unlock overlays" and 507572 "zuma: Enable face unlock" (2026-10-16). 507572 only copies `frameworks/native/data/etc/android.hardware.biometrics.face.xml` and sets `config_face_enroll_hal_owns_camera=true`.
  - NEW: 507219, 507410, 507411 and 507449, "Update overlays/vintf/properties/sepolicy from CP3A.260905.009"; 508951 "zuma: Remove GoogleParts"; 508952 "zuma: Add EuiccPolicy overlay".
  - ABANDONED: 502821 Revert "zuma: Switch to prebuilt USB HAL"; 502822 "Update namespaces for USB HAL" — [Gerrit zuma](https://review.lineageos.org/q/project:LineageOS/android_device_google_zuma+branch:lineage-24.0)
- **android_device_google_shusky.**
  - MERGED: 497866 PRESIGNED NowPlaying (2026-08-21); 505909 "Copy missing fingerprint permission xml" (2026-10-02); 507574 "Import face unlock overlays" (2026-10-16).
  - NEW:
    - 507244 "Update proprietary files to CP3A.260905.009"
    - 507220, 507412 and 507450 (overlays, properties, sepolicy from CP3A.260905.009)
    - 508741 "shusky: Update to CP3A.261005.005"
    - 507573 "Add trimmed-down preinstalled packages sysconfig"
    - 509380 "shusky: Fix Rust symbol hashes in blobs" (2026-10-20)
    - 509402 "shusky: Add missing google_build.xml" (2026-10-20). Its message says it lets Pixel Camera install through Aurora Store and refers to https://github.com/LineageOS/issues/issues/755
    - 503704 "Shim android.hardware.usb-service to sync restricted state"
  - ABANDONED: 502823 "Restore source built USB services" — [Gerrit shusky](https://review.lineageos.org/q/project:LineageOS/android_device_google_shusky+branch:lineage-24.0)
- android_device_google_husky and android_device_google_shusky-kernels: no changes since 2026-08-15 — Gerrit query
- android_kernel_google_gs-6.1_manifest: MERGED 499550 (r30, 2026-08-27); MERGED 508770 "Track custom build/kernel revision" plus its revert 508845 (both 2026-10-16); NEW 505652 "Sync android14-6.1-2026-03_r24 kernel". android_kernel_google_gs-6.1_devices: NEW 505645 "Download android14-6.1-2026-03_r24 GKI"; NEW 505644 "Import kernel-lynx-15902539 changes" — [Gerrit gs-6.1 manifest](https://review.lineageos.org/q/project:LineageOS/android_kernel_google_gs-6.1_manifest+branch:lineage-24.0)
- android_hardware_google_pixel: NEW 507735 "usb: Bump libpixelusb-aidl to AIDL USB gadget V2"; NEW 503695–503697 USB restriction series; ABANDONED 502733 — [Gerrit pixel](https://review.lineageos.org/q/project:LineageOS/android_hardware_google_pixel+branch:lineage-24.0)
- Older restructuring in shusky and zuma during the 24.0 bring-up, all by Michael Bestas:
  - 2026-06-21/27 "sepolicy: Regenerate", "Switch some more stuff to prebuilt", and "Import generated sepolicy/overlays from CP2A.260605.012"
  - zuma 2026-06-28 "Switch to prebuilt health HAL", "Switch to prebuilt USB HAL", "Don't build gpu_probe", "Remove dependency on gs-common" and "Remove prebuilt targets from PRODUCT_PACKAGES"
  - zuma 2026-05-11 "Allow to provide custom AVB keys and build an enabled vbmeta.img" (Arian)
  - zuma 2026-04-04 "parts: Get rid of GSF dependency" (LuK1337) — [zuma commits](https://github.com/LineageOS/android_device_google_zuma/commits/lineage-24.0), [shusky commits](https://github.com/LineageOS/android_device_google_shusky/commits/lineage-24.0)
- The official nightly of 2026-10-16 built successfully with zuma f085107 and shusky bf38587 — [build-manifest.xml](https://mirrorbits.lineageos.org/full/husky/20261016/build-manifest.xml)

### Inferences
- Health looks good: an official weekly build was produced 2026-10-16. Tip-of-branch differs from that build only by the face-unlock changes, which use a framework xml and a blob that is present.
- Main risk: the CP3A series is open. If it merges partially (device tree CP3A while Muppets is still CP2A, or the reverse), expect vintf, sepolicy or blob-list mismatches. For a first-try build, pin all of shusky, zuma and the Muppets vendor repo to commits from the same day, or to the 2026-10-16 build-manifest revisions with the Muppets tip 7085ddc0.
- 509380 "Fix Rust symbol hashes in blobs" suggests the CP3A blobs need extra blob fixups to link. That applies only after the CP3A update, not to the current CP2A state.

### Gaps
- I did not read the Gerrit change diffs for the CP3A series, so I could not see what new modules or blobs it needs.
- I found no public CI or build-log record of failed husky lineage-24.0 builds. The download portal shows only successful builds, with no gaps visible between 2026-10-12 and 2026-10-16.
