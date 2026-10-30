#!/usr/bin/env python3
"""Render the ExpressiveOS boot animation frames.

Drawn from the ExpressiveOS logo (docs/assets/screenshots/logo.png) and Google Sans Flex.
Motion inspired by Loic's boot animation concept: the petals unfurl, a ring pulses out,
the wordmark pops in, the mark spins while booting, and a ripple plays when boot completes.

usage: render.py LOGO.png FONT.ttf OUTDIR [--only part0,part1,part2] [--dynamic]
Writes OUTDIR/desc.txt and OUTDIR/part{0,1,2}/img%05d.png (1080x1320, 8-bit RGB, 30 fps).
--dynamic draws the holiday copy instead: the same scene as 8-bit RGBA colour masks for
BootAnimation's dynamic colours (DYN_CHANNEL), which the phone colours in at boot.
Needs numpy and Pillow built with FreeType variable fonts and libraqm (kerning).
"""
import argparse, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1080, 1320, 30
BG = (0, 0, 0)                         # #000000, so the screen around the canvas is black too
CX, CY = 540.0, 588.0                  # pinwheel centre on the canvas
MARK_W = 456.0                         # mark width at rest
WORD = "ExpressiveOS"
WORD_BASE = 1010                       # baseline of the wordmark
WORD_W = 740                           # wordmark width at rest

# name: (first scene frame, frames, plays (0 = until boot completes), pause frames after each play).
# Rest frames are left to the pause, so the loop is 34 drawn + 20 held = 54 frames (1.8 s).
PARTS = {
    "part0": (0, 43, 1, 6),     # intro; ends at rest, held 6 frames
    "part1": (4, 34, 0, 20),    # one turn (scene frames 4-37, ends at rest), then 20 frames at rest
    "part2": (0, 26, 1, 0),     # ripple when boot completes; ends at rest
}
FLASH = 0.45                           # part2's flash at its peak: how far the wordmark goes to white

# --dynamic: BootAnimation's dynamic-colour shader (BootAnimationShaders.h) draws a pixel as
# r*color1 + g*color2 + b*color3 + a*color4, the colours from persist.bootanim.color1..4: the
# holiday's petal mids in the catalog's petal order (violet, blue, coral, green). So each channel
# is one petal's weight, and the background is all zeros. Where all four channels are 0.05 or more
# it draws grey instead, so no pixel may have all four above DYN_MASK_MAX (12/255 < 0.05 <= 13/255).
DYN_CHANNEL = {"purple": 0, "blue": 1, "coral": 2, "green": 3}
# desc.txt's start colours, drawn while the properties are empty: Bloom's petal mids (Evolver
# studio/Bloom.kt), in the same order
DYN_START = ("#AE69FC", "#417BFC", "#FD7771", "#4AD29D")
DYN_MASK_MAX = 12
DYN_SHADE = 0.62                       # a petal's deepest shade, as a fraction of its colour
DYN_WORD = 0.85                        # the wordmark at rest, as a fraction of its colours

# ---------------------------------------------------------------- easing
def clamp01(t): return max(0.0, min(1.0, t))
def ease_out_cubic(t): t = clamp01(t); return 1 - (1 - t) ** 3
def ease_in_out_cubic(t):
    t = clamp01(t); return 4 * t ** 3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2
def ease_out_back(t, s=1.7):
    t = clamp01(t) - 1; return 1 + (s + 1) * t ** 3 + s * t ** 2
def smooth(t): t = clamp01(t); return t * t * (3 - 2 * t)
def bump(t):                           # 0 -> 1 -> 0 over [0, 1], smooth ends
    t = clamp01(t); return math.sin(math.pi * t) ** 2

