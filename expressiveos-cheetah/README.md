# ExpressiveOS for cheetah (Pixel 7 Pro) and the other phones

ExpressiveOS is its own ROM, built on Evolution X (cnb) like any standard custom ROM (Daryl,
2026-10-25 and 2026-10-26):

- its own name and version: `ExpressiveOS-17.0-<date>-cheetah-1.0-Unofficial.zip`, "ExpressiveOS 1.0"
  in Settings and the Updater;
- its own release keys, update feed (`denson9874/expressiveos_ota`, branch `main`), release folder
  (`~/releases/expressiveos-cheetah`), SourceForge folder (`expressiveos/cheetah`) and R2 prefix
  (`expressiveos/cheetah/`), all set in `eos.conf` and `devices/cheetah.conf`;
- a clean install only: updates from other ROMs, Evolution X included, never install on it;
- KernelSU Next with susfs and NeoZygisk switched on at first boot (both active after one restart)
  ([`ksu/`](ksu/README.md)), ViPER4Android RE ([`viper4android/`](viper4android/README.md)), its
  own boot animation ([`bootanimation/`](bootanimation/README.md)) and its own wallpaper, Bloom, on a
  clean install's first screen ([`wallpapers/`](wallpapers/README.md)).

That's ExpressiveOS on cheetah, the kit's first phone and the one every script builds unless told
otherwise. husky (Pixel 8 Pro) and the four Pixel 11s build from the same kit and tree, with their own
names, folders and switches (Other phones, below).

