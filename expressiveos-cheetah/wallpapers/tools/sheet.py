"""Contact sheet: each wallpaper on the mock lock screen (top row) and home screen (bottom row), with its
Monet seed, the petal it lands on and a few TONAL_SPOT swatches.  usage: sheet.py MOCKDIR OUTDIR OUT.png"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw

import mock
import monet

mockdir, outdir, out = sys.argv[1:4]
NAMES = [("bloom", "Bloom", "dark · default"), ("dusk", "Dusk", "dark"), ("dawn", "Dawn", "light"), ("mint", "Mint", "light")]
SC = 0.25
PW, PH = int(mock.W * SC) + 2 * max(4, int(mock.dp(4) * SC)), int(mock.H * SC) + 2 * max(4, int(mock.dp(4) * SC))
GAP, TOP, LAB = 44, 196, 34
pal_h = 230
Wd = 4 * PW + 5 * GAP
Hd = TOP + 2 * PH + LAB * 2 + GAP + pal_h
bg = (24, 24, 27)
sheet = Image.new("RGBA", (Wd, Hd), bg + (255,))
d = ImageDraw.Draw(sheet)
f_t = mock.font(mock.UI, 40, wght=600, opsz=40)
f_s = mock.font(mock.UI, 22, wght=450)
f_xs = mock.font(mock.UI, 19, wght=450)
f_h = mock.font(mock.UI, 26, wght=550)
d.text((GAP, 34), "ExpressiveOS wallpapers · 1440 × 3120 · mock lock and home screens (Pixel 7 Pro)", font=f_h,
       fill=(235, 235, 240))
d.text((GAP, 72), "Theme colours: Monet TONAL_SPOT from each wallpaper's seed (approximation of Android's "
       "quantizer and scorer); glyphs are generic placeholders.", font=f_xs, fill=(170, 170, 178))
def nearest3(h):
    """Nearest of each petal's light, mid (OKLab halfway) and deep colour, by CAM16 hue."""
    import wp
    best = None
    for name, (lt, dpc) in wp.PETALS.items():
        mid = wp.to_srgb(wp.ok_mix(wp.lin(lt), wp.lin(dpc), 0.5))
        mh = "#%02X%02X%02X" % tuple(int(round(v * 255)) for v in mid)
        for which, hx in (("light", lt), ("mid", mh), ("deep", dpc)):
            ph = float(monet.cam16(np.array([int(hx[j:j + 2], 16) for j in (1, 3, 5)]))[0])
            dd = min(abs(h - ph), 360 - abs(h - ph))
            if best is None or dd < best[0]:
                best = (dd, name, which, hx)
    return best


for i, (key, title, kind) in enumerate(NAMES):
    x = GAP + i * (PW + GAP)
    wall = Image.open(os.path.join(outdir, f"expressiveos_{key}.png")).convert("RGB")
    pop, _ = monet.wallpaper_colors(np.asarray(wall))
    s = monet.seed_colors(pop)[0]
    near = nearest3(s["hue"])
    d.text((x, TOP - 40), title, font=f_t, fill=(245, 245, 248), anchor="ls")
    d.text((x + d.textlength(title, font=f_t) + 14, TOP - 42), kind, font=f_s, fill=(170, 170, 178), anchor="ls")
    for row, m in enumerate(("lock", "home")):
        y = TOP + row * (PH + LAB + GAP // 2)
        fr = mock.frame(Image.open(os.path.join(mockdir, f"expressiveos_{key}_{m}.png")), SC)
        sheet.alpha_composite(fr, (x, y))
        d.text((x + PW / 2, y + PH + 22), "lock screen" if m == "lock" else "home screen", font=f_xs,
               fill=(150, 150, 158), anchor="mm")
    y = TOP + 2 * (PH + LAB + GAP // 2) + 6
    sw = 46
    d.rounded_rectangle((x, y, x + sw, y + sw), radius=10, fill=tuple(int(s["hex"][j:j + 2], 16) for j in (1, 3, 5)))
    d.text((x + sw + 14, y + 4), f"seed {s['hex']}  H{s['hue']:.0f}", font=f_s, fill=(235, 235, 240))
    d.text((x + sw + 14, y + 30), f"{near[1]} petal, {near[2]} {near[3]}", font=f_xs,
           fill=(170, 170, 178))
    tone = monet.tonal_spot(s["hex"])
    chips = [("a1", 40), ("a1", 80), ("a1", 90), ("a2", 40), ("a3", 40), ("n1", 90), ("n1", 10)]
    cw = (PW - 6 * 8) / 7
    for j, (p, t) in enumerate(chips):
        cx0 = x + j * (cw + 8)
        d.rounded_rectangle((cx0, y + 70, cx0 + cw, y + 70 + 64), radius=12, fill=tuple(int(v) for v in tone(p, t)))
        d.text((cx0 + cw / 2, y + 70 + 84), f"{p} {t}", font=f_xs, fill=(150, 150, 158), anchor="mm")
sheet.convert("RGB").save(out, optimize=True)
print(out, sheet.size)