# ---------------------------------------------------------------- the mark, split into petals
class Mark:
    """The logo keyed off its background and split into its four petals by hue."""
    # petal order is clockwise from the top right, which is also the unfurl order
    NAMES = ["blue", "green", "coral", "purple"]

    def __init__(self, path, dynamic=False):
        src = np.asarray(Image.open(path).convert("RGB")).astype(np.float64)
        bgc = np.median(np.concatenate([src[:40].reshape(-1, 3), src[-40:].reshape(-1, 3)]), axis=0)
        a = np.clip((np.abs(src - bgc).max(2) - 6) / 24, 0, 1)
        fg = np.where(a[..., None] > 0, (src - (1 - a[..., None]) * bgc) / np.maximum(a[..., None], 1e-6), 0)
        fg = np.clip(fg, 0, 255)
        # hole centre: the dark pinwheel centre, near the middle of the image
        h0, w0 = a.shape
        cy0, cx0 = h0 // 2, w0 // 2
        win = a[cy0 - 100:cy0 + 100, cx0 - 100:cx0 + 100]
        yy, xx = np.where(win < 0.5)
        self.pivot_src = (xx.mean() + cx0 - 100, yy.mean() + cy0 - 100)
        ys, xs = np.where(a > 0.5)
        self.src_w = xs.max() - xs.min() + 1
        self.rest_scale = MARK_W / self.src_w            # source -> canvas at rest
        base_scale = self.rest_scale * 1.2               # layers kept at the largest size drawn
        # hue weights, soft over +-8 degrees at each boundary
        r, g, b = fg[..., 0] / 255, fg[..., 1] / 255, fg[..., 2] / 255
        mx, mn = fg.max(2) / 255, fg.min(2) / 255
        d = mx - mn + 1e-9
        hue = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60
        bounds = {"coral": (320, 50), "green": (50, 190), "blue": (190, 250), "purple": (250, 320)}
        def member(lo, hi, soft=8.0):
            # soft indicator of hue in [lo, hi) on the colour circle; neighbours sum to 1
            span = (hi - lo) % 360
            off = (hue - lo) % 360
            sd = np.where(off < span, np.minimum(off, span - off), -np.minimum(off - span, 360 - off))
            return np.clip(0.5 + sd / (2 * soft), 0, 1)
        ws = {k: member(*bounds[k]) for k in self.NAMES}
        tot = sum(ws.values()) + 1e-9
        self.base_scale = base_scale
        size = (round(w0 * base_scale), round(h0 * base_scale))
        self.dynamic = dynamic
        if dynamic:
            share = {k: ws[k] / tot for k in self.NAMES}
            # The coral petal's tail sweeps through yellow into the green petal. One colour per
            # petal would make that a hard seam, so coral hands over to green across the whole
            # sweep (hues 40-140) instead
            cg = share["coral"] + share["green"]
            t = np.clip((np.where(hue >= 250, hue - 360, hue) - 40) / 100, 0, 1)
            share["coral"], share["green"] = cg * (1 - t), cg * t
            shares = self.dynamic_shares(src, bgc, a, share)
        self.layers = {}
        for k in self.NAMES:
            if dynamic:
                ak, wk = shares[k]
                z = np.zeros_like(ak)
                rgba = np.dstack([wk * 255, z, z, ak * 255])          # premultiplied; R is the weight
            else:
                ak = a * ws[k] / tot
                rgba = np.dstack([fg * ak[..., None], ak * 255])      # premultiplied
            im = Image.fromarray(np.clip(np.rint(rgba), 0, 255).astype(np.uint8), "RGBa")
            self.layers[k] = im.resize(size, Image.LANCZOS)
        self.pivot = (self.pivot_src[0] * base_scale, self.pivot_src[1] * base_scale)

    @staticmethod
    def dynamic_shares(src, bgc, a, share):
        """--dynamic: each petal's (coverage, weight) per source pixel. The weight is the logo's
        own shading: the petal's luminance from its deepest to its brightest 3% mapped to
        DYN_SHADE..1. Along the outline a pixel is part background, which that would read as
        dark petal (and its hue as a petal's), so within 2 px of the background the petal and
        shade come from the pixels further in, and the coverage from where the pixel's luminance
        lies between the background's and theirs."""
        luma = np.array([0.2126, 0.7152, 0.0722])
        lum = src @ luma
        inside = a >= 1
        for _ in range(2):
            inside = inside & np.all([np.roll(inside, d, ax) for ax in (0, 1) for d in (-1, 1)], 0)
        fields = []
        for k, wk in share.items():
            lo, hi = np.percentile(lum[inside & (wk > 0.5)], [3, 97])
            fields += [wk, wk * (DYN_SHADE + (1 - DYN_SHADE) * np.clip((lum - lo) / (hi - lo), 0, 1))]
        fields = np.dstack(fields + [lum])
        # fill outwards from inside, a ring of pixels at a time: each takes its filled neighbours' mean
        done = inside.astype(np.float64)
        fields[~inside] = 0
        for _ in range(6):
            sums = sum(np.roll(fields, d, ax) for ax in (0, 1) for d in (-1, 1))
            n = sum(np.roll(done, d, ax) for ax in (0, 1) for d in (-1, 1))
            new = (done == 0) & (n > 0)
            fields[new] = sums[new] / n[new][:, None]
            done[new] = 1
        bl = bgc @ luma
        cov = np.where(inside, 1, np.clip((lum - bl) / np.maximum(fields[..., -1] - bl, 1), 0, 1))
        cov = np.where((a > 0) & (done > 0), cov, 0)
        return {k: (cov * fields[..., 2 * i], cov * fields[..., 2 * i + 1]) for i, k in enumerate(share)}

    def draw(self, acc, pose):
        """Composite petals (premultiplied) onto acc (H, W, 4 float, premultiplied); a dynamic
        mark's acc is (H, W, 5): each petal's weight in its DYN_CHANNEL, then coverage.
        pose: {name: (rot_deg, scale, alpha)} with scale relative to rest."""
        for k in self.NAMES:
            rot, sc, al = pose[k]
            if al <= 0.002 or sc <= 0.01:
                continue
            s = sc * self.rest_scale / self.base_scale        # base layer -> canvas
            th = math.radians(rot)
            c, si = math.cos(th), math.sin(th)
            # canvas (x, y) -> layer (u, v): inverse of rotate(theta) * scale(s) about the pivot
            a_, b_ = c / s, si / s
            d_, e_ = -si / s, c / s
            px, py = self.pivot
            coeffs = (a_, b_, px - a_ * CX - b_ * CY, d_, e_, py - d_ * CX - e_ * CY)
            out = self.layers[k].transform((W, H), Image.AFFINE, coeffs, resample=Image.BICUBIC)
            arr = np.asarray(out, dtype=np.float32)
            # 'RGBa' data is premultiplied. The petals split the logo's pixels between them, so
            # they add up (at rest the sum is the logo exactly); clamp where moving petals overlap.
            if self.dynamic:
                acc[..., DYN_CHANNEL[k]] += arr[..., 0] * al
                acc[..., 4] += arr[..., 3] * al
            else:
                acc += arr * al
        over = np.maximum(acc[..., -1:] / 255, 1)
        acc /= over


