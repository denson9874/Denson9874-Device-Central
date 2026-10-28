# ExpressiveOS for cheetah (Pixel 7 Pro)

ExpressiveOS is its own ROM, built on Evolution X (cnb) like any standard custom ROM (Daryl,
2026-10-25 and 2026-10-26):

- its own name and version: `ExpressiveOS-17.0-<date>-cheetah-1.0-Unofficial.zip`, "ExpressiveOS 1.0"
  in Settings and the Updater;
- its own release keys, update feed (`denson9874/expressiveos_ota`, branch `main`), release folder
  (`~/releases/expressiveos-cheetah`), SourceForge folder (`expressiveos/cheetah`) and R2 prefix
  (`expressiveos/cheetah/`), all set in `eos.conf`;
- a clean install only: updates from other ROMs, Evolution X included, never install on it;
- KernelSU Next with susfs and NeoZygisk switched on at first boot (both active after one restart)
  ([`ksu/`](ksu/README.md)), ViPER4Android RE ([`viper4android/`](viper4android/README.md)), its
  own boot animation ([`bootanimation/`](bootanimation/README.md)) and its own wallpaper, Bloom, on a
  clean install's first screen ([`wallpapers/`](wallpapers/README.md)).

The Evolution X cheetah build (`evolution-cheetah/`, built in `~/evolution`) stays as it is, unrooted.
Nothing here touches it: every script refuses `~/evolution` and `~/derpfest`, writes nothing through a
symlink that leads out of `~/expressiveos` (its `out/` and `out-kernel/` included), and builds only while
holding the lock the Evolution X routines take (`~/.evolution-tree.lock`). The one exception is
`tools/server-cleanup.sh` (Disk, below).

## What's here

