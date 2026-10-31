# Publishing a release for the web flasher

`flasher_publish.py` runs on the build server after `eos-pack.sh`. It uploads one release's fastboot zip, plus the stock
`init_boot` for a KernelSU Next build, to the R2 bucket that the flasher's Worker reads from. It then lists the release in
that device's `flasher.json`. It uses only the Python standard library and `~/bin/rclone` (rclone's `r2:` remote, set up as
in `tools/ota_mirror/README.md`).

```sh
python3 -I flasher_publish.py <device> <path to ...-fastboot.zip> [--testers] [--remote r2:denson9874-ota] \
    [--rclone ~/bin/rclone] [--keep N] [--dry-run]

# e.g. the tested release, then a candidate eos-pack.sh --testers sent (the path on its TESTERS line)
python3 -I flasher_publish.py cheetah ~/releases/expressiveos-cheetah/ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-fastboot.zip
python3 -I flasher_publish.py cheetah ~/releases/expressiveos-cheetah/testers/ExpressiveOS-17.0-20261031-cheetah-1.0-OFFICIAL-r2-fastboot.zip --testers
```

Publish from the release folder or `testers/`, never from `check/`: each candidate run of `eos-pack.sh` replaces what
`check/` holds, and its builds aren't yet named as testers get them. One run per device at a time: a second one fails
at once (`~/.expressiveos-flasher-<device>.lock`). A `--dry-run` doesn't take the lock.

The last line it prints is `FLASHER_PUBLISH=OK` or `FLASHER_PUBLISH=FAIL`. A failure also prints one `FAIL: ...` line on
stderr and exits with status 1.

## What it checks first

- `<device>` is one of cheetah, husky, kodiak, grizzly, cubs or yogi. The zip is named
  `ExpressiveOS-<android>-<yyyymmdd>-<device>-<version>-<type>[-rN]-fastboot.zip`, for that device.
- The zip matches the `.sha256` beside it, which must be the one line sha256sum writes.
- If `<name>-init_boot-stock.img` is beside the zip, it must match its own `.sha256` and be a boot image (`ANDROID!`).
  The flasher then offers KernelSU Next or no root (`"root": "kernelsu-next"`). With no stock image the release is
  listed as one without KernelSU Next (`"root": null`). A stock image's `.sha256` without the image itself is a failure,
  and so is a release that R2 already holds with a stock image in the same channel (it would be relisted without root).
- The zip is stored, as `eos-pack.sh` makes it with `zip -0`. It holds `fastboot-info.txt`, `android-info.txt`,
  `init_boot.img`, `vbmeta.img` and `super_empty.img`. Its `android-info.txt` says `require board=<device>` and has no
  other board or product line, and every other line that isn't blank is a requirement fastboot can read (fastboot
  skips a line it can't, and the flasher only warns about one).

## Where it writes in R2

It writes these paths and nothing else:

| Key | What |
|---|---|
| `expressiveos/<device>/flasher/<file>` and `<file>.sha256` | a release's zip, and its stock init_boot if there is one |
| `expressiveos/<device>/flasher/testers/<file>` and `<file>.sha256` | the same for a testers build (`--testers`) |
| `expressiveos/<device>/flasher.json` | the manifest the flasher reads, which lists both channels |

Each channel has its own folder. The Worker serves `flasher/<file>` as `/dl/<device>/<file>` and `flasher/testers/<file>`
as `/dl/<device>/testers/<file>`. A testers build and a release can have the same name, as `eos-pack.sh` keeps names
unique only within its own folders, and both are published and listed.

- **Names are never overwritten.** The run looks only in its own channel's folder. If that folder already holds a file
  under the name with the same sha256, the upload is skipped, so running it again is safe, and the release keeps its
  place in the manifest. If the sha256 differs, the run fails before anything is uploaded.
- **The `.sha256` goes up before its file.** That claims the name first, and a run cut short during a long upload can
  simply be run again. It is checked in R2 before the file goes up.
- **What goes up is what was hashed.** The stock image and each `.sha256` go up from the run's own copies. The zip goes
  up from the file itself, which must not change from its hashing to the end of its upload; if it does, the run fails
  and says what to remove from R2.
- **The manifest is never silently replaced.** If `flasher.json` exists but isn't a valid manifest, the run fails and
  writes nothing.
- **Dropped releases stay in R2.** The manifest lists only the newest `--keep` releases of each channel (2 by default),
  sorted by date, then publish time, then `-rN`. Files of releases it no longer lists are printed as
  `no longer listed: <remote path>`, a path in their own channel's folder, and left in place.
- **The manifest is read back.** After the upload, the script reads `flasher.json` back and checks that it lists the new
  release.
- **`--dry-run` writes nothing.** It runs every local check and every read of R2 (a missing bucket fails), then prints
  what it would upload and the manifest it would write.

## The manifest

```json
{
  "schema": 1,
  "device": "cheetah",
  "updated": "2026-10-31T09:00:00Z",
  "releases": [
    {
      "name": "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL",
      "channel": "release",
      "android": "17.0", "version": "1.0", "type": "OFFICIAL", "date": "2026-10-30",
      "published": "2026-10-31T09:00:00Z",
      "zip": {"file": "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-fastboot.zip", "size": 6123456789, "sha256": "..."},
      "initBootStock": {"file": "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-init_boot-stock.img", "size": 8388608, "sha256": "..."},
      "root": "kernelsu-next",
      "requirements": ["require board=cheetah", "require version-bootloader=..."]
    }
  ]
}
```

`channel` is `release` or, with `--testers`, `testers`. A name is listed at most once in each channel, so it can be in
both. `initBootStock` and `root` are both `null` for a build without KernelSU Next. `requirements` holds the non-empty
lines of the zip's `android-info.txt`.

## Tests

```sh
python3 -m unittest discover -s tools/expressiveos_flasher/publish
```

The tests build small stored Zip64 fastboot zips. They run the script as the server does (`python3 -I`), against a fake
rclone that serves a temporary folder as the bucket and exits with 3 for a missing directory, as rclone does.
