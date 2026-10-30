# ExpressiveOS's phones

One file per phone, `<device>.conf`, read by `lib.sh` for the device a run builds
(`EOS_DEVICE`, cheetah unless set: `EOS_DEVICE=husky tools/eos-images.sh`). The keys,
feed, manifest and version stay in `../eos.conf`; a device file holds only what differs
between phones, and `lib.sh` refuses any other name (`EOS_DEVICE_KEYS`), a value with
quotes, `$`, backquotes, backslashes or `;`, and release, upload or board names that
aren't the phone's own. `cheetah.conf` restates what the kit always built, so cheetah's
builds, packs, records (`out/eos`, `out/ksu`) and log (`~/expressiveos-build.log`) don't
change. The other phones keep theirs in `out/eos-<device>`, `out/ksu-<device>` and
`~/expressiveos-build-<device>.log`, in the same tree.

A phone's own tree changes are `<device>/patches/<project>/` (the same layout as
`../patches/`) and, for KernelSU Next, `<device>/ksu-patches/<project>/`. Like the shared
ones, a patch for one of ExpressiveOS's own repos must already be a commit there.

| Key | What it is |
|---|---|
| `EOS_LUNCH` | lunch target, `lineage_<device>-<release>-user` |
| `EOS_MODEL` | `ro.product.product.model` the build must carry |
| `EOS_BOARD` | the one board the fastboot zip's `android-info.txt` requires (the device) |
| `EOS_RELEASES`, `EOS_SF_DIR`, `EOS_R2_PREFIX` | release folder, SourceForge folder, R2 prefix: `expressiveos-<device>`, `.../expressiveos/<device>`, `expressiveos/<device>/` |
| `EOS_DEVICE_TREE` | the device tree whose log holds ExpressiveOS's identity commits (maintainer, feed) |
| `EOS_BOARDCONFIG` | the BoardConfig.mk the KernelSU Next patches change |
| `EOS_VENDOR_DIR` | the vendor blobs project |
| `EOS_RADIO_MK` | the makefile listing the firmware images with their sha1 (`radio/<x>.img,<sha1>`) |
| `EOS_FIRMWARE` | the firmware partitions the OTA payload must carry |
| `EOS_FIRMWARE_MODE` | `cache`: newest cached factory firmware put into the vendor repo (cheetah); `blobs`: the vendor repo's own (husky); `images`: `vendor/google/<device>-images` made from `~/android-dt/firmware/image-<device>-*.zip` by the tree's extract-images.sh (Pixel 11) |
| `EOS_LFS_PROJECTS` | projects whose Git LFS files must all be present |
| `EOS_UPDATER_OVERLAY` | the Updater overlay APK that must point at `denson9874/expressiveos_ota` |
| `EOS_SENTINEL` | a file setup.sh expects after a sync |
| `EOS_KERNEL` | `gs-6.1`: built from `pins/kernel.xml`'s source; `prebuilt`: the tree's prebuilt boot image |
| `EOS_KMI` | the kernel's KMI (`android14-6.1`, `android16-6.12`) |
| `EOS_KSU` | `lkm`: KernelSU Next in init_boot; `none`: the stock init_boot, no root |
| `EOS_V4A` | `1`: ViPER4Android built in (gs201's HIDL effect HAL only); `0`: none |
| `EOS_SUPER_EMPTY` | `out`: the build's super_empty.img; `factory`: the one in the factory image zip |
| `EOS_FLASH_VKB` | `1`: the fastboot zip flashes vendor_kernel_boot even when the tree's fastboot-info.txt doesn't |
| `EOS_SCONE_PATCH` | the kit patch naming the SCONE module that must be installed (optional) |
| `EOS_SYSUI_ODEX` | `1`: SystemUIGoogle's odex must be on /system_ext |
