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

- It boots `/product/media/bootanimation.zip` unless `persist.sys.bootanim.name` picks another
  style (`resolveBootAnimationPath()`): Evolution X's, which ExpressiveOS doesn't ship, or our
  holiday copy (below). A clean flash has no name set.
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
in `bootanim.conf` (`../tools/eos-verify.sh` checks this one on every phone). The holiday copy
(below) ships on every phone too.

## Holiday boot animations

While a holiday theme is on, the phone boots a copy of this animation in the holiday's colours:
the same motion, with each petal in one of the holiday's four petal colours.

### How it works

- **The zip.** `bootanimation_holiday.zip` (`/product/media`) is this animation drawn as colour
  masks for AOSP's dynamic colours (`desc.txt` line 2:
  `dynamic_colors part0 #AE69FC #417BFC #FD7771 #4AD29D 0 0`). The GPU draws each pixel as
  `r*color1 + g*color2 + b*color3 + a*color4`, so each channel is one petal's weight: R the violet
  petal (top left), G blue (top right), B coral (bottom left), A green (bottom right). That is the
  holiday catalog's petal order, so `colorN` is the holiday's petal `N` mid. Black is all zeros.
- **The colours.** `persist.bootanim.color1..4`, signed decimal ARGB, as SystemUI writes them.
  During a holiday the theme engine (Evolver) sets `persist.sys.bootanim.name=holiday` and the
  four petal mids, and SystemUIGoogle writes the same four from the Secure key
  `expressiveos_holiday_bootanim` (`RRGGBB,RRGGBB,RRGGBB,RRGGBB`) instead of Monet's. Without
  colours the zip plays in the start colours above, Bloom's petal mids (Evolver `Bloom.kt`).
- **The boot.** gs201's vendor init starts bootanim at late-fs, before `/data` is mounted
  (`init.gs201.rc`, "Start bootanimation class before mount"), and persist properties only load
  later, in post-fs-data. So at boot those five properties are still empty. The init rc
  `expressiveos-bootanim-hint.rc` (`/product/etc/init`) keeps a copy of them in
  `/metadata/bootanim/` (`name`, `color1`..`color4`; `default` or `none` when a property is
  empty), and `/metadata` is mounted in init's first stage. init rewrites each file whenever its
  property changes and all five once per boot, when property triggers turn on after `on boot`.
  Only init writes there; the files are labelled `bootanim_metadata_file`
  (`device_evolution_sepolicy`), which bootanim may read.
- **BootAnimation** (`frameworks/base` `cmds/bootanimation`): while
  `persist.sys.bootanim.name` is empty it takes the name from `/metadata/bootanim/name`: up to 64
  of `[a-z0-9_]`, not `default` or `custom`, and only if `/product/media/bootanimation_<name>.zip`
  is there.
  Each colour whose property is still empty starts from its file; AOSP re-reads the properties at
  every part until they load. It never waits for any of it, so a holiday boot should be as fast
  as any other (On the phone, steps 7 and 8, measure it). A holiday zip that doesn't load plays the
  everyday one instead.

The hint is the previous boot's state, kept up to date: a holiday that starts or ends while the
phone is off shows on the boot after the theme engine has run (it runs after unlock).

`bootanimation.mk` ships the zip and the rc together, and `../tools/eos-verify.sh` fails a build
that has one without the other: without the rc no boot picks the zip, and the rc alone names a
zip that isn't there. It also fails a build whose BootAnimation doesn't read `/metadata/bootanim`
(`/system/lib64/libbootanimation_preapex.so`, where `BootAnimation.cpp` is built) or whose
`/system_ext/etc/selinux/system_ext_file_contexts` doesn't label it `bootanim_metadata_file`,
or whose `system_ext_sepolicy.cil` doesn't let bootanim read that type.
If any of these is missing, every holiday boot plays the everyday animation and nothing on the phone
says why; a later rebase of `frameworks/base` or `device/lineage/sepolicy` that dropped the change
would do just that. `apply-bootanim.sh` refuses a tree whose `BootAnimation.cpp`,
`common/private/file_contexts` or `common/private/bootanim.te` lacks it, before the build. It only notes, without failing, when no
init rc in the phone's vendor tree starts bootanim at late-fs any more: then the hint may be
unneeded, but does no harm.

### What it looks like

`tools/render.py --dynamic` draws the same scene as the everyday zip. What the shader can't draw
is left out or changed:

- Each petal is one colour, shaded by the logo's own lighting (from 62% to 100% of the colour).
  There is no orange-to-pink sweep inside a petal and no pink-white highlight. The coral petal's
  tail, which sweeps through yellow into the green petal, blends from one colour to the other.