# ---------------------------------------------------------------- the wordmark
class Wordmark:
    STOPS = np.array([[0xc1, 0x78, 0xfd], [0x8a, 0x6c, 0xf9], [0x3f, 0x79, 0xfd],
                      [0x34, 0xcb, 0x98], [0xfd, 0xa0, 0x7c], [0xfd, 0x57, 0x6e]], np.float32)
    # --dynamic: each stop as the petal whose colour it is (violet, violet, blue, green, coral, coral)
    DYN_STOPS = np.eye(4, dtype=np.float32)[[0, 0, 1, 3, 2, 2]]

    def __init__(self, font_path):
        size = 200
        while True:
            f = ImageFont.truetype(font_path, size, layout_engine=ImageFont.Layout.RAQM)
            f.set_variation_by_axes([72, 100, 720, 0, 100, 0])   # opsz wdth wght GRAD ROND slnt
            wlen = f.getlength(WORD)
            if wlen <= WORD_W:
                break
            size -= 2
        self.font, self.size = f, size
        x0 = (W - wlen) / 2
        self.glyphs = []                 # (mask L image, left x, top y, centre x, centre y)
        for i, ch in enumerate(WORD):
            x = x0 + f.getlength(WORD[:i])
            bb = f.getbbox(ch, anchor="ls")
            pad = 16
            gw, gh = bb[2] - bb[0] + 2 * pad, bb[3] - bb[1] + 2 * pad
            m = Image.new("L", (gw, gh), 0)
            ImageDraw.Draw(m).text((pad - bb[0], pad - bb[1]), ch, font=f, fill=255, anchor="ls")
            left, top = x + bb[0] - pad, WORD_BASE + bb[1] - pad
            self.glyphs.append((m, left, top, left + gw / 2, WORD_BASE - size * 0.36))
        self.x0, self.x1 = x0, x0 + wlen
        t = np.clip((np.arange(W, dtype=np.float32) - x0) / (wlen), 0, 1) * (len(self.STOPS) - 1)
        i = np.minimum(t.astype(int), len(self.STOPS) - 2)
        fr = (t - i)[:, None]
        self.grad = self.STOPS[i] * (1 - fr) + self.STOPS[i + 1] * fr       # (W, 3)
        self.dyn_grad = self.DYN_STOPS[i] * (1 - fr) + self.DYN_STOPS[i + 1] * fr   # (W, 4)
        # a gentle top-to-bottom lift, like the mark's lighting
        yy = np.arange(H, dtype=np.float32)
        self.lift = np.clip((WORD_BASE - yy) / (size * 0.75), 0, 1)[:, None] * 0.18

    def coverage(self, states):
        """states: per letter (scale, alpha, dy). The letters' coverage, (H, W) in 0-1."""
        cov = np.zeros((H, W), np.float32)
        for (m, left, top, gcx, gcy), (sc, al, dy) in zip(self.glyphs, states):
            if al <= 0.002 or sc <= 0.01:
                continue
            # scale the glyph about its own optical centre
            inv = 1 / sc
            ox, oy = gcx - left, gcy - top          # centre in glyph coords
            coeffs = (inv, 0, ox - inv * gcx, 0, inv, oy - inv * (gcy + dy))
            g = m.transform((W, H), Image.AFFINE, coeffs, resample=Image.BICUBIC)
            ga = np.asarray(g, np.float32) / 255 * al
            cov = 1 - (1 - cov) * (1 - ga)
        return cov

    def draw(self, img, states, flash=0.0):
        """states: per letter (scale, alpha, dy). img: (H, W, 3) float, straight."""
        cov = self.coverage(states)
        col = self.grad[None, :, :] + (255 - self.grad[None, :, :]) * self.lift[:, :, None]
        col = col + (255 - col) * flash
        img *= (1 - cov[..., None])
        img += col * cov[..., None]

    def draw_dynamic(self, w, states, flash=0.0):
        """As draw, onto petal weights w (H, W, 4, 0-255). No white lift: the letters are at
        DYN_WORD, and the flash brightens them to their full colours instead of whitening them."""
        cov = self.coverage(states)
        col = self.dyn_grad[None, :, :] * (255 * (DYN_WORD + (1 - DYN_WORD) * flash / FLASH))
        w *= (1 - cov[..., None])
        w += col * cov[..., None]