The Evolution X cheetah build (`evolution-cheetah/`, built in `~/evolution`) stays as it is, unrooted.
Nothing here touches it: every script refuses `~/evolution` and `~/derpfest` (`prepare.sh` only copies
a Pixel 11's vendor blobs out of it, Other phones), writes nothing through a
symlink that leads out of `~/expressiveos` (its `out/` and `out-kernel/` included), and builds only while
holding the lock the Evolution X routines take (`~/.evolution-tree.lock`). The one exception is
`tools/server-cleanup.sh` (Disk, below).

## What's here

| Path | What it does |
|---|---|
| `eos.conf` | Names, feed, release folders and key pins every script reads |
| `devices/` | One `<device>.conf` per phone, what differs between them, and a phone's own tree patches ([`devices/`](devices/README.md); Other phones, below) |
| `setup.sh` | Sets up `~/expressiveos` (ExpressiveOS's own manifest, full history, Git LFS) or syncs it again, and moves a 1.0 tree onto that manifest (Sources, below) |
| `pins/kernel.xml` | The exact kernel source ExpressiveOS builds |
| `sources/` | Where ExpressiveOS's own sources came from: `eos-1.0-base/` (the 1.0 builds' sources), `org-fork.sh` (the forks in the ExpressiveOS GitHub organization) and `own-manifest.py` (ExpressiveOS's manifest); `update-check.sh`, `update.sh` and `update.py`, the monthly update (see below), and `tests/`, its tests; `updates/<id>/`, each update's own files |
| `prepare.sh`, `apply.sh`, `patches/` | Git LFS files, the kit's tree patches (below), the phone's firmware (cheetah's: the newest cached, `update-firmware.sh`) |
| `tools/eos-keys-check.sh` | The key guard: ExpressiveOS's own keys, never Evolution X's, DerpFest's or the AOSP test keys |
| `tools/eos-images.sh` | The build, start to finish |
| `tools/eos-verify.sh` | Checks a finished build offline |
| `tools/eos-target-files.sh` | Checks the target-files zip kept with the build (`eos-verify.sh` runs it) |
| `tools/eos-pack.sh` | The fastboot zip, the release gate, the SourceForge upload and testers' uploads |
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
| `devices/<device>/patches`, `devices/<device>/ksu-patches` | One phone's own, after the shared ones and only in its builds: its device tree's maintainer and feed commits (as pantah's 0001 and 0002), its own fixes, and its KernelSU Next changes |

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
| `expressiveos-build` | Installs the kit, then `tools/eos-images.sh` and `tools/eos-pack.sh` in `eos-build` (query: `device=<phone>` or `devices=<phone>,<phone>,...`, `kernel-only`, `kernel-sync`, `clean`) |
| `expressiveos-pack` | Installs the kit, then `tools/eos-pack.sh` in `eos-pack` (query: `device=<phone>`, `testers`) |

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
also goes to `~/expressiveos-build.log` (another phone's: `~/expressiveos-build-<device>.log`; the run
before is kept as `.1`); the last line is `BUILD_EXIT=0` or `BUILD_EXIT=1`.

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
  manifest any more. Another phone's projects must be in the manifest too (`setup.sh` checks its
  `EOS_SENTINEL` file after a sync; husky's are LineageOS's trees and TheMuppets' blobs, as they are),
  all but the Pixel 11s' vendor blobs (Other phones);
- the rest, LineageOS's and AOSP's, at the commits of the 1.0 builds (LineageOS never rewrites its
  branches, and AOSP's are tags);
- `evolution/manifest` stays at Evolution X's last manifest: `build_kernel` reads the LineageOS version
  from it, and a manifest can't name its own next commit.

Each commit is on the branch its `upstream` names, so a fresh tree syncs anywhere. `setup.sh` fetches the
manifest and checks it before anything syncs (nothing but remotes and projects: no `<include>`,
`<extend-project>` or `<submanifest>`; every project at a commit; the server's checkout of it unchanged),
then syncs the projects to that commit of it only, so a bad manifest changes no source. `setup.sh` and every build check
the tree against it (`tree_manifest` and `pins_check` in `lib.sh`: the manifest as GitHub has it, no local
manifest, each project synced to its commit, the kit's own commits on top) and stop if anything is off.
`pins/kernel.xml` pins the kernel source the same way: the 18 projects of LineageOS's gs-6.1 kernel
manifest (lineage-24.0), which `ksu/tools/ksu-images.sh` syncs `out-kernel/google/gs-6.1` to before
`build_kernel`, which never syncs it itself (`SKIP_KERNEL_SYNC=1`).

To change a project that's ExpressiveOS's own repo: commit to its `expressiveos` branch (never rewrite
it, and never edit a kit patch for it: `apply.sh` stops on both), then move that project's `revision`
in the manifest's `default.xml` to the new commit, and commit that. Newer LineageOS or AOSP sources come
the same way, by the monthly update (below), and only when Daryl asks.

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
  kit has patches for (`patches/`, `ksu/patches/`, `viper4android/patches/`, and each phone's
  `devices/<device>/patches/` and `ksu-patches/`) has every one of them as a
  commit above its 1.0 commit, and it gives those forks their full history (no `clone-depth`):
  `vendor_google_cheetah` was one commit deep, which would hide its kit commits under the top one from
  `apply.sh` and `eos-verify.sh`.

A tree from before (Evolution X's manifest, `.repo/manifests/expressiveos-pins.xml` and
`.repo/local_manifests/cheetah.xml`) moves to ExpressiveOS's manifest with `setup.sh`: the local manifest
is kept beside it as `cheetah.xml.eos-1.0`, `expressiveos-pins.xml` is deleted, BtHelper (another repo
name now) is checked out again, and the sync fetches only the kit's commits from the forks (and
`vendor/google/cheetah`'s few older commits, its clone being one commit deep); their files are what the
1.0 tree had with the kit's patches applied.

A complete run leaves in `out/eos/` (another phone's in `out/eos-<device>/`): `build.ok` (the OTA
package's sha256, which `eos-pack.sh` needs),
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
with its own AVB salts and an incremental writes whole). Another phone's build is checked the same way
against its `devices/<device>.conf`: its model, firmware, and what it ships or doesn't (KernelSU Next,
ViPER4Android).

## The monthly update

ExpressiveOS takes LineageOS's new commits (and with them Google's monthly security fixes, which
LineageOS merges) once a month, after LineageOS's "release: Bump Security String" commit, and only when
Daryl says so. One update serves every phone: they share the tree, and all six build the same release
config (`cp2a`). Everything runs on the build server from the runner, in `~/expressiveos-update` (outside
the tree; its scratch repos borrow the tree's git objects, so only new commits download), and nothing
reaches GitHub before step 5. That folder holds an update's plan, merges, `kernel.xml` and reports until
its pull request is merged and its `kernel.xml` committed (step 5); otherwise it's safe to delete.

How the update treats a project of ExpressiveOS's manifest depends only on its line's remote name and on
whether LineageOS's manifest has a project at the same path (`update.py`'s `kind_of`):

| the line | LineageOS's manifest has the path | every update |
|---|---|---|
| `remote="expressiveos"` | yes | a fork: LineageOS's commits merged into its branch, pushed |
| `remote="expressiveos"` | no (every device's trees and blobs) | ExpressiveOS's own: keeps its commit |
| another remote | yes | LineageOS's or AOSP's: moves to what LineageOS's manifest names |
| another remote, with `upstream=` | no | moves to its upstream's tip, unreviewed (the `-kernels` prebuilts) |
| another remote, no `upstream=` | no | pinned: stays at its commit, never contacted |

GitHub's fork relation, `org-fork.sh` and `dest-branch` play no part: a repo of the ExpressiveOS
organization under any other remote name is not ExpressiveOS's to the update (lint calls it a problem).
So a device's trees and blobs in the organization, on `expressiveos`, are ExpressiveOS's own; LineageOS's
or TheMuppets' (husky's) with no `upstream=` are pinned, and listed with the projects outside LineageOS's
manifest. Either way the update never brings LineageOS's (or TheMuppets') device commits into them: those
move together by hand, as a manifest commit. A manifest change is one line per project before `</manifest>`, in
`own-manifest.py`'s layout (plan writes the update into that text, and refuses anything else), never a
second manifest file, an `<include>` or a `notdefault` group, and `own-manifest.py` is never run again
(it would put the projects back on the 1.0 sources). Before such a change is merged, lint it:
`expressiveos-update` with query `lint pull/<n>` (or `sources/update.sh lint <branch>`, which needs no
tree, on the build server or any Linux machine with git 2.38 or newer and python3) shows what plan would refuse, each new or changed project's kind, and
whether its commit is where its line says; it ends `MANIFEST_LINT=OK` or `MANIFEST_LINT=PROBLEMS`.
From an update's first plan until its pull request is merged, nothing else changes the manifest or the
forks' `expressiveos` branches: plan and push stop on anything that moved, and a fork's new commits would
go into its merge.

Every run ends with one status line, the last of its output:

| run | its last line |
|---|---|
| `update-check.sh` | `UPDATE_CHECK=OK`, `INCOMPLETE`, `FAILED` or `NOT_RUN` |
| `update.sh plan <id>` | `UPDATE_PLAN=READY`, `CONFLICTS`, `NOT_READY` or `NOT_RUN` |
| `update.sh push <id>` | `UPDATE_PUSH=OK`, `FAILED` or `NOT_RUN` |
| `update.sh verify <id>` | `UPDATE_VERIFY=OK`, `DIFFERS`, `FAILED` or `NOT_RUN` |
| `update.sh lint [ref]` | `MANIFEST_LINT=OK`, `PROBLEMS` or `FAILED` |
| `update.sh token` | `TOKEN_CHECK=OK` or `FAIL` |

A run that stops, in `update.py` or in the script before it (no tree, the tree on another manifest, a key
missing from `eos.conf`), prints a `FAIL:` line and ends with its `FAILED` (plan: `NOT_READY`; token:
`FAIL`) and `(stopped: <why>)`. `NOT_RUN` names the build or setup holding `~/.expressiveos.lock`: run it
again in a gap between builds.

### 1. The dry run

`sources/update-check.sh` (the runner's read-only `expressiveos-update-check`) changes nothing in the
tree and pushes nothing. Against LineageOS's manifest today it shows:

- for LineageOS's and AOSP's projects, which move and by how many commits (a LineageOS project's
  must descend from ours; shallow and AOSP projects aren't counted);
- for ExpressiveOS's forks of LineageOS's and AOSP's repos (44 at 1.0), LineageOS's new commits
  merged into each in memory (`git merge-tree`): clean, or the files that conflict, and which of those
  the kit's own changes touch (any device's), and the commits a fork's branch has past its pin, which
  the update takes too;
- the projects outside LineageOS's manifest on other remotes: those that will move to their own
  upstream's tip, and those pinned;
- what LineageOS's manifest changed since the last update (`last-update.conf`; before the first, the
  1.0 sources' base): projects added, removed, moved to a fork;
- the security patch level before and after (our release config's flag in `vendor/lineage`, which
  LineageOS bumps monthly);
- the kernel's 18 projects against `pins/kernel.xml` (Google's GKI tag), and KernelSU Next's and
  NeoZygisk's newest releases against `ksu/ksu.conf`.

It also checks the manifest's text as plan will (the tree's, and GitHub's where that's newer). The report
is `~/expressiveos-update/reports/update-check-<time>.txt`. ExpressiveOS's own repos (Evolution X's apps
and vendor repos, the devices' trees and blobs) have nothing upstream, and Google's factory images (each
device's firmware and vendor blobs) aren't part of it. It ends `UPDATE_CHECK=OK` or
`UPDATE_CHECK=INCOMPLETE`, or `UPDATE_CHECK=NOT_RUN` (naming the holder) while a build or setup holds
`~/.expressiveos.lock`: check again in a gap between builds.

### 2. The update's folder

An update is a folder of this kit, committed here before it runs: `sources/updates/<id>/`, its id the
month (`2026-11`; `2026-11-2` for a second one that month):

- `update.conf`: `LINEAGE_MANIFEST=<commit>`, the commit of LineageOS's manifest (on its `lineage-24.0`
  branch) the update takes, and nothing else. It fixes which repos, branches and tags the update takes.
  LineageOS's manifest names branches, not commits, so each project takes its branch's newest commit
  when the plan runs, except a fork on a branch whose resolution, or whose merge this update pushed
  already, is for an older commit of it: it takes that commit. LineageOS can go on committing while a
  conflict is resolved, and the resolution stays good (the newer commits wait for the next update);
- `resolutions/<project path>.patch`: how a fork's merge that conflicts is resolved (step 4), one per
  such fork.

Nothing else may be in it. An id is used once: the manifest records the last update in
`last-update.conf` (`UPDATE=<id>`, `LINEAGE_MANIFEST=<commit>`), which the next dry run and plan count
from.

### 3. The plan

`expressiveos-update` with query `plan <id>` (`sources/update.sh plan <id>`) makes the whole update and
pushes nothing. It needs the tree on GitHub's manifest (otherwise: run `expressiveos-setup` first, no
build needed) and doesn't run while a build or setup does (`~/.expressiveos.lock`). It makes, in
`~/expressiveos-update/updates/<id>/`:

- each fork's merge of LineageOS's commits, a merge commit by `EOS_UPDATE_IDENT` (`eos.conf`) in its
  scratch repo, with the resolution put in where the merge conflicts. Every merge runs with git's
  default merge settings pinned and none of the machine's git config or attributes (no `.gitattributes`
  merge drivers, no renormalizing), so the build server and the machine a resolution is made on merge
  alike;
- every other LineageOS and AOSP project's new commit, and each project outside LineageOS's manifest
  with an `upstream=` its upstream's tip (listed on their own). A LineageOS project's must descend from
  ours (LineageOS never rewrites its branches); a shallow one's (`clone-depth`) and AOSP's (a new tag)
  aren't checked;
- the new `default.xml`: those commits, and what LineageOS's manifest changed since the last update,
  taken three ways. A project's repo, branch or clone depth moves where ours was still LineageOS's, and
  the plan stops where both changed it; groups and linkfiles/copyfiles are taken element by element
  (LineageOS's additions and removals, ExpressiveOS's own entries kept), forks' too. Projects LineageOS
  added are added, except ones outside repo's default sync (`notdefault`), which LineageOS's own sync
  leaves out too, until LineageOS puts them into it. A project LineageOS takes out of the default sync
  is taken out, except a fork, which stays in it (a note). A repo LineageOS moved to another path moves
  (a fork's: by hand). Projects it dropped stay: LineageOS's following their own branch, one on an AOSP
  tag with a note, and a fork at its pin, ExpressiveOS's own from then on (a note). A new AOSP tag moves
  the `aosp` remote and each project's upstream. It's checked as `setup.sh` checks a manifest, then
  committed with `last-update.conf` on top of GitHub's (`plan.json` records it, every fork's merge, and
  the forks it moves to their branch's tip without one);
- the security patch level before and after;
- `kernel.xml`: `pins/kernel.xml` with each kernel project on LineageOS's kernel manifest's commit
  today (and its branch or tag, where that moved), also printed in the report. `pins/kernel.xml` is the
  kernel of every device built from LineageOS's gs-6.1 kernel manifest (cheetah, husky): one file, with
  that manifest's projects exactly. Where it can't be proposed, the plan says why under "Needs a look"
  and its last line adds `kernel: no new pins proposed`;
- the push token's reach, asked of GitHub as a push would ask (step 5).

The report is `reports/update-plan-<id>-<time>.txt`. The run ends with `UPDATE_PLAN=READY`,
`UPDATE_PLAN=CONFLICTS` (each conflict shown with the fork's side, the merge base's and LineageOS's, the
commits on each side that touch the file, and the commands to resolve it) or `UPDATE_PLAN=NOT_READY` (the
problems listed); a plan that stops ends `UPDATE_PLAN=NOT_READY (stopped: <why>)`. A plan can run again,
and starts over, until a push of it has made `update/<id>`.
After that it refuses and leaves the update's files as they are: `plan.json` for push run again, and
`kernel.xml` for step 5.

### 4. Resolving a conflict

By hand, in a clone of the fork, on any machine with git 2.38 or newer. The plan prints these commands
with the fork's and LineageOS's addresses and commits filled in:

```bash
git clone https://github.com/ExpressiveOS/<fork> <fork> && cd <fork>
git checkout --detach <fork commit>
git fetch https://github.com/LineageOS/<repo> refs/heads/lineage-24.0
git merge --no-commit <LineageOS commit>
# fix each conflicting file, then git add it
python3 -I <kit>/sources/update.py resolution . --out <kit>/sources/updates/<id>/resolutions/<project path>.patch
```

`resolution` refuses a shallow clone, a merge with files still conflicting or conflict markers left in,
and file names it can't write down (control characters, quotes, backslashes). It redoes the merge as the
plan does, in a scratch repo of its own with none of the clone's config or `.gitattributes`, so whatever
those changed in the clone's merge (a merge driver's work) is written down as part of the fix. Its file
starts `merge <fork commit>
<LineageOS commit>`, then `resolved <file>` for each conflicting file and `changed <file>` for each other
file the fix changed, and holds the diff from the fork's commit to the fixed merge for those files
(renames written as a delete and an add). Keeping one side as the merge left it (a binary file, a file
one side deleted) is a resolution too. Before writing it, `resolution` puts it into the merge the way the
plan will and refuses unless that makes exactly the clone's merge. The plan puts it in only where the
merge is that same one and conflicts in exactly those files, and stops on conflict markers left in: a
resolution for an older fork commit is stale, and the merge is resolved again. Commit it here, then plan
again.

### 5. The push

When the plan is `READY` and Daryl says go: `expressiveos-update` with query `push <id>`. The runner hands
it the push token (step 6) for that step only. It checks the plan first and pushes nothing unless all of
it still fits: the kit's `updates/<id>/` as the plan read it, GitHub's manifest, every fork's branch the
plan merged into and every fork it pins at its branch's tip, all where the plan left them. Then it
pushes each fork's merge to its `expressiveos` branch (a fast-forward, never forced), then the manifest's
commit as branch `update/<id>` of ExpressiveOS's manifest, and prints the pull request link
(`expressiveos...update/<id>`).

If a push stops partway, run push again: it skips the forks already at their merge and pushes the rest.
If it says to plan again (something moved since the plan), plan again: a fork whose merge was pushed
already keeps it ("merged by this update and pushed before"; LineageOS's newer commits wait for the next
update, as in step 2), and the next push goes on from there.

Merging that pull request is the update. Then `expressiveos-update` with query `verify <id>` checks
GitHub's manifest against the plan: each project at the plan's commit (or a later one of a fork's branch
that has the merge), each fork's branch holding its merge, `last-update.conf` naming the update, and
what's there that the plan didn't make; it ends `UPDATE_VERIFY=OK` or `UPDATE_VERIFY=DIFFERS`. Then
`expressiveos-setup` syncs the tree to it; the plan's `kernel.xml` goes into this kit as
`pins/kernel.xml` in a commit of its own, and the next build of each gs-6.1 device runs with
`kernel-sync`; then build, test and release as usual. A fork's new commits on its own branch are
already in the merge: the forks' `expressiveos` branches never rewind, so a pull request that isn't
merged leaves only the forks a commit ahead of the manifest's pins, which the next update takes.

### 6. The push token

`expressiveos-update` with query `token` checks it, read-only: may it push to every repo of
ExpressiveOS's manifest and the manifest itself? It asks GitHub as a push's first request does (no login
must get 401, the token 200) and pushes nothing; it ends `TOKEN_CHECK=OK`. The token is a fine-grained
one of the ExpressiveOS organization's (Repository access: All repositories; Permissions: Contents, read
and write; nothing else), saved as the Actions secret `EXPRESSIVEOS_PUSH_TOKEN` of this repo. It lives
in that step's environment only, never on the server's disk, in a command line or in a log (git gets it
from a credential helper that reads the environment), and goes only to https://github.com/, never to
another host or over plain http, whatever the manifest names. It expires after a year: make a new one the same
way, save it over the secret, and check it.