- The glow around the mark is in the petals' colours. There is no grey halo behind it: the shader
  draws grey only where all four channels are 0.05 or more, and a halo's fading edge would turn
  coloured.
- The rings take the petals' colours by quadrant instead of white.
- The wordmark runs through the four colours in the everyday gradient's order (violet, blue, green,
  coral) at 85%, and the outro's flash brightens it to 100% instead of whitening it.
- Where all four petals' glows meet, in the dark pinwheel hub, the weakest channel is lowered to
  12/255 so the shader doesn't draw the hub grey: up to about 2,000 pixels a frame in the outro,
  each one colour lower by 15/255 at most. `render.py` reports how many; `tools/pack.py` refuses
  any pixel the shader would draw grey.

It is 15.8 MB (`bootanim.conf`), about half the everyday zip, since a mask frame compresses
better. GPU memory is the same: frames decode to RGBA either way.

### Regenerating it

After a change to `tools/render.py`:

```
tools/make-bootanim.sh --holiday <ExpressiveLauncher>/android/lawnchair/res/font/googlesansflex_variable.ttf \
    --preview /tmp/halloween.mp4 --palette FF8A1F,B26BFF,FFB347,7CE35A
```

Then update `BOOTANIM_HOLIDAY_ZIP_SHA256` and `BOOTANIM_HOLIDAY_ZIP_SIZE` in `bootanim.conf` from
its last two lines. `--palette` takes a holiday's four petal mids in the catalog's order (Evolver
`HolidayCatalog.kt`; on the phone during that holiday, `adb shell settings get secure
expressiveos_holiday_bootanim`): Halloween `FF8A1F,B26BFF,FFB347,7CE35A`, Thanksgiving
`F2A541,E07B39,D6455B,E9C46A`. Without it the preview is in the start colours. For a preview of the
zip itself, unzip it into a folder and run `tools/preview.sh <folder> out.mp4 --palette ...`;
`tools/tint.py` writes the coloured frames alone.

### On the phone

The KernelSU build is needed for `su`: these properties and `/metadata` aren't readable from a
plain `adb shell`. A command of several parts is quoted twice, `adb shell "su -c '...'"`, so that
`su` runs all of it. Read BootAnimation's log with `adb logcat -d -s BootAnimation` soon after a
step or a boot, before the buffers wrap.

1. Installed: `adb shell ls -l /product/media/ /product/etc/init/expressiveos-bootanim-hint.rc`
   shows `bootanimation_holiday.zip` and the rc.
2. The hint: `adb shell "su -c 'ls -lZ /metadata/bootanim; head /metadata/bootanim/*'"`. Expect
   five files, `-rw-r--r-- root root`, `u:object_r:bootanim_metadata_file:s0`; `name` is
   `default`, the colours SystemUI's (or `none`).
3. Halloween, set by hand as the theme engine sets it:

   ```
   adb shell settings put secure expressiveos_holiday_bootanim FF8A1F,B26BFF,FFB347,7CE35A
   adb shell "su -c 'setprop persist.sys.bootanim.name holiday; setprop persist.bootanim.color1 -30177; setprop persist.bootanim.color2 -5084161; setprop persist.bootanim.color3 -19641; setprop persist.bootanim.color4 -8592550'"
   ```

   (Thanksgiving: `F2A541,E07B39,D6455B,E9C46A`, `-875199 -2065607 -2734757 -1457046`). Step 2
   shows `holiday` and those values at once. SystemUI writes the same colours from the Secure key
   at every start and theme change, so they stay.
4. The zip over the running UI, without a reboot:
   `adb shell "su -c 'setprop service.bootanim.exit 0; start bootanim'"`, then
   `adb shell su -c 'setprop service.bootanim.exit 1'`. It plays in Halloween colours: the zip and
   its masks are right. This says nothing about a real boot (the properties are loaded by then).
5. The hints over the running UI: empty the five properties, which writes `default` and `none` to
   the files, put Halloween in the files by hand, and start bootanim:

   ```
   adb shell "su -c 'setprop persist.sys.bootanim.name \"\"; for i in 1 2 3 4; do setprop persist.bootanim.color\$i \"\"; done; sleep 1'"
   adb shell "su -c 'cd /metadata/bootanim && echo holiday > name && echo -30177 > color1 && echo -5084161 > color2 && echo -19641 > color3 && echo -8592550 > color4'"
   adb shell "su -c 'setprop service.bootanim.exit 0; start bootanim'"
   ```

   It plays in Halloween colours, from the files alone; the log has
   `persist.sys.bootanim.name is empty, using the hint 'holiday' from /metadata/bootanim` and
   `persist.bootanim.color* are empty, using the hints color1=-30177 color2=-5084161 color3=-19641 color4=-8592550 from /metadata/bootanim`.
   Stop it as in step 4, and step 3 again puts the properties, and so the files, back.