# ---------------------------------------------------------------- canvas pieces
yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
RR = np.hypot(xx - CX, yy - CY)
BGA = np.array(BG, np.float32)
HALO_C = np.array([22, 22, 22], np.float32)   # neutral: a tinted lift reads as a coloured background

def halo(strength):
    # soft lift behind the mark, gone by r = 480
    t = np.clip((RR - 150) / (480 - 150), 0, 1)
    w = (1 - t * t * (3 - 2 * t)) * strength
    return BGA + (HALO_C - BGA) * w[..., None]

def ring(img, r, width, amp, color=(236, 228, 255)):
    if amp <= 0.002: return
    g = np.exp(-((RR - r) / width) ** 2) * amp
    col = np.array(color, np.float32)
    img += (col - img) * g[..., None]

def bloom(img, petal_acc, amount):
    """Colour glow from the mark: blurred petals added softly."""
    if amount <= 0.002: return
    small = Image.fromarray(np.clip(petal_acc[..., :3], 0, 255).astype(np.uint8), "RGB").resize((W // 4, H // 4), Image.BILINEAR)
    small = small.filter(ImageFilter.GaussianBlur(14))
    big = np.asarray(small.resize((W, H), Image.BICUBIC), np.float32)
    fade = np.clip(1 - (RR - 300) / 180, 0, 1)[..., None]     # nothing past r = 480
    img += big * amount * fade

# --dynamic: no halo (a grey lift is the shader's grey, and its tail would turn coloured where it
# drops below the threshold) and no white: the rings take the petals' colours by quadrant, each
# petal's around its own diagonal, blending over about 20 degrees where two meet
_quad = None
def quadrants():
    global _quad
    if _quad is None:
        ang = np.arctan2(yy - CY, xx - CX)
        centre = {"purple": -0.75 * math.pi, "blue": -0.25 * math.pi, "green": 0.25 * math.pi, "coral": 0.75 * math.pi}
        q = np.zeros((H, W, 4), np.float32)
        for k, c in centre.items():
            q[..., DYN_CHANNEL[k]] = np.maximum(np.cos(ang - c), 0) ** 8
        _quad = q / q.sum(2, keepdims=True)
    return _quad

def ring_dynamic(w, r, width, amp):
    if amp <= 0.002: return
    g = np.exp(-((RR - r) / width) ** 2) * amp
    w += (quadrants() * 255 - w) * g[..., None]

def bloom_dynamic(w, petal_acc, amount):
    """bloom() for each petal's weight: its glow is in its own colour."""
    if amount <= 0.002: return
    fade = np.clip(1 - (RR - 300) / 180, 0, 1)
    for c in range(4):
        small = Image.fromarray(np.clip(petal_acc[..., c], 0, 255).astype(np.uint8), "L").resize((W // 4, H // 4), Image.BILINEAR)
        small = small.filter(ImageFilter.GaussianBlur(14))
        big = np.asarray(small.resize((W, H), Image.BICUBIC), np.float32)
        w[..., c] += big * amount * fade

def dynamic_mask(w):
    """The weights as RGBA bytes. Where all four channels would reach the shader's grey, the
    smallest goes down to DYN_MASK_MAX. Returns the image and how many pixels that took."""
    m = np.clip(np.rint(w), 0, 255).astype(np.uint8)
    grey = (m > DYN_MASK_MAX).all(2)
    if grey.any():
        px = m[grey]
        px[np.arange(len(px)), px.argmin(1)] = DYN_MASK_MAX
        m[grey] = px
    return Image.fromarray(m, "RGBA"), int(grey.sum())

# ---------------------------------------------------------------- poses
REST_PETALS = {k: (0.0, 1.0, 1.0) for k in Mark.NAMES}
REST_LETTERS = [(1.0, 1.0, 0.0)] * len(WORD)

def state(part, f):
    """The scene at frame f (float, for motion blur) of a part."""
    s = dict(rot=0.0, scale=1.0, petals=dict(REST_PETALS), letters=list(REST_LETTERS),
             halo=1.0, bloom=0.30, rings=[], flash=0.0)
    if part == "part0":
        # petals unfurl clockwise: each swings in from -110 degrees and grows from the centre
        petals = {}
        for i, k in enumerate(Mark.NAMES):
            t = (f - 2 - 3.2 * i) / 13.0
            if t <= 0:
                petals[k] = (0, 0, 0)
                continue
            rot = -110 * (1 - ease_out_cubic(t))
            sc = 0.30 + 0.70 * ease_out_back(t, 1.3)
            al = clamp01(t * 3.0)
            petals[k] = (rot, sc, al)
        s["petals"] = petals
        s["halo"] = smooth((f - 2) / 22)
        s["bloom"] = 0.30 * smooth((f - 6) / 20) + 0.25 * bump((f - 14) / 16)
        # ring pulse as the last petal lands
        t = (f - 17) / 14
        if 0 <= t <= 1:
            s["rings"] = [(140 + 230 * ease_out_cubic(t), 5 + 6 * t, 0.85 * (1 - t) ** 1.5)]
        # letters pop in, left to right
        letters = []
        for i in range(len(WORD)):
            t = (f - 19 - 1.25 * i) / 9.0
            if t <= 0:
                letters.append((0, 0, 0)); continue
            letters.append((0.45 + 0.55 * ease_out_back(t, 2.2), clamp01(t * 2.5), 22 * (1 - ease_out_cubic(t))))
        s["letters"] = letters
    elif part == "part1":
        # one clockwise turn with a swell (the hold before it is the previous part's pause)
        t = (f - 3) / 33
        if 0 <= t <= 1:
            s["rot"] = 360 * ease_in_out_cubic(t)
            s["scale"] = 1 + 0.10 * bump(t)
            s["bloom"] = 0.30 + 0.20 * bump(t)
            s["halo"] = 1 + 0.25 * bump(t)
    elif part == "part2":
        # ripple when boot completes, then settle to rest
        s["scale"] = 1 + 0.14 * bump(clamp01(f / 24)) ** 0.8
        s["flash"] = FLASH * bump(clamp01((f - 1) / 16))
        s["bloom"] = 0.30 + 0.35 * bump(clamp01(f / 22))
        s["halo"] = 1 + 0.35 * bump(clamp01(f / 24))
        rings = []
        for d, amp in ((0, 0.9), (5, 0.45)):
            tt = (f - d) / 20
            if 0 <= tt <= 1:
                rings.append((200 + 270 * ease_out_cubic(tt), 6 + 10 * tt, amp * (1 - tt) ** 1.4))
        s["rings"] = rings
    return s

def compose_petals(st):
    pose = {}
    for k, (rot, sc, al) in st["petals"].items():
        pose[k] = (rot + st["rot"], sc * st["scale"], al)
    return pose

def angular_speed(part, f):
    a = state(part, f - 0.5); b = state(part, f + 0.5)
    sp = 0.0
    for k in Mark.NAMES:
        ra = a["petals"][k][0] + a["rot"]; rb = b["petals"][k][0] + b["rot"]
        sp = max(sp, abs(rb - ra))
    return sp

def draw_mark(mark, part, f):
    # motion blur: average the mark over half a frame of shutter when it moves fast
    deg = angular_speed(part, f)
    px = math.radians(deg) * 260          # travel at the petal tips, px per frame
    n = int(min(24, max(1, math.ceil(px * 0.5 / 3))))
    ch = 5 if mark.dynamic else 4
    acc_sum = np.zeros((H, W, ch), np.float32)
    for j in range(n):
        ff = f + ((j + 0.5) / n - 0.5) * 0.5 if n > 1 else f
        sj = state(part, ff)
        acc = np.zeros((H, W, ch), np.float32)
        mark.draw(acc, compose_petals(sj))
        acc_sum += acc
    return acc_sum / n

def render_frame(mark, word, part, f):
    st = state(part, f)
    img = halo(st["halo"])
    acc = draw_mark(mark, part, f)
    bloom(img, acc, st["bloom"])
    img *= (1 - acc[..., 3:4] / 255)
    img += acc[..., :3]
    for (r, w_, amp) in st["rings"]:
        ring(img, r, w_, amp)
    word.draw(img, st["letters"], st["flash"])
    return Image.fromarray(np.clip(np.rint(img), 0, 255).astype(np.uint8), "RGB")

def render_dynamic_frame(mark, word, part, f):
    """render_frame for --dynamic, in petal weights (0-255) instead of colours, on zeros.
    Returns the RGBA mask and how many pixels dynamic_mask lowered."""
    st = state(part, f)
    w = np.zeros((H, W, 4), np.float32)
    acc = draw_mark(mark, part, f)
    bloom_dynamic(w, acc, st["bloom"])
    w *= (1 - acc[..., 4:5] / 255)
    w += acc[..., :4]
    for (r, w_, amp) in st["rings"]:
        ring_dynamic(w, r, w_, amp)
    word.draw_dynamic(w, st["letters"], st["flash"])
    return dynamic_mask(w)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("logo"); ap.add_argument("font"); ap.add_argument("out")
    ap.add_argument("--only", default=",".join(PARTS), help="parts to render (default all)")
    ap.add_argument("--dynamic", action="store_true", help="the holiday copy: colour masks")
    args = ap.parse_args()
    mark = Mark(args.logo, args.dynamic)
    word = Wordmark(args.font)
    print(f"wordmark: {word.size}px, x {word.x0:.0f}-{word.x1:.0f}", file=sys.stderr)
    os.makedirs(args.out, exist_ok=True)
    # dynamic_colors must be the second line. Transition 0 0: only part0's first frame (black)
    # is drawn in the start colours, every later one in the properties' colours
    dyn = f"dynamic_colors part0 {' '.join(DYN_START)} 0 0\n" if args.dynamic else ""
    desc = f"{W} {H} {FPS}\n" + dyn + "".join(
        f"c {plays} {pause} {name} #{BG[0]:02x}{BG[1]:02x}{BG[2]:02x}\n"
        for name, (_, _, plays, pause) in PARTS.items())
    tmp = os.path.join(args.out, f".desc.txt.{os.getpid()}")    # parts may render in parallel
    with open(tmp, "w", newline="\n") as fh:
        fh.write(desc)
    os.replace(tmp, os.path.join(args.out, "desc.txt"))
    for part in args.only.split(","):
        first, count, _, _ = PARTS[part]
        d = os.path.join(args.out, part)
        os.makedirs(d, exist_ok=True)
        lowered = 0
        for i in range(count):
            if args.dynamic:
                im, n = render_dynamic_frame(mark, word, part, float(first + i))
                if n:
                    print(f"{part}/img{i:05d}.png: {n} pixels lowered out of the shader's grey", file=sys.stderr)
                lowered += n
            else:
                im = render_frame(mark, word, part, float(first + i))
            im.save(os.path.join(d, f"img{i:05d}.png"), optimize=True)
        print(f"{part}: {count} frames" + (f", {lowered} pixels lowered out of the shader's grey" if args.dynamic else ""),
              file=sys.stderr)


if __name__ == "__main__":
    main()
