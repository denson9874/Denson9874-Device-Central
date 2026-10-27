# ExpressiveOS branding

Daryl, 2026-10-27: "ExpressiveOS only, no mention". Every screen a user sees says ExpressiveOS, and
Evolution X's people, links and logo are gone from the UI. Copyright and SPDX lines in the sources
stay, and so do internal names (`org.evolution.*` packages, class and resource names, `ro.evolution.*`
properties). The Evolver is "Expressive Studio", subtitle "Make your device yours" (Daryl,
2026-10-27): two strings in `packages_apps_Evolver` 0001.

The patches are in `../patches/` (the table in [the kit's README](../README.md)), made at the build
server's revisions of 2026-10-26 and applied by `apply.sh` like the others. `tools/brand-check.py`
(run by `eos-verify.sh`) fails the build if any app, framework string, APEX or tombstone header still
names Evolution X, apart from the links it lists on purpose:

- the keybox downloads (Expressive Studio's and AxSpoofManager's), which keep working as before;
- Settings' photo of the phone and the Theme Store catalog, both on Evolution X's GitHub;
- the Expressive Studio HTTP user agent and `paste.evolution-x.org` in PastyUtils, which nothing calls
  any more: the crash dialog's Copy button copies the log itself.

## The images

`tools/make-brand.py` draws every icon and image the patches carry from two inputs:

| Input | Where | sha256 |
|---|---|---|
| The logo | `docs/assets/screenshots/logo.png` in this repo | `d41dbcb2c35f756dca919a347c01a2cd5d0ce2cd4bc7ea6a395aa3520e662d64` |
| Google Sans Flex (variable) | `android/lawnchair/res/font/googlesansflex_variable.ttf` in [ExpressiveLauncher](https://github.com/denson9874/ExpressiveLauncher) | `2510a8b7a24beb1fe8163e9a49813ccfe96b5453444b9443d42665ca4fa320c9` |

```bash
python3 -m venv brandenv && brandenv/bin/pip install numpy scipy pillow fonttools uharfbuzz potracer cairosvg
brandenv/bin/python tools/make-brand.py logo.png googlesansflex_variable.ttf out \
    --recovery <a bootable/recovery checkout>     # only for the recovery images
```

| Output | Used in |
|---|---|
| `wordmark.txt` (the "ExpressiveOS" wordmark, Evolution X's 1080x240 box) | Settings' Android version banner and About header, the Updater's main screen |
| `mark-24.txt`, `mark-108.txt` (the four petals as path data) | the status bar logo, the Settings and Expressive Studio icons, the Updater's monochrome icon, the easter egg |
| `mark-colors.txt` (each petal's light and deep colour) | the gradients on the coloured icons |
| `launcher/mipmap-*/ic_launcher_foreground.png` | the Updater's app icon |
| `recovery/res-*/images/` | recovery's logo, fastbootd and the 81-frame install animation |

The same inputs give the same text files; PNGs can differ by a few pixels with other cairo or Pillow
versions. To change the artwork, regenerate, copy the outputs into the clones of the projects at the
server's revisions, commit there and export the patches again (`git format-patch -N --binary`).
