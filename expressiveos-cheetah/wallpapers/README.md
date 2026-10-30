# ExpressiveOS wallpapers (cheetah)

Four wallpapers drawn by us from the ExpressiveOS mark's four petals, and Bloom as the wallpaper a
clean install starts on, so the system colours match the logo from the first screen (Daryl,
2026-10-27). Each is 1440x3120 (cheetah's full resolution), 8-bit sRGB PNG, with no text and a clear
top half for the clock. Every thread of each ribbon is an echo of one petal's outline.

This folder is only the wallpaper part of the ExpressiveOS kit. **None of it applies to the Evolution
X tree** (`~/evolution`): `apply-wallpapers.sh` refuses it.

## The four

| Wallpaper | Look | Petal | Monet seed (approximate) |
|---|---|---|---|
| Bloom (the default) | dark: a blue silk sheet rising from the lower right, violet at its edge, a purple ribbon out of focus behind it | blue | `#3167F4`, hue 274: the blue petal's deep `#1842D1` (hue 277) |
| Dusk | dark: a violet ribbon twisting across the lower third, rose where it turns, over a rose horizon glow | purple | `#52267A`, hue 311: the purple petal's colours (`#AB72DD`, hue 312) |
| Dawn | light: warm paper, a coral silk sheet rising from the lower left, crimson at its edge | coral | `#E69D87`, hue 35, a soft peach: the coral petal's colours (`#EC896F`, hue 33) |
| Mint | light: cool paper, a green ribbon twisting across the lower third, mint light with a touch of sky blue | green | `#4DBD92`, hue 168: the green petal's deep `#18A07C` (hue 171) |

The ribbons sit in the lower part of the screen, below the clock and the lock screen's notifications
(`tools/final.py`'s `LOWER`, Daryl's preview of 2026-10-27).

The seeds come from `tools/monet.py`, a port of Android's quantizer (Celebi: Wu then WSMeans) and
seed scorer, so the real phone can differ by a few degrees of hue. Bloom's first-boot theme is
Material TONAL_SPOT from that blue.

## How it gets into the build

1.0 ships Bloom as the first-boot wallpaper and keeps Google's Pixel wallpapers in the picker (Daryl,
2026-10-27): the picker reads only one wallpaper pack, so `ExpressiveWallpapers/`, which has all four but
none of Pixel's, isn't built yet. In 1.1 one pack holds both. Until then Dusk, Dawn and Mint aren't on
the phone or in the release: to try one, push it from the kit
(`adb push ExpressiveWallpapers/res/drawable-nodpi/expressiveos_dawn.png /sdcard/Pictures/`) and set it
from Photos or Files.

Run `apply-wallpapers.sh` after `repo sync`, along with the other ExpressiveOS kits
(`../tools/eos-images.sh` does). It checks every PNG against `wallpapers.conf`, stages
`wallpapers.mk`, `overlay/` and Bloom into `vendor/extra/wallpapers` (no `Android.bp`, so the picker
APK isn't even a module), removes anything else there, and adds
`$(call inherit-product, vendor/extra/wallpapers/wallpapers.mk)` to `vendor/extra/product.mk`.
Running it again changes nothing; its last line is `WALLPAPERS_APPLY=OK` or `WALLPAPERS_APPLY=FAIL`.
`vendor/extra` isn't a repo project, so `repo sync` leaves it alone.

`wallpapers.mk` (for every ExpressiveOS phone: `lineage_cheetah`, `lineage_husky`, `lineage_kodiak`,
`lineage_grizzly`, `lineage_cubs` and `lineage_yogi`) does two things, and in 1.1 a third:

1. **The first-boot wallpaper.** It copies Bloom to `/product/media/wallpaper/expressiveos_bloom.png`
   and sets `ro.config.wallpaper` to it. `WallpaperManager.openRawDefaultWallpaper()` (frameworks/base
   `cnb`) reads that property first, then
   `/product/wallpaper/image/default_wallpaper_<ro.boot.hardware.color>`, and only then
   framework-res's `default_wallpaper` drawable, which is where Evolution X puts its own
   (`vendor/lineage/overlay/common/frameworks/base/core/res/res/drawable-*/default_wallpaper.png`, 8
   density folders, 1920x2856 for phones). So one file replaces it at every density, and nothing in
   `vendor/lineage` changes. SystemUI's wallpaper (`WallpaperManager`'s default bitmap) and the
   system's crop (`WallpaperCropper`) both go through that same lookup.
2. **The theme follows the wallpaper.** Evolution X sets `theming_defaults` to `*|TONAL_SPOT|#0049c7`, a
   preset colour: on first boot, when SystemUI's `hardware_color_styles` flag is on,
   `ThemeOverlayController` stores colour source "preset", and after that a new wallpaper no longer
   recolours the system until the user picks wallpaper colours by hand. `overlay/` puts back AOSP's
   own `*|TONAL_SPOT|home_wallpaper`. It wins over Evolution X's because
   `vendor/lineage/config/common.mk` inherits `vendor/extra/product.mk` on its line 2, so our overlay
   folder comes first in `PRODUCT_PACKAGE_OVERLAYS`, and Soong gives earlier folders the higher
   priority. Both end up in the same auto-generated RRO,
   `/product/overlay/framework-res__evolution_cheetah__auto_generated_rro_product.apk`.