6. The fallback over the running UI, with step 3's properties: a holiday zip that can't be opened
   (its first 4 KB, bound over it) plays the everyday one:

   ```
   adb shell "su -c 'head -c 4096 /product/media/bootanimation_holiday.zip > /data/local/tmp/bad.zip; chcon u:object_r:system_file:s0 /data/local/tmp/bad.zip; mount --bind /data/local/tmp/bad.zip /product/media/bootanimation_holiday.zip; setprop service.bootanim.exit 0; start bootanim'"
   adb shell "su -c 'setprop service.bootanim.exit 1; umount /product/media/bootanimation_holiday.zip; rm /data/local/tmp/bad.zip'"
   ```

   Before the second line the everyday animation plays, and the log has
   `/product/media/bootanimation_holiday.zip is unusable, falling back to /product/media/bootanimation.zip`.
7. A real holiday boot, with step 3's properties: `adb reboot`. The holiday colours show from the
   first frame. `adb logcat -d -s BootAnimation | grep -E 'using the hint|Bootanimation requested|is unusable|Sysprops loaded|Loaded dynamic color|Playing files|BootAnimationShownTiming'`
   shows, in this order:
   - `persist.sys.bootanim.name is empty, using the hint 'holiday' from /metadata/bootanim`, then
     `Bootanimation requested -> /product/media/bootanimation_holiday.zip (exists=1)`;
   - `persist.bootanim.color* are empty, using the hints color1=-30177 color2=-5084161 color3=-19641 color4=-8592550 from /metadata/bootanim`;
   - `Sysprops loaded? 0`, unless the properties loaded before the first frame. That is right:
     the hints don't count as loaded properties, so BootAnimation keeps reading the properties at
     every part;
   - `BootAnimationShownTiming start time`, then `Playing files = /product/media/bootanimation_holiday.zip/part0`
     and `part1`;
   - once the properties have loaded, usually at the start of a `part1` turn, `Loaded dynamic
     color: persist.bootanim.color1 -> -30177` (and 2-4) and `Sysprops loaded? 1`.

   Without the two `using the hint` lines the boot didn't use the hints: check step 2 and step 11.
   Note `BootAnimationShownTiming` (the first frame, in milliseconds since boot) and reboot twice
   more.
8. Back: `adb shell settings delete secure expressiveos_holiday_bootanim` and
   `adb shell "su -c 'setprop persist.sys.bootanim.name \"\"'"`. `name` reads `default` at once.
   `adb reboot` three times, with step 7's grep after each: the everyday animation,
   `Bootanimation requested -> /product/media/bootanimation.zip` and no `using the hint` line.
   Step 7's three `BootAnimationShownTiming` times fall within the spread of these three: nothing
   waits for the hints.
9. A stale hint:
   `adb shell "su -c 'setprop persist.sys.bootanim.name \"\"; sleep 1; echo holiday > /metadata/bootanim/name'"`,
   then `adb reboot`. This one boot plays the holiday animation (`using the hint 'holiday'`), in
   the colours the colour files hold, and after it `adb shell su -c 'cat /metadata/bootanim/name'`
   reads `default`: the next boot is an everyday one. That is the most a wrong hint does, one
   boot in the old look, never a wait.
