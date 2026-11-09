"""ExpressiveOS wallpapers, final set. usage: final.py NAME OUT.png [scale]

bloom  dark, blue-led (the default): a blue silk sheet rising from the lower right, violet at its outer
       edge, pale blue where it folds, with a purple ribbon out of focus behind it.
dusk   dark, purple-led: a violet ribbon that twists across the lower third, rose where it turns, over a
       warm rose horizon glow.
dawn   light, coral-led: warm paper, a coral silk sheet rising from the lower left, crimson at its edge and
       peach where it folds, in a soft peach light.
mint   light, green-led: cool paper, a green ribbon that twists across the lower third (mirror of dusk's
       form), in mint light with a touch of sky blue.
Each ribbon is drawn from one petal of the ExpressiveOS mark: every thread is an echo of that petal's outline.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import art2
import layers
import wp

L = wp.lin
W, H = wp.W, wp.H
CENT = {"blue": -37.2, "green": 48.2, "coral": 143.1, "purple": -129.8}   # petal centroid angles in the mark


def bloom(k):
    return art2.bloom(k, front_gain=BLOOM_G[0], back_gain=BLOOM_G[1])


BLOOM_G = (1.2, 0.40)


def _twist(petal, stops, weight, dy, s0, s1, extra=None):
    """The twisting-ribbon form (found for the purple petal; other petals are turned onto its place)."""
    o = CENT["purple"] - CENT[petal]
    d = dict(petal=petal, n=160, p0=(s0, 52.46 + o, 0.057 * W, (1.306 + dy) * H),
             p1=(s1, 150.78 + o, 0.231 * W, (0.857 + dy) * H), weight=weight, rot=(6.0, 2.0), by="t", stops=stops)
    d.update(extra or {})
    return d


def dusk(k):
    wt = lambda t: (0.05 + 0.30 * t ** 1.5) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t))
    rib = _twist("purple", [(0.0, "#3A1C8C"), (0.35, "#6B2BBB"), (0.7, "#A955E6"), (0.9, "#E58AD6"), (1.0, "#FFD3EC")],
                 wt, DUSK_DY, DUSK_S[0], DUSK_S[1], dict(seed=13, gain=1.05))
    return layers.dark(
        k, bg=[(0.0, L("#06040E")), (0.45, L("#0D0720")), (1.0, L("#190A30"))],
        glows=[(0.75, 1.05, 1.1, 0.30, "#D33952", 0.30), (0.3, 0.90, 1.2, 0.45, "#6B2BBB", 0.24),
               (0.0, 0.0, 1.0, 0.3, "#6B2BBB", 0.04)],
        ribbons=[rib])


DUSK_DY, DUSK_S = -0.05, (70.0, 46.0)


def dawn(k):
    rib = dict(petal="coral", n=130, p0=(82.0, 80.0, 1.20 * W, 1.18 * H), p1=(33.0, 160.0, 0.92 * W, 0.99 * H),
               weight=lambda t: (0.14 + 0.45 * t ** 1.3) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t)),
               rot=(6.0, 2.0), seed=21, centre=(1.0 * W, 1.0 * H), ramp=(185.0, 85.0), gain=0.85,
               stops=[(0.0, "#C0304E"), (0.45, "#D9445A"), (0.8, "#EE7A62"), (1.0, "#F9B07E")],
               shadow=0.10, tint=0.45, relief=0.35, aura=("#F5A08A", 0.45, 140))
    return layers.light2(
        k, bg=[(0.0, L("#FFF9F3")), (0.5, L("#FEF1E8")), (1.0, L("#FCE6DA"))],
        fields=[("coral", (70.0, 120.0, 1.05 * W, 1.02 * H), 200, "#F28A6E", 0.55),
                ("coral", (60.0, 60.0, -0.05 * W, 1.12 * H), 220, "#F5A38C", 0.35)],
        ribbons=[rib], flip=True)


def mint(k):
    wt = lambda t: (0.25 + 0.55 * t ** 1.2) * (0.6 + 0.4 * math.cos(2 * math.pi * 4 * t))
    rib = _twist("green", MINT_ST, wt, MINT_DY, 75.0, 48.0,
                 dict(seed=31, gain=MINT_GAIN, blend=MINT_BLEND, amax=0.85, shadow=0.10, tint=0.6, relief=0.45, aura=("#7ED9B0", 0.65, 150)))
    return layers.light2(
        k, bg=[(0.0, L("#F4FAF7")), (0.45, L("#EAF6F0")), (1.0, L("#CDEEDD"))],
        fields=[("radial", 0.75, 1.0, 1.4, 0.55, "#62CD9E", 0.75), ("radial", 0.1, 1.05, 1.1, 0.40, "#9CCFF5", 0.45),
                ("radial", 0.5, 0.75, 1.0, 0.25, "#C9EEDC", 0.5)],
        ribbons=[rib], flip=True)


MINT_ST = [(0.0, "#3FAF92"), (0.45, "#1FA57E"), (0.8, "#2FB88C"), (1.0, "#7FDDB0")]
MINT_GAIN = 0.9
MINT_BLEND = "mix"
MINT_DY = -0.06

ART = {"bloom": bloom, "dusk": dusk, "dawn": dawn, "mint": mint}

LOWER = (0.35, 0.06)   # the open sky above 35% of the height stretches by 6% of it: the ribbons sit lower,
                       # clear of the lock screen's large clock, and their bottom 6% leaves the screen


def lower(img, top=LOWER[0], by=LOWER[1]):
    """Every row at or below `top` moves down by `by` (fractions of the height); the rows above it stretch
    to fill the gap. Above `top` there is only background and glow, so nothing visibly changes shape."""
    h = img.shape[0]
    y = np.arange(h, dtype=np.float64)
    a, b = top * h, (top + by) * h
    src = np.where(y < b, y * (a / b), y - (b - a))
    i = np.floor(src).astype(int)
    f = (src - i).astype(img.dtype)[:, None, None]
    j = np.minimum(i + 1, h - 1)
    return img[i] * (1 - f) + img[j] * f

if __name__ == "__main__":
    name, out = sys.argv[1], sys.argv[2]
    k = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    wp.finish(lower(ART[name](k)), out, grain=1.0, seed=7)
