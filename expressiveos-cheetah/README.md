# ExpressiveOS for cheetah (Pixel 7 Pro)

ExpressiveOS is its own ROM, built on Evolution X (cnb) like any standard custom ROM (Daryl,
2026-10-25 and 2026-10-26):

- its own name and version: `ExpressiveOS-17.0-<date>-cheetah-1.0-Unofficial.zip`, "ExpressiveOS 1.0"
  in Settings and the Updater;
- its own release keys, update feed (`denson9874/expressiveos_ota`, branch `main`), release folder
  (`~/releases/expressiveos-cheetah`), SourceForge folder (`expressiveos/cheetah`) and R2 prefix
  (`expressiveos/cheetah/`), all set in `eos.conf`;
- a clean install only: updates from other ROMs, Evolution X included, never install on it;
- KernelSU Next with susfs ([`ksu/`](ksu/README.md)), ViPER4Android RE
  ([`viper4android/`](viper4android/README.md)) and its own boot animation
  ([`bootanimation/`](bootanimation/README.md)).

The Evolution X cheetah build (`evolution-cheetah/`, built in `~/evolution`) stays as it is, unrooted.
Nothing here touches it: every script refuses `~/evolution` and `~/derpfest`, writes nothing through a
symlink that leads out of `~/expressiveos` (its `out/` and `out-kernel/` included), and builds only while
holding the lock the Evolution X routines take (`~/.evolution-tree.lock`). The one exception is
`tools/server-cleanup.sh` (Disk, below).

## What's here

