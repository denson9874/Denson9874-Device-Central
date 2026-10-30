# ExpressiveOS boot animation (cheetah)

ExpressiveOS's own boot animation for the Pixel 7 Pro, drawn by us from the ExpressiveOS logo
(`docs/assets/screenshots/logo.png`) and Google Sans Flex. The motion is inspired by Loic's
boot animation concept, shared in the ExpressiveLauncher feedback group
(t.me/ExpressiveLauncherFeedback/463): none of his artwork is used, and he gets a credit in
every release (Daryl, 2026-10-26). The wordmark reads "ExpressiveOS" (Daryl, 2026-10-26).

This folder is only the boot animation part of the ExpressiveOS kit. **None of it applies to
the Evolution X tree** (`~/evolution`): `apply-bootanim.sh` refuses it.

## What plays

| Part | desc.txt | What happens | Length |
|---|---|---|---|
| `part0` | `c 1 6` | The petals unfurl one by one, clockwise from the blue one, a ring pulses out, and "ExpressiveOS" pops in letter by letter. Ends at rest and holds. | 43 frames + 6 held = 1.6 s |
| `part1` | `c 0 20` | One clockwise turn of the logo with a slight swell, then rest. Repeats until boot completes. | 34 frames + 20 held = 1.8 s a loop |
| `part2` | `c 1 0` | When boot completes: a double ripple, the logo swells and the wordmark brightens, then everything settles at rest. | 26 frames = 0.9 s |

`1080 1320 30`: a 1080x1320 canvas at 30 fps (4 refreshes a frame at 120 Hz) on black
(`#000000`, also the colour of the screen around the canvas), with a faint neutral lift behind
the logo. The petals and wordmark use the logo's colours.

How Evolution X plays it (`frameworks/base` `cnb`, `cmds/bootanimation/BootAnimation.cpp`):

- It boots `/product/media/bootanimation.zip` unless `persist.sys.bootanim.name` picks one of
  Evolution X's other styles (`resolveBootAnimationPath()`); a clean flash has no name set.
- Frames are drawn 1:1, centred: on cheetah's default FHD+ boot mode (1080x2340) the canvas sits
  at y 510-1830. A user who boots in QHD+ sees it at 75% size, still sharp.
- Every entry must be STORED (`"bootanimation.zip is compressed; must be only stored"`).
- A part's pause holds its last frame, so rest frames aren't stored twice. The pause is cut
  short once boot completes, so `part2` starts as soon as the current turn ends.
- `c` parts always finish. The looping part's textures stay in GPU memory until the animation
  exits: 34 frames x 5.7 MB = about 194 MB.

## On the other phones