### 7. The tests

`sources/tests/run.sh` tests the dry run, plan, push and resolution on throwaway worlds of `file://`
repos standing in for LineageOS, AOSP and GitHub, with a tree and a copy of this kit (git 2.38 or newer,
about 10 minutes; nothing leaves the machine, and nothing outside `$EOS_TEST_WORK`, default
`$TMPDIR/eos-update-tests`, is touched). Run it after any change to `update.py`; each script's header
says what it checks (`devices.sh`: device projects, the lint, verify, and a kit missing what the update
reads).

## Test and release

cheetah's, as below; another phone's run the same with its own folders and board (Other phones).

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

For a phone nobody has tested a build on yet, `tools/eos-pack.sh --testers` (the runner's
`expressiveos-pack` with query `testers`, only when Daryl says so) uploads `check/`'s candidate for
testers: no `.device-ok`, but the keys pinned and its images its target-files', as for a release.
The fastboot zip, its `.sha256` and (with KernelSU Next) the stock init_boot go to SourceForge's
`expressiveos/<device>/testers/` and `~/releases/expressiveos-<device>/testers/`, never over another
file; never to the release folder itself, target-files or the feed. It ends with
`UPLOADED_TESTERS <url>`.

The Updater feed stays `{"response": []}` until the OTA publish script exists (below).

