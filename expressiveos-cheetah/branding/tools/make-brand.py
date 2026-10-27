#!/usr/bin/env python3
"""ExpressiveOS's brand assets for the tree patches, drawn from the logo and Google Sans Flex.

usage: make-brand.py LOGO.png FONT.ttf OUTDIR

Writes into OUTDIR:
  wordmark.txt            the "ExpressiveOS" wordmark as Android path data, one glyph a line,
                          in a 1080x240 viewport (where Evolution X's wordmark sat: x 210-870,
                          y 65-175), for Settings' and the Updater's GlowView-style banners
  mark-24.txt             the mark's four petals, filled and spaced apart, in a 24x24 viewport
                          with 2 units of margin: status bar, Settings and launcher icons
  mark-108.txt            the same petals in a 108x108 viewport, inside the 66-unit safe zone of
                          an adaptive icon (foreground and monochrome layers)
  mark-colors.txt         each petal's two gradient colours, from the logo (light, deep)
  launcher/mipmap-*/ic_launcher_foreground.png   the logo itself, 108dp, for adaptive icons
  recovery/res-*/images/  logo_image, logo_image_switch, fastbootd (the mark in the pill instead
                          of Evolution X's E) and loop00000-loop00080 (the petals traced by a
                          travelling light), made from Evolution X's images in --recovery
  preview/                PNGs of all of the above, to look at

Needs numpy, scipy, Pillow, fonttools, uharfbuzz, potracer (pip "potracer", imported as potrace) and
cairosvg. The same inputs always give the same text files; PNGs can differ by a few pixels with
other cairo or Pillow versions.
"""
import argparse
import io
import os
import re

import numpy as np
from PIL import Image

WORD = "ExpressiveOS"
# Google Sans Flex axes, the boot animation's wordmark (bootanimation/tools/render.py)
AXES = {"opsz": 72, "wdth": 100, "wght": 720, "GRAD": 0, "ROND": 100, "slnt": 0}
NAMES = ["blue", "green", "coral", "purple"]          # clockwise from the top right
HUES = {"coral": (320, 50), "green": (50, 190), "blue": (190, 250), "purple": (250, 320)}
RECOVERY_BLUE = (0, 96, 254)                          # Evolution X's recovery accent, kept
DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}


def fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# ---------------------------------------------------------------- the logo, split into petals
class Logo:
    """The logo keyed off its background (as render.py does) and split by hue into petals."""

    def __init__(self, path):
        src = np.asarray(Image.open(path).convert("RGB")).astype(np.float64)
        self.size = src.shape[1], src.shape[0]
        bgc = np.median(np.concatenate([src[:40].reshape(-1, 3), src[-40:].reshape(-1, 3)]), axis=0)
        a = np.clip((np.abs(src - bgc).max(2) - 6) / 24, 0, 1)
        fg = np.where(a[..., None] > 0, (src - (1 - a[..., None]) * bgc) / np.maximum(a[..., None], 1e-6), 0)
        self.fg = np.clip(fg, 0, 255)
        self.alpha = a
        r, g, b = self.fg[..., 0] / 255, self.fg[..., 1] / 255, self.fg[..., 2] / 255
        mx, mn = self.fg.max(2) / 255, self.fg.min(2) / 255
        d = mx - mn + 1e-9
        hue = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60

        def member(lo, hi, soft=8.0):
            span = (hi - lo) % 360
            off = (hue - lo) % 360
            sd = np.where(off < span, np.minimum(off, span - off), -np.minimum(off - span, 360 - off))
            return np.clip(0.5 + sd / (2 * soft), 0, 1)

        ws = {k: member(*HUES[k]) for k in NAMES}
        tot = sum(ws.values()) + 1e-9
        self.cover = {k: a * ws[k] / tot for k in NAMES}       # each petal's share of the alpha
        ys, xs = np.where(a > 0.5)
        self.bbox = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)

    def petal_mask(self, k, inset=0.0, smooth=0.06):
        """Petal k as a bool mask, shrunk by inset source pixels (to open gaps between petals).
        An opening of smooth x the mark's width first drops the thin tails that curl into the
        centre, which read as noise once the petals are flat shapes."""
        from scipy.ndimage import binary_fill_holes, distance_transform_edt, label
        m = self.cover[k] > 0.5
        r = smooth * (self.bbox[2] - self.bbox[0])
        if r > 0:
            m = distance_transform_edt(m) > r                 # erode by r
            m = distance_transform_edt(~m) <= r               # dilate by r
        lab, n = label(m)                                     # keep the petal, not crumbs
        if n > 1:
            sizes = np.bincount(lab.ravel())[1:]
            m = lab == (1 + int(np.argmax(sizes)))
        m = binary_fill_holes(m)
        # and a soft blur at half: smooths the small waves the hue split leaves on the edges
        from scipy.ndimage import gaussian_filter
        m = gaussian_filter(m.astype(np.float32), 0.012 * (self.bbox[2] - self.bbox[0])) > 0.5
        if inset > 0:
            m = distance_transform_edt(m) > float(inset)
        return m

    def colors(self, k):
        """Light and deep colours of petal k: the mean of its 8% brightest and darkest pixels."""
        m = self.cover[k] > 0.9
        px = self.fg[m]
        lum = px @ np.array([0.299, 0.587, 0.114])
        o = np.argsort(lum)
        n = max(1, len(o) // 12)
        return tuple(np.rint(px[o[-n:]].mean(0)).astype(int)), tuple(np.rint(px[o[:n]].mean(0)).astype(int))


def trace(mask, xf):
    """Potrace a bool mask; returns Android/SVG path data, mapped by xf(x, y) -> (x, y)."""
    import potrace
    bm = potrace.Bitmap(~mask)          # potracer fills the False (dark) pixels
    plist = bm.trace(turdsize=50, turnpolicy=potrace.POTRACE_TURNPOLICY_MINORITY,
                     alphamax=1.0, opticurve=True, opttolerance=0.4)
    out = []
    for curve in plist:
        x, y = xf(curve.start_point.x, curve.start_point.y)
        cmd = [f"M{fmt(x)},{fmt(y)}"]
        for seg in curve.segments:
            if seg.is_corner:
                cx, cy = xf(seg.c.x, seg.c.y)
                ex, ey = xf(seg.end_point.x, seg.end_point.y)
                cmd.append(f"L{fmt(cx)},{fmt(cy)}L{fmt(ex)},{fmt(ey)}")
            else:
                a = xf(seg.c1.x, seg.c1.y)
                b = xf(seg.c2.x, seg.c2.y)
                e = xf(seg.end_point.x, seg.end_point.y)
                cmd.append("C" + " ".join(f"{fmt(p[0])},{fmt(p[1])}" for p in (a, b, e)))
        cmd.append("Z")
        out.append("".join(cmd))
    return "".join(out)


def fit(bbox, box):
    """Map source bbox (x0, y0, x1, y1) centred into box (x0, y0, x1, y1), aspect kept."""
    sx0, sy0, sx1, sy1 = bbox
    bx0, by0, bx1, by1 = box
    s = min((bx1 - bx0) / (sx1 - sx0), (by1 - by0) / (sy1 - sy0))
    ox = (bx0 + bx1) / 2 - s * (sx0 + sx1) / 2
    oy = (by0 + by1) / 2 - s * (sy0 + sy1) / 2
    return lambda x, y: (ox + s * x, oy + s * y)


def mark_paths(logo, box, inset):
    xf = fit(logo.bbox, box)
    return {k: trace(logo.petal_mask(k, inset), xf) for k in NAMES}


# ---------------------------------------------------------------- the wordmark
def wordmark_paths(font_path, box):
    import uharfbuzz as hb
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer

    data = open(font_path, "rb").read()
    face = hb.Face(data)
    hfont = hb.Font(face)
    hfont.set_variations(AXES)
    buf = hb.Buffer()
    buf.add_str(WORD)
    buf.guess_segment_properties()
    hb.shape(hfont, buf, {"kern": True, "liga": False})
    inst = instancer.instantiateVariableFont(TTFont(font_path), dict(AXES))
    gs = inst.getGlyphSet()
    order = inst.getGlyphOrder()
    placed, x = [], 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        placed.append((order[info.codepoint], x + pos.x_offset, pos.y_offset))
        x += pos.x_advance
    bp = BoundsPen(gs)
    for name, gx, gy in placed:
        gs[name].draw(TransformPen(bp, (1, 0, 0, 1, gx, gy)))
    x0, y0, x1, y1 = bp.bounds                      # font units, y up
    bx0, by0, bx1, by1 = box
    s = min((bx1 - bx0) / (x1 - x0), (by1 - by0) / (y1 - y0))
    ox = (bx0 + bx1) / 2 - s * (x0 + x1) / 2
    oy = (by0 + by1) / 2 + s * (y0 + y1) / 2        # y flips
    lines = []
    for name, gx, gy in placed:
        pen = SVGPathPen(gs, ntos=fmt)
        gs[name].draw(TransformPen(pen, (s, 0, 0, -s, ox + s * gx, oy - s * gy)))
        d = pen.getCommands()
        if d:
            lines.append(d)
    return lines


# ---------------------------------------------------------------- rendering
def svg(w, h, body, bg=None):
    rect = f'<rect width="{w}" height="{h}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">{rect}{body}</svg>')