Every ExpressiveOS phone ships this same zip: `bootanimation.mk` sets it for `lineage_cheetah`,
`lineage_husky`, `lineage_kodiak`, `lineage_grizzly`, `lineage_cubs` and `lineage_yogi`. It was drawn
for cheetah's screen (a 1440x3120 panel that boots in FHD+, 1080x2340, where the canvas spans the full
width), and `BootAnimation.cpp` never scales it: the 1080x1320 canvas is drawn at its own pixel size
in the middle of whatever mode a phone boots in, on the same black. On the other screens (their
trees' `TARGET_SCREEN_WIDTH`x`TARGET_SCREEN_HEIGHT`) that is cosmetic only:

- A wider or denser mode shows the logo and wordmark smaller, with more black around them: husky and
  kodiak (1344x2992) booting at full width have the canvas across about 80% of it, grizzly
  (1280x2856) about 84%.
- cubs (1080x2424) and yogi's outer screen (1080x2342) are 1080 px wide, like cheetah's FHD+ mode.
  yogi's inner screen is close to square: the canvas sits in its middle with black on every side.
- A mode narrower than 1080 px cuts off the canvas's sides, which are black: the mark is 456 px wide,
  the wordmark 740 and the last ripple about 950 across, so only a much narrower mode would clip any
  of them.

No phone gets a canvas of its own: that would take a render for each size, each with its own sha256
in `bootanim.conf` (`../tools/eos-verify.sh` checks this one on every phone).

## Files

- `bootanimation.zip`: the build input, 29 MB. Its sha256 is pinned in `bootanim.conf`.
- `bootanimation.mk`: sets `TARGET_BOOTANIMATION` for every ExpressiveOS phone's product
  (above).
- `apply-bootanim.sh [top]`: puts both into `vendor/extra/bootanimation` in the ExpressiveOS
  tree (default `~/expressiveos`), checks the zip against `bootanim.conf`, refuses a phone whose
  `lineage_<device>.mk` turns Evolution X's other styles on (below), and adds
  `$(call inherit-product, vendor/extra/bootanimation/bootanimation.mk)` to
  `vendor/extra/product.mk`. Running it again changes nothing; its last line is
  `BOOTANIM_APPLY=OK` or `BOOTANIM_APPLY=FAIL`.
- `tools/render.py`: draws every frame (numpy and Pillow).
- `tools/pack.py`: checks the frames and writes the zip: STORED, `desc.txt` first, fixed order and
  timestamps, so the same frames always give the same bytes.
- `tools/make-bootanim.sh FONT.ttf [OUT.zip] [--preview OUT.mp4]`: renders and packs (a few
  minutes), and prints the new sha256 and size for `bootanim.conf`.
- `tools/preview.sh`: an MP4 of what the phone shows (intro, three loops, outro) on the full screen.

## How it gets into the build

Run `apply-bootanim.sh` after `repo sync`, along with the other ExpressiveOS kits. Evolution X's
`vendor/lineage/config/common.mk` inherits `vendor/extra/product.mk`, and product makefiles are
read before `vendor/lineage/bootanimation/Android.mk`, which copies `TARGET_BOOTANIMATION` to
`/product/media/bootanimation.zip` and links `bootanimation-dark.zip` to it. `vendor/extra`
isn't a repo project, so `repo sync` leaves it alone.

Evolution X's 12 other styles (about 190 MiB) must stay out of `/product/media`. `vendor/extra` can't
turn them off, because `common.mk` sets `TARGET_INCLUDE_BOOT_ANIMATIONS ?= true` before it inherits our
file, so `../patches/device_google_pantah/0010` sets it to false in `lineage_cheetah.mk`, and
`../tools/eos-images.sh` also exports `TARGET_INCLUDE_BOOT_ANIMATIONS=false`. Each other phone's
`lineage_<device>.mk`, in its `EOS_DEVICE_TREE`, does the same: husky's from
`../devices/husky/patches/device_google_shusky/` ("husky: ship only ExpressiveOS's boot animation"),
the Pixel 11s' from a commit on their own trees, which started with `TARGET_INCLUDE_BOOT_ANIMATIONS :=
true`. The export wins over `?= true` but never over a `:=` in the device tree, so `apply-bootanim.sh`
fails before the build when the phone's `lineage_<device>.mk` sets it to anything but `false`.

`../tools/eos-verify.sh` checks both after every build. By hand:

```
sha256sum out/target/product/cheetah/product/media/bootanimation.zip   # the sha256 in bootanim.conf
ls out/target/product/cheetah/product/media/                           # no bootanimation_*.zip
```

On the phone, watch a reboot, or run `adb logcat -s BootAnimation` and look for
`Playing files = /product/media/bootanimation.zip/part1`.

## Changing it

Edit `tools/render.py`, which holds the timing, sizes and colours. Then run
`tools/make-bootanim.sh <ExpressiveLauncher>/android/lawnchair/res/font/googlesansflex_variable.ttf --preview /tmp/preview.mp4`
and update `BOOTANIM_ZIP_SHA256` and `BOOTANIM_ZIP_SIZE` in `bootanim.conf` from its last two lines.
The script refuses a logo or font that isn't the pinned one. The wordmark needs Pillow with
FreeType variable fonts and libraqm (for kerning). Other Pillow or numpy versions can change a
few pixels, and so the sha256.

Frames are 8-bit RGB PNGs. A 256-colour version would be about half the size, but it showed
visible grain in the logo's gradients.

## Credits

- Concept and motion: inspired by Loic's boot animation concept (ExpressiveLauncher feedback
  group, 2026).
- Logo: ExpressiveOS.
- Font: Google Sans Flex by Google, SIL Open Font License 1.1, from ExpressiveLauncher.

## Not checked yet

- Booting it on a phone. Everything above comes from reading Evolution X's `BootAnimation.cpp` and
  build files. The decode time of the intro and outro frames (each frame is decoded as it plays)
  hasn't been measured on Tensor G2.
