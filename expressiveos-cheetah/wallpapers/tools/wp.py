"""ExpressiveOS wallpapers: shared drawing code (numpy, scipy, cairocffi, Pillow).

Everything is drawn in linear-light float32 and written once as 8-bit sRGB with fine grain and
triangular dither, so the long gradients never band.
"""
import math
import os
import re
import struct
import zlib

import cairocffi as cairo
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, zoom

W, H = 1440, 3120
HERE = os.path.dirname(os.path.abspath(__file__))
# The mark as vector paths in a 108x108 viewport (../../branding/tools/make-brand.py writes it)
MARK = os.environ.get("EOS_MARK") or os.path.join(HERE, "mark-108.txt")
PETALS = {"blue": ("#76BCFB", "#1842D1"), "green": ("#ACEFB3", "#18A07C"),
          "coral": ("#FDCF8E", "#D33952"), "purple": ("#F3B1FC", "#6B2BBB")}
ORDER = ["blue", "green", "coral", "purple"]


def hex_rgb(h):
    return np.array([int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)], np.float32) / 255.0


def to_lin(c):
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def to_srgb(c):
    c = np.clip(np.asarray(c, np.float32), 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055).astype(np.float32)


def lin(h):
    return to_lin(hex_rgb(h))


# OKLab, for mixing colours without muddy middles
_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]], np.float32)
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]], np.float32)
_M1i = np.linalg.inv(_M1).astype(np.float32)
_M2i = np.linalg.inv(_M2).astype(np.float32)


def lin_to_ok(c):
    lms = np.cbrt(np.asarray(c, np.float32) @ _M1.T)
    return lms @ _M2.T


def ok_to_lin(c):
    lms = np.asarray(c, np.float32) @ _M2i.T
    return (lms ** 3) @ _M1i.T


def ok_mix(a, b, t):
    """Mix linear colours a and b (arrays broadcastable) by t in OKLab."""
    oa, ob = lin_to_ok(a), lin_to_ok(b)
    t = np.asarray(t, np.float32)[..., None] if np.ndim(t) else t
    return np.maximum(ok_to_lin(oa + (ob - oa) * t), 0)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------------------- the mark
def load_mark():
    paths = {}
    for line in open(MARK):
        name, d = line.split(" ", 1)
        paths[name] = d.strip()
    return paths


def path_cmds(d):
    toks = re.findall(r"[MLCZz]|-?\d*\.?\d+(?:e-?\d+)?", d)
    out = []
    i = 0
    cmd = None
    while i < len(toks):
        t = toks[i]
        if t in "MLCZz":
            cmd = t
            i += 1
            if t in "Zz":
                out.append(("Z",))
            continue
        n = {"M": 2, "L": 2, "C": 6}[cmd]
        vals = [float(v) for v in toks[i:i + n]]
        out.append((cmd, *vals))
        i += n
        if cmd == "M":
            cmd = "L"
    return out


def flatten(d, steps=24):
    pts = []
    cur = None
    for c in path_cmds(d):
        if c[0] == "M":
            cur = (c[1], c[2]); pts.append(cur)
        elif c[0] == "L":
            cur = (c[1], c[2]); pts.append(cur)
        elif c[0] == "C":
            x0, y0 = cur
            x1, y1, x2, y2, x3, y3 = c[1:]
            for s in range(1, steps + 1):
                t = s / steps
                mt = 1 - t
                pts.append((mt ** 3 * x0 + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t ** 3 * x3,
                            mt ** 3 * y0 + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t ** 3 * y3))
            cur = (x3, y3)
    return np.array(pts)


class Xf:
    """mark (108x108) coordinates -> canvas pixels: scale s, rotation deg about the mark centre (54,54),
    the mark centre placed at (cx, cy)."""

    def __init__(self, s, deg, cx, cy, flip=False):
        self.s, self.deg, self.cx, self.cy, self.flip = s, deg, cx, cy, flip

    def matrix(self, k=1.0):
        a = math.radians(self.deg)
        ca, sa = math.cos(a) * self.s * k, math.sin(a) * self.s * k
        fx = -1.0 if self.flip else 1.0
        # x' = ca*fx*(x-54) - sa*(y-54) + cx ; y' = sa*fx*(x-54) + ca*(y-54) + cy
        return cairo.Matrix(ca * fx, sa * fx, -sa, ca, self.cx * k - 54 * (ca * fx - sa), self.cy * k - 54 * (sa * fx + ca))

    def apply(self, pts, k=1.0):
        m = self.matrix(k)
        return np.array([m.transform_point(x, y) for x, y in pts])


def raster(d, xf, w, h, k=1.0):
    """Anti-aliased coverage (float32 0..1) of path d under xf, on a w x h canvas scaled by k."""
    surf = cairo.ImageSurface(cairo.FORMAT_A8, w, h)
    ctx = cairo.Context(surf)
    ctx.set_matrix(xf.matrix(k))
    for c in path_cmds(d):
        if c[0] == "M":
            ctx.move_to(c[1], c[2])
        elif c[0] == "L":
            ctx.line_to(c[1], c[2])
        elif c[0] == "C":
            ctx.curve_to(*c[1:])
        else:
            ctx.close_path()
    ctx.set_source_rgba(0, 0, 0, 1)
    ctx.fill()
    surf.flush()
    stride = surf.get_stride()
    a = np.frombuffer(surf.get_data(), np.uint8).reshape(h, stride)[:, :w]
    return a.astype(np.float32) / 255.0