10. Step 3 again, then power off and plug in a charger. The charging screen is as it always
    is (bootanim doesn't run in charger mode); hold power to boot, and it's the holiday animation
    of step 7. On the next clean flash (`fastboot -w`, which formats `/metadata` too), the first
    boot has no `using the hint` line and plays the everyday animation, and after it step 2 shows
    the five files with `name` `default`.
11. After all of the above: `adb shell su -c dmesg | grep avc | grep bootanim` prints nothing.

## Files

- `bootanimation.zip`: the build input, 29 MB. Its sha256 is pinned in `bootanim.conf`.
- `bootanimation_holiday.zip`: the holiday copy, 15.8 MB, pinned there too.
- `expressiveos-bootanim-hint.rc`: the init rc that copies the boot animation's name and colours
  to `/metadata/bootanim` (Holiday boot animations, above).
- `bootanimation.mk`: sets `TARGET_BOOTANIMATION` for every ExpressiveOS phone's product
  (above), and installs the holiday zip and the rc.
- `apply-bootanim.sh [top]`: puts all four into `vendor/extra/bootanimation` in the ExpressiveOS
  tree (default `~/expressiveos`), checks the zips against `bootanim.conf`, refuses a phone whose
  `lineage_<device>.mk` turns Evolution X's other styles on (below) and a tree whose BootAnimation
  or sepolicy can't read the holiday hint (above), and adds
  `$(call inherit-product, vendor/extra/bootanimation/bootanimation.mk)` to
  `vendor/extra/product.mk`. Running it again changes nothing; its last line is
  `BOOTANIM_APPLY=OK` or `BOOTANIM_APPLY=FAIL`.
- `tools/render.py`: draws every frame (numpy and Pillow); `--dynamic`, the holiday copy's masks.
- `tools/pack.py`: checks the frames and writes the zip: STORED, `desc.txt` first, fixed order and
  timestamps, so the same frames always give the same bytes.
- `tools/make-bootanim.sh [--holiday] FONT.ttf [OUT.zip] [--preview OUT.mp4 [--palette ...]]`:
  renders and packs (a few minutes), and prints the new sha256 and size for `bootanim.conf`.
- `tools/preview.sh`: an MP4 of what the phone shows (intro, three loops, outro) on the full screen;
  the holiday copy's in a holiday's colours (`--palette`).
- `tools/tint.py`: colours the holiday copy's masks as the phone does, for `preview.sh`.

## How it gets into the build

Run `apply-bootanim.sh` after `repo sync`, along with the other ExpressiveOS kits. Evolution X's
`vendor/lineage/config/common.mk` inherits `vendor/extra/product.mk`, and product makefiles are
read before `vendor/lineage/bootanimation/Android.mk`, which copies `TARGET_BOOTANIMATION` to
`/product/media/bootanimation.zip` and links `bootanimation-dark.zip` to it. The holiday zip and
its rc go in with `PRODUCT_COPY_FILES`, as Evolution X's own styles do; the build checks the rc
with `host_init_verifier`. `vendor/extra` isn't a repo project, so `repo sync` leaves it alone.

Evolution X's 12 other styles (about 190 MiB) must stay out of `/product/media`. `vendor/extra` can't
turn them off, because `common.mk` sets `TARGET_INCLUDE_BOOT_ANIMATIONS ?= true` before it inherits our
file, so `../patches/device_google_pantah/0010` sets it to false in `lineage_cheetah.mk`, and
`../tools/eos-images.sh` also exports `TARGET_INCLUDE_BOOT_ANIMATIONS=false`. Each other phone's
`lineage_<device>.mk`, in its `EOS_DEVICE_TREE`, does the same: husky's from
`../devices/husky/patches/device_google_shusky/` ("husky: ship only ExpressiveOS's boot animation"),
the Pixel 11s' from a commit on their own trees, which started with `TARGET_INCLUDE_BOOT_ANIMATIONS :=
true`. The export wins over `?= true` but never over a `:=` in the device tree, so `apply-bootanim.sh`
fails before the build when the phone's `lineage_<device>.mk` sets it to anything but `false`.

`../tools/eos-verify.sh` checks all of this after every build. By hand:

```
sha256sum out/target/product/cheetah/product/media/bootanimation.zip   # the sha256 in bootanim.conf
sha256sum out/target/product/cheetah/product/media/bootanimation_holiday.zip   # and the holiday one
ls out/target/product/cheetah/product/media/                           # no other bootanimation_*.zip
ls out/target/product/cheetah/product/etc/init/expressiveos-bootanim-hint.rc
grep -caF /metadata/bootanim out/target/product/cheetah/system/lib64/libbootanimation_preapex.so   # not 0
grep bootanim_metadata_file out/target/product/cheetah/system_ext/etc/selinux/system_ext_file_contexts
```

On the phone, watch a reboot, or run `adb logcat -s BootAnimation` and look for
`Playing files = /product/media/bootanimation.zip/part1`.

## Changing it

Edit `tools/render.py`, which holds the timing, sizes and colours. Then run
`tools/make-bootanim.sh <ExpressiveLauncher>/android/lawnchair/res/font/googlesansflex_variable.ttf --preview /tmp/preview.mp4`
and update `BOOTANIM_ZIP_SHA256` and `BOOTANIM_ZIP_SIZE` in `bootanim.conf` from its last two lines.
The script refuses a logo or font that isn't the pinned one. The wordmark needs Pillow with
FreeType variable fonts and libraqm (for kerning). Other Pillow or numpy versions can change a
few pixels, and so the sha256. Render the holiday copy again too (Holiday boot animations, above),
so the two stay the same animation.

The everyday frames are 8-bit RGB PNGs (the holiday copy's are RGBA masks). A 256-colour version would be about half the size, but it showed
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
- The holiday copy on a phone (On the phone, above). The previews come from `tools/tint.py`, which
  does the shader's sums in Python; the GPU's precision may round a level differently. A real
  holiday boot also needs the `frameworks_base`, `device_evolution_sepolicy`, SystemUIGoogle and
  Evolver changes it's built for.