| Path | What it does |
|---|---|
| `eos.conf` | Names, feed, release folders and key pins every script reads |
| `setup.sh` | Sets up `~/expressiveos` (ExpressiveOS's own manifest, full history, Git LFS) or syncs it again, and moves a 1.0 tree onto that manifest (Sources, below) |
| `pins/kernel.xml` | The exact kernel source ExpressiveOS builds |
| `sources/` | Where ExpressiveOS's own sources came from: `eos-1.0-base/` (the 1.0 builds' sources), `org-fork.sh` (the forks in the ExpressiveOS GitHub organization) and `own-manifest.py` (ExpressiveOS's manifest); `update-check.sh` and `update.py`, the monthly update's dry run |
| `prepare.sh`, `apply.sh`, `patches/` | Git LFS files, the kit's tree patches (below), the newest cached firmware (`update-firmware.sh`) |
| `tools/eos-keys-check.sh` | The key guard: ExpressiveOS's own keys, never Evolution X's, DerpFest's or the AOSP test keys |
| `tools/eos-images.sh` | The build, start to finish |
| `tools/eos-verify.sh` | Checks a finished build offline |
| `tools/eos-target-files.sh` | Checks the target-files zip kept with the build (`eos-verify.sh` runs it) |
| `tools/eos-pack.sh` | The fastboot zip, the release gate and the SourceForge upload |
| `tools/server-cleanup.sh` | Frees disk on the build server (runner actions `server-cleanup-list` and `server-cleanup`) |
| `lib.sh`, `tools/payload.py`, `tools/payload-sig.py` | Shared guards and helpers; `payload-sig.py` checks a payload's signatures without update_engine's code |

Tree patches (`apply.sh`). In a project that's one of ExpressiveOS's own repos (Sources, below) each is a
commit there already, and `apply.sh` only checks that commit is the patch's change; a new patch for such a
project, or a patch changed in place, stops the build. In any other project they're local commits, which
`repo sync` drops and the next build puts back:

| Patches | What |
|---|---|
| `device_google_pantah` 0001, 0002, 0010 | ExpressiveOS's own: maintainer, update feed, only ExpressiveOS's boot animation |
| `device_google_pantah` 0003-0009, `device_google_gs201` 0001-0005, `vendor_google_cheetah` | `evolution-cheetah`'s, copied unchanged |
| `device_google_gs201` 0006 | ExpressiveOS's own: target-files takes the system, vendor, product and other dynamic partition images the build made (`COPY_IMAGES_FOR_TARGET_FILES_ZIP`) instead of making them again with other file times, so the fastboot zip and the OTA carry the same ones and an incremental OTA can patch them on phones installed either way (target-files still signs its own boot images and vbmeta, which an incremental writes whole) |
| `frameworks_base` 0001-0010 | The fixes the Evolution X tree carries, refreshed for today's frameworks/base: they apply without history too |
| `frameworks_base` 0011-0020 | evolution-kodiak's background-power fixes (2026-10-26), copied: SystemUI animations that kept running with the screen off or on AOD, the colored status bar icons setting, AxSpoofManager's fetches, Extreme Charging's 50% limit |
| `vendor_lineage` 0001 | ExpressiveOS 1.0 names, and the build's own date, so both make passes name one zip |
| `vendor_lineage` 0002 | evolution-kodiak's, copied: games get stock's 60 fps default again |
| `vendor_lineage` 0003 | ExpressiveOS's own: `m evolution` keeps the target-files zip its OTA package is made from |
| `frameworks_base` 0021-0024, `packages_apps_Settings`, `packages_apps_Evolver`, `packages_apps_Updater`, `lineage-sdk`, `packages_apps_LineageParts`, `packages_apps_EvoEgg`, `packages_apps_Sandbox`, `vendor_pixel-style`, `system_core`, `bootable_recovery` | ExpressiveOS's branding (Daryl, 2026-10-27: "ExpressiveOS only, no mention"): every screen, icon, link and the crash report header say ExpressiveOS, the Evolver is "Expressive Studio", the crash dialog copies the log instead of uploading it to Evolution X's paste site, recovery shows ExpressiveOS's mark. Made at the server's revisions of 2026-10-26; the images come from [`branding/`](branding/README.md) |
| `system_update_engine` 0001 | update_engine checks payload and metadata signatures again (Daryl, 2026-10-27); Evolution X's 59fbd47 skips them, on the phone and in the host's `delta_generator` |
| `system_update_engine` 0002 | No OTA downgrades on user builds again (59fbd47's other half): going back to an older build means fastboot |
| `packages_apps_Updater` 0005 | ExpressiveOS's own: a feed entry with `base_timestamp` (an incremental package) is offered only to the build it was made from |
| `packages_apps_Settings` 0005, `packages_apps_Updater` 0006, `packages_apps_EvoEgg` 0003 | The Bloom colours (Daryl, 2026-10-27: "instead of the neon ExpressiveOS ... the bloom colors"; the logo's petals were Daryl's pick): the glowing wordmark on Settings' Android version screen, Expressive Studio's About page and the Updater's main screen and top bar sweeps the Bloom mark's four petals instead of Evolution X's neon pink, violet and cyan, and the easter egg's stars take the petals instead of Evolution X's blue ([`branding/`](branding/README.md#the-colours)) |
| `packages_apps_Evolver` 0005, 0006 | Expressive Studio's Bento Bloom layout (Daryl, 2026-10-28: picked "A"): the home is a bento of Bloom-coloured tiles (the lock screen as it is now, with its wallpaper and clock face, beside themes and wallpaper, then colours, fonts, the clock styles and what's new, then the other sections on their petals' colours), and the lock screen page opens with that preview, the face's name and the clock and wallpaper pickers. The tiles open the pages through the screen's own rows, kept hidden for search. Display face: Google Sans Flex, rounded ([`branding/`](branding/README.md#expressive-studios-font)). They apply to the server's Evolver of 2026-10-26 (69ffc36, the revision ExpressiveOS is pinned to) and don't need Evolution X's 2026-10-27 rewrite |
| `system_update_engine` 0003 | Recovery's sideload checks payload signatures too (LineageOS's 27c007a skips them, and Evolution X's recovery has no package check at all) |
| `ksu/patches`, `viper4android/patches` | Their kits' own (see their READMEs) |

A folder is named after its project's path with `_` for `/`; a project whose name has a `_` of its own
(`system/update_engine`) names itself in the folder's `PROJECT` file.

Never `evolution-cheetah/apply.sh` or its pantah 0001/0002: they point the Updater at Evolution X's feed.

## First time on the build server

1. **Disk and packages.** A full-history tree with `out/` and `out-kernel/` needs about 450 GB
   (`setup.sh` checks; 620 GB were free on 2026-10-26). Every host package the scripts need is
   installed; `ksu/tools/ksu-module.sh` and `cheetah-ksu.sh` check theirs.
2. **The kit.** Put this folder on the server as `~/expressiveos-cheetah` (like `~/evolution-cheetah`), or
   run it from a checkout of this repo: the scripts find their files next to themselves. `git am` needs a
   committer identity (`git config --global user.name` and `user.email`).
3. **The tree:** `~/expressiveos-cheetah/setup.sh` (the first sync downloads a few hundred GB).
4. **The keys**, by hand, once (next section).
5. **KernelSU Next:** `~/expressiveos-cheetah/ksu/fetch-ksu.sh`, again after every change to
   `ksu/ksu.conf`. ViPER4Android fetches its own files during the build.

Or from the runner (`.github/workflows/kodiak-build.yml`, with `tree_ref` the branch to install the kit
from), without a shell on the server:

| Action | What it does |
|---|---|
| `expressiveos-status` | Read-only: the sessions, locks, kit, tree, keys, build and the end of each log |
| `expressiveos-setup` | Installs `tree_ref`'s kit as `~/expressiveos-cheetah`, then runs `setup.sh` and `ksu/fetch-ksu.sh` in tmux session `eos-setup` |
| `expressiveos-keys` | "Keys" below, once, never over an existing `vendor/evolution-priv`, and a backup archive `~/expressiveos-keys-<time>.tar.gz` (mode 600) to copy off the server |
| `expressiveos-build` | Installs the kit, then `tools/eos-images.sh` and `tools/eos-pack.sh` in `eos-build` (query: `kernel-only`, `kernel-sync`) |
| `expressiveos-pack` | Installs the kit, then `tools/eos-pack.sh` in `eos-pack` |

The sessions run outside the job (a first build outlasts its 4 hours) with a fresh login's environment, and
a committer identity for `git am` when git has none. Each logs to `~/expressiveos-jobs/<name>.log`, ending
`SESSION_EXIT=<n>`; on the server, `tmux attach -t eos-build` watches one. No action starts while an
ExpressiveOS session or script is running.

## Keys

The keys are what make ExpressiveOS its own ROM: every ExpressiveOS phone trusts them for updates from
its first install on. Evolution X's makefiles fall back to the AOSP test keys without a word when
`keys.mk` is missing, so the build checks them before it starts (`eos-keys-check.sh tree` and `vars`) and
after it ends (`out`).

Make them with Evolution X's own template, in a fresh login shell (never one where `envsetup.sh` ran in
`~/evolution`: `croot` would take you there):

```bash
cd ~/expressiveos
if [ -e vendor/evolution-priv ]; then
    ls -la vendor/evolution-priv; echo "STOP: something is already there; don't make keys over it"
else
    git clone https://github.com/Evolution-X/vendor_evolution-priv_keys-template vendor/evolution-priv/keys &&
    cd vendor/evolution-priv/keys && git remote remove origin && {
        ./keys.sh             # about 2 minutes, no prompts; it always exits 1 (make_key's trap)
        ls *.pk8 | wc -l      # 89
        chmod 700 . && chmod 600 *.pk8
        ~/expressiveos-cheetah/tools/eos-keys-check.sh tree   # last line KEYS_CHECK=UNPINNED, with both fingerprints
    }
fi
```

Then, before any build leaves the server:

1. **Back up the folder off the server**, for example
   `tar -C ~/expressiveos/vendor/evolution-priv -czf - keys | gpg -c > ~/expressiveos-keys-$(date +%F).tar.gz.gpg`,
   copied to the Mac and somewhere offline. It's the only copy. Without it no ExpressiveOS phone can take
   another update.
2. **Pin them:** put the two fingerprints `eos-keys-check.sh` printed into `eos.conf`
   (`EOS_AVB_PUBKEY_SHA1`, `EOS_OTA_CERT_SHA256`) and commit that. From then on a tree with any other keys
   fails, and `eos-pack.sh --release` works only with them (`KEYS_CHECK=OK`).

The keys never go into git, and never `tools/keys/expressive_platform.keystore`.

## Build

In tmux. A first build runs longer than the runner job's 4-hour limit.

```bash
~/expressiveos-cheetah/setup.sh               # only to set up the tree or put it back on its pins
~/expressiveos-cheetah/tools/eos-images.sh    # waits for the Evolution X routines' lock and any running build
```

It waits for `~/.expressiveos.lock`, then the routines' `~/.evolution-tree.lock`, and holds both to the end
(never set `EOS_HOLDS_LOCK` yourself: the script checks that its own run holds them).
`ksu/tools/ksu-images.sh`, `ksu-module.sh` and `cheetah-ksu.sh` run alone take the same two locks. It runs `prepare.sh`, the key checks,
the three kits, checks the name and version the build will carry,
records the sources, runs the two make passes (`ksu/tools/ksu-images.sh`) and `eos-verify.sh`. Everything
also goes to `~/expressiveos-build.log` (the run before is kept as `.1`); the last line is `BUILD_EXIT=0`
or `BUILD_EXIT=1`.

- `KERNEL_ONLY=1`: stop after `build_kernel` and `kernelsu.ko`.
- `EOS_KERNEL_SYNC=1`: sync the kernel source to `pins/kernel.xml` again. Otherwise only the first
  build syncs it, and later ones check it's still on the pins.

## Sources

ExpressiveOS builds its own sources (Daryl, 2026-10-28: fully independent of Evolution X, whose
rebuilds and force-pushes broke the Studio patches on 2026-10-27; ExpressiveOS merges LineageOS and
Google's security fixes itself). The tree is [ExpressiveOS/manifest](https://github.com/ExpressiveOS/manifest),
branch `expressiveos` (`eos.conf`), one flat `default.xml` with every project at a commit, never a
branch head:

- the 74 projects Evolution X, Evolution-X-Devices and BtHelper's TheParasiteProject hosted come from
  ExpressiveOS's forks of them in the [ExpressiveOS](https://github.com/ExpressiveOS) organization, at
  their `expressiveos` branch: the commit of the 1.0 builds (tag `eos-1.0-base`) plus the kit's
  changes as commits (`OTA`, in the tree twice, also has `expressiveos-vanilla` for
  `evolution/OTA-VANILLA`). cheetah's device trees and blobs are among them: the kit has no local
  manifest any more;
- the rest, LineageOS's and AOSP's, at the commits of the 1.0 builds (LineageOS never rewrites its
  branches, and AOSP's are tags);
- `evolution/manifest` stays at Evolution X's last manifest: `build_kernel` reads the LineageOS version
  from it, and a manifest can't name its own next commit.

Each commit is on the branch its `upstream` names, so a fresh tree syncs anywhere. `setup.sh` fetches the
manifest and checks it before anything syncs (no `<include>`, every project at a commit), then syncs the
projects to that commit of it only, so a bad manifest changes no source. `setup.sh` and every build check
the tree against it (`tree_manifest` and `pins_check` in `lib.sh`: the manifest as GitHub has it, no local
manifest, each project synced to its commit, the kit's own commits on top) and stop if anything is off.
`pins/kernel.xml` pins the kernel source the same way: the 18 projects of LineageOS's gs-6.1 kernel
manifest (lineage-24.0), which `ksu/tools/ksu-images.sh` syncs `out-kernel/google/gs-6.1` to before
`build_kernel`, which never syncs it itself (`SKIP_KERNEL_SYNC=1`).

To change a project that's ExpressiveOS's own repo: commit to its `expressiveos` branch (never rewrite
it, and never edit a kit patch for it: `apply.sh` stops on both), then move that project's `revision`
in the manifest's `default.xml` to the new commit, and commit that. Newer LineageOS or AOSP sources come
the same way, with a new manifest commit, and only when Daryl asks.

The monthly update starts with its dry run, `sources/update-check.sh` (the runner's read-only
`expressiveos-update-check`), which changes nothing in the tree and pushes nothing. Against LineageOS's
manifest today it shows:

- for LineageOS's and AOSP's projects, which move and by how many commits (each must descend from
  ours);
- for ExpressiveOS's forks of LineageOS's and AOSP's repos (45 of the 74), LineageOS's new commits
  merged into each in memory (`git merge-tree`): clean, or the files that conflict, and which of those
  the kit's own changes touch;
- what LineageOS's manifest changed since the sources' base (projects added, removed, moved to a fork);
- the security patch level before and after (our release config's flag in `vendor/lineage`, which
  LineageOS bumps monthly);
- the kernel's 18 projects against `pins/kernel.xml` (Google's GKI tag), and KernelSU Next's and
  NeoZygisk's newest releases against `ksu/ksu.conf`.

Its fetches and test merges stay in `~/expressiveos-update`, in scratch repos that borrow the tree's git
objects, so only new commits download; the report is `reports/update-check-<time>.txt` there. The
other 29 forks (Evolution X's own apps and vendor repos, cheetah's trees and blobs) have nothing
upstream, and Google's factory images (cheetah's firmware and vendor blobs) aren't part of it.

Where it came from, in `sources/`:

- `eos-1.0-base/manifest.xml` and `cheetah.xml`: the exact commit of every project of the 1.0 builds of
  2026-10-26 and 2026-10-27 (Evolution X's cnb manifest and the kit's local manifest then), read off
  the build server's tree by the runner's read-only `expressiveos-pins` action. A record now.
- `org-fork.sh` made the forks, from a machine where `gh` is logged in as an owner (Daryl's Mac): one
  of each of the 73 repos those name outside LineageOS (69 Evolution-X, 3 Evolution-X-Devices,
  BtHelper), with tag `eos-1.0-base` and default branch `expressiveos` at its 1.0 commit, and
  `blobs`, which holds the Git LFS files of `vendor_gms` and `vendor_google_cheetah` (Evolution X keeps
  them on gitea.com and a personal gitlab.com account; the forks' `.lfsconfig` points at `blobs`). It
  can run again any time and redoes nothing.
- `own-manifest.py` made `default.xml` from them and the forks' branches. It fails unless each fork the
  kit has patches for (`patches/`, `ksu/patches/`, `viper4android/patches/`) has every one of them as a
  commit above its 1.0 commit, and it gives those forks their full history (no `clone-depth`):
  `vendor_google_cheetah` was one commit deep, which would hide its kit commits under the top one from
  `apply.sh` and `eos-verify.sh`.

A tree from before (Evolution X's manifest, `.repo/manifests/expressiveos-pins.xml` and
`.repo/local_manifests/cheetah.xml`) moves to ExpressiveOS's manifest with `setup.sh`: the local manifest
is kept beside it as `cheetah.xml.eos-1.0`, `expressiveos-pins.xml` is deleted, BtHelper (another repo
name now) is checked out again, and the sync fetches only the kit's commits from the forks (and
`vendor/google/cheetah`'s few older commits, its clone being one commit deep); their files are what the
1.0 tree had with the kit's patches applied.

A complete run leaves in `out/eos/`: `build.ok` (the OTA package's sha256, which `eos-pack.sh` needs),
`target-files.ok` (the sha256 of the target-files zip it was made from, which `m evolution` leaves in
`obj/PACKAGING/target_files_intermediates/`),
`manifest.xml` (the tree's `repo manifest -r`), `kernel-manifest.xml` (the kernel's) and `sources.txt`
(the kit's commit, the KernelSU Next source, and each patched project's upstream revision and HEAD).
They're the record of what the build was made from, for the GPL source offer.

`eos-verify.sh` checks, without a phone: the package (the build's own, A/B, for cheetah), the identity
(cheetah, Pixel 7 Pro, user build, every kit patch in, the Updater on ExpressiveOS's feed), the keys
(every image vbmeta chains, otacerts, and the package's zip and payload signatures; recovery's otacerts
also hold LineageOS's release certificate, which Evolution X adds there, and nothing else; the payload is
signed with the pinned OTA key, `delta_generator` refuses AOSP's test key for it, and update_engine and
recovery's update_engine_sideload carry the signature and downgrade checks), the payload (every
partition plus the nine firmware images, its init_boot is out/'s KernelSU Next one, its boot, init_boot,
vbmeta and vbmeta_system are ExpressiveOS's, patch levels), KernelSU Next and the stock init_boot,
ViPER4Android, the boot animation, the wallpaper, the branding (`tools/brand-check.py`: no app, framework string or
tombstone header names Evolution X, apart from the few links it lists on purpose), the firmware and the
fastboot files, and the target-files zip (`tools/eos-target-files.sh`: the package's, with out/'s KernelSU
Next init_boot, and a WARNING if a dynamic partition image the fastboot zip flashes, system, vendor,
product and the rest, isn't byte for byte its copy there: an incremental OTA from this build couldn't
patch it on phones installed from the fastboot zip, so `eos-pack.sh --release` refuses such a build,
though it still packs as a candidate; a note lists the other images, which target-files signs again
with its own AVB salts and an incremental writes whole).

## Test and release

1. `tools/eos-pack.sh` packs the candidate into `~/releases/expressiveos-cheetah/check/`:
   `<name>-fastboot.zip` (what `fastboot-info.txt` flashes, with `android-info.txt` saying
   `require board=cheetah` only, so it can't land on a Pixel 7), `<name>-init_boot-stock.img` for users
   who want no root, `<name>-target_files.zip` (what the OTA package was made from), their `.sha256`,
   and the `out/eos/` records.
2. Back up the phone. Then a clean install: unlock the bootloader, flash the latest stock firmware,
   then `fastboot -w update <name>-fastboot.zip`.
3. Test on the phone: it boots, the KernelSU Next manager shows "Working", ViPER4Android's driver loads
   (`viper4android/tools/v4a-check.sh device`), the boot animation plays, the phone starts on Bloom
   with blue system colours, the Updater shows
   ExpressiveOS 1.0 and no updates, and Play Integrity.
4. Write `check/<name>-fastboot.zip.device-ok` with the line `sha256 <the zip's sha256>` (the pack
   prints it) and a note on what you tested.
5. `tools/eos-pack.sh --release` copies the tested zip into `~/releases/expressiveos-cheetah` (a second
   release the same day gets `-r2`), and `--upload` also uploads it to SourceForge, where a name that
   holds another zip is never overwritten either (even once the server's copy is gone; if SourceForge
   can't be checked, nothing is released). Both need the keys pinned and repack out/ to check it's byte
   for byte the zip that was tested, whose dynamic partition images must be its target-files' (above). The release folder must be `~/releases/expressiveos-cheetah` itself,
   not a symlink. The release keeps its target-files in `target-files/`, named after the release
   (`target-files/LATEST` names the newest), and `--upload` sends them to R2's
   `expressiveos/cheetah/target-files/` (`EOS_R2_REMOTE`, `~/bin/rclone`), or with `EOS_R2_REMOTE=` empty to
   SourceForge's `expressiveos/cheetah/target-files`: every incremental OTA from the release starts from them.

The Updater feed stays `{"response": []}` until the OTA publish script exists (below).

## Disk

`tools/server-cleanup.sh`, through the runner actions `server-cleanup-list` (read-only) and
`server-cleanup` (query: groups such as `1,2,3`), lists and removes old builds and outputs, Evolution X's
and DerpFest's copies included, by exact path and only while it holds `~/.evolution-tree.lock`. It never
touches the `~/android-dt/firmware/image-*.zip` files every fastboot pack reads or the firmware cache,
never removes a folder holding a `.device-ok` record, and never the newest ExpressiveOS release's
target-files (`target-files/LATEST`). Release zips don't need to stay on the server
(they're on SourceForge, Google Drive or R2); anything else needs Daryl's OK before it goes.

A target-files zip takes several GB (about 8, until the first build measures it): one in `out/` (kept
until the next build starts), a copy in `check/`, one per release in `target-files/` (a hard link to
`check/`'s while that's the same build), and while `m evolution` packages it, its unpacked copy in `out/`
too. An older release's can go once its `.uploaded` marker is there.

## Not done yet

- The OTA publish script (feed JSON in Evolution X's Updater format, changelog, R2 upload), modelled on
  `evolution-kodiak/tools/p11-ota.sh` with ExpressiveOS's own feed and folders. Don't publish
  `ota_property_files` yet. With `system_update_engine` 0001, update_engine refuses a payload that isn't
  signed with ExpressiveOS's key even when it streams one, but that has to be seen on a 1.0 phone first:
  `update_engine_client --verify` must refuse an Evolution X cheetah OTA's metadata
  (`kDownloadMetadataSignatureMismatch`) and take ExpressiveOS's ("Payload is applicable"). It writes
  no partition; root comes from KernelSU Next. A user build doesn't install `update_engine_client`, so
  build it in the same tree (`m update_engine_client`) and copy
  `out/target/product/cheetah/system/bin/update_engine_client` out. Then delete it there, to keep out/'s
  system folder as the build made it (no rebuild: system.img packs only the build's own file list, so it
  never held it). Run each OTA's metadata in turn (the remote command is quoted once, so `su` covers all
  of it):

  ```bash
  python3 -I -c 'import sys,struct,zipfile; f=zipfile.ZipFile(sys.argv[1]).open("payload.bin"); h=f.read(24); _,_,m,s=struct.unpack(">4sQQI",h); open(sys.argv[2],"wb").write(h+f.read(m+s))' <ota.zip> meta.bin
  adb push update_engine_client meta.bin /data/local/tmp/
  adb shell "su -c 'chmod 755 /data/local/tmp/update_engine_client; cp /data/local/tmp/meta.bin /data/ota_package/eos-meta.bin; /data/local/tmp/update_engine_client --verify --metadata=/data/ota_package/eos-meta.bin; echo rc=\$?; rm -f /data/ota_package/eos-meta.bin'"
  adb logcat -d | grep -E 'Failed to validate metadata signature|Payload is (not )?applicable'
  ```
- The incremental OTA script: `ota_from_target_files -i` from a release's target-files to the next, signed
  with the tree's release key, everything but the dynamic partitions in full (`--full_ota_partitions`), and
  offered only to phones on that base build (`packages_apps_Updater` 0005's `base_timestamp`).
- Decisions still open: patch-level properties in cheetah's vbmeta, purging the old keystore from this
  repo's history.