## Other phones

`EOS_DEVICE` picks the phone, cheetah unless set: cheetah (Pixel 7 Pro), husky (Pixel 8 Pro), kodiak
(Pixel 11 Pro XL), grizzly (Pixel 11 Pro), cubs (Pixel 11) and yogi (Pixel 11 Pro Fold). Each has a
`devices/<device>.conf` holding what differs between them: lunch target, model, release and upload
folders, device tree, vendor and firmware sources, kernel, and the KernelSU Next and ViPER4Android
switches ([`devices/`](devices/README.md) lists the keys). The keys, feed, manifest and version stay
`eos.conf`'s, one set for all of them, and so does the tree, `~/expressiveos`. cheetah's records stay
where they always were; another phone keeps its own beside them:

| | cheetah | another phone |
|---|---|---|
| Build output | `out/target/product/cheetah` | `out/target/product/<device>` |
| Records (`build.ok`, `sources.txt`, ...) | `out/eos/` | `out/eos-<device>/` |
| KernelSU Next's work | `out/ksu/` | `out/ksu-<device>/` |
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
`build.ok`: pack needs a full build after it). The phones share the tree, so they build one after another, never at once (each
build holds `~/.expressiveos.lock`).

- **husky** builds like cheetah: LineageOS's husky, shusky and zuma trees with TheMuppets' blobs (its
  firmware is that vendor repo's own), and the same gs-6.1 kernel source and GKI `boot.img` as cheetah,
  so the same KernelSU Next module ([`ksu/`](ksu/README.md#other-phones)). Its audio effects run on the
  AIDL effect HAL: no ViPER4Android.
- **The Pixel 11s** (kodiak, grizzly, cubs, yogi) run Google's stock kernel (the factory image's
  android16-6.12 GKI `boot.img`, prebuilt) and stock vendor, vendor_dlkm, system_dlkm and dtbo images:
  no root (no android16-6.12 KernelSU Next module yet; init_boot is the build's own, stock) and no
  ViPER4Android (no HIDL effect HAL) for now. Their vendor blobs, `vendor/google/<device>`, aren't in
  ExpressiveOS's manifest (Google's files, never pushed anywhere): `prepare.sh` copies the build
  server's own repo of them (`~/evolution`'s, only read) on the first build and moves to its newer
  commits after, and `sources.txt` records the commit. `vendor/google/<device>-images` (those images and
  the firmware) is made by the device tree's `extract-images.sh` from the newest
  `~/android-dt/firmware/image-<device>-*.zip`, again only when that zip changes. The fastboot zip takes
  its `super_empty.img` from that zip too, flashes `vendor_kernel_boot`, and says
  `require board=<device>` only (the factory zip's `android-info.txt` names all four).

Testing is the same gate, on a phone of that model (`check/<zip>.device-ok`), less what it doesn't ship
(KernelSU Next, ViPER4Android); until someone has tested one, `eos-pack.sh --testers` (Test and
release) gets a candidate to testers.

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
- Root and ViPER4Android on the Pixel 11s: an android16-6.12 KernelSU Next module, and ViPER4Android
  on the AIDL effect HAL (husky's too).
- Decisions still open: patch-level properties in cheetah's vbmeta, purging the old keystore from this
  repo's history.