def blur(img, sigma):
    if sigma <= 0.3:
        return img
    if img.ndim == 3:
        return np.stack([gaussian_filter(img[..., i], sigma, mode="nearest") for i in range(img.shape[2])], -1)
    return gaussian_filter(img, sigma, mode="nearest")


def fast_blur(img, sigma, w, h):
    """Large blurs: blur at a lower resolution and come back up (the result has no fine detail)."""
    if sigma < 12:
        return blur(img, sigma)
    f = max(1, int(sigma // 6))
    small = img[::1, ::1]
    sh, sw = (h + f - 1) // f, (w + f - 1) // f
    from PIL import Image as _I
    def down(ch):
        return np.asarray(_I.fromarray(ch).resize((sw, sh), _I.BOX), np.float32)
    def up(ch):
        return np.asarray(_I.fromarray(ch).resize((w, h), _I.BICUBIC), np.float32)
    if img.ndim == 3:
        return np.stack([up(gaussian_filter(down(img[..., i]), sigma / f, mode="nearest")) for i in range(img.shape[2])], -1)
    return up(gaussian_filter(down(img), sigma / f, mode="nearest"))


def shade_petal(name, xf, w, h, light=(-0.55, -0.65, 0.52), k=1.0, gloss=0.35, soft=0.07,
                ramp=(0.0, 1.0), tint=None, sat=1.0, ambient=0.62):
    """A petal as a soft, glossy 3D form, like the logo's: light at its outer end, deep toward the
    centre of the mark, lit from the upper left. Returns (premultiplied linear rgb, alpha)."""
    d = load_mark()[name]
    a = raster(d, xf, w, h, k)
    if a.max() <= 0:
        return np.zeros((h, w, 3), np.float32), a
    size = xf.s * k * 30.0                                   # a petal is ~30 mark units across
    hgt = fast_blur(a, soft * size, w, h)
    hgt = hgt / max(hgt.max(), 1e-6)
    gy, gx = np.gradient(hgt)
    nscale = size * 0.55
    nx, ny, nz = -gx * nscale, -gy * nscale, np.ones_like(gx)
    nl = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    L = np.array(light, np.float32); L /= np.linalg.norm(L)
    diff = np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1)
    Hv = L + np.array([0, 0, 1], np.float32); Hv /= np.linalg.norm(Hv)
    spec = np.clip(nx * Hv[0] + ny * Hv[1] + nz * Hv[2], 0, 1) ** 18
    # ramp: distance from the mark's centre, relative to this petal's reach
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    cx, cy = xf.cx * k, xf.cy * k
    r = np.hypot(xx - cx, yy - cy)
    sel = a > 0.5
    rmin, rmax = np.percentile(r[sel], 3), np.percentile(r[sel], 99.5)
    t = np.clip((r - rmin) / max(rmax - rmin, 1e-6), 0, 1)
    t = ramp[0] + (ramp[1] - ramp[0]) * smoothstep(0.0, 1.0, t)
    light_c, deep_c = PETALS[name]
    lc, dc = lin(light_c), lin(deep_c)
    if tint is not None:
        lc, dc = tint(lc), tint(dc)
    base = ok_mix(dc, lc, t)
    if sat != 1.0:
        ok = lin_to_ok(base)
        ok[..., 1:] *= sat
        base = np.maximum(ok_to_lin(ok), 0)
    shade = ambient + (1 - ambient) * diff
    col = base * shade[..., None] + gloss * spec[..., None] * ok_mix(lc, np.ones(3, np.float32), 0.6)
    return (col * a[..., None]).astype(np.float32), a


def over(dst_rgb, src_rgb_pm, src_a):
    return src_rgb_pm + dst_rgb * (1 - src_a[..., None])


def radial(w, h, cx, cy, rx, ry, power=2.0):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
    return np.clip(1 - d, 0, 1) ** power


def vgrad(w, h, stops):
    """Vertical gradient through (pos 0..1, linear colour) stops, mixed in OKLab."""
    y = (np.arange(h, dtype=np.float32) + 0.5) / h
    out = np.zeros((h, 3), np.float32)
    for (p0, c0), (p1, c1) in zip(stops[:-1], stops[1:]):
        m = (y >= p0) & (y <= p1)
        tt = smoothstep(0, 1, (y[m] - p0) / max(p1 - p0, 1e-6))
        out[m] = ok_mix(c0, c1, tt)
    return np.broadcast_to(out[:, None, :], (h, w, 3)).copy()


# ---------------------------------------------------------------------------- output
def finish(rgb_lin, path, grain=1.1, seed=1):
    """Linear -> sRGB 8-bit with fine monochrome grain (grain/255 rms) and TPDF dither; sRGB PNG."""
    rng = np.random.default_rng(seed)
    s = to_srgb(rgb_lin) * 255.0
    h, w = s.shape[:2]
    g = rng.standard_normal((h, w)).astype(np.float32)
    g = gaussian_filter(g, 0.55) * (grain / 0.33)          # slightly soft grain, not pixel salt
    tpdf = (rng.random((h, w, 3), dtype=np.float32) - rng.random((h, w, 3), dtype=np.float32))
    out = np.clip(np.rint(s + g[..., None] + tpdf), 0, 255).astype(np.uint8)
    save_png(out, path)
    return out


def save_png(u8, path):
    """8-bit RGB PNG with an sRGB chunk (rendering intent perceptual), no other metadata."""
    from PIL import PngImagePlugin
    info = PngImagePlugin.PngInfo()
    info.add(b"sRGB", b"\x00")
    Image.fromarray(u8, "RGB").save(path, pnginfo=info, optimize=False, compress_level=9)
