"""Mock lock and home screens (Pixel 7 Pro, 1440x3120, 3.5 px/dp) over a wallpaper, coloured with a
rough Material TONAL_SPOT scheme from the wallpaper's Monet seed (monet.py).

usage: mock.py WALLPAPER.png OUTDIR      writes OUTDIR/<name>_lock.png and <name>_home.png (1440x3120)
Generic glyphs only: no app or brand logos.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import monet

DP = 3.5
W, H = 1440, 3120
# Google Sans Flex and its clock cut, as Evolution X ships them (vendor/extras/prebuilt/product/fonts)
FONTS = os.environ.get("EOS_FONTS", "vendor/extras/prebuilt/product/fonts")
CLOCK = os.path.join(FONTS, "GoogleSansFlexClock-Regular.ttf")
UI = os.path.join(FONTS, "GoogleSansFlex-Regular.ttf")


def font(path, px, **axes):
    f = ImageFont.truetype(path, int(round(px)))
    try:
        names = [a["name"] if isinstance(a["name"], str) else a["name"].decode() for a in f.get_variation_axes()]
        tags = {"Width": "wdth", "Weight": "wght", "Roundness": "ROND", "Slant": "slnt", "Optical size": "opsz",
                "Grade": "GRAD"}
        cur = {"wdth": 100, "wght": 400, "ROND": 0, "slnt": 0, "opsz": 18, "GRAD": 0}
        cur.update(axes)
        f.set_variation_by_axes([cur[tags.get(n, n)] for n in names])
    except (OSError, KeyError):
        pass
    return f


def dp(v):
    return v * DP


class Scheme:
    def __init__(self, seed_hex):
        self.t = monet.tonal_spot(seed_hex)

    def __call__(self, pal, tone, a=255):
        r, g, b = self.t(pal, tone)
        return (int(r), int(g), int(b), a)


def text(d, xy, s, f, fill, anchor="la"):
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


# ---------------------------------------------------------------- glyphs (centre cx, cy; size s px)
def g_wifi(d, cx, cy, s, col):
    for i, r in enumerate((0.95, 0.66, 0.37)):
        rr = r * s
        d.pieslice((cx - rr, cy - rr, cx + rr, cy + rr), 225, 315, fill=col if i == 0 else None)
    rr = 0.95 * s
    d.pieslice((cx - rr, cy - rr, cx + rr, cy + rr), 225, 315, fill=col)


def g_signal(d, cx, cy, s, col):
    d.polygon([(cx + s * 0.5, cy - s * 0.5), (cx + s * 0.5, cy + s * 0.5), (cx - s * 0.5, cy + s * 0.5)], fill=col)


def g_battery(d, cx, cy, s, col, frac=0.82):
    w, h = s * 0.55, s * 1.0
    d.rounded_rectangle((cx - w / 2, cy - h / 2 + s * 0.08, cx + w / 2, cy + h / 2), radius=s * 0.09, outline=col,
                        width=max(2, int(s * 0.08)))
    d.rectangle((cx - w * 0.18, cy - h / 2, cx + w * 0.18, cy - h / 2 + s * 0.08), fill=col)
    top = cy + h / 2 - (h - s * 0.08) * frac
    d.rectangle((cx - w / 2 + s * 0.1, top + s * 0.06, cx + w / 2 - s * 0.1, cy + h / 2 - s * 0.1), fill=col)


def g_flash(d, cx, cy, s, col):
    d.polygon([(cx - s * 0.28, cy - s * 0.5), (cx + s * 0.28, cy - s * 0.5), (cx + s * 0.16, cy - s * 0.1),
               (cx - s * 0.16, cy - s * 0.1)], fill=col)
    d.rounded_rectangle((cx - s * 0.16, cy - s * 0.12, cx + s * 0.16, cy + s * 0.5), radius=s * 0.06, fill=col)


def g_camera(d, cx, cy, s, col, bg):
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.32, cx + s * 0.5, cy + s * 0.4), radius=s * 0.12, fill=col)
    d.rounded_rectangle((cx - s * 0.2, cy - s * 0.46, cx + s * 0.2, cy - s * 0.25), radius=s * 0.05, fill=col)
    r = s * 0.2
    d.ellipse((cx - r, cy + 0.04 * s - r, cx + r, cy + 0.04 * s + r), fill=bg)


def g_finger(d, cx, cy, s, col):
    w = max(3, int(s * 0.055))
    for i, r in enumerate((0.5, 0.39, 0.28, 0.17)):
        rx, ry = r * s * 0.78, r * s
        start, end = (150 + i * 8, 390 - i * 14)
        d.arc((cx - rx, cy - ry, cx + rx, cy + ry), start, end, fill=col, width=w)
    d.line((cx, cy - s * 0.04, cx, cy + s * 0.2), fill=col, width=w)


def g_bubble(d, cx, cy, s, col):
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.42, cx + s * 0.5, cy + s * 0.3), radius=s * 0.22, fill=col)
    d.polygon([(cx - s * 0.3, cy + s * 0.2), (cx - s * 0.05, cy + s * 0.25), (cx - s * 0.36, cy + s * 0.5)], fill=col)


def g_phone(d, cx, cy, s, col):
    w = max(3, int(s * 0.2))
    d.arc((cx - s * 0.5, cy - s * 0.5, cx + s * 0.5, cy + s * 0.5), 100, 170, fill=col, width=w)
    d.ellipse((cx - s * 0.52, cy - s * 0.2, cx - s * 0.22, cy + s * 0.1), fill=col)
    d.ellipse((cx - s * 0.1, cy + s * 0.22, cx + s * 0.2, cy + s * 0.52), fill=col)


def g_globe(d, cx, cy, s, col):
    w = max(3, int(s * 0.09))
    d.ellipse((cx - s * 0.5, cy - s * 0.5, cx + s * 0.5, cy + s * 0.5), outline=col, width=w)
    d.ellipse((cx - s * 0.22, cy - s * 0.5, cx + s * 0.22, cy + s * 0.5), outline=col, width=w)
    d.line((cx - s * 0.5, cy, cx + s * 0.5, cy), fill=col, width=w)


def g_mail(d, cx, cy, s, col, bg):
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.36, cx + s * 0.5, cy + s * 0.36), radius=s * 0.08, fill=col)
    w = max(3, int(s * 0.09))
    d.line((cx - s * 0.42, cy - s * 0.26, cx, cy + s * 0.04, cx + s * 0.42, cy - s * 0.26), fill=bg, width=w, joint="curve")


def g_photo(d, cx, cy, s, col, bg):
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.42, cx + s * 0.5, cy + s * 0.42), radius=s * 0.1, fill=col)
    d.polygon([(cx - s * 0.38, cy + s * 0.3), (cx - s * 0.1, cy - s * 0.06), (cx + s * 0.08, cy + s * 0.14),
               (cx + s * 0.2, cy + s * 0.02), (cx + s * 0.38, cy + s * 0.3)], fill=bg)
    r = s * 0.09
    d.ellipse((cx + s * 0.18 - r, cy - s * 0.2 - r, cx + s * 0.18 + r, cy - s * 0.2 + r), fill=bg)


def g_play(d, cx, cy, s, col):
    d.polygon([(cx - s * 0.32, cy - s * 0.42), (cx + s * 0.44, cy), (cx - s * 0.32, cy + s * 0.42)], fill=col)


def g_note(d, cx, cy, s, col):
    w = max(3, int(s * 0.1))
    d.line((cx + s * 0.14, cy + s * 0.32, cx + s * 0.14, cy - s * 0.46), fill=col, width=w)
    d.line((cx + s * 0.14, cy - s * 0.46, cx + s * 0.44, cy - s * 0.3), fill=col, width=w)
    d.ellipse((cx - s * 0.36, cy + s * 0.12, cx + s * 0.18, cy + s * 0.5), fill=col)


def g_folder(d, cx, cy, s, col):
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.38, cx - s * 0.02, cy - s * 0.14), radius=s * 0.07, fill=col)
    d.rounded_rectangle((cx - s * 0.5, cy - s * 0.26, cx + s * 0.5, cy + s * 0.4), radius=s * 0.09, fill=col)


def g_search(d, cx, cy, s, col):
    w = max(3, int(s * 0.12))
    r = s * 0.3
    d.ellipse((cx - r - s * 0.1, cy - r - s * 0.1, cx + r - s * 0.1, cy + r - s * 0.1), outline=col, width=w)
    d.line((cx + s * 0.13, cy + s * 0.13, cx + s * 0.42, cy + s * 0.42), fill=col, width=w)


def g_mic(d, cx, cy, s, col):
    w = max(3, int(s * 0.1))
    d.rounded_rectangle((cx - s * 0.16, cy - s * 0.48, cx + s * 0.16, cy + s * 0.12), radius=s * 0.16, fill=col)
    d.arc((cx - s * 0.32, cy - s * 0.3, cx + s * 0.32, cy + s * 0.3), 0, 180, fill=col, width=w)
    d.line((cx, cy + s * 0.3, cx, cy + s * 0.48), fill=col, width=w)


def g_cloud(d, cx, cy, s, col):
    for (x, y, r) in ((-0.22, 0.08, 0.24), (0.06, -0.06, 0.32), (0.3, 0.1, 0.2)):
        d.ellipse((cx + (x - r) * s, cy + (y - r) * s, cx + (x + r) * s, cy + (y + r) * s), fill=col)
    d.rounded_rectangle((cx - 0.44 * s, cy + 0.02 * s, cx + 0.5 * s, cy + 0.32 * s), radius=0.15 * s, fill=col)


def status_icons(d, right, cy, col):
    s = dp(16)
    g_battery(d, right - s * 0.3, cy, s, col)
    g_signal(d, right - s * 1.45, cy + s * 0.02, s * 0.82, col)
    g_wifi(d, right - s * 2.7, cy + s * 0.28, s * 0.95, col)


def luminance_top(img):
    a = np.asarray(img.convert("RGB").resize((72, 156))).astype(np.float32) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    y = lin @ np.array([0.2126, 0.7152, 0.0722])
    return float(y[:60].mean())


def lock(wall, sch, dark_text):
    img = wall.convert("RGBA").copy()
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    fg = (24, 24, 28, 255) if dark_text else (255, 255, 255, 255)
    clock_col = sch("a1", 30) if dark_text else sch("a1", 90)
    sub = (40, 40, 46, 230) if dark_text else (240, 240, 245, 235)
    # status bar
    status_icons(d, W - dp(24), dp(26), fg)
    text(d, (dp(24), dp(26)), "No SIM", font(UI, dp(14), wght=500), sub, "lm")
    # date and weather, the large clock (stacked)
    f_date = font(UI, dp(18), wght=500, opsz=18)
    text(d, (W / 2, dp(118)), "Tuesday, Oct 27", f_date, fg, "mm")
    g_cloud(d, W / 2 - dp(32), dp(150), dp(18), fg)
    text(d, (W / 2 - dp(16), dp(150)), "18°C", font(UI, dp(16), wght=500), fg, "lm")
    f_clock = font(CLOCK, dp(146), wght=520, ROND=100, wdth=100)
    text(d, (W / 2, dp(255)), "10", f_clock, clock_col, "mm")
    text(d, (W / 2, dp(392)), "09", f_clock, clock_col, "mm")
    # bottom: shortcuts and fingerprint
    r = dp(32)
    btn = sch("n2", 22, 200) if not dark_text else sch("a1", 92, 210)
    ico = sch("a1", 90) if not dark_text else sch("a1", 25)
    for cx, g in ((dp(56), "flash"), (W - dp(56), "cam")):
        cy = H - dp(88)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=btn)
        if g == "flash":
            g_flash(d, cx, cy, dp(22), ico)
        else:
            g_camera(d, cx, cy, dp(22), ico, btn)
    g_finger(d, W / 2, H - dp(210), dp(44), fg)
    text(d, (W / 2, H - dp(150)), "Swipe up to open", font(UI, dp(13), wght=450), sub, "mm")
    return Image.alpha_composite(img, ov)


def home(wall, sch, dark_theme, dark_text):
    img = wall.convert("RGBA").copy()
    # the launcher's soft scrim behind the status bar and the dock
    yy = np.linspace(0, 1, H)[:, None]
    a = np.clip((0.06 - yy) / 0.06, 0, 1) * 0.18 + np.clip((yy - 0.80) / 0.2, 0, 1) ** 1.5 * 0.16
    scrim_col = (255, 255, 255) if dark_text else (0, 0, 0)
    scrim = np.zeros((H, W, 4), np.uint8)
    scrim[..., :3] = scrim_col
    scrim[..., 3] = (np.repeat(a, W, 1) * 255).astype(np.uint8)
    img = Image.alpha_composite(img, Image.fromarray(scrim, "RGBA"))
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    fg = (24, 24, 28, 255) if dark_text else (255, 255, 255, 255)
    status_icons(d, W - dp(24), dp(26), fg)
    text(d, (dp(24), dp(26)), "10:09", font(UI, dp(15), wght=500), fg, "lm")
    # At a Glance
    text(d, (dp(28), dp(92)), "Tuesday, Oct 27", font(UI, dp(26), wght=430, opsz=32), fg, "ls")
    g_cloud(d, dp(42), dp(122), dp(22), fg)
    text(d, (dp(62), dp(123)), "18°C  Cloudy", font(UI, dp(16), wght=480), fg, "lm")
    # themed icons
    if dark_theme:
        ibg, ifg = sch("n2", 22), sch("a1", 85)
    else:
        ibg, ifg = sch("a1", 90), sch("a1", 30)
    r = dp(28)
    cols = [W * (i + 0.5) / 4 for i in range(4)]
    row1 = [("folder", "Files"), ("mail", "Mail"), ("photo", "Gallery"), ("note", "Music")]
    row2 = ["phone", "bubble", "globe", "camera"]
    lab = font(UI, dp(13), wght=470)
    y1 = H - dp(262)
    for cx, (g, name) in zip(cols, row1):
        d.ellipse((cx - r, y1 - r, cx + r, y1 + r), fill=ibg)
        glyph(d, g, cx, y1, dp(26), ifg, ibg)
        text(d, (cx, y1 + r + dp(14)), name, lab, fg, "mm")
    y2 = H - dp(160)
    for cx, g in zip(cols, row2):
        d.ellipse((cx - r, y2 - r, cx + r, y2 + r), fill=ibg)
        glyph(d, g, cx, y2, dp(26), ifg, ibg)
    # search pill
    y3 = H - dp(78)
    pill = sch("n2", 24, 235) if dark_theme else sch("n2", 95, 240)
    pfg = sch("a1", 85) if dark_theme else sch("a1", 30)
    d.rounded_rectangle((dp(20), y3 - dp(26), W - dp(20), y3 + dp(26)), radius=dp(26), fill=pill)
    g_search(d, dp(52), y3, dp(22), pfg)
    text(d, (dp(76), y3), "Search", font(UI, dp(17), wght=450), (pfg[0], pfg[1], pfg[2], 200), "lm")
    g_mic(d, W - dp(52), y3, dp(22), pfg)
    # gesture handle
    d.rounded_rectangle((W / 2 - dp(54), H - dp(14), W / 2 + dp(54), H - dp(9)), radius=dp(3), fill=fg)
    return Image.alpha_composite(img, ov)


def glyph(d, g, cx, cy, s, col, bg):
    {"folder": lambda: g_folder(d, cx, cy, s, col), "mail": lambda: g_mail(d, cx, cy, s, col, bg),
     "photo": lambda: g_photo(d, cx, cy, s, col, bg), "note": lambda: g_note(d, cx, cy, s, col),
     "phone": lambda: g_phone(d, cx, cy, s, col), "bubble": lambda: g_bubble(d, cx, cy, s, col),
     "globe": lambda: g_globe(d, cx, cy, s, col), "camera": lambda: g_camera(d, cx, cy, s, col, bg)}[g]()


def frame(img, scale=0.25):
    """The screen at scale, with rounded corners, a hole-punch camera and a thin bezel."""
    w, h = int(W * scale), int(H * scale)
    sm = img.convert("RGB").resize((w, h), Image.LANCZOS)
    k = 4
    mask = Image.new("L", (w * k, h * k), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=int(dp(30) * scale * k), fill=255)
    mask = mask.resize((w, h), Image.LANCZOS)
    pad = max(4, int(dp(4) * scale))
    out = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    bez = Image.new("L", ((w + 2 * pad) * k, (h + 2 * pad) * k), 0)
    ImageDraw.Draw(bez).rounded_rectangle((0, 0, (w + 2 * pad) * k - 1, (h + 2 * pad) * k - 1),
                                          radius=int((dp(30) * scale + pad) * k), fill=255)
    bez = bez.resize((w + 2 * pad, h + 2 * pad), Image.LANCZOS)
    out.paste((14, 14, 16, 255), (0, 0), bez)
    scr = sm.convert("RGBA")
    cam = ImageDraw.Draw(scr)
    cr = dp(5) * scale * 1.6
    cam.ellipse((w / 2 - cr, dp(20) * scale - cr, w / 2 + cr, dp(20) * scale + cr), fill=(0, 0, 0, 255))
    out.paste(scr, (pad, pad), mask)
    return out


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    name = os.path.splitext(os.path.basename(src))[0]
    wall = Image.open(src).convert("RGB")
    pop, _ = monet.wallpaper_colors(np.asarray(wall))
    seed = monet.seed_colors(pop)[0]["hex"]
    sch = Scheme(seed)
    dark_text = luminance_top(wall) > 0.45
    lock(wall, sch, dark_text).convert("RGB").save(os.path.join(outdir, name + "_lock.png"))
    home(wall, sch, not dark_text, dark_text).convert("RGB").save(os.path.join(outdir, name + "_home.png"))
    print(name, "seed", seed, "dark_text", dark_text)


if __name__ == "__main__":
    main()