def raster(svg_text, w, h):
    import cairosvg
    png = cairosvg.svg2png(bytestring=svg_text.encode(), output_width=w, output_height=h)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def hexc(c):
    return "#%02X%02X%02X" % tuple(c)


# ---------------------------------------------------------------- recovery
def pill_mark_region(img):
    """Bounding box of the mark inside the recovery pill: blue pixels away from the pill's
    outline, in the middle third of the width."""
    a = np.asarray(img.convert("RGB")).astype(int)
    blue = (a[..., 2] > 120) & (a[..., 0] < 90)
    h, w = blue.shape
    sub = blue[:, w // 3: 2 * w // 3]
    rows = np.where(sub.any(1))[0]
    # the pill's top and bottom lines are the first and last rows with a long blue run
    long_rows = [r for r in rows if sub[r].sum() > sub.shape[1] * 0.8]
    top, bot = min(long_rows), max(long_rows)
    inner = sub[top + 1:bot]
    inner_rows = [r for r in range(inner.shape[0]) if inner[r].any() and inner[r].sum() < inner.shape[1] * 0.8]
    r0, r1 = top + 1 + min(inner_rows), top + 1 + max(inner_rows) + 1
    cols = np.where(sub[r0:r1].any(0))[0]
    return (w // 3 + cols.min(), r0, w // 3 + cols.max() + 1, r1), (top, bot)


def stroke_width(img, region):
    """The E's stroke width: the most common horizontal run of blue in its region."""
    a = np.asarray(img.convert("RGB")).astype(int)
    x0, y0, x1, y1 = region
    blue = (a[y0:y1, x0:x1, 2] > 160) & (a[y0:y1, x0:x1, 0] < 60)
    runs = []
    for row in blue.T:                     # vertical runs (the E's horizontal strokes)
        n = 0
        for v in row:
            if v:
                n += 1
            elif n:
                runs.append(n)
                n = 0
    return float(np.median(runs)) if runs else 4.0


def quantize(img):
    """RGB without alpha, as minui wants, as an adaptive palette image like Evolution X's."""
    return img.convert("RGB").quantize(colors=64, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)


def recovery_logos(logo, src_dir, out_dir):
    for dens in DENSITIES:
        d_in = os.path.join(src_dir, f"res-{dens}", "images")
        d_out = os.path.join(out_dir, f"res-{dens}", "images")
        os.makedirs(d_out, exist_ok=True)
        for name in ("logo_image", "logo_image_switch", "fastbootd"):
            src = Image.open(os.path.join(d_in, name + ".png")).convert("RGB")
            region, (top, bot) = pill_mark_region(src)
            sw = stroke_width(src, region)
            x0, y0, x1, y1 = region
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            # the petals fill the same height as the E, a touch taller (they're round)
            hgt = (y1 - y0) * 1.08
            box = (cx - hgt / 2, cy - hgt / 2, cx + hgt / 2, cy + hgt / 2)
            inset = logo_px_per_unit(logo, hgt) * sw * 1.1
            paths = mark_paths(logo, box, inset)
            body = "".join(f'<path d="{paths[k]}" fill="none" stroke="{hexc(RECOVERY_BLUE)}" '
                           f'stroke-width="{fmt(sw)}" stroke-linejoin="round"/>' for k in NAMES)
            w, h = src.size
            mark = raster(svg(w, h, body), w, h)
            out = src.copy()
            # clear the E (and only it): a black box a little larger than its bounds, inside the pill
            pad = max(2, int(sw))
            ex0, ey0, ex1, ey1 = max(0, x0 - pad), max(top + int(sw) + 1, y0 - pad), min(w, x1 + pad), min(bot - int(sw), y1 + pad)
            out.paste((0, 0, 0), (ex0, ey0, ex1, ey1))
            out = Image.alpha_composite(out.convert("RGBA"), mark).convert("RGB")
            quantize(out).save(os.path.join(d_out, name + ".png"), optimize=True)


def logo_px_per_unit(logo, target_px):
    """Source pixels per target pixel when the logo's bbox height maps to target_px."""
    return (logo.bbox[3] - logo.bbox[1]) / target_px


def outline_points(path_d, n=600):
    """Sample a closed path (M/L/C/Z only, as trace() writes) into n points per subpath."""
    toks = re.findall(r"[MLCZ]|-?\d+(?:\.\d+)?", path_d)
    subs, cur, i, pt = [], [], 0, None
    while i < len(toks):
        t = toks[i]
        if t == "M":
            pt = (float(toks[i + 1]), float(toks[i + 2]))
            cur = [pt]
            i += 3
        elif t == "L":
            pt = (float(toks[i + 1]), float(toks[i + 2]))
            cur.append(pt)
            i += 3
        elif t == "C":
            p1 = (float(toks[i + 1]), float(toks[i + 2]))
            p2 = (float(toks[i + 3]), float(toks[i + 4]))
            p3 = (float(toks[i + 5]), float(toks[i + 6]))
            for s in np.linspace(0, 1, 24)[1:]:
                u = 1 - s
                cur.append(tuple(u ** 3 * np.array(pt) + 3 * u * u * s * np.array(p1) + 3 * u * s * s * np.array(p2) + s ** 3 * np.array(p3)))
            pt = p3
            i += 7
        elif t == "Z":
            cur.append(cur[0])
            subs.append(np.array(cur))
            i += 1
        else:
            i += 1
    out = []
    for p in subs:
        x, y = p[:, 0], p[:, 1]
        if np.sum(x[:-1] * y[1:] - x[1:] * y[:-1]) < 0:     # y down: > 0 is clockwise on screen
            p = p[::-1]
        seg = np.hypot(*np.diff(p, axis=0).T)
        cum = np.concatenate([[0], np.cumsum(seg)])
        t = np.linspace(0, cum[-1], n, endpoint=False)
        out.append((np.stack([np.interp(t, cum, p[:, 0]), np.interp(t, cum, p[:, 1])], 1), cum[-1]))
    return out


def recovery_loop(logo, src_dir, out_dir, frames=81):
    """Each petal outlined in dim grey, with a white light running clockwise around it; the
    four lights are a quarter turn apart, so the light seems to circle the mark."""
    for dens in DENSITIES:
        d_in = os.path.join(src_dir, f"res-{dens}", "images")
        d_out = os.path.join(out_dir, f"res-{dens}", "images")
        os.makedirs(d_out, exist_ok=True)
        ref = Image.open(os.path.join(d_in, "loop00000.png")).convert("L")
        w, h = ref.size
        a = np.asarray(ref)
        ys, xs = np.where(a > 20)
        cx, cy = (xs.min() + xs.max() + 1) / 2, (ys.min() + ys.max() + 1) / 2
        hgt = (ys.max() - ys.min() + 1) * 0.82
        sw = stroke_width_gray(a)
        box = (cx - hgt / 2, cy - hgt / 2, cx + hgt / 2, cy + hgt / 2)
        inset = logo_px_per_unit(logo, hgt) * sw * 1.2
        paths = mark_paths(logo, box, inset)
        samples = {k: outline_points(paths[k]) for k in NAMES}
        dim = "#3C3C3C"
        base = "".join(f'<path d="{paths[k]}" fill="none" stroke="{dim}" stroke-width="{fmt(sw)}" '
                       f'stroke-linejoin="round"/>' for k in NAMES)
        for f in range(frames):
            body = [base]
            for i, k in enumerate(NAMES):
                for pts, length in samples[k][:1]:          # the outer outline only
                    n = len(pts)
                    head = ((f / frames) + i / 4) % 1.0
                    span = 0.42
                    idx = [int((head - span + j * span / 60) % 1.0 * n) for j in range(61)]
                    seq = pts[idx]
                    d = "M" + "L".join(f"{fmt(x)},{fmt(y)}" for x, y in seq)
                    body.append(f'<path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="{fmt(sw)}" '
                                f'stroke-linecap="round" stroke-linejoin="round"/>')
            img = raster(svg(w, h, "".join(body), bg="#000000"), w, h).convert("L")
            # 16 grey levels are plenty for antialiased lines and keep the frames about as
            # small as Evolution X's (recovery keeps one density of them in vendor_boot's ramdisk)
            lv = np.rint(np.asarray(img, np.float32) / 17).astype(np.uint8)
            pal = Image.fromarray(lv, "P")
            pal.putpalette([i * 17 for i in range(16) for _ in range(3)])
            pal.save(os.path.join(d_out, f"loop{f:05d}.png"), optimize=True, bits=4)


def stroke_width_gray(a):
    m = a > 100
    runs = []
    for row in m.T:
        n = 0
        for v in row:
            if v:
                n += 1
            elif n:
                runs.append(n)
                n = 0
    return float(np.median(runs)) if runs else 4.0


# ---------------------------------------------------------------- launcher
def launcher_pngs(logo, out_dir):
    """The logo itself on transparency, sized for an adaptive icon's 108dp foreground: the mark
    fills 60dp, inside the 66dp safe circle."""
    fg = logo.fg
    rgba = np.dstack([fg, logo.alpha * 255]).astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")
    x0, y0, x1, y1 = logo.bbox
    side = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    crop = im.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))
    for dens, s in DENSITIES.items():
        px = round(108 * s)
        mark = round(60 * s)
        d = os.path.join(out_dir, f"mipmap-{dens}")
        os.makedirs(d, exist_ok=True)
        canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        m = crop.resize((mark, mark), Image.LANCZOS)
        canvas.paste(m, ((px - mark) // 2, (px - mark) // 2), m)
        canvas.save(os.path.join(d, "ic_launcher_foreground.png"), optimize=True)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logo")
    ap.add_argument("font")
    ap.add_argument("out")
    ap.add_argument("--recovery", help="Evolution X's bootable/recovery checkout (its res-*/images)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    logo = Logo(args.logo)

    word = wordmark_paths(args.font, (210, 65, 870, 175))
    open(os.path.join(args.out, "wordmark.txt"), "w").write("\n".join(word) + "\n")

    # icons: a 20-unit mark in 24 units; gaps of about 1.1 units between petals
    m24 = mark_paths(logo, (2, 2, 22, 22), logo_px_per_unit(logo, 20) * 0.55)
    open(os.path.join(args.out, "mark-24.txt"), "w").write("".join(f"{k} {m24[k]}\n" for k in NAMES))
    m108 = mark_paths(logo, (24, 24, 84, 84), logo_px_per_unit(logo, 60) * 1.2)
    open(os.path.join(args.out, "mark-108.txt"), "w").write("".join(f"{k} {m108[k]}\n" for k in NAMES))
    cols = {k: logo.colors(k) for k in NAMES}
    open(os.path.join(args.out, "mark-colors.txt"), "w").write(
        "".join(f"{k} {hexc(cols[k][0])} {hexc(cols[k][1])}\n" for k in NAMES))

    launcher_pngs(logo, os.path.join(args.out, "launcher"))
    if args.recovery:
        recovery_logos(logo, args.recovery, os.path.join(args.out, "recovery"))
        recovery_loop(logo, args.recovery, os.path.join(args.out, "recovery"))

    # previews
    pv = os.path.join(args.out, "preview")
    os.makedirs(pv, exist_ok=True)
    wbody = "".join(f'<path d="{d}" fill="#FFFFFF"/>' for d in word)
    raster(svg(1080, 240, wbody, bg="#202124"), 1080, 240).save(os.path.join(pv, "wordmark.png"))
    for name, paths, size in (("mark-24", m24, 24), ("mark-108", m108, 108)):
        body = "".join(f'<path d="{paths[k]}" fill="#FFFFFF" fill-rule="evenodd"/>' for k in NAMES)
        raster(svg(size, size, body, bg="#202124"), 480, 480).save(os.path.join(pv, name + ".png"))
        for px in (24, 48, 72):
            raster(svg(size, size, body, bg="#202124"), px, px).save(os.path.join(pv, f"{name}-{px}px.png"))
    print("OK", args.out)


if __name__ == "__main__":
    main()
