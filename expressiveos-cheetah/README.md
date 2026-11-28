# ExpressiveOS for cheetah (Pixel 7 Pro) and the other phones

ExpressiveOS is its own ROM, built from its own sources like any standard custom ROM (Daryl,
2026-10-25 and 2026-10-26):

- its own name and version: `ExpressiveOS-17.0-<date>-cheetah-1.0-Official.zip`, "ExpressiveOS 1.0"
  in Settings and the Updater;
- its own release keys, update feed (`denson9874/expressiveos_ota`, branch `main`), release folder
  (`~/releases/expressiveos-cheetah`), SourceForge folder (`expressiveos/cheetah`) and R2 prefix
  (`expressiveos/cheetah/`), all set in `eos.conf` and `devices/cheetah.conf`;
- a clean install only: updates from other ROMs never install on it;
- root out of the box with Wild Kernels' BakaSU kernel, susfs built in (Daryl, 2026-11-14):
  `EOS_KSU=wild` in every phone's `devices/<device>.conf` ships Wild's kernel in `boot.img`, and no
  manager: users install BakaSU's APK, release or nightly ([`ksu/`](ksu/README.md)); the stock `boot`
  ships beside each zip for users who want no root. ViPER4Android RE ([`viper4android/`](viper4android/README.md)), its
  own boot animation ([`bootanimation/`](bootanimation/README.md)), its own wallpaper, Bloom, on a
  clean install's first screen ([`wallpapers/`](wallpapers/README.md)), and Daryl's Expressive
  Launcher as the default Home and Recents app, with Pixel Launcher next to it for the launcher
  switch in Expressive Studio ([`launcher/`](launcher/README.md)).

That's ExpressiveOS on cheetah, the kit's first phone and the one every script builds unless told
otherwise. husky (Pixel 8 Pro) and the four Pixel 11s build from the same kit and tree, with their own
names, folders and switches (Other phones, below).

Since 2026-11-02 the build server builds ExpressiveOS only: Evolution X and DerpFest were retired and
their trees (`~/evolution`, `~/derpfest`) deleted, after the retire script (since removed) copied the Pixel 11
vendor blob repos into `~/expressiveos/vendor/google/` and their keys and server-only work into
`~/retired/`. The scripts write nothing through a symlink that leads out of `~/expressiveos` (its
`out/` and `out-kernel/` included), and build only while holding the tree lock,
`~/.expressiveos-tree.lock`; through 1.1 they hold its old name, `~/.evolution-tree.lock`, too, so a
run of an older kit still waits for them and they for it. The one exception is
`tools/server-cleanup.sh` (Disk, below). Cheetah's and husky's firmware caches are filled by
`tools/fetch-firmware.sh` (runner action `expressiveos-firmware`, query `device=husky` for husky).

**Factory firmware pins (`firmware/<device>.conf`).** Google shows the factory image tables only after a visitor accepts its
terms, so the fetcher doesn't rely on scraping unattended. When Google ships a monthly release, a person opens
`https://developers.google.com/android/images#<device>`, accepts the terms, and copies the newest generic
Android 17 release (no carrier suffix) into `firmware/<device>.conf` (`cheetah`, `husky`, `kodiak`, `grizzly`,
`cubs`, `yogi`):

```
url=https://dl.google.com/dl/android/aosp/<device>-<build>-factory-<8 hex>.zip
sha256=<the 64-hex SHA-256 from the same row>
```

Merge it, then run the runner action `expressiveos-firmware` (query empty for cheetah, `device=<phone>`
for any other phone; `check [device=<phone>]` only says what the pin and the cache hold). For `cheetah`
and `husky` (`EOS_FIRMWARE_MODE=cache`, `EOS_KERNEL=prebuilt`), `prepare.sh` updates the bootloader and
radio in `vendor/google/<device>` via `update-firmware.sh` and regenerates
`vendor/google/<device>-kernel-images` via `extract-kernel-images.sh`. For the four Pixel 11s (`kodiak`,
`grizzly`, `cubs`, `yogi`, `EOS_FIRMWARE_MODE=images`), also update `STOCK_BUILD` in `extract-images.sh`,
`BOOT_SECURITY_PATCH` in `BoardConfig.mk`, and `BuildFingerprint` in `eos_<device>.mk` together in
`ExpressiveOS-Devices/device_google_<device>` (`extract-images.sh` refuses a zip whose build id doesn't match
`STOCK_BUILD`).

## What's here

