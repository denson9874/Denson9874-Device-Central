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

## The colours

ExpressiveOS's own colours are the Bloom mark's four petals (Daryl, 2026-10-27: "instead of the neon
ExpressiveOS in several places in the rom let's do the bloom colors"). The light and deep tones are
`make-brand.py`'s `mark-colors.txt`; the mid tones are the middle of each petal's gradient in the logo.

| Petal | Light | Mid | Deep |
|---|---|---|---|
| Violet | `#F3B1FC` | `#AE69FC` | `#6B2BBB` |
| Blue | `#76BCFB` | `#417BFC` | `#1842D1` |
| Coral | `#FDCF8E` | `#FD7771` | `#D33952` |
| Green | `#ACEFB3` | `#4AD29D` | `#18A07C` |

The ground behind the logo is `#141329`.

The glowing wordmark (Settings' `GlowView` on the Android version screen and Expressive Studio's About
page, the Updater's `EvolutionLogoGlow`) was Evolution X's neon pink `#FF2E9A`, violet `#8B5CF6` and
cyan `#22D3EE`. `packages_apps_Settings` 0005 and `packages_apps_Updater` 0006 sweep the petals instead,
in the boot animation wordmark's order (violet, blue, green, coral), with a blue fringe on the left and
a violet one on the right: the mid tones (light tones for the fringe) when the theme's text is light,
which means a dark surface, and the deep tones when it is dark. `packages_apps_EvoEgg` 0003 tints the
easter egg's background stars with the petals' mid tones, in turn, instead of Evolution X's electric blue
`#005eff`. The boot animation (its wordmark gradient runs through the petals' hues with six stops of its
own, and its glow is the blurred petals; the halo behind the mark is a neutral grey lift), the app icons
and the egg's flying marks already use the petals, and the status bar logo is white or the theme's accent.
Recovery and fastbootd still outline the mark in Evolution X's recovery blue `#0060FE` (`RECOVERY_BLUE`).

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

## Expressive Studio's font

Expressive Studio's home and lock screen header (`packages_apps_Evolver` 0005, 0006) set their titles and
clock in Google Sans Flex with its rounded terminals, in bold. `tools/make-studio-font.py` cuts it from the
same variable font as above into one static font: wght 700, ROND 100, opsz 18, normal width and grade,
upright, Latin only (Vietnamese included). Static, so the weight never depends on the text engine
applying variation settings.

```bash
brandenv/bin/python tools/make-studio-font.py googlesansflex_variable.ttf google_sans_flex_rounded_bold.ttf
```

It gives the Evolver's `res/font/google_sans_flex_rounded_bold.ttf` byte for byte (92,908 bytes, sha256
`35592f26cea8a30bf16e1740ee55259ce84d20e9394dac94af9013f5f5d54ea2`, with fontTools 4.68), named Google Sans
Flex Rounded Bold. Google Sans Flex is under the SIL Open Font License 1.1, with no Reserved Font Name: the
cut font keeps its copyright and licence in its name table, and 0005 adds the licence's text as the
Evolver's `licenses/GoogleSansFlex-OFL.txt`.