| Path | What it does |
|---|---|
| `eos.conf` | Names, feed, release folders and key pins every script reads |
| `setup.sh` | Sets up `~/expressiveos` (Evolution X's manifest, full history, Git LFS, `local_manifests/cheetah.xml`) or syncs it |
| `prepare.sh`, `apply.sh`, `patches/` | Git LFS files, the kit's tree patches (below), the newest cached firmware (`update-firmware.sh`) |
| `tools/eos-keys-check.sh` | The key guard: ExpressiveOS's own keys, never Evolution X's, DerpFest's or the AOSP test keys |
| `tools/eos-images.sh` | The build, start to finish |
| `tools/eos-verify.sh` | Checks a finished build offline |
| `tools/eos-pack.sh` | The fastboot zip, the release gate and the SourceForge upload |
| `tools/server-cleanup.sh` | Frees disk on the build server (runner actions `server-cleanup-list` and `server-cleanup`) |
| `lib.sh`, `tools/payload.py` | Shared guards and helpers |

Tree patches (`apply.sh`, as local commits; `repo sync` drops them and the next build puts them back):

| Patches | What |
|---|---|
| `device_google_pantah` 0001, 0002, 0010 | ExpressiveOS's own: maintainer, update feed, only ExpressiveOS's boot animation |
| `device_google_pantah` 0003-0009, `device_google_gs201`, `vendor_google_cheetah` | `evolution-cheetah`'s, copied unchanged |
| `frameworks_base` 0001-0010 | The fixes the Evolution X tree carries, refreshed for today's frameworks/base: they apply without history too |
| `frameworks_base` 0011-0020 | evolution-kodiak's background-power fixes (2026-10-26), copied: SystemUI animations that kept running with the screen off or on AOD, the colored status bar icons setting, AxSpoofManager's fetches, Extreme Charging's 50% limit |
| `vendor_lineage` 0001 | ExpressiveOS 1.0 names, and the build's own date, so both make passes name one zip |
| `vendor_lineage` 0002 | evolution-kodiak's, copied: games get stock's 60 fps default again |
| `frameworks_base` 0021-0024, `packages_apps_Settings`, `packages_apps_Evolver`, `packages_apps_Updater`, `lineage-sdk`, `packages_apps_LineageParts`, `packages_apps_EvoEgg`, `packages_apps_Sandbox`, `vendor_pixel-style`, `system_core`, `bootable_recovery` | ExpressiveOS's branding (Daryl, 2026-10-27: "ExpressiveOS only, no mention"): every screen, icon, link and the crash report header say ExpressiveOS, the Evolver is "Expressive Studio", the crash dialog copies the log instead of uploading it to Evolution X's paste site, recovery shows ExpressiveOS's mark. Made at the server's revisions of 2026-10-26; the images come from [`branding/`](branding/README.md) |
| `ksu/patches`, `viper4android/patches` | Their kits' own (see their READMEs) |

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
~/expressiveos-cheetah/setup.sh               # only when you want newer sources (repo sync)
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
- `EOS_KERNEL_SYNC=1`: sync the kernel source again. It follows branch heads, so only the first build
  syncs it otherwise.

A complete run leaves in `out/eos/`: `build.ok` (the OTA package's sha256, which `eos-pack.sh` needs),
`manifest.xml` (the tree's `repo manifest -r`), `kernel-manifest.xml` (the kernel's) and `sources.txt`
(the kit's commit, the KernelSU Next source, and each patched project's upstream revision and HEAD).
They're the record of what the build was made from, for the GPL source offer.

`eos-verify.sh` checks, without a phone: the package (the build's own, A/B, for cheetah), the identity
(cheetah, Pixel 7 Pro, user build, every kit patch in, the Updater on ExpressiveOS's feed), the keys
(every image vbmeta chains, otacerts, and the package's zip and payload signatures; recovery's otacerts
also hold LineageOS's release certificate, which Evolution X adds there, and nothing else), the payload (every
partition plus the nine firmware images, its init_boot is out/'s KernelSU Next one, its boot, init_boot,
vbmeta and vbmeta_system are ExpressiveOS's, patch levels), KernelSU Next and the stock init_boot,
ViPER4Android, the boot animation, the branding (`tools/brand-check.py`: no app, framework string or
tombstone header names Evolution X, apart from the few links it lists on purpose), the firmware and the
fastboot files.

## Test and release

1. `tools/eos-pack.sh` packs the candidate into `~/releases/expressiveos-cheetah/check/`:
   `<name>-fastboot.zip` (what `fastboot-info.txt` flashes, with `android-info.txt` saying
   `require board=cheetah` only, so it can't land on a Pixel 7), `<name>-init_boot-stock.img` for users
   who want no root, their `.sha256`, and the `out/eos/` records.
2. Back up the phone. Then a clean install: unlock the bootloader, flash the latest stock firmware,
   then `fastboot -w update <name>-fastboot.zip`.
3. Test on the phone: it boots, the KernelSU Next manager shows "Working", ViPER4Android's driver loads
   (`viper4android/tools/v4a-check.sh device`), the boot animation plays, the Updater shows
   ExpressiveOS 1.0 and no updates, and Play Integrity.
4. Write `check/<name>-fastboot.zip.device-ok` with the line `sha256 <the zip's sha256>` (the pack
   prints it) and a note on what you tested.
5. `tools/eos-pack.sh --release` copies the tested zip into `~/releases/expressiveos-cheetah` (a second
   release the same day gets `-r2`), and `--upload` also uploads it to SourceForge, where a name that
   holds another zip is never overwritten either (even once the server's copy is gone; if SourceForge
   can't be checked, nothing is released). Both need the keys pinned and repack out/ to check it's byte
   for byte the zip that was tested. The release folder must be `~/releases/expressiveos-cheetah` itself,
   not a symlink.

The Updater feed stays `{"response": []}` until the OTA publish script exists (below).

## Disk

`tools/server-cleanup.sh`, through the runner actions `server-cleanup-list` (read-only) and
`server-cleanup` (query: groups such as `1,2,3`), lists and removes old builds and outputs, Evolution X's
and DerpFest's copies included, by exact path and only while it holds `~/.evolution-tree.lock`. It never
touches the `~/android-dt/firmware/image-*.zip` files every fastboot pack reads or the firmware cache,
and never removes a folder holding a `.device-ok` record. Release zips don't need to stay on the server
(they're on SourceForge, Google Drive or R2); anything else needs Daryl's OK before it goes.

## Not done yet

- The OTA publish script (feed JSON in Evolution X's Updater format, changelog, R2 upload), modelled on
  `evolution-kodiak/tools/p11-ota.sh` with ExpressiveOS's own feed and folders. Never publish
  `ota_property_files`: the Updater's package check is the only thing keeping Evolution X packages off
  ExpressiveOS phones.
- Freezing the tree: 318 projects follow branch heads. After the first good build, rebuild from its
  `out/eos/manifest.xml` until moving on is a decision.
- Decisions still open: patch-level properties in cheetah's vbmeta, purging the old keystore from this
  repo's history.
