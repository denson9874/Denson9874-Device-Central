"""Generic silk layers: each ribbon coloured by angle around a centre, or along its length (by stroke)."""
import math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import silk, wp
L = wp.lin


def ribbon_rgb(r, w, h, k, hm=7):
    """-> (scalar density s, linear colour per pixel)."""
    stops = [(p, L(c)) for p, c in r["stops"]]
    if r.get("by", "angle") == "t":
        s, t = silk.strands_t(r["petal"], r["n"], r["p0"], r["p1"], w, h, k, r["weight"],
                              width=r.get("width", (1.6, 2.6)), harmonics=hm, rot_wave=r.get("rot", (4.0, 1.0)),
                              seed=r["seed"], soft=r.get("soft", 0.7))
        x = t if not r.get("tcurve") else r["tcurve"](t)
    else:
        s = silk.strands(r["petal"], r["n"], r["p0"], r["p1"], w, h, k, r["weight"], width=r.get("width", (1.6, 2.6)),
                         harmonics=hm, rot_wave=r.get("rot", (4.0, 1.0)), seed=r["seed"], soft=r.get("soft", 0.7))
        ang = silk.angle_map(w, h, k, *r["centre"])
        x = np.clip(((ang % 360.0) - r["ramp"][0]) / r["ramp"][1], 0, 1)
    return s, silk.colour_ramp(x, stops)


def dark(k, bg, glows, ribbons, flip=False, hm=7, glow=(28, 1.3), haze=(160, 1.0), vig=0.16):
    w, h = int(round(wp.W * k)), int(round(wp.H * k))
    img = wp.vgrad(w, h, bg)
    for (gx, gy, rx, ry, col, amt) in glows:
        img += wp.radial(w, h, gx * w, gy * h, rx * w, ry * h, 2.0)[..., None] * L(col) * amt
    out = np.zeros((h, w, 3), np.float32)
    for r in ribbons:
        s, col = ribbon_rgb(r, w, h, k, hm)
        out += r["gain"] * s[..., None] * col
    img = img + out * 0.95 + wp.fast_blur(out, glow[0] * k, w, h) * glow[1] + wp.fast_blur(out, haze[0] * k, w, h) * haze[1]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.hypot((xx / w - 0.5) / 0.75, (yy / h - 0.45) / 0.85)
    img = img * (1 - vig * wp.smoothstep(0.35, 1.05, d))[..., None]
    return img[:, ::-1].copy() if flip else img


def light(k, bg, fields, ribbons, flip=False, hm=7, vig=0.05, hl_light=(-0.45, -0.75, 0.5)):
    """A light wallpaper: pastel paper, soft colour fields, and silk ribbons: a translucent body tinted
    toward the ribbon colour, fine coloured threads, a soft cast shadow, and satin highlights."""
    w, h = int(round(wp.W * k)), int(round(wp.H * k))
    img = wp.vgrad(w, h, bg)
    for (gx, gy, rx, ry, col, amt) in fields:
        f = wp.radial(w, h, gx * w, gy * h, rx * w, ry * h, 2.0)[..., None] * amt
        img = img * (1 - f) + L(col) * f
    for r in ribbons:
        s, col = ribbon_rgb(r, w, h, k, hm)
        # cast shadow: the density, offset down and blurred, darkens the paper a little (tinted)
        dx, dy = int(r.get("sh_off", (10, 26))[0] * k), int(r.get("sh_off", (10, 26))[1] * k)
        sh = np.roll(np.roll(s, dy, 0), dx, 1)
        sh = np.clip(wp.fast_blur(sh, r.get("sh_blur", 36) * k, w, h) * r.get("sh_gain", 1.0), 0, 1)
        img = img * (1 - r.get("shadow", 0.10) * sh[..., None] * (1 - 0.5 * col))
        # translucent body
        body = np.clip(wp.fast_blur(s, r.get("body_blur", 9) * k, w, h) * r.get("body_gain", 1.0), 0, 1)
        bcol = wp.ok_mix(col, np.ones(3, np.float32), r.get("body_pale", 0.45))
        ba = body[..., None] * r.get("body", 0.35)
        img = img * (1 - ba) + bcol * ba
        # threads
        a = np.clip(s * r["gain"], 0, 1)[..., None] * r.get("thread", 0.8)
        img = img * (1 - a) + col * a
        # satin highlight and shade from the folds
        rel = relief(body, w, h, k, r.get("relief", 0.0), r.get("relief_sigma", 14.0), hl_light)
        img = img * rel[..., None]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.hypot((xx / w - 0.5) / 0.75, (yy / h - 0.45) / 0.85)
    img = img * (1 - vig * wp.smoothstep(0.35, 1.05, d))[..., None]
    return img[:, ::-1].copy() if flip else img