| Path | What it does |
|---|---|
| `eos.conf` | Names, feed, release folders and key pins every script reads |
| `devices/` | One `<device>.conf` per phone, what differs between them, and a phone's own tree patches ([`devices/`](devices/README.md); Other phones, below) |
| `setup.sh` | Sets up the ExpressiveOS tree (ExpressiveOS's own manifest, full history, Git LFS) or syncs it again (Sources, below) |
| `pins/wild-kernel.conf` | The pinned Wild Kernels BakaSU release (`ksu/ksu.conf` + prebuilt stock GKI modules) |
| `sources/` | Monthly pure-AOSP ASB updater (`update-aosp.py`, `update-check.sh`, `update.sh`), multi-org repo catalog/organizer (`eos-org-organize.py`), offline test suites (`tests/test_update_aosp.py`, `tests/test_eos_org_organize.py`), and `updates/<id>/` (each monthly update's `update.conf` and conflict resolutions) |
| `prepare.sh`, `apply.sh`, `patches/` | Git LFS files, the kit's tree patches (below), the phone's firmware and prebuilt kernel/vendor image extraction (`update-firmware.sh`, `extract-kernel-images.sh`, `extract-images.sh`) |
| `tools/eos-keys-check.sh` | The key guard: ExpressiveOS's own keys, never Evolution X's, DerpFest's or the AOSP test keys |
| `tools/eos-keybox.py` | Checks an attestation `keybox.xml` against Google's live roots and CRL, checks `EOS_KEYBOX_URL`, and uploads to R2 |
| `tools/eos-images.sh` | The build, start to finish |
| `tools/eos-verify.sh` | Checks a finished build offline |
| `tools/eos-target-files.sh` | Checks the target-files zip kept with the build (`eos-verify.sh` runs it) |
| `tools/eos-pack.sh` | The fastboot zip, the release gate, the SourceForge upload and testers' uploads |
| `tools/eos-ota.sh` | A release's OTA packages for the Updater: the full one and an incremental from the feed's build, to R2 (Updates over the air, below; offline test `tools/tests/eos-ota-test.sh`) |
| `tools/server-cleanup.sh` | Frees disk on the build server (runner actions `server-cleanup-list` and `server-cleanup`) |
| `lib.sh`, `tools/payload.py`, `tools/payload-sig.py` | Shared guards and helpers; `payload-sig.py` checks a payload's signatures without update_engine's code |
| `tools/gms-drop.py` | Compares the Google apps package (`vendor/gms`) with a stock Pixel image and copies stock's newer apps over ours (Pixel Drops, below) |

Tree patches (`apply.sh`). In a project that's one of ExpressiveOS's own repos (Sources, below) each is a
commit there already, and `apply.sh` only checks that commit is the patch's change; a new patch for such a
project, or a patch changed in place, stops the build. In any other project they're local commits, which
`repo sync` drops and the next build puts back:

| Patches | What |
|---|---|
| `device_google_pantah` 0001, 0002, 0010 | ExpressiveOS's own: maintainer, update feed, only ExpressiveOS's boot animation |
| `device_google_pantah` 0003-0009, `device_google_gs201` 0001-0004, `vendor_google_cheetah` | The old cheetah kit's, copied unchanged |
| `device_google_gs201` 0005 | ExpressiveOS's own: target-files takes the system, vendor, product and other dynamic partition images the build made (`COPY_IMAGES_FOR_TARGET_FILES_ZIP`) instead of making them again with other file times, so the fastboot zip and the OTA carry the same ones and an incremental OTA can patch them on phones installed either way (target-files still signs its own boot images and vbmeta, which an incremental writes whole) |
| `frameworks_base` 0001-0010 | The fixes the Evolution X tree carries, refreshed for today's frameworks/base: they apply without history too |
| `frameworks_base` 0011-0020 | The old Pixel 11 kit's background-power fixes (2026-10-26), copied: SystemUI animations that kept running with the screen off or on AOD, the colored status bar icons setting, AxSpoofManager's fetches, Extreme Charging's 50% limit |
| `vendor_lineage` 0001 | ExpressiveOS 1.0 names, and the build's own date, so both make passes name one zip |
| `vendor_lineage` 0002 | The old Pixel 11 kit's, copied: games get stock's 60 fps default again |
| `vendor_lineage` 0003 | ExpressiveOS's own: the full build's goal (`m bacon` since 1.1, `m evolution` before) keeps the target-files zip its OTA package is made from |
| `frameworks_base` 0021-0024, `packages_apps_Settings`, `packages_apps_Evolver`, `packages_apps_Updater`, `lineage-sdk`, `packages_apps_LineageParts`, `packages_apps_EvoEgg`, `packages_apps_Sandbox`, `vendor_pixel-style`, `system_core`, `bootable_recovery` | ExpressiveOS's branding (Daryl, 2026-10-27: "ExpressiveOS only, no mention"): every screen, icon, link and the crash report header say ExpressiveOS, the Evolver is "Expressive Studio", the crash dialog copies the log instead of uploading it to Evolution X's paste site, recovery shows ExpressiveOS's mark. Made at the server's revisions of 2026-10-26; the images come from [`branding/`](branding/README.md) |
| `system_update_engine` 0001 | update_engine checks payload and metadata signatures again (Daryl, 2026-10-27); Evolution X's 59fbd47 skips them, on the phone and in the host's `delta_generator` |
| `system_update_engine` 0002 | No OTA downgrades on user builds again (59fbd47's other half): going back to an older build means fastboot |
| `packages_apps_Updater` 0005 | ExpressiveOS's own: a feed entry with `base_timestamp` (an incremental package) is offered only to the build it was made from |
| `packages_apps_Settings` 0005, `packages_apps_Updater` 0006, `packages_apps_EvoEgg` 0003 | The Bloom colours (Daryl, 2026-10-27: "instead of the neon ExpressiveOS ... the bloom colors"; the logo's petals were Daryl's pick): the glowing wordmark on Settings' Android version screen, Expressive Studio's About page and the Updater's main screen and top bar sweeps the Bloom mark's four petals instead of Evolution X's neon pink, violet and cyan, and the easter egg's stars take the petals instead of Evolution X's blue ([`branding/`](branding/README.md#the-colours)) |
| `packages_apps_Evolver` 0005, 0006 | Expressive Studio's Bento Bloom layout (Daryl, 2026-10-28: picked "A"): the home is a bento of Bloom-coloured tiles (the lock screen as it is now, with its wallpaper and clock face, beside themes and wallpaper, then colours, fonts, the clock styles and what's new, then the other sections on their petals' colours), and the lock screen page opens with that preview, the face's name and the clock and wallpaper pickers. The tiles open the pages through the screen's own rows, kept hidden for search. Display face: Google Sans Flex, rounded ([`branding/`](branding/README.md#expressive-studios-font)). They apply to the server's Evolver of 2026-10-26 (69ffc36, the revision ExpressiveOS is pinned to) and don't need Evolution X's 2026-10-27 rewrite |
| `system_update_engine` 0003 | Recovery's sideload checks payload signatures too (LineageOS's 27c007a skips them, and Evolution X's recovery has no package check at all) |
| `ksu/patches`, `viper4android/patches` | Their kits' own (see their READMEs) |
| `devices/<device>/patches`, `devices/<device>/ksu-patches` | One phone's own, after the shared ones and only in its builds: its device tree's maintainer and feed commits (as pantah's 0001 and 0002), its own fixes, and its SukiSU changes |

A folder is named after its project's path with `_` for `/`; a project whose name has a `_` of its own
(`system/update_engine`) names itself in the folder's `PROJECT` file.

## First time on the build server

1. **Disk and packages.** A full-history tree with `out/` and `out-kernel/` needs about 450 GB
   (`setup.sh` checks; 620 GB were free on 2026-10-26). Every host package the scripts need is
   installed.
2. **The kit.** Put this folder on the server as `~/expressiveos-cheetah`, or
   run it from a checkout of this repo: the scripts find their files next to themselves. `git am` needs a
   committer identity (`git config --global user.name` and `user.email`).
3. **The tree:** `~/expressiveos-cheetah/setup.sh` (the first sync downloads a few hundred GB).
4. **The keys**: never made again. Restore them from the backup (next section).
5. **Wild Kernels:** `~/expressiveos-cheetah/ksu/fetch-ksu.sh`, again after every change to `ksu/ksu.conf`
   (the build runs it too). ViPER4Android and Expressive Launcher fetch their own files during the build.

Or from the runner (`.github/workflows/kodiak-build.yml`, with `tree_ref` the branch to install the kit
from), without a shell on the server:

| Action | What it does |
|---|---|
| `expressiveos-status` | Read-only: the sessions, locks, kit, tree, keys, build and the end of each log |
| `expressiveos-setup` | Installs `tree_ref`'s kit as `~/expressiveos-cheetah`, then runs `setup.sh` and `ksu/fetch-ksu.sh` in tmux session `eos-setup` |
| `expressiveos-build` | Installs the kit, then `tools/eos-images.sh` and `tools/eos-pack.sh` in `eos-build` (query: `device=<phone>` or `devices=<phone>,<phone>,...`, `kernel-only`, `kernel-sync`, `installclean`, `quick`, `clean`, `try=`, `modules=`) |
| `expressiveos-pack` | Installs the kit, then `tools/eos-pack.sh` in `eos-pack` (query: `device=<phone>`, `testers`) |

The sessions run outside the job (a first build outlasts its 4 hours) with a fresh login's environment, and
a committer identity for `git am` when git has none. Each logs to `~/expressiveos-jobs/<name>.log`, ending
`SESSION_EXIT=<n>`; on the server, `tmux attach -t eos-build` watches one. No action starts while an
ExpressiveOS session or script is running.

## Keys

The keys are what make ExpressiveOS its own ROM: every ExpressiveOS phone trusts them for updates from
its first install on. The build's makefiles fall back to the AOSP test keys without a word when
`keys.mk` is missing, so the build checks them before it starts (`eos-keys-check.sh tree` and `vars`) and
after it ends (`out`).

**The keys exist and are never made again.** They were made once on the build server (2026-10-26) and
`eos.conf` pins their public fingerprints (`EOS_AVB_PUBKEY_SHA1`, `EOS_OTA_CERT_SHA256`): every phone
refuses an update signed with any other key, and the same keys can't be made twice. Nothing in the kit
or the runner makes keys any more, and `eos-keys-check.sh` fails a tree whose keys aren't the pinned ones.

**The key folder is `vendor/expressiveos-priv/keys`** since 1.1: on 2026-11-07 at 09:09 UTC the runner's
`expressiveos-keys-move` (`tools/eos-keys-move.sh`) moved it there from `vendor/evolution-priv/keys`, its
name before. A move, not new keys: every key file is byte-identical, only `keys.mk`'s two paths name the
new folder, and the 1.0 phones keep taking updates. Query `check` (read-only) shows which folder the tree
has, every file's size and sha256, and whether a move could run; `move` and `revert` refuse while
anything builds or syncs, and each leaves a backup archive in `~` from before and from after. The
scripts read the new folder whenever it's there and the old one only while it isn't (a tree before the
move, or after `revert`); 1.1's `vendor/lineage` reads only the new one, 1.0's only the old one.

When `~/expressiveos/vendor/expressiveos-priv/keys` is missing or damaged (a new server, the tree set up
again), restore it from the backup: the newest `~/expressiveos-keys-<time>.tar.gz` on the server
(`expressiveos-status` lists them), or its copy kept off the server (a `.tar.gz.gpg` one: `gpg -d` it
first). An archive from before the move (`~/expressiveos-keys-20261107-090905.tar.gz`, made just before
it, and older ones such as 2026-10-26's) has a `keys.mk` that names `vendor/evolution-priv`; the one made
just after it, `~/expressiveos-keys-20261107-090906.tar.gz`, and newer ones name `vendor/expressiveos-priv`.
To be sure, `tar -xzOf <archive> keys/keys.mk | grep -m1 -o 'vendor/[a-z]*-priv'` prints the folder an
archive's `keys.mk` names (`keys.mk` holds paths, no keys). Restore an old one into
`vendor/evolution-priv` instead (the same lines with that folder), then run `tools/eos-keys-move.sh move`. In a fresh login shell:

```bash
cd ~/expressiveos
priv=vendor/expressiveos-priv   # vendor/evolution-priv for an archive from before the move (20261107-090905 and older)
if [ -e vendor/expressiveos-priv ] || [ -L vendor/expressiveos-priv ] || [ -e vendor/evolution-priv ] || [ -L vendor/evolution-priv ]; then
    ls -la vendor/*-priv; echo "STOP: a key folder is there already; check it (eos-keys-check.sh tree, eos-keys-move.sh check), don't restore over it"
else
    umask 077 && mkdir -p "$priv" &&
    tar -C "$priv" -xzf ~/expressiveos-keys-<time>.tar.gz &&   # the archive holds keys/
    chmod 700 "$priv/keys" && chmod 600 "$priv"/keys/*.pk8 &&
    ~/expressiveos-cheetah/tools/eos-keys-check.sh tree   # last line KEYS_CHECK=OK
fi
```

Anything but `KEYS_CHECK=OK`: stop and build nothing. When the check says the keys aren't the pinned
ones, find the right backup. Never make new keys and never change the pins in `eos.conf` to fit other
keys; a pin missing from `eos.conf` goes back to the value it was committed with (`git log -p eos.conf`).

The keys never go into git, and never `tools/keys/expressive_platform.keystore`.

## Build

In tmux. A first build runs longer than the runner job's 4-hour limit.

```bash
~/expressiveos-cheetah/setup.sh               # only to set up the tree or put it back on its pins
~/expressiveos-cheetah/tools/eos-images.sh    # waits for the build locks and any running build
```

It waits for `~/.expressiveos.lock`, then the tree lock, `~/.expressiveos-tree.lock`, and through 1.1
its old name, `~/.evolution-tree.lock`, and holds them to the end
(never set `EOS_HOLDS_LOCK` yourself: the script checks that its own run holds them).
`tools/eos-make.sh` run alone takes the same locks. It runs `prepare.sh`, the key checks,
the three kits, checks the name and version the build will carry,
records the sources, runs the make (`tools/eos-make.sh`) and `eos-verify.sh`. Everything
also goes to `~/expressiveos-build.log` (another phone's: `~/expressiveos-build-<device>.log`; the run
before is kept as `.1`); the last line is `BUILD_EXIT=0` or `BUILD_EXIT=1`.

- `KERNEL_ONLY=1`: stop after `build_kernel`.
- `EOS_KERNEL_SYNC=1`: sync the kernel source to `pins/kernel.xml` again. Otherwise only the first
  build syncs it, and later ones check it's still on the pins.
- `EOS_INSTALLCLEAN=1`: start the make with `m installclean` (the runner's `installclean`). A
  `modules=` compile check asks the next build that makes images (full or quick) for it itself; a
  kernel-only run skips it.
- `EOS_QUICK=1`: a quick build (the runner's `quick`), to test a change on a phone: the images only,
  `m droid` where a full build runs `m bacon`, which is `droid` plus the OTA package and its
  target-files zip (`vendor/lineage`'s `build/tasks/bacon.mk`; a tree from before 1.1 has no `bacon`
  goal and builds the same with `m evolution`), about 5 of a cheetah build's 8 to
  11 minutes. `eos-verify.sh` checks everything but the package, its payload and the target-files,
  and the run writes `quick.ok` instead of `build.ok` (Test and release, "Quick builds").

### Progress

The runner's `expressiveos-progress` (`tools/eos-progress.py`) is read-only and takes a few seconds, so
it runs fine while a build does. It tells you how the running `eos-build` or `eos-pack` session is
going, or how the last one went. It prints a `PROGRESS` line per phone: its state, its step (wait,
prepare, kernel, make, target_files, ota_zip, verify, pack, done), the make's actions done out of the
total (Soong's own `out/build_progress.pb`), and an ETA for when the phone should be built and packed.
Then come a `SESSION` line, the log's last 40 lines as `LOG` lines, and `PROGRESS_OK`, followed by the
same in words with US Eastern times. The docstring at the top of the script spells out every field.

**The live build page.** Every `eos-build` and `eos-pack` session the runner starts also sends that
output to R2 once a minute (`tools/eos-progress-publish.sh`, started by the session's job script and
ending with it, after one last send that holds the result). `tools/progress-page/index.html`, sent
along and served by the OTA mirror, shows it: each phone's state, step, percent, ETA in US Eastern and
the log's last lines, refreshed by itself, and a warning when a running session stops reporting. The
mirror is public, so the page's address ends in a key made on the server
(`~/.expressiveos-progress-key`); `bash ~/expressiveos-jobs/progress/eos-progress-publish.sh --where`
prints the address on the server. Never run that in a runner job: Actions logs are public. A send
that fails is silent and never touches the build. Test: `tools/tests/eos-progress-publish-test.sh`.

To know where a build is, `lib.sh`'s `eos_step` prints a line as each step begins, such as
`STEP make device=husky kind=full fresh=0 at=<UTC>`. `eos-images.sh` prints prepare and verify,
`eos-make.sh` prints kernel (lunch and `build_kernel`, on the phones that build theirs) and make,
and `eos-pack.sh` prints pack. As each step ends, `eos_step` writes how long it took to
`~/expressiveos-build-times.txt`, one `TIME` line per step for every phone. `fresh=1` means
`out/target/product/<device>` wasn't there when the build began, so the build made all of it again.
The make's ETA comes from the first of these that is known:

- Soong's own estimate in its progress lines, based on how long the same actions took last time.
- The make's pace so far.
- The median of the last 5 recorded makes like this one (same phone, same kind, same fresh).
- This server's measured times.

The other steps' ETAs come from their recorded times, or from typical times.

## Sources

ExpressiveOS builds its own sources (Daryl, 2026-10-28: fully independent; ExpressiveOS merges
LineageOS and Google's security fixes itself). The tree is [ExpressiveOS/manifest](https://github.com/ExpressiveOS/manifest),
branch `expressiveos` (`eos.conf`), one flat `default.xml` with every project at a commit, never a
branch head:

- the 71 projects of the 1.0 sources hosted on GitHub outside LineageOS come from ExpressiveOS's own
  repos in the [ExpressiveOS](https://github.com/ExpressiveOS) organization, at their `expressiveos`
  branch: the commit of the 1.0 builds (tag `eos-1.0-base`) plus the kit's changes as commits.
  cheetah's device trees and blobs are among them: the kit has no local
  manifest any more. Another phone's projects must be in the manifest too (`setup.sh` checks its
  `EOS_SENTINEL` file after a sync; husky's are LineageOS's trees and TheMuppets' blobs, as they are),
  all but the Pixel 11s' vendor blobs (Other phones);
- the rest, LineageOS's and AOSP's, at the commits of the 1.0 builds (LineageOS never rewrites its
  branches, and AOSP's are tags);
- the 1.0 sources' old manifest and OTA json checkouts (`evolution/manifest`, `evolution/OTA`,
  `evolution/OTA-VANILLA`) are left out: nothing builds from them, and `build_kernel` reads the
  LineageOS version from the tree's own manifest (`.repo/manifests/default.xml`).

Each commit is on the branch its `upstream` names, so a fresh tree syncs anywhere. `setup.sh` fetches the
manifest and checks it before anything syncs (nothing but remotes and projects: no `<include>`,
`<extend-project>` or `<submanifest>`; every project at a commit; the server's checkout of it unchanged),
then syncs the projects to that commit of it only, so a bad manifest changes no source. `setup.sh` and every build check
the tree against it (`tree_manifest` and `pins_check` in `lib.sh`: the manifest as GitHub has it, no local
manifest, each project synced to its commit, the kit's own commits on top) and stop if anything is off.
`pins/kernel.xml` pins the kernel source the same way: the 18 projects of LineageOS's gs-6.1 kernel
manifest (lineage-24.0), which `tools/eos-make.sh` syncs `out-kernel/google/gs-6.1` to before
`build_kernel`, which never syncs it itself (`SKIP_KERNEL_SYNC=1`).

To change a project that's ExpressiveOS's own repo: commit to its `expressiveos` branch (never rewrite
it, and never edit a kit patch for it: `apply.sh` stops on both), then move that project's `revision`
in the manifest's `default.xml` to the new commit, and commit that. Newer LineageOS or AOSP sources come
the same way, by the monthly update (below), and only when Daryl asks.

Where it came from, in `sources/`:

- `eos-1.0-base/manifest.xml` and `cheetah.xml`: the exact commit of every project of the 1.0 builds of
  2026-10-26 and 2026-10-27 (Evolution X's cnb manifest and the kit's local manifest then), read off
  the build server's tree by the runner's read-only `expressiveos-pins` action. A record now.
- ExpressiveOS's repos were made once from them, each with tag `eos-1.0-base` and default branch
  `expressiveos` at its 1.0 commit, and `blobs` holds the Git LFS files of `vendor_gms` and
  `vendor_google_cheetah` (their `.lfsconfig` points at `blobs`). The script that made them is retired:
  the repos change only by their own commits.
- `own-manifest.py` made `default.xml` from them and those repos' branches. It fails unless each fork the
  kit has patches for (`patches/`, `ksu/patches/`, `viper4android/patches/`, and each phone's
  `devices/<device>/patches/` and `ksu-patches/`) has every one of them as a
  commit above its 1.0 commit, and it gives those forks their full history (no `clone-depth`):
  `vendor_google_cheetah` was one commit deep, which would hide its kit commits under the top one from
  `apply.sh` and `eos-verify.sh`.

`setup.sh` stops on a tree synced from any other manifest.

A complete run leaves in `out/eos/` (another phone's in `out/eos-<device>/`): `build.ok` (the OTA
package's sha256, which `eos-pack.sh` needs),
`target-files.ok` (the sha256 of the target-files zip it was made from, which `m bacon` leaves in
`obj/PACKAGING/target_files_intermediates/`),
`manifest.xml` (the tree's `repo manifest -r`), `kernel-manifest.xml` (the kernel's) and `sources.txt`
(the kit's commit, the Wild Kernels release and Expressive Launcher sources, and each patched project's
upstream revision and HEAD).
They're the record of what the build was made from, for the GPL source offer.
A quick build (`EOS_QUICK=1`) writes `quick.ok` in place of `build.ok` and `target-files.ok`: the
sha256 of every file its fastboot zip takes from out/ (`fastboot_files` in `lib.sh`) and, with
root, of the stock boot.

`eos-verify.sh` checks, without a phone: the package (the build's own, A/B, for cheetah), the identity
(cheetah, Pixel 7 Pro, user build, every kit patch in, the Updater on ExpressiveOS's feed), the keys
(every image vbmeta chains, otacerts, and the package's zip and payload signatures; recovery's otacerts
also hold LineageOS's release certificate, which Evolution X adds there, and nothing else; the payload is
signed with the pinned OTA key, `delta_generator` refuses AOSP's test key for it, and update_engine and
recovery's update_engine_sideload carry the signature and downgrade checks), the payload (every
partition plus the nine firmware images, its boot carries Wild's kernel, its boot, init_boot,
vbmeta and vbmeta_system are ExpressiveOS's, patch levels), Wild Kernels and the stock boot,
ViPER4Android, Expressive Launcher (the only launcher, with its overlays and licences), the boot animation, the
wallpaper, the branding (`tools/brand-check.py`: no app, framework string or
tombstone header names Evolution X, apart from the few links it lists on purpose), the firmware and the
fastboot files, and the target-files zip (`tools/eos-target-files.sh`: the package's, with out/'s KernelSU
Next init_boot, and a WARNING if a dynamic partition image the fastboot zip flashes, system, vendor,
product and the rest, isn't byte for byte its copy there: an incremental OTA from this build couldn't
patch it on phones installed from the fastboot zip, so `eos-pack.sh --release` refuses such a build,
though it still packs as a candidate; a note lists the other images, which target-files signs again
with its own AVB salts and an incremental writes whole). Another phone's build is checked the same way
against its `devices/<device>.conf`: its model, firmware, and what it ships or doesn't (root,
ViPER4Android). A quick build has no package, payload or target-files: `eos-verify.sh` (and
`eos-keys-check.sh out`) checks out/'s own vbmeta, init_boot, boot and vbmeta_system and their
patch levels instead, that out/ holds no package or target-files zip, and everything else as above,
and prints `VERIFIED_QUICK <name>`.

## The monthly update (EOS 2.0 pure AOSP)

ExpressiveOS 2.0 is built directly on pure AOSP (`android-17.0.0_r1` base, branch `expressiveos-2.0` in
`ExpressiveOS/manifest`, zero LineageOS remotes or repos). Its 107 non-AOSP repositories are split across
three active GitHub organizations plus one archived 1.x org (managed by `sources/eos-org-organize.py`):

- **`ExpressiveOS`** (`remote="expressiveos"`, 58 manifest projects + `manifest` + `blobs`): Core platform, frameworks, system daemons, custom apps, vendor/GMS/UI, and the Git LFS backing store (`ExpressiveOS/blobs`, referenced by `.lfsconfig` in `vendor_gms`, `vendor_google_cheetah`, and `vendor_google_husky`).
- **`ExpressiveOS-Devices`** (`remote="expressiveos-devices"`, 15 projects): Pixel device trees (`device_google_*`), Pixel HALs/sepolicy (`hardware_google_*`), and vendor blob repos (`vendor_google_{cheetah,husky}`).
- **`ExpressiveOS-ASB`** (`remote="expressiveos-asb"`, 34+ projects): Pure upstream AOSP repositories carrying monthly Android Security Bulletin (ASB) cherry-picks (all new monthly `NEW_FORK_NEEDED` repos are created here automatically with standardized `fn-*` / `eos-asb-patch` topics).
- **`ExpressiveOS-Legacy`** (18 archived read-only repos, not in 2.0 manifest): Frozen EOS 1.x-only repositories.

Because Google's monthly `android-security-17.0.0_r*` branch diverged from `android-17.0.0_r1`,
`sources/update-aosp.py` never switches `<default revision>` to the security tag. Instead, once a month when
Google publishes the Android Security Bulletin tags (and only when Daryl says go), `update-aosp.py`
cherry-picks `--no-merges` ASB commits between `AOSP_SEC_TAG` and `TARGET_SEC_TAG` onto each affected repo,
bumps `release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto` in `vendor/expressiveos`, and
rewrites `default.xml` + `last-update.conf` with 40-hex commit SHAs.

> **QPR release tags (`android-17.0.0_r2+`) vs monthly ASB tags (`android-security-17.0.0_r*`).**
> `update-aosp.py check` queries both `android-17.0.0_r*` and `android-security-17.0.0_r*` on
> `android.googlesource.com/platform/manifest`. If a new quarterly platform release tag (`android-17.0.0_r2+`)
> appears beyond `last-update.conf`'s `AOSP_BASE_TAG`, `check` prints an explicit `NOTE:` warning:
> `update-aosp.py` cherry-picks `android-security-17.0.0_r*` ASB fixes onto the current `AOSP_BASE_TAG`,
> whereas rebasing the 107+ ExpressiveOS forks onto a full QPR source drop requires manual review.

How `update-aosp.py` treats each project in `ExpressiveOS/manifest`:

| Manifest entry | Changed between `AOSP_SEC_TAG..TARGET_SEC_TAG`? | Action |
|---|---|---|
| `remote="expressiveos"` / `expressiveos-asb` / `expressiveos-devices` | Yes | Existing EOS fork: cherry-pick `--no-merges` ASB commits onto `expressiveos-2.0` (or apply `resolutions/<eos_repo>.patch`) |
| `remote="aosp"` | Yes | `NEW_FORK_NEEDED`: create `ExpressiveOS-ASB/<path_with_underscores>` via `create-repos <id>` (with standardized topics), strip any `clone-depth`, cherry-pick ASB commits, and switch the project to `remote="expressiveos-asb"` |
| `vendor/expressiveos` | Always | Bump `RELEASE_PLATFORM_SECURITY_PATCH.textproto` to `TARGET_SPL` |
| Any project | No | Stays at its existing 40-hex commit SHA |

Every run ends with one status line:

| Command | Final status line |
|---|---|
| `update-check.sh` | `UPDATE_CHECK=OK`, `INCOMPLETE`, `FAILED` or `NOT_RUN` |
| `update.sh plan <id>` | `UPDATE_PLAN=READY`, `CONFLICTS`, `NOT_READY` or `NOT_RUN` |
| `update.sh create-repos <id>` | `CREATE_REPOS=OK` or `FAIL` |
| `update.sh push <id>` | `UPDATE_PUSH=OK`, `FAILED` or `NOT_RUN` |
| `update.sh verify <id>` | `UPDATE_VERIFY=OK`, `DIFFERS`, `FAILED` or `NOT_RUN` |
| `update.sh lint [ref]` | `MANIFEST_LINT=OK` or `FAIL` |
| `update.sh token` | `TOKEN_CHECK=OK` or `FAIL` |

### 1. Dry run (`check`)

`sources/update-check.sh` (runner action `expressiveos-update-check`) is read-only: it queries
`android.googlesource.com/platform/manifest` for `android-17.0.0_r*` and `android-security-17.0.0_r*`,
diffs `last-update.conf`'s `AOSP_SEC_TAG` against the latest security tag, tests every ASB cherry-pick in
scratch repos under `$EOS_UPDATE_WORK` (borrowing full-history git objects from `$EOS_TOP`, while skipping
shallow `clone-depth` checkouts), and classifies each affected repo as `CLEAN`, `CONFLICTS`, or
`NEW_FORK_NEEDED`.

### 2. Update folder (`sources/updates/<id>/`)

Commit `sources/updates/<id>/update.conf` (e.g. `sources/updates/2026-12/update.conf`) in this repo:

```ini
AOSP_SEC_TAG=android-security-17.0.0_r3
TARGET_SEC_TAG=android-security-17.0.0_r4
TARGET_SPL=2026-12-01
```

(`AOSP_SEC_TAG` is optional if `last-update.conf` in the manifest already records the previous tag.)

### 3. Plan & conflict resolutions (`plan <id>`)

Run `expressiveos-update` with query `plan <id>` (`sources/update.sh plan <id>`). It stages deterministic
commits (preserving upstream ASB committer timestamps so re-running `plan <id>` produces identical 40-hex
SHAs), writes `default.xml`, `last-update.conf` (preserving `AOSP_BASE_TAG`) and `plan.json` under
`$EOS_UPDATE_WORK/<id>/`, and lints the manifest + SPL textproto.

If a repo reports `CONFLICTS`, resolve it on top of the manifest's pinned commit `<base_rev>` and save
`git format-patch --stdout <base_rev>..HEAD` to
`sources/updates/<id>/resolutions/<eos_repo>.patch` (for example `packages_apps_Settings.patch`), commit
that patch to the kit, and run `plan <id>` again until `UPDATE_PLAN=READY`.

### 4. New forks (`create-repos <id>`), push (`push <id>`), and verify (`verify <id>`)

1. If `plan.json` lists `new_repos` (`new_repos > 0`), create them from the Mac with admin `gh` auth:
   `python3 -I expressiveos-cheetah/sources/update-aosp.py create-repos <id> --work <work>` (creates the
   listed public empty repos under `github.com/ExpressiveOS-ASB` with standardized `fn-*` / `eos-asb-patch`
   topics; verify push access across all three orgs with `expressiveos-update` query `token`).
2. On Daryl's go, run `expressiveos-update` with query `push <id>`. It fast-forward pushes each updated
   fork's `expressiveos-2.0` branch (never force-pushing) and pushes branch `update/<id>` to
   `ExpressiveOS/manifest` for PR review (`lint pull/<n>` validates the PR).
3. After Daryl merges the `ExpressiveOS/manifest` PR into `expressiveos-2.0`, run `expressiveos-update`
   with query `verify <id>` (`UPDATE_VERIFY=OK`), sync the build tree (`setup.sh`), refresh factory
   firmware (`firmware/<device>.conf` + `expressiveos-firmware`, plus Pixel 11 `STOCK_BUILD` /
   `BOOT_SECURITY_PATCH` / `BuildFingerprint`), and build.

### 5. Push tokens & offline tests

- `expressiveos-update` query `token` verifies `git-receive-pack` access across `ExpressiveOS/manifest`
  and every `expressiveos`, `expressiveos-asb`, and `expressiveos-devices` repo (`TOKEN_CHECK=OK`) using
  three per-org Actions secrets (`EXPRESSIVEOS_PUSH_TOKEN`, `EXPRESSIVEOS_ASB_PUSH_TOKEN`, and
  `EXPRESSIVEOS_DEVICES_PUSH_TOKEN`, mapped to `EOS_PUSH_TOKEN`, `EOS_ASB_PUSH_TOKEN`, and
  `EOS_DEVICES_PUSH_TOKEN`; note that `git-receive-pack` checks `Contents: write`, while pushing
  `.github/workflows` changes also requires `Workflows: write`).
- Run `python3 -B expressiveos-cheetah/sources/tests/test_update_aosp.py -v` and
  `python3 -B expressiveos-cheetah/sources/tests/test_eos_org_organize.py -v` after any change to
  `update-aosp.py`, `update.sh`, or `eos-org-organize.py`.

## Pixel Drops

Google ships a Pixel Drop every few months. Its features reach a phone four ways, and only the
second needs a change here:

1. **Play Store updates and Google's server switches.** Phone, Messages, Contacts and the other
   Google apps update on ExpressiveOS as on stock. Nothing to do.
2. **Pixel-only system apps and their config files**, which the ROM carries in `vendor/gms`
   (ExpressiveOS/vendor_gms): Pixel Launcher, the wallpaper and icon apps, Pixel Search, the
   sysconfig and permission XMLs. These move only when we refresh the package from a stock image.
3. **Android platform changes** (a quarterly release). They come with the LineageOS base, through
   the monthly update above.
4. **Features behind Google's device check or behind hardware we don't have.** Not added, and not
   worked around: on-device Gemini features, and anything a phone model lacks the parts for.

On each Drop:

1. Read Google's own post and sort every feature into the four groups, per phone family. Label
   each line measured or inferred.
2. Get the newest stock image of the newest Pixel we support (it holds the widest app set): a
   person opens https://developers.google.com/android/images, accepts the terms, and copies that
   release's link and SHA-256, as for cheetah's firmware pin. On the build server, with no build
   running and under the tree lock, unpack its `product`, `system_ext` and `system` images into
   one folder. The Pixel 11 image zip in `~/android-dt/firmware/` holds them as plain EROFS images
   (first run 2026-11-10, kodiak CD1A.261005.003, 30 seconds):

   ```
   S=~/gms-drop-scratch; mkdir -p $S/img $S/stock
   unzip -q ~/android-dt/firmware/image-<device>-<build>.zip product.img system_ext.img system.img -d $S/img
   for p in product system_ext system; do
     ~/expressiveos/out/host/linux-x86/bin/fsck.erofs --extract=$S/stock/$p $S/img/$p.img
   done
   ```

   Delete `$S` when the compare is done (about 13 GB): nothing stays on the server.
3. Compare, changing nothing:

   ```
   python3 -I tools/gms-drop.py compare <stock> ~/expressiveos/vendor/gms
   ```

   It matches apps by package name (stock's folder names carry versions and change), and lists the
   apps stock has newer, same-`versionCode` apps whose non-`META-INF` payload changed (QPR
   rebuilds that keep `versionCode` fixed), the stock apps we don't carry (a Drop's new app shows
   here), and every config file that differs. It ends `GMS_DROP=NONE` or `GMS_DROP=CHANGES <n>`,
   the number of newer apps, same-`versionCode` payload rebuilds, and changed config files to
   decide on.
4. In a clone of ExpressiveOS/vendor_gms (with its Git LFS files), `gms-drop.py apply <stock> <clone>`
   copies stock's newer APKs over ours at our paths. It never downgrades, never adds an app, never
   blindly overwrites same-`versionCode` rebuilds (check Java ABI against our framework jars,
   private `@*android:*` resource IDs, and signing certs for `PRESIGNED` APKs first), and never
   touches `blobs/`: `nowplaying.xml` and others carry our fixes, so a config change or a new
   app is a hand edit with its `Android.bp` and `gms_*.mk` entry, reviewed like any inherited code.
   The result is a commit on the fork and a manifest pin, never a kit patch.
5. The next test build carries it. On the 7 Pro and one Pixel 11, check each group 1 and 2 feature
   over adb, with the standing checks (crash buffer, `SecurityException`, AICore associations, Now
   Playing): a refreshed Google app can ask for a permission the old XMLs don't grant, and that
   shows as a boot-time `Privileged permissions not in privapp-permissions allowlist` crash.
6. Release notes name only the Drop features a phone test showed working, per phone.

`tools/tests/gms-drop-test.sh` tests the tool offline (as a non-root user).

## Test and release

cheetah's, as below; another phone's run the same with its own folders and board (Other phones).

1. `tools/eos-pack.sh` packs the candidate into `~/releases/expressiveos-cheetah/check/`:
   `<name>-fastboot.zip` (what `fastboot-info.txt` flashes, with `android-info.txt` saying
   `require board=cheetah` only, so it can't land on a Pixel 7), `<name>-boot-stock.img` for users
   who want no root, `<name>-target_files.zip` (what the OTA package was made from), their `.sha256`,
   and the `out/eos/` records.
2. Back up the phone. Then a clean install: unlock the bootloader, flash the latest stock firmware,
   then `fastboot -w update <name>-fastboot.zip`.
3. Test on the phone: it boots, the BakaSU manager (installed by hand) shows "Working", ViPER4Android's driver loads
   (`viper4android/tools/v4a-check.sh device`), Expressive Launcher is Home and Recents with gestures
   working (`launcher/tools/launcher-check.sh device`), the boot animation plays, the phone starts on Bloom
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
   It also keeps out/'s OTA package, `ota/<release>.zip` with its `.sha256`, for the Updater (below).
6. `tools/eos-ota.sh --upload` (the runner's `expressiveos-ota` with query `upload`, only when Daryl
   says so) puts the release on the Updater: below.

For a phone nobody has tested a build on yet, `tools/eos-pack.sh --testers` (the runner's
`expressiveos-pack` with query `testers`, only when Daryl says so) uploads `check/`'s candidate for
testers: no `.device-ok`, but the keys pinned and its images its target-files', as for a release.
The fastboot zip, its `.sha256` and (with root) the stock boot go to SourceForge's
`expressiveos/<device>/testers/` and `~/releases/expressiveos-<device>/testers/`, never over another
file; never to the release folder itself, target-files or the feed. It ends with
`UPLOADED_TESTERS <url>`.

### Quick builds

To try a change on a phone, `EOS_QUICK=1 tools/eos-images.sh` (the runner's `expressiveos-build`
with query `quick`, with `try=` or `device=` as usual) builds the images only, about 5 minutes
sooner. `tools/eos-pack.sh` then packs it by itself as a quick candidate:
`check/<name>-quick-fastboot.zip` (and `<name>-quick-boot-stock.img` with root), flashed
the same way (step 2), with its `.sha256` and `.pack-ok` (`build quick`). It replaces `check/`'s
candidate, as any candidate does, and it is never released or sent to testers: with no target-files,
no incremental OTA could update phones installed from it, and a release must be the very zip that was
tested. `--release`, `--upload` and `--testers` refuse it. When the change works, build again without
`quick`, pack, flash and test that zip, and release it.

### Release notes

Each release's notes are written by hand in `release-notes/<EOS_VERSION>.md` (for example
`release-notes/1.0.md`), in Expressive Launcher's announcement format (its
`docs/release_notes/<version>_announcement.md`), so one text serves the phone, XDA and Telegram. For a
new release, copy the last file and rewrite it. `eos-pack.sh` fills in each phone's values (`{{MODEL}}`,
`{{BUILD}}`, `{{SPL}}`, `{{SHA256}}`...), keeps a line that starts with `@<device> ` only for that phone,
and writes two files next to the zip:

- `<build>-announcement.md`: the Markdown, for Expressive Launcher's `scripts/format_xda.py` (XDA) and
  `scripts/post_telegram.py` (Telegram).
- `<build>-changelog.txt`: a plain-text copy that reads well in Studio's What's new (plain text) and the
  Updater (Markdown). It becomes the feed's `changelogs/<device>.txt`.

The notes never say whether Play Integrity, attestation or Wallet pass or fail: Google's checks change
without a ROM update. A pack fails if the notes file is missing or has an unknown `{{...}}`.

### Updates over the air

Every release goes to the Updater as a full OTA package, plus one incremental from the build the feed
offers when it's made (Daryl, 2026-11-02): phones on that build download the incremental, a fraction of the
full package; every other phone takes the full one. `tools/eos-ota.sh` makes and checks both and writes the
feed files; the feed itself (`denson9874/expressiveos_ota`, `builds/<device>.json` and
`changelogs/<device>.txt`) changes only by a pull request, and phones see the update once it's merged.

- The full package is the release's own (`ota/<release>.zip`, out/'s, which `eos-verify.sh` checked).
- The incremental, `ota/<release>-incremental-from-<base date>.zip`, is `ota_from_target_files -i` from
  the base build's target-files (`target-files/`, else R2's) to the release's, signed with the tree's
  release key. The dynamic partitions (system, vendor, product...) are patched block by block: they're
  the target-files' byte for byte on every phone of the base build, however it was installed (the
  incremental base, which `--release` needs). Everything else (boot, init_boot, vbmeta, the firmware...)
  is written whole (`--full_ota_partitions`): the fastboot zip flashes out/'s images, which target-files
  signs again with its own AVB salts, and the firmware is whichever stock release the user flashed.
- The base is the build the feed's full entry offers now; with none (the first release) there's no
  incremental. A rerun of a release already in the feed makes the incremental from the same base again.
- Both are checked: A/B, this phone, this build, signed with the pinned OTA key, every A/B partition;
  the incremental from the base build. The Updater never goes back: a release older than the feed's
  stops with `OTA_SUPERSEDED`.
- The feed lists the incremental first, with `base_timestamp` (`packages_apps_Updater` 0005 offers it
  only to the base build) and a timestamp one second after the build's: of the updates a phone may take
  the Updater shows the newest by timestamp, so a phone on the base build gets the incremental, not the
  full package of the same build. Then the full package, for every other phone.
- R2's `expressiveos/<device>/ota/` keeps what the new feed and the one phones read now point at; the
  OTA mirror (`EOS_OTA_MIRROR`) serves them.

A release, start to finish, once the first one is in the feed (your phone on that build):

1. Build and pack as usual (`expressiveos-build`), but don't flash the candidate: `tools/eos-ota.sh
   --candidate` (runner: `expressiveos-ota` with `candidate`) makes the incremental from the feed's build
   to it and puts it, with a test feed of its own, in R2's `ota/test/`.
2. On the phone (root): `adb shell "su -c 'setprop evolution.updater.uri <the test feed's URL>'"`, then the
   Updater's check for updates: it offers the incremental; install it and reboot. The setting goes with
   the reboot. Test the build (Test and release, step 3) and write the candidate's `.device-ok`.
3. Release it (`eos-pack.sh --upload`; runner: `expressiveos-pack` with `release`), then
   `eos-ota.sh --upload` (runner: `expressiveos-ota` with `upload`), and open the feed's pull request with
   the files it printed. Merge it, and phones get the update.

Without `--upload` or `--candidate`, `eos-ota.sh` makes and checks the packages and the feed files and
uploads nothing. The packages take a few GB in `ota/`; once they're on R2 an older release's can go.

## Other phones

`EOS_DEVICE` picks the phone, cheetah unless set: cheetah (Pixel 7 Pro), husky (Pixel 8 Pro), kodiak
(Pixel 11 Pro XL), grizzly (Pixel 11 Pro), cubs (Pixel 11) and yogi (Pixel 11 Pro Fold). Each has a
`devices/<device>.conf` holding what differs between them: lunch target, model, release and upload
folders, device tree, vendor and firmware sources, kernel, and the Wild Kernels and ViPER4Android
switches ([`devices/`](devices/README.md) lists the keys; the boot animation, the wallpaper and Expressive
Launcher go on every phone, with no switch). The keys, feed, manifest and version stay
`eos.conf`'s, one set for all of them, and so does the tree, `~/expressiveos`. cheetah's records stay
where they always were; another phone keeps its own beside them:

| | cheetah | another phone |
|---|---|---|
| Build output | `out/target/product/cheetah` | `out/target/product/<device>` |
| Records (`build.ok`, `sources.txt`, ...) | `out/eos/` | `out/eos-<device>/` |
| Wild Kernels' work (boot-wild, boot-stock) | `out/ksu/` | `out/ksu-<device>/` |
| Build log | `~/expressiveos-build.log` | `~/expressiveos-build-<device>.log` |
| Releases; SourceForge and R2 | `~/releases/expressiveos-cheetah`; `expressiveos/cheetah` | `~/releases/expressiveos-<device>`; `expressiveos/<device>` |

A phone builds and packs the same way, named:

```bash
EOS_DEVICE=husky ~/expressiveos-cheetah/tools/eos-images.sh
EOS_DEVICE=husky ~/expressiveos-cheetah/tools/eos-pack.sh
```

From the runner: `expressiveos-build` with query `device=kodiak`, or `devices=husky,kodiak,...` for each
in turn in the one `eos-build` session, stopping at the first that fails (`clean` then removes each
packed phone's `out/target/product/<device>`, never cheetah's: that candidate can then go to testers
only, since a release repacks from `out/`; to release it, build again without `clean` and test that
zip); `expressiveos-pack` with `device=<phone>`. `try=<path>@<commit>` builds an unmerged commit of
one of ExpressiveOS's own projects (it stays checked out until a build without `try=`), and
`modules=<module>,...` is a compile check of just those modules (it removes the last build's
`build.ok`: pack needs another build after it, full or quick, and that build starts with `m installclean`, since
`m` would leave a module the product doesn't install, like Settings beside SettingsGoogle, in `out/`
and the target-files zip, though not in the images, which take only the build's file list;
`installclean` asks any build that makes images for it, and `eos-verify.sh` refuses two APKs with
one package name, but for two pairs of Evolution X overlays the product itself installs:
`known_dups` there). The phones share the tree, so they build one after another, never at once (each
build holds `~/.expressiveos.lock`).

- **husky** builds like cheetah: LineageOS's husky, shusky and zuma trees with TheMuppets' blobs (its
  firmware is that vendor repo's own), and the same gs-6.1 kernel source and GKI `boot.img` as cheetah,
  so the same Wild 6.1.162 kernel ([`ksu/`](ksu/README.md)). Its audio effects run on the AIDL effect HAL, so it gets ViPER4Android's AIDL driver (`EOS_V4A=aidl`).
- **The Pixel 11s** (kodiak, grizzly, cubs, yogi) run Google's stock kernel (the factory image's
  android16-6.12 GKI `boot.img`, prebuilt) and stock vendor, vendor_dlkm, system_dlkm and dtbo images:
  Wild's android16-6.12 kernel replaces the GKI's in boot ([`ksu/`](ksu/README.md)). ViPER4Android's AIDL driver reaches the
  read-only stock vendor through `/product/vendor_overlay`, laid over it at boot (`EOS_V4A=aidl-overlay`,
  kodiak first; [`viper4android/`](viper4android/README.md)). Their vendor blobs, `vendor/google/<device>`, aren't in
  ExpressiveOS's manifest (Google's files, never pushed anywhere): the build server's own repo of
  them is in the tree (copied there on 2026-11-02, before the old trees were deleted), `prepare.sh` only
  reads it and stops when it's missing, and `sources.txt` records its commit. `vendor/google/<device>-images` (those images and
  the firmware) is made by the device tree's `extract-images.sh` from the newest
  `~/android-dt/firmware/image-<device>-*.zip`, again only when that zip changes. The fastboot zip takes
  its `super_empty.img` from that zip too, flashes `vendor_kernel_boot`, and says
  `require board=<device>` only (the factory zip's `android-info.txt` names all four).

Testing is the same gate, on a phone of that model (`check/<zip>.device-ok`), less what it doesn't ship
(root, ViPER4Android); until someone has tested one, `eos-pack.sh --testers` (Test and
release) gets a candidate to testers.

## Disk

`tools/server-cleanup.sh`, through the runner actions `server-cleanup-list` (read-only) and
`server-cleanup` (query: groups such as `1,2,3`), lists and removes old builds and outputs, Evolution X's
and DerpFest's copies included, by exact path and only while it holds the tree lock (both its names). It never
touches the `~/android-dt/firmware/image-*.zip` files every fastboot pack reads or the firmware cache,
never removes a folder holding a `.device-ok` record, and never the newest ExpressiveOS release's
target-files (`target-files/LATEST`). Release zips don't need to stay on the server
(they're on SourceForge, Google Drive or R2); anything else needs Daryl's OK before it goes.

A target-files zip takes several GB (about 8, until the first build measures it): one in `out/` (kept
until the next build starts), a copy in `check/`, one per release in `target-files/` (a hard link to
`check/`'s while that's the same build), and while `m bacon` packages it, its unpacked copy in `out/`
too. An older release's can go once its `.uploaded` marker is there.

## Not done yet

- Streaming updates (the feed's `ota_property_files`, which `eos-ota.sh` doesn't publish yet). With
  `system_update_engine` 0001, update_engine refuses a payload that isn't signed with ExpressiveOS's key
  even when it streams one, but that has to be seen on a 1.0 phone first:
  `update_engine_client --verify` must refuse an Evolution X cheetah OTA's metadata
  (`kDownloadMetadataSignatureMismatch`) and take ExpressiveOS's ("Payload is applicable"). It writes
  no partition; root comes from Wild Kernels' BakaSU kernel. A user build doesn't install `update_engine_client`, so
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
- ViPER4Android on grizzly, cubs and yogi (`EOS_V4A=aidl-overlay`) once kodiak passes its phone test.
- Decisions still open: patch-level properties in cheetah's vbmeta, purging the old keystore from this
  repo's history.
