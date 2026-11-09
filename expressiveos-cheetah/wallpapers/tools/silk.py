"""Silk: fine echoes of a petal's outline (smoothed), accumulated in float, coloured afterwards."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cairocffi as cairo
import numpy as np
import wp


def petal_outline(name, harmonics=10, n=1200):
    """The petal's outline in mark units, resampled by arc length and low-passed: the gesture of the
    petal without the small kinks of the traced logo."""
    pts = wp.flatten(wp.load_mark()[name], steps=40)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    s = np.concatenate([[0], np.cumsum(seg)])
    u = np.linspace(0, s[-1], n, endpoint=False)
    x = np.interp(u, s, pts[:, 0]); y = np.interp(u, s, pts[:, 1])
    z = x + 1j * y
    Z = np.fft.fft(z)
    keep = np.zeros(n, bool)
    keep[:harmonics + 1] = True
    keep[-harmonics:] = True
    Z[~keep] = 0
    z = np.fft.ifft(Z)
    return np.stack([z.real, z.imag], -1)


_cache = {}


def outline(name, harmonics):
    key = (name, harmonics)
    if key not in _cache:
        _cache[key] = petal_outline(name, harmonics)
    return _cache[key]


def poly_stroke(pts, xf, w, h, k, width, fill=False):
    surf = cairo.ImageSurface(cairo.FORMAT_A8, w, h)
    ctx = cairo.Context(surf)
    ctx.set_matrix(xf.matrix(k))
    ctx.move_to(*pts[0])
    for p in pts[1:]:
        ctx.line_to(*p)
    ctx.close_path()
    ctx.identity_matrix()
    if fill:
        ctx.fill()
    else:
        ctx.set_line_width(max(width * k, 0.35))
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        ctx.stroke()
    surf.flush()
    a = np.frombuffer(surf.get_data(), np.uint8).reshape(h, surf.get_stride())[:, :w]
    return a.astype(np.float32) / 255.0


def lerp(a, b, t):
    return a + (b - a) * t


def strands(name, n, p0, p1, w, h, k, weight, width=(1.5, 2.5), harmonics=10, seed=3,
            rot_wave=(0.0, 1.0), scale_wave=(0.0, 1.0), soft=0.7, morph=None):
    """Scalar intensity of n strokes between transforms p0=(s, deg, cx, cy) and p1 (mark units -> px).
    weight(t) gives each stroke's brightness. morph(t) may return a harmonics count per stroke."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w), np.float32)
    ts = np.linspace(0, 1, n) + rng.normal(0, 0.22 / n, n)
    ts = np.clip(np.sort(ts), 0, 1)
    ramp, rcyc = rot_wave
    samp, scyc = scale_wave
    for t in ts:
        s = lerp(p0[0], p1[0], t) * (1 + samp * math.sin(2 * math.pi * scyc * t))
        deg = lerp(p0[1], p1[1], t) + ramp * math.sin(2 * math.pi * rcyc * t + 0.7)
        cx = lerp(p0[2], p1[2], t); cy = lerp(p0[3], p1[3], t)
        hm = morph(t) if morph else harmonics
        m = poly_stroke(outline(name, hm), wp.Xf(s, deg, cx, cy), w, h, k, lerp(width[0], width[1], rng.random()))
        acc += m * (weight(t) * (0.7 + 0.6 * rng.random()))
    if soft * k > 0.3:
        acc = wp.blur(acc, soft * k)
    return acc


def shape(name, xf, w, h, k, sigma, harmonics=10):
    a = poly_stroke(outline(name, harmonics), xf, w, h, k, 0, fill=True)
    return wp.fast_blur(a, sigma * k, w, h) if sigma * k > 0.3 else a


def angle_map(w, h, k, cx, cy):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return np.degrees(np.arctan2(yy - cy * k, xx - cx * k))


def colour_ramp(x, stops):
    """x (array, 0..1) -> linear rgb through (pos, linear colour) stops in OKLab."""
    x = np.clip(x, 0, 1)
    out = np.zeros(x.shape + (3,), np.float32)
    oks = [(p, wp.lin_to_ok(c)) for p, c in stops]
    for (p0, c0), (p1, c1) in zip(oks[:-1], oks[1:]):
        m = (x >= p0) & (x <= p1)
        t = ((x[m] - p0) / max(p1 - p0, 1e-6))[..., None]
        out[m] = wp.ok_to_lin(c0 + (c1 - c0) * t)
    out[x < oks[0][0]] = wp.ok_to_lin(oks[0][1])
    out[x > oks[-1][0]] = wp.ok_to_lin(oks[-1][1])
    return np.maximum(out, 0)


def strands_t(name, n, p0, p1, w, h, k, weight, width=(1.5, 2.5), harmonics=10, seed=3,
              rot_wave=(0.0, 1.0), soft=0.7):
    """Like strands(), and also the weighted mean stroke index per pixel (0 = first stroke, 1 = last),
    so a ribbon can be coloured along its length (by stroke) instead of by angle."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w), np.float32)
    acct = np.zeros((h, w), np.float32)
    ts = np.linspace(0, 1, n) + rng.normal(0, 0.22 / n, n)
    ts = np.clip(np.sort(ts), 0, 1)
    ramp, rcyc = rot_wave
    for t in ts:
        s = lerp(p0[0], p1[0], t)
        deg = lerp(p0[1], p1[1], t) + ramp * math.sin(2 * math.pi * rcyc * t + 0.7)
        cx = lerp(p0[2], p1[2], t); cy = lerp(p0[3], p1[3], t)
        m = poly_stroke(outline(name, harmonics), wp.Xf(s, deg, cx, cy), w, h, k, lerp(width[0], width[1], rng.random()))
        m *= weight(t) * (0.7 + 0.6 * rng.random())
        acc += m
        acct += m * t
    if soft * k > 0.3:
        acc = wp.blur(acc, soft * k); acct = wp.blur(acct, soft * k)
    tb = wp.fast_blur(acct, 6 * k, w, h) / np.maximum(wp.fast_blur(acc, 6 * k, w, h), 1e-5)
    return acc, np.clip(tb, 0, 1)
