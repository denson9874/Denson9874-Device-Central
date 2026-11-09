"""ExpressiveOS wallpapers. usage: art2.py NAME OUT.png [scale]"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import silk
import wp

L = wp.lin


def vignette(w, h, strength=0.25, cx=0.5, cy=0.45):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.hypot((xx / w - cx) / 0.75, (yy / h - cy) / 0.85)
    return 1 - strength * wp.smoothstep(0.35, 1.05, d)


def relief(s, w, h, k, amount, sigma=22.0, light=(-0.45, -0.75, 0.5)):
    """Satin relief: treat the blurred strand density as a height field and light it from the upper
    left, so the folds get highlights on one side and soft shade on the other. Returns a multiplier."""
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


def dims(k):
    return int(round(wp.W * k)), int(round(wp.H * k))


def dark_silk(k, bg, glows, front, back, flip=False, hm=7, top_glow=None):
    """A dark wallpaper: one silk ribbon (front) and one out-of-focus ribbon behind it (back).
    front/back: dict(petal, n, p0, p1, weight, ramp centre (cx, cy), ramp (a0, span), stops, gain, soft, rot, seed)."""
    w, h = dims(k)
    img = wp.vgrad(w, h, bg)
    for (gx, gy, rx, ry, col, amt) in glows:
        img += wp.radial(w, h, gx * w, gy * h, rx * w, ry * h, 2.0)[..., None] * L(col) * amt
    out = np.zeros((h, w, 3), np.float32)
    for r in (back, front):
        if r is None:
            continue
        s = silk.strands(r["petal"], r["n"], r["p0"], r["p1"], w, h, k, r["weight"], width=r.get("width", (1.6, 2.6)),
                         harmonics=hm, rot_wave=r.get("rot", (4.0, 1.0)), seed=r["seed"], soft=r.get("soft", 0.7))
        ang = silk.angle_map(w, h, k, *r["centre"])
        x = np.clip(((ang % 360.0) - r["ramp"][0]) / r["ramp"][1], 0, 1)
        out += r["gain"] * s[..., None] * silk.colour_ramp(x, [(p, L(c)) for p, c in r["stops"]])
    glow = wp.fast_blur(out, 28 * k, w, h)
    haze = wp.fast_blur(out, 160 * k, w, h)
    img = img + out * 0.95 + glow * 1.3 + haze * 1.0
    img = img * vignette(w, h, 0.16)[..., None]
    return img[:, ::-1].copy() if flip else img


def bloom(k, front_gain=1.0, back_gain=0.5):
    """Dark, blue-led (the default): one blue silk ribbon rising from the lower right, violet at its
    outer edge, glowing pale blue where it folds; a purple ribbon out of focus behind it."""
    W, H = wp.W, wp.H
    return dark_silk(
        k,
        bg=[(0.0, L("#03050E")), (0.45, L("#050C22")), (1.0, L("#08143A"))],
        glows=[(0.85, 0.95, 1.2, 0.40, "#1842D1", 0.30), (0.05, 1.00, 0.9, 0.30, "#6B2BBB", 0.14),
               (1.0, 0.0, 1.0, 0.35, "#1842D1", 0.05)],
        back=dict(petal="purple", n=60, p0=(80.0, 20.0, 0.05 * W, 1.28 * H), p1=(50.0, 55.0, 0.05 * W, 1.28 * H),
                  weight=lambda t: 0.08 + 0.13 * t * (1 - t) * 4, width=(2.0, 3.0), rot=(3.0, 1.0), seed=5, soft=22.0,
                  centre=(0.05 * W, 1.28 * H), ramp=(200.0, 100.0), gain=back_gain,
                  stops=[(0.0, "#3A1C8C"), (0.6, "#7B3FD6"), (1.0, "#E7A6F7")]),
        front=dict(petal="blue", n=130, p0=(82.0, -100.0, 1.20 * W, 1.18 * H), p1=(33.0, -20.0, 0.92 * W, 0.99 * H),
                   weight=lambda t: (0.05 + 0.30 * t ** 1.5) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t)),
                   rot=(6.0, 2.0), seed=11, centre=(1.0 * W, 1.0 * H), ramp=(185.0, 85.0), gain=front_gain,
                   stops=[(0.0, "#3B30C4"), (0.3, "#1F42D6"), (0.78, "#2A6CF0"), (1.0, "#A8D4FF")]))


def dusk(k):
    """Dark, purple-led: a violet silk ribbon rising from the lower left, rose where it folds; a coral
    ribbon out of focus behind it."""
    W, H = wp.W, wp.H
    return dark_silk(
        k, flip=True,
        bg=[(0.0, L("#06040E")), (0.45, L("#0E0720")), (1.0, L("#1A0B34"))],
        glows=[(0.85, 0.95, 1.2, 0.40, "#6B2BBB", 0.34), (0.05, 1.00, 0.9, 0.30, "#D33952", 0.12),
               (1.0, 0.0, 1.0, 0.35, "#6B2BBB", 0.05)],
        back=dict(petal="coral", n=60, p0=(82.0, 107.0, 0.04 * W, 1.28 * H), p1=(50.0, 142.0, 0.04 * W, 1.28 * H),
                  weight=lambda t: 0.08 + 0.12 * t * (1 - t) * 4, width=(2.0, 3.0), rot=(3.0, 1.0), seed=9, soft=22.0,
                  centre=(0.04 * W, 1.28 * H), ramp=(200.0, 100.0), gain=0.5,
                  stops=[(0.0, "#6B1A4A"), (0.6, "#D33952"), (1.0, "#FDCF8E")]),
        front=dict(petal="purple", n=130, p0=(80.0, -7.0, 1.20 * W, 1.18 * H), p1=(33.0, 73.0, 0.92 * W, 0.99 * H),
                   weight=lambda t: (0.05 + 0.30 * t ** 1.5) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t)),
                   rot=(6.0, 2.0), seed=13, centre=(1.0 * W, 1.0 * H), ramp=(185.0, 85.0), gain=1.0,
                   stops=[(0.0, "#3A1C8C"), (0.3, "#5E2CC0"), (0.75, "#9A4FE6"), (1.0, "#F6C2FF")]))


def light_silk(k, bg, fields, front, back=None, flip=False, hm=7):
    """A light wallpaper: pastel colour fields, a silk ribbon of fine coloured threads (multiplied in, like
    dyed silk on paper) with a soft shadow, and an optional out-of-focus ribbon behind."""
    w, h = dims(k)
    img = wp.vgrad(w, h, bg)
    for (petal, xf, sigma, col, amt) in fields:
        f = silk.shape(petal, wp.Xf(*xf), w, h, k, sigma, hm)
        img = img * (1 - f[..., None] * amt) + f[..., None] * amt * L(col)
    for r in (back, front):
        if r is None:
            continue
        s = silk.strands(r["petal"], r["n"], r["p0"], r["p1"], w, h, k, r["weight"], width=r.get("width", (1.6, 2.6)),
                         harmonics=hm, rot_wave=r.get("rot", (4.0, 1.0)), seed=r["seed"], soft=r.get("soft", 0.7))
        ang = silk.angle_map(w, h, k, *r["centre"])
        x = np.clip(((ang % 360.0) - r["ramp"][0]) / r["ramp"][1], 0, 1)
        col = silk.colour_ramp(x, [(p, L(c)) for p, c in r["stops"]])
        sh = wp.fast_blur(s, 40 * k, w, h)
        img = img * (1 - r.get("shadow", 0.10) * np.clip(sh, 0, 1.5)[..., None])
        a = np.clip(s * r["gain"], 0, 1)[..., None]
        img = img * (1 - a) + img * col * a                          # dye: multiply toward the colour
        glow = wp.fast_blur(s, 60 * k, w, h)
        img = img * (1 - np.clip(glow * r.get("tint", 0.25), 0, 0.6)[..., None] * (1 - col))
        img = img * relief(s, w, h, k, r.get("relief", 0.0), r.get("relief_sigma", 22.0))[..., None]
    img = img * vignette(w, h, 0.06)[..., None]
    return img[:, ::-1].copy() if flip else img


def dawn(k):
    """Light, coral-led: warm paper and peach light, a coral silk ribbon rising from the lower right,
    crimson at its outer edge and peach where it folds; a rose ribbon out of focus behind it."""
    W, H = wp.W, wp.H
    return light_silk(
        k,
        bg=[(0.0, L("#FFF9F3")), (0.5, L("#FEF1E8")), (1.0, L("#FCE6DA"))],
        fields=[("coral", (70.0, 120.0, 1.05 * W, 1.02 * H), 200, "#F28A6E", 0.55),
                ("coral", (60.0, 60.0, -0.05 * W, 1.12 * H), 220, "#F5A38C", 0.35),
                ("coral", (44.0, 150.0, 1.00 * W, 0.62 * H), 240, "#FFB38A", 0.30)],
        back=dict(petal="purple", n=60, p0=(80.0, 20.0, 0.05 * W, 1.28 * H), p1=(50.0, 55.0, 0.05 * W, 1.28 * H),
                  weight=lambda t: 0.12 + 0.16 * t * (1 - t) * 4, width=(2.0, 3.0), rot=(3.0, 1.0), seed=5, soft=20.0,
                  centre=(0.05 * W, 1.28 * H), ramp=(200.0, 100.0), gain=0.55,
                  stops=[(0.0, "#E0606E"), (0.6, "#EE7A70"), (1.0, "#F7A890")], shadow=0.0, tint=0.25),
        front=dict(petal="coral", n=130, p0=(82.0, 80.0, 1.20 * W, 1.18 * H), p1=(33.0, 160.0, 0.92 * W, 0.99 * H),
                   weight=lambda t: (0.14 + 0.45 * t ** 1.3) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t)),
                   rot=(6.0, 2.0), seed=21, centre=(1.0 * W, 1.0 * H), ramp=(185.0, 85.0), gain=0.85,
                   stops=[(0.0, "#C0304E"), (0.45, "#D9445A"), (0.8, "#EE7A62"), (1.0, "#F9B07E")],
                   shadow=0.10, tint=0.45, relief=0.35))


def mint(k):
    """Light, green-led: cool paper and mint light, a green silk ribbon rising from the lower left,
    deep teal at its outer edge and pale mint where it folds; a sky-blue ribbon out of focus behind it."""
    W, H = wp.W, wp.H
    return light_silk(
        k, flip=True,
        bg=[(0.0, L("#F6FBF8")), (0.5, L("#EEF7F2")), (1.0, L("#E2F2EA"))],
        fields=[("green", (70.0, 120.0, 1.05 * W, 1.02 * H), 200, "#7ED9B0", 0.50),
                ("green", (60.0, 60.0, -0.05 * W, 1.12 * H), 220, "#A6E6CF", 0.35),
                ("green", (44.0, 150.0, 1.00 * W, 0.62 * H), 240, "#CFF0DE", 0.30)],
        back=dict(petal="blue", n=60, p0=(80.0, -73.0, 0.05 * W, 1.28 * H), p1=(50.0, -38.0, 0.05 * W, 1.28 * H),
                  weight=lambda t: 0.12 + 0.16 * t * (1 - t) * 4, width=(2.0, 3.0), rot=(3.0, 1.0), seed=7, soft=26.0,
                  centre=(0.05 * W, 1.28 * H), ramp=(200.0, 100.0), gain=0.45,
                  stops=[(0.0, "#4F8FE0"), (0.6, "#76BCFB"), (1.0, "#A8D8FF")], shadow=0.0, tint=0.22),
        front=dict(petal="green", n=130, p0=(82.0, -185.0, 1.20 * W, 1.18 * H), p1=(33.0, -105.0, 0.92 * W, 0.99 * H),
                   weight=lambda t: (0.14 + 0.45 * t ** 1.3) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t)),
                   rot=(6.0, 2.0), seed=31, centre=(1.0 * W, 1.0 * H), ramp=(185.0, 85.0), gain=0.85,
                   stops=[(0.0, "#0F6E6A"), (0.45, "#18A07C"), (0.8, "#3FBF96"), (1.0, "#9FE6C0")],
                   shadow=0.10, tint=0.45, relief=0.35))


ART = {"bloom": bloom, "dusk": dusk, "dawn": dawn, "mint": mint}

if __name__ == "__main__":
    name, out = sys.argv[1], sys.argv[2]
    k = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    wp.finish(ART[name](k), out, grain=1.0, seed=7)