3. **The picker (1.1, not built in 1.0).** `ExpressiveWallpapers` is a resource-only partner customization APK: Google's
   wallpaper picker finds it by `com.android.launcher3.action.PARTNER_CUSTOMIZATION` and shows an
   "ExpressiveOS" category with all four, plus Google Photos' "Your memories" live wallpaper, which it
   copies from Google's `PixelWallpapers2026`. The picker reads only the first system app that answers
   that action, so this APK `overrides` PixelWallpapers2026: the 16 Pixel 2026 wallpapers aren't in the
   build. `default_wallpapper_hidden` (the picker's spelling) keeps Bloom from showing twice. 1.1 has to
   add Pixel's own wallpapers to it (or the other way round) before it goes into `PRODUCT_PACKAGES`.

## On the other phones

Every ExpressiveOS phone starts on Bloom, with the theme following it. The four were drawn for
cheetah's 1440x3120 screen, and no phone gets a size of its own: the system scales the picture to
fill each screen and crops what's left over (`WallpaperCropper`). On the other screens (their trees'
`TARGET_SCREEN_WIDTH`x`TARGET_SCREEN_HEIGHT`) that is cosmetic only:

- No phone's screen is taller than 3120 px, so the picture is only ever scaled down and stays sharp.
- husky and kodiak (1344x2992), grizzly (1280x2856) and cubs (1080x2424) are a little taller for their
  width than cheetah: about 3% of the picture's width is cropped, split between the sides. yogi's
  outer screen (1080x2342) has cheetah's shape.
- yogi's inner screen is close to square, so any crop of this tall picture shows a much shorter band
  of it there: less of the ribbon in the lower part, or of the clear top, depending on the crop the
  system picks for that screen.
- The first-boot colours come from the wallpaper (`theming_defaults`), so they're Bloom's blue on
  every phone, within the few degrees of hue `tools/monet.py` already allows for.

## Files

- `wallpapers.conf`: the sha256 of every PNG, the default, and the pinned sources.
- `wallpapers.mk`: the first two parts above, for every ExpressiveOS phone.
- `overlay/frameworks/base/core/res/res/values/config.xml`: `theming_defaults`.
- `ExpressiveWallpapers/`: `Android.bp`, the manifest (`org.expressiveos.wallpapers`),
  `res/xml/wallpapers.xml` (the picker's format: attributes without a namespace), strings, and the
  eight PNGs in `res/drawable-nodpi` (four wallpapers, four 300x300 thumbnails). `wallpapers.mk` copies Bloom from
  here, so the kit holds it once.
- `apply-wallpapers.sh [top]`: stages what 1.0 ships (default tree `~/expressiveos`).
- `tools/make-wallpapers.sh [OUTDIR] [--preview SHEET.png]`: renders the four and the thumbnails again
  (about 20 s) and prints the sha256 lines for `wallpapers.conf`. The same sources give the same bytes.
  `--preview` puts each on a mock lock screen and home screen.
- `tools/final.py`, `art2.py`, `layers.py`, `silk.py`, `wp.py`: the drawing (numpy, scipy, Pillow,
  cairocffi), in linear light and written once to 8 bits with fine grain and dither, so the long
  gradients don't band. `mark-108.txt` is the mark as vector paths
  (from `../branding/tools/make-brand.py`).
- `tools/thumbs.py`, `mock.py`, `sheet.py`, `monet.py`: thumbnails, previews and the Monet estimate.

`../tools/eos-verify.sh` checks after every build: `/product/media/wallpaper/expressiveos_bloom.png` is
`wallpapers.conf`'s, `ro.config.wallpaper` points at it, no `ExpressiveWallpapers` shipped, and the
auto-RRO carries `*|TONAL_SPOT|home_wallpaper`. By hand:

```
sha256sum out/target/product/cheetah/product/media/wallpaper/expressiveos_bloom.png
grep ro.config.wallpaper out/target/product/cheetah/product/etc/build.prop
```

On the phone, after a clean install: the lock and home screens show Bloom with blue system colours,
and setting Dawn (pushed as above) turns them peach. `adb logcat -s ThemeOverlayController` shows `Default
seed color read from home wallpaper` on first boot when the hardware-colour defaults are on. A phone
flashed without a wipe that has a wallpaper of its own keeps it and its colours. One still on the old
default wallpaper shows Bloom afterwards (the default is looked up again on every load), but keeps any
colour source its first boot stored: an earlier candidate that booted with the hardware-colour defaults
on stored a `#0049c7` preset, which stays, and setting a wallpaper doesn't recolour it until the colours
are set to follow the wallpaper in Wallpaper & style. Without a stored preset, Bloom's colours follow.
Only a clean install (`fastboot -w`) shows the first-boot colours as intended.

## Changing them

Edit `tools/final.py` (geometry, colours, glow) or the shared drawing code, run
`EOS_FONTS=~/expressiveos/vendor/extras/prebuilt/product/fonts tools/make-wallpapers.sh --preview /tmp/sheet.png`
(the mock screens need the tree's Google Sans Flex fonts; it checks for them before replacing any PNG),
look at the sheet, and update the `WALLPAPER_*`
lines in `wallpapers.conf` from its output. A new default: change `WALLPAPER_DEFAULT`,
`WALLPAPER_DEFAULT_PATH` and both lines in `wallpapers.mk`; the scripts read the rest from
`wallpapers.conf`.