def relief(s, w, h, k, amount, sigma=14.0, light=(-0.45, -0.75, 0.5)):
    if amount <= 0:
        return np.ones((h, w), np.float32)
    hgt = wp.fast_blur(s, sigma * k, w, h)
    gy, gx = np.gradient(hgt)
    sc = 1.0 / max(np.percentile(np.hypot(gx, gy), 99.5), 1e-6)
    nx, ny = -gx * sc, -gy * sc
    nz = np.ones_like(nx)
    n = np.sqrt(nx * nx + ny * ny + nz * nz)
    Lv = np.array(light, np.float32); Lv /= np.linalg.norm(Lv)
    d = (nx * Lv[0] + ny * Lv[1] + nz * Lv[2]) / n - Lv[2]
    return (1 + amount * d).astype(np.float32)


def light2(k, bg, fields, ribbons, flip=False, hm=7, vig=0.06):
    """art2.light_silk with per-ribbon colouring by angle or by stroke: pastel fields (petal shapes or
    radial glows), threads dyed into the paper (multiply toward the colour), soft shadow, tint glow, relief."""
    w, h = int(round(wp.W * k)), int(round(wp.H * k))
    img = wp.vgrad(w, h, bg)
    for f in fields:
        if f[0] == "radial":
            _, gx, gy, rx, ry, col, amt = f
            a = wp.radial(w, h, gx * w, gy * h, rx * w, ry * h, 2.0)
        else:
            petal, xf, sigma, col, amt = f
            a = silk.shape(petal, wp.Xf(*xf), w, h, k, sigma, hm)
        img = img * (1 - a[..., None] * amt) + a[..., None] * amt * L(col)
    for r in ribbons:
        s, col = ribbon_rgb(r, w, h, k, hm)
        if r.get("aura"):
            acol, aamt, asig = r["aura"]
            au = wp.fast_blur(s, asig * k, w, h)
            au = np.clip(au / max(np.percentile(au, 99.5), 1e-6), 0, 1) ** 0.8 * aamt
            img = img * (1 - au[..., None]) + L(acol) * au[..., None]
        sh = wp.fast_blur(s, 40 * k, w, h)
        img = img * (1 - r.get("shadow", 0.10) * np.clip(sh, 0, 1.5)[..., None])
        a = np.clip(s * r["gain"], 0, r.get("amax", 1.0))[..., None]
        if r.get("blend") == "mix":          # coloured threads (no darkening toward grey where they cross)
            img = img * (1 - a) + col * a
        else:                                # dyed: multiply toward the colour
            img = img * (1 - a) + img * col * a
        glow = wp.fast_blur(s, 60 * k, w, h)
        img = img * (1 - np.clip(glow * r.get("tint", 0.25), 0, 0.6)[..., None] * (1 - col))
        img = img * relief(s, w, h, k, r.get("relief", 0.0), r.get("relief_sigma", 22.0))[..., None]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.hypot((xx / w - 0.5) / 0.75, (yy / h - 0.45) / 0.85)
    img = img * (1 - vig * wp.smoothstep(0.35, 1.05, d))[..., None]
    return img[:, ::-1].copy() if flip else img
