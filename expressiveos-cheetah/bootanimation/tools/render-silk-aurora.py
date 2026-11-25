#!/usr/bin/env python3
"""Render ExpressiveOS's 'Silk Aurora' boot animation frames (1080x1320, 30 fps, 8-bit RGB).

Three-part on-device Android boot animation aligned with ExpressiveOS Bloom colours and
Google Sans Flex Rounded (wght 720, ROND 100, opsz 72):
  part0 (160 frames, c 1 0): 4-petal Bloom filament trace -> diagonal plasma convergence ->
                             chromatic shockwaves & 3D Bloom mark unfurl -> lockup glide with
                             "Expressive" wake -> full-width 4-petal Silk Aurora Wave into
                             centered "ExpressiveOS", handing off into the periodic aurora veil.
  part1 ( 36 frames, c 0 0): Seamless 1.2s periodic loop of "ExpressiveOS" over a gossamer
                             4-petal Silk Aurora veil and twinkling Bloom embers while booting.
  part2 ( 26 frames, c 1 0): Boot-complete Bloom chord shimmer and double ripple, settling to
                             clean rest on #000000 OLED black.

Every frame tapers strictly to #000000 at all four canvas edges so the 1080x1320 canvas sits
seamlessly on wider or taller screens (husky, kodiak, grizzly, cubs, yogi).

usage: render-silk-aurora.py LOGO.png FONT.ttf OUTDIR [--only part0,part1,part2]
"""
import argparse
import concurrent.futures
import math
import os
import re
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 1080, 1320, 30
CX0, CY0 = 540.0, 660.0
BG = (0, 0, 0)
WORD_W = 740.0  # matches render.py's wordmark width on the 1080-wide canvas

PARTS = {
    "part0": (160, 1, 0),  # 5.33s intro, plays once
    "part1": (36,  0, 0),  # 1.20s seamless loop until boot completes
    "part2": (26,  1, 0),  # 0.87s outro when boot completes
}
PART_SEED_BASE = {"part0": 10000, "part1": 20000, "part2": 30000}

PALETTE_HEX = {
    "violet": ("#F3B1FC", "#AE69FC", "#6B2BBB"),
    "blue":   ("#76BCFB", "#417BFC", "#1842D1"),
    "green":  ("#ACEFB3", "#4AD29D", "#18A07C"),
    "coral":  ("#FDCF8E", "#FD7771", "#D33952"),
}
PETAL_ORDER = ["violet", "blue", "green", "coral"]

PETAL_SVG_PATHS = {
    "violet": (
        "M31.6,49.85C28.87,49.52 26.32,47.15 25.51,44.19C25.23,43.2 25.16,41.28 25.35,40.16"
        "C26.33,34.55 32.26,28.52 38.55,26.75C44.99,24.94 50.8,27.42 54.27,33.45"
        "C55.31,35.26 56.3,37.46 56.93,39.36C58.19,43.13 58.06,44.72 56.44,45.52"
        "C56.08,45.69 55.97,45.71 54.74,45.71C53.6,45.72 53.34,45.74 52.84,45.89"
        "C51.77,46.22 51.24,46.2 50,45.8C47.56,45.01 45.82,45.04 43.08,45.94"
        "C41.94,46.31 37.74,47.96 35.12,49.06C33.11,49.91 32.74,49.99 31.6,49.85Z"
    ),
    "blue": (
        "M62.35,60.52C60.86,59.94 60.28,58.18 61.09,56.66C61.97,55 61.95,55.07 61.94,54.39"
        "C61.94,53.71 61.75,53.23 61.16,52.41C60.56,51.57 60.57,51.6 60.5,47.88"
        "C60.46,45.46 60.42,44.32 60.33,43.73C59.87,40.75 59.1,38.15 57.9,35.55"
        "C56.63,32.83 56.75,33.18 56.75,32.18C56.75,31.35 56.77,31.25 57,30.73"
        "C57.97,28.49 60.55,26.67 63.39,26.24C65.26,25.95 67.78,26.18 69.65,26.8"
        "C75.86,28.85 81.88,36.14 82.53,42.42C83.02,47.07 81.24,50.72 76.9,54.01"
        "C73.74,56.39 68.69,59.03 64.85,60.3C63.89,60.61 62.85,60.71 62.35,60.52Z"
    ),
    "green": (
        "M63.53,81.74C60.09,81.23 56.93,79.33 54.29,76.21C52.72,74.36 52.52,73.67 52.99,71.81"
        "C53.29,70.61 53.71,68.27 54,66.21C54.36,63.6 54.55,63.12 55.63,62.02"
        "C56.91,60.72 58.07,60.74 59.55,62.11C61.1,63.54 61.79,63.63 64.71,62.75"
        "C67.6,61.88 71.14,60.29 74.5,58.34C76.14,57.39 76.48,57.27 77.26,57.31"
        "C78.93,57.41 81.03,59.31 81.98,61.6C84.14,66.78 81.64,73.45 75.82,78.01"
        "C71.94,81.05 67.64,82.36 63.53,81.74Z"
    ),
    "coral": (
        "M41.21,81.63C36.57,81.07 31.74,77.81 28.29,72.91C24.98,68.22 24.31,63.39 26.37,59"
        "C27.8,55.97 30.96,53.38 35.8,51.28C37.68,50.47 42.64,48.51 43.86,48.1"
        "C45.69,47.48 46.83,47.57 47.64,48.38C48.45,49.19 48.56,50.47 47.9,51.42"
        "C47.79,51.59 47.37,52 46.98,52.34C45.8,53.35 45.5,54.21 45.97,55.25"
        "C46.24,55.84 46.39,55.99 47.68,56.97C49.74,58.54 51.25,60.28 51.77,61.68"
        "C51.99,62.28 51.99,63.64 51.76,65.16C51.68,65.76 51.56,66.6 51.52,67.02"
        "C51.3,68.94 50.89,70.81 50.43,71.96C49.98,73.08 49.92,73.56 50.04,74.94"
        "C50.14,76.21 50.1,76.78 49.82,77.56C49.19,79.37 47.36,80.87 45.1,81.45"
        "C44.25,81.67 42.28,81.76 41.21,81.63Z"
    ),
}

PETAL_DIRS = {
    "violet": (-0.7071, -0.7071),
    "blue":   ( 0.7071, -0.7071),
    "green":  ( 0.7071,  0.7071),
    "coral":  (-0.7071,  0.7071),
}


def srgb_u8_to_lin(arr):
    x = np.asarray(arr, dtype=np.float32) / 255.0
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def hex_to_lin(h):
    h = h.lstrip("#")
    rgb = np.array([int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)], dtype=np.float32)
    return srgb_u8_to_lin(rgb)


# Precompute smooth canvas border fade so all 4 outer edges are strictly #000000 on wider screens
def _make_border_mask():
    margin_x, margin_y = 68.0, 96.0
    tx = np.minimum(np.arange(W, dtype=np.float32), (W - 1) - np.arange(W, dtype=np.float32)) / margin_x
    ty = np.minimum(np.arange(H, dtype=np.float32), (H - 1) - np.arange(H, dtype=np.float32)) / margin_y
    tx = np.clip(tx, 0.0, 1.0)
    ty = np.clip(ty, 0.0, 1.0)
    wx = tx * tx * (3.0 - 2.0 * tx)
    wy = ty * ty * (3.0 - 2.0 * ty)
    return (wy[:, None] * wx[None, :])[:, :, None].astype(np.float32)


BORDER_MASK = _make_border_mask()


def lin_to_srgb_u8(lin, seed=0):
    x = np.maximum(lin * BORDER_MASK, 0.0)
    s = np.where(x <= 0.0031308, x * 12.92, 1.055 * (np.maximum(x, 1e-8) ** (1.0 / 2.4)) - 0.055)
    s255 = s * 255.0
    active = s255.max(axis=2, keepdims=True) >= 0.65
    return np.where(active, np.clip(np.rint(s255), 0.0, 255.0), 0.0).astype(np.uint8)


PAL = {k: tuple(hex_to_lin(c) for c in v) for k, v in PALETTE_HEX.items()}


def clamp01(t):
    return 0.0 if t <= 0.0 else (1.0 if t >= 1.0 else float(t))


def smoothstep(a, b, x):
    t = clamp01((x - a) / (b - a))
    return t * t * (3.0 - 2.0 * t)


def ease_out_cubic(t):
    t = clamp01(t)
    return 1.0 - (1.0 - t) ** 3


def ease_in_cubic(t):
    t = clamp01(t)
    return t ** 3


def ease_in_out_cubic(t):
    t = clamp01(t)
    return 4.0 * t ** 3 if t < 0.5 else 1.0 - ((-2.0 * t + 2.0) ** 3) * 0.5


def ease_out_back(t, s=1.42):
    t = clamp01(t) - 1.0
    return 1.0 + (s + 1.0) * (t ** 3) + s * (t ** 2)


def bump(t):
    t = clamp01(t)
    return math.sin(math.pi * t) ** 2


def sample_svg_path(d, n=560):
    toks = re.findall(r"[MLCZ]|-?\d+(?:\.\d+)?", d)
    pts = []
    i = 0
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    while i < len(toks):
        op = toks[i]
        if op == "M":
            cur = (float(toks[i + 1]) - 54.0, float(toks[i + 2]) - 54.0)
            start = cur
            pts.append(cur)
            i += 3
        elif op == "L":
            cur = (float(toks[i + 1]) - 54.0, float(toks[i + 2]) - 54.0)
            pts.append(cur)
            i += 3
        elif op == "C":
            p0 = np.array(cur)
            p1 = np.array([float(toks[i + 1]) - 54.0, float(toks[i + 2]) - 54.0])
            p2 = np.array([float(toks[i + 3]) - 54.0, float(toks[i + 4]) - 54.0])
            p3 = np.array([float(toks[i + 5]) - 54.0, float(toks[i + 6]) - 54.0])
            for s in np.linspace(0.0, 1.0, 26)[1:]:
                u = 1.0 - s
                p = (u**3) * p0 + 3 * (u**2) * s * p1 + 3 * u * (s**2) * p2 + (s**3) * p3
                pts.append((float(p[0]), float(p[1])))
            cur = (float(p3[0]), float(p3[1]))
            i += 7
        elif op == "Z":
            pts.append(start)
            i += 1
        else:
            i += 1
    arr = np.array(pts, dtype=np.float32)
    radii = np.hypot(arr[:, 0], arr[:, 1])
    i0 = int(np.argmin(radii[:-1]))
    arr_closed = arr[:-1]
    arr_rot = np.concatenate([arr_closed[i0:], arr_closed[:i0], arr_closed[i0:i0 + 1]], axis=0)
    x, y = arr_rot[:, 0], arr_rot[:, 1]
    if np.sum(x[:-1] * y[1:] - x[1:] * y[:-1]) < 0:
        arr_rot = arr_rot[::-1]
    seg = np.hypot(np.diff(arr_rot[:, 0]), np.diff(arr_rot[:, 1]))
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    u = np.linspace(0.0, cum[-1], n, endpoint=False)
    xs = np.interp(u, cum, arr_rot[:, 0])
    ys = np.interp(u, cum, arr_rot[:, 1])
    out = np.stack([xs, ys], axis=1).astype(np.float32)
    dx = np.roll(out[:, 0], -1) - np.roll(out[:, 0], 1)
    dy = np.roll(out[:, 1], -1) - np.roll(out[:, 1], 1)
    ln = np.maximum(np.hypot(dx, dy), 1e-6)
    normals = np.stack([-dy / ln, dx / ln], axis=1).astype(np.float32)
    return out, normals


class ShadedBloomMark:
    def __init__(self, logo_path):
        src = np.asarray(Image.open(logo_path).convert("RGB"), dtype=np.float32)
        bgc = np.median(np.concatenate([src[:40].reshape(-1, 3), src[-40:].reshape(-1, 3)]), axis=0)
        a = np.clip((np.abs(src - bgc).max(axis=2) - 6.0) / 24.0, 0.0, 1.0)
        fg = np.where(a[..., None] > 0.0, (src - (1.0 - a[..., None]) * bgc) / np.maximum(a[..., None], 1e-6), 0.0)
        fg = np.clip(fg, 0.0, 255.0)

        ys, xs = np.where(a > 0.5)
        x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)
        self.src_span = float(max(x1 - x0, y1 - y0))
        self.cx_src = (x0 + x1) * 0.5
        self.cy_src = (y0 + y1) * 0.5

        r, g, b = fg[..., 0] / 255.0, fg[..., 1] / 255.0, fg[..., 2] / 255.0
        mx, mn = fg.max(axis=2) / 255.0, fg.min(axis=2) / 255.0
        d = mx - mn + 1e-9
        hue = np.where(mx == r, ((g - b) / d) % 6.0, np.where(mx == g, (b - r) / d + 2.0, (r - g) / d + 4.0)) * 60.0
        bounds = {"coral": (320.0, 50.0), "green": (50.0, 190.0), "blue": (190.0, 250.0), "violet": (250.0, 320.0)}

        def member(lo, hi, soft=8.0):
            span = (hi - lo) % 360.0
            off = (hue - lo) % 360.0
            sd = np.where(off < span, np.minimum(off, span - off), -np.minimum(off - span, 360.0 - off))
            return np.clip(0.5 + sd / (2.0 * soft), 0.0, 1.0)

        ws = {k: member(*bounds[k]) for k in PETAL_ORDER}
        tot = sum(ws.values()) + 1e-9

        target_span = 440.0
        pad = 64
        box_sz = int(target_span + 2 * pad)
        s = target_span / self.src_span
        self.base_span = target_span
        self.pivot = (box_sz * 0.5, box_sz * 0.5)
        fg_lin = srgb_u8_to_lin(fg)
        M = np.array([[s, 0.0, self.pivot[0] - s * self.cx_src],
                      [0.0, s, self.pivot[1] - s * self.cy_src]], dtype=np.float32)
        self.layers = {}
        for k in PETAL_ORDER:
            ak = (a * ws[k] / tot).astype(np.float32)
            premult = np.dstack([fg_lin * ak[..., None], ak])
            self.layers[k] = cv2.warpAffine(
                premult, M, (box_sz, box_sz),
                flags=cv2.INTER_AREA, borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0)
            )

    def composite_pose(self, cx, cy, mark_w, petals_pose):
        max_sc = max((sc for (_, sc, al, _, _) in petals_pose.values() if al > 0.002), default=0.0)
        if max_sc <= 0.005:
            return None
        rad = int(math.ceil(mark_w * max_sc * 0.85)) + 24
        x0 = max(0, int(cx - rad))
        y0 = max(0, int(cy - rad))
        x1 = min(W, int(cx + rad))
        y1 = min(H, int(cy + rad))
        if x1 <= x0 or y1 <= y0:
            return None
        rw, rh = x1 - x0, y1 - y0
        acc = np.zeros((rh, rw, 4), dtype=np.float32)
        px, py = self.pivot
        for k in PETAL_ORDER:
            rot_deg, sc, al, dx, dy = petals_pose[k]
            if al <= 0.002 or sc <= 0.005:
                continue
            s = (mark_w * sc) / self.base_span
            th = math.radians(rot_deg)
            cs, sn = math.cos(th) * s, math.sin(th) * s
            tcx, tcy = cx + dx - x0, cy + dy - y0
            M = np.array([
                [cs, -sn, tcx - cs * px + sn * py],
                [sn,  cs, tcy - sn * px - cs * py],
            ], dtype=np.float32)
            warped = cv2.warpAffine(
                self.layers[k], M, (rw, rh),
                flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0)
            )
            acc += warped * float(al)
        acc /= np.maximum(acc[..., 3:4], 1.0)
        return x0, y0, acc


class FlexWordmark:
    WORD = "ExpressiveOS"
    STOPS_SRGB = np.array([
        [0xC1, 0x78, 0xFD],
        [0x8A, 0x6C, 0xF9],
        [0x3F, 0x79, 0xFD],
        [0x34, 0xCB, 0x98],
        [0xFD, 0xA0, 0x7C],
        [0xFD, 0x57, 0x6E],
    ], dtype=np.float32)

    def __init__(self, font_path):
        size = 180
        while True:
            f = ImageFont.truetype(font_path, size, layout_engine=ImageFont.Layout.RAQM)
            f.set_variation_by_axes([72, 100, 720, 0, 100, 0])
            wlen = float(f.getlength(self.WORD))
            if wlen <= WORD_W:
                break
            size -= 2
        self.font = f
        self.size = size
        self.full_w = wlen
        self.expr_w = float(f.getlength("Expressive"))
        self.cap_h = size * 0.71
        self.base_y = CY0 + self.cap_h * 0.48
        self.final_x0 = (W - self.full_w) * 0.5

        # Lockup geometry inside 1080px width: [Mark (176px)] + 32px gap + ["Expressive" (~598px)] = ~806px wide
        self.lockup_mark_w = 176.0
        gap = 32.0
        total_lockup_w = self.lockup_mark_w + gap + self.expr_w
        lockup_left = CX0 - total_lockup_w * 0.5
        self.lockup_mark_cx = lockup_left + self.lockup_mark_w * 0.5
        self.lockup_dx = (lockup_left + self.lockup_mark_w + gap) - self.final_x0

        self.glyphs = []
        pad = 16
        for i, ch in enumerate(self.WORD):
            gx = self.final_x0 + float(f.getlength(self.WORD[:i]))
            bb = f.getbbox(ch, anchor="ls")
            gw, gh = bb[2] - bb[0] + 2 * pad, bb[3] - bb[1] + 2 * pad
            m = Image.new("L", (gw, gh), 0)
            ImageDraw.Draw(m).text((pad - bb[0], pad - bb[1]), ch, font=f, fill=255, anchor="ls")
            mask = np.asarray(m, dtype=np.float32) / 255.0
            left, top = gx + bb[0] - pad, self.base_y + bb[1] - pad
            self.glyphs.append((ch, mask, left, top, left + gw * 0.5, self.base_y - self.cap_h * 0.5))

        yy = np.arange(H, dtype=np.float32)
        self.lift = np.clip((self.base_y - yy) / (size * 0.76), 0.0, 1.0)[:, None] * 0.18

    def render_mask_and_color(self, glyph_states, dx_shift, color_mix_bloom,
                              wave_crest_x=None, wave_amp=0.0, sheen_x=None, flash_uniform=0.0):
        y_top = max(0, int(self.base_y - self.size * 1.4))
        y_bot = min(H, int(self.base_y + self.size * 0.7))
        bh = y_bot - y_top
        cov = np.zeros((bh, W), dtype=np.float32)

        for (_, mask, left, top, gcx, gcy), (sc, al, dy) in zip(self.glyphs, glyph_states):
            if al <= 0.002 or sc <= 0.01:
                continue
            tcx, tcy = gcx + dx_shift, gcy + dy
            ox, oy = gcx - left, gcy - top
            M = np.array([
                [sc, 0.0, tcx - sc * ox],
                [0.0, sc, (tcy - y_top) - sc * oy],
            ], dtype=np.float32)
            warped = cv2.warpAffine(mask, M, (W, bh), flags=cv2.INTER_LINEAR,
                                    borderMode=cv2.BORDER_CONSTANT, borderValue=0.0)
            ga = warped * float(al)
            cov = 1.0 - (1.0 - cov) * (1.0 - ga)

        if cov.max() <= 0.002:
            return None

        xs = np.arange(W, dtype=np.float32) - dx_shift
        u = np.clip((xs - self.final_x0) / max(self.full_w, 1.0), 0.0, 1.0) * 5.0
        idx = np.minimum(u.astype(np.int32), 4)
        fr = (u - idx)[:, None]
        vivid_srgb = self.STOPS_SRGB[idx] * (1.0 - fr) + self.STOPS_SRGB[idx + 1] * fr
        lift_band = self.lift[y_top:y_bot]
        vivid_2d = vivid_srgb[None, :, :] + (255.0 - vivid_srgb[None, :, :]) * lift_band[:, :, None]

        pearl_base = np.array([244.0, 241.0, 255.0], dtype=np.float32)[None, None, :]
        pearl_2d = pearl_base * 0.72 + vivid_2d * 0.28
        col_srgb = pearl_2d * (1.0 - color_mix_bloom) + vivid_2d * color_mix_bloom
        word_lin = srgb_u8_to_lin(col_srgb)

        flash_x = np.full((1, W, 1), float(flash_uniform), dtype=np.float32)
        if wave_crest_x is not None and wave_amp > 0.002:
            xs_scr = np.arange(W, dtype=np.float32)[None, :, None]
            flash_x += wave_amp * np.exp(-(((xs_scr - wave_crest_x) / 95.0) ** 2))
        if sheen_x is not None:
            xs_scr = np.arange(W, dtype=np.float32)[None, :, None]
            flash_x += 0.26 * np.exp(-(((xs_scr - sheen_x) / 115.0) ** 2))

        word_lin_lit = word_lin + flash_x * np.array([1.0, 0.98, 1.05], dtype=np.float32)
        glow_emit = word_lin * cov[..., None] * (0.24 + 0.80 * flash_x)
        return y_top, y_bot, cov, word_lin_lit, glow_emit


class IntroParticleSystem:
    """Closed-form intro particles for part0 (0.00s - 5.25s)."""

    def __init__(self, lockup_mark_cx):
        rng = np.random.default_rng(20261125)
        self.items = []

        # 1. Diagonal plasma convergence sparks (1.05s - 1.75s)
        for i in range(110):
            t0 = (1.05 + rng.random() * 0.10) if i < 55 else (1.15 + rng.random() * 0.55)
            p_name = PETAL_ORDER[i % 4]
            if rng.random() < 0.58:
                dx, dy = PETAL_DIRS[p_name]
                ang = math.atan2(dy, dx) + rng.normal(0.0, 0.36)
            else:
                ang = rng.random() * 2.0 * math.pi
            spd = 260.0 + rng.random() * 540.0
            col = PAL[p_name][0 if rng.random() < 0.65 else 1] * (2.0 + rng.random() * 1.4)
            self.items.append((
                t0, 0.35 + rng.random() * 0.38,
                CX0 + rng.normal(0, 12), CY0 + rng.normal(0, 12),
                math.cos(ang) * spd, math.sin(ang) * spd,
                2.8, 14.0, 7.5 + rng.random() * 5.0, 4.5, rng.random() * 6.28,
                col, "streak", 1.7 + rng.random() * 1.4, 0.0, 0.0, i % 4
            ))

        # 2. 3D Bloom detonation (1.85s): radial streaks + mini Bloom petals outside r_init >= 76px
        for i in range(135):
            t0 = 1.85 + rng.random() * 0.09
            p_idx = i % 4
            p_name = PETAL_ORDER[p_idx]
            dx, dy = PETAL_DIRS[p_name]
            ang = math.atan2(dy, dx) + rng.normal(0.0, 0.62)
            is_petal = (i % 4 == 0 and i < 112)
            spd = (240.0 + rng.random() * 420.0) if is_petal else (340.0 + rng.random() * 640.0)
            life = (0.78 + rng.random() * 0.55) if is_petal else (0.55 + rng.random() * 0.62)
            col = PAL[p_name][int(rng.integers(0, 2))] * (1.65 if is_petal else 2.4)
            sz = (0.14 + rng.random() * 0.11) if is_petal else (1.7 + rng.random() * 1.7)
            r_init = 76.0 + rng.random() * 28.0
            self.items.append((
                t0, life,
                CX0 + math.cos(ang) * r_init, CY0 + math.sin(ang) * r_init,
                math.cos(ang) * spd, math.sin(ang) * spd,
                2.6, 30.0 if is_petal else 12.0,
                5.5 + rng.random() * 4.5, 8.0, rng.random() * 6.28,
                col, "petal" if is_petal else "streak", sz,
                rng.random() * 6.28, (rng.random() - 0.5) * 6.8, p_idx
            ))

        # 3. Lockup rightward wake sparks (2.82s - 3.65s)
        for i in range(80):
            u = i / 80.0
            t0 = 2.84 + u * 0.55 + rng.random() * 0.12
            x_spawn = lockup_mark_cx + 68.0 + u * 620.0
            y_spawn = CY0 + rng.normal(0.0, 28.0)
            p_name = PETAL_ORDER[min(3, int(u * 4.0 + rng.normal(0, 0.35)) % 4)]
            ang = rng.normal(0.0, 0.45)
            spd = 110.0 + rng.random() * 230.0
            col = PAL[p_name][0] * (1.45 + rng.random() * 1.0)
            self.items.append((
                t0, 0.48 + rng.random() * 0.52,
                x_spawn, y_spawn,
                math.cos(ang) * spd, math.sin(ang) * spd,
                2.2, 18.0, 4.5 + rng.random() * 4.0, 9.0, rng.random() * 6.28,
                col, "streak" if i % 3 != 0 else "ember", 1.5 + rng.random() * 1.4, 0.0, 0.0, i % 4
            ))

        # 4. Silk Aurora sweep pollen (3.42s - 5.10s, tapering out before part1 periodic embers take over)
        for i in range(110):
            u = i / 110.0
            t0 = 3.44 + u * 0.85 + rng.random() * 0.20
            x_spawn = 140.0 + u * 800.0 + rng.normal(0.0, 42.0)
            y_spawn = CY0 + math.sin(x_spawn * 0.008 - t0 * 2.5) * 44.0 + rng.normal(0.0, 34.0)
            p_name = PETAL_ORDER[int((x_spawn / W) * 4.0) % 4]
            ang = rng.normal(0.0, 0.85)
            spd = 35.0 + rng.random() * 105.0
            life = min(0.85 + rng.random() * 0.85, max(0.25, 5.18 - t0))
            col = PAL[p_name][0 if rng.random() < 0.65 else 1] * (1.25 + rng.random() * 0.85)
            self.items.append((
                t0, life,
                x_spawn, y_spawn,
                math.cos(ang) * spd, math.sin(ang) * spd - 10.0,
                1.6, 8.0, 3.0 + rng.random() * 3.0, 10.0, rng.random() * 6.28,
                col, "ember", 1.5 + rng.random() * 1.7, 0.0, 0.0, i % 4
            ))

    def draw(self, t, emit_buf, petal_polys):
        shutter = 0.65 / FPS
        for (t0, life, x0, y0, vx0, vy0, drag, grav, cf, ca, cph, col, kind, sz, r0, vr, pidx) in self.items:
            tau = t - t0
            if tau <= 0.0 or tau >= life:
                continue
            u = tau / life
            alpha = min(1.0, tau * 16.0) * ((1.0 - u) ** 1.65)
            if kind == "ember":
                alpha *= 0.72 + 0.28 * math.sin(tau * 13.0 + cph)
            if alpha <= 0.004:
                continue

            def pos(tt):
                tt = max(0.0, tt)
                s = (1.0 - math.exp(-drag * tt)) / drag
                px = x0 + vx0 * s + ca * math.sin(cf * tt + cph) * min(1.0, tt * 2.0)
                py = y0 + vy0 * s + (grav / drag) * (tt - s) + ca * math.cos(0.87 * cf * tt + cph) * min(1.0, tt * 2.0)
                return px, py

            px, py = pos(tau)
            if px < 40 or px >= W - 40 or py < 50 or py >= H - 50:
                continue
            c = col * alpha
            if kind == "petal":
                poly0 = petal_polys[pidx]
                rot = r0 + vr * tau
                cs, sn = math.cos(rot) * sz, math.sin(rot) * sz
                pts = np.empty_like(poly0)
                pts[:, 0] = px + cs * poly0[:, 0] - sn * poly0[:, 1]
                pts[:, 1] = py + sn * poly0[:, 0] + cs * poly0[:, 1]
                bx0, by0 = max(0, int(pts[:, 0].min()) - 3), max(0, int(pts[:, 1].min()) - 3)
                bx1, by1 = min(W, int(pts[:, 0].max()) + 4), min(H, int(pts[:, 1].max()) + 4)
                if bx1 > bx0 and by1 > by0:
                    m = np.zeros((by1 - by0, bx1 - bx0), dtype=np.uint8)
                    ipts = np.round((pts - np.array([[bx0, by0]], dtype=np.float32)) * 16.0).astype(np.int32)
                    cv2.fillPoly(m, [ipts], 255, lineType=cv2.LINE_AA, shift=4)
                    emit_buf[by0:by1, bx0:bx1] += (m.astype(np.float32)[:, :, None] / 255.0) * c[None, None, :]
            elif kind == "streak":
                px0, py0 = pos(max(0.0, tau - shutter))
                bx0, by0 = max(0, int(min(px, px0) - sz - 4)), max(0, int(min(py, py0) - sz - 4))
                bx1, by1 = min(W, int(max(px, px0) + sz + 5)), min(H, int(max(py, py0) + sz + 5))
                if bx1 > bx0 and by1 > by0:
                    m = np.zeros((by1 - by0, bx1 - bx0), dtype=np.uint8)
                    pa = (int(round((px0 - bx0) * 16.0)), int(round((py0 - by0) * 16.0)))
                    pb = (int(round((px - bx0) * 16.0)), int(round((py - by0) * 16.0)))
                    cv2.line(m, pa, pb, 255, thickness=max(1, int(round(sz))), lineType=cv2.LINE_AA, shift=4)
                    emit_buf[by0:by1, bx0:bx1] += (m.astype(np.float32)[:, :, None] / 255.0) * c[None, None, :]
            else:
                rad = int(math.ceil(sz * 2.5)) + 2
                bx0, by0 = max(0, int(px) - rad), max(0, int(py) - rad)
                bx1, by1 = min(W, int(px) + rad + 1), min(H, int(py) + rad + 1)
                if bx1 > bx0 and by1 > by0:
                    yy, xx = np.mgrid[by0:by1, bx0:bx1].astype(np.float32)
                    g = np.exp(-(((xx - px) ** 2 + (yy - py) ** 2) / (2.0 * (sz * 0.85) ** 2)))
                    emit_buf[by0:by1, bx0:bx1] += g[:, :, None] * c[None, None, :]


def add_aa_polyline(emit_buf, pts, color_lin, thickness=2.0):
    if len(pts) < 2:
        return
    pad = int(math.ceil(thickness)) + 4
    x0 = max(0, int(np.floor(pts[:, 0].min())) - pad)
    y0 = max(0, int(np.floor(pts[:, 1].min())) - pad)
    x1 = min(W, int(np.ceil(pts[:, 0].max())) + pad)
    y1 = min(H, int(np.ceil(pts[:, 1].max())) + pad)
    if x1 <= x0 or y1 <= y0:
        return
    m = np.zeros((y1 - y0, x1 - x0), dtype=np.uint8)
    ipts = np.round((pts - np.array([[x0, y0]], dtype=np.float32)) * 16.0).astype(np.int32)
    th = max(1, int(round(thickness)))
    cv2.polylines(m, [ipts], False, 255, thickness=th, lineType=cv2.LINE_AA, shift=4)
    scale = (thickness / th) if thickness < 1.0 else 1.0
    emit_buf[y0:y1, x0:x1] += (m.astype(np.float32)[:, :, None] * (scale / 255.0)) * color_lin[None, None, :]


def draw_contour_trace(t, emit_buf, petal_curves, mark_w):
    """0.00s - 1.88s: 4-petal Bloom contour trace + pre-drop coil."""
    if t >= 1.88:
        return
    fade_out = 1.0 - smoothstep(1.80, 1.88, t)
    coil = ease_in_cubic(clamp01((t - 1.66) / 0.19))
    sc = (mark_w / 60.0) * (1.0 - 0.24 * coil)
    rot_coil = coil * 26.0
    cr, sr = math.cos(math.radians(rot_coil)), math.sin(math.radians(rot_coil))

    for idx, k in enumerate(PETAL_ORDER):
        pts0, nrm0 = petal_curves[k]
        n = len(pts0)
        prog = ease_in_out_cubic(clamp01((t - (0.03 + idx * 0.06)) / 0.82))
        if prog <= 0.002:
            continue
        px = CX0 + (cr * pts0[:, 0] - sr * pts0[:, 1]) * sc
        py = CY0 + (sr * pts0[:, 0] + cr * pts0[:, 1]) * sc
        nx = cr * nrm0[:, 0] - sr * nrm0[:, 1]
        ny = sr * nrm0[:, 0] + cr * nrm0[:, 1]
        base_pts = np.stack([px, py], axis=1)

        end_i = max(2, int(round(prog * n)))
        seg = base_pts[:end_i] if prog < 0.999 else np.vstack([base_pts, base_pts[:1]])
        c_light, c_mid, _ = PAL[k]
        surge = 1.0 + 0.80 * smoothstep(1.02, 1.15, t)
        add_aa_polyline(emit_buf, seg, c_mid * (1.35 * surge * fade_out), thickness=3.0)
        add_aa_polyline(emit_buf, seg, c_light * (1.65 * surge * fade_out), thickness=1.4)

        if t < 1.72:
            head_u = prog if prog < 0.999 else ((t - 0.88) * 1.7 + idx * 0.25) % 1.0
            hi = int(head_u * n) % n
            span = int(0.16 * n)
            arc_idx = (np.arange(hi - span, hi + 1) % n) if prog >= 0.999 else np.arange(max(0, end_i - span), end_i)
            if len(arc_idx) >= 2:
                comet_pts = base_pts[arc_idx]
                add_aa_polyline(emit_buf, comet_pts, (c_light * 2.5 + 0.40) * fade_out, thickness=2.4)
                s_arr = np.linspace(0.0, 1.0, len(arc_idx), dtype=np.float32)
                env = np.maximum(np.sin(np.pi * s_arr), 0.0) ** 1.3
                for branch, freq, amp in ((0, 9.0, 6.0), (1, 14.0, -4.6)):
                    disp = env * amp * (
                        np.sin(s_arr * freq - t * 24.0 + idx * 1.7 + branch * 2.1)
                        + 0.45 * np.sin(s_arr * (freq * 1.9) + t * 32.0)
                    )
                    t_pts = comet_pts + np.stack([nx[arc_idx] * disp, ny[arc_idx] * disp], axis=1)
                    add_aa_polyline(emit_buf, t_pts, c_light * (1.3 * fade_out), thickness=1.1)


def draw_diagonal_convergence(t, emit_buf):
    """1.03s - 1.86s: Four Bloom diagonal plasma arcs converging through (CX0, CY0)."""
    if t < 1.03 or t >= 1.86:
        return
    grow = ease_out_cubic(clamp01((t - 1.03) / 0.11))
    retract = ease_in_cubic(clamp01((t - 1.66) / 0.19))
    amp = smoothstep(1.03, 1.09, t) * (1.0 - smoothstep(1.80, 1.86, t))
    if amp <= 0.003:
        return

    max_len = 520.0 * grow * (1.0 - 0.92 * retract)
    n_pts = 120
    s = np.linspace(0.0, 1.0, n_pts, dtype=np.float32)
    env = (np.maximum(np.sin(np.pi * s), 0.0) ** 0.85) * (1.0 - 0.65 * retract)

    for idx, k in enumerate(PETAL_ORDER):
        dx, dy = PETAL_DIRS[k]
        nx, ny = -dy, dx
        c_light, c_mid, _ = PAL[k]
        dist = max_len * (1.0 - s)
        bx, by = CX0 + dx * dist, CY0 + dy * dist
        disp1 = env * 16.0 * (
            0.60 * np.sin(s * 13.0 - t * 24.0 + idx * 1.9)
            + 0.32 * np.sin(s * 29.0 + t * 37.0 + idx * 3.1)
            + 0.18 * np.sin(s * 53.0 - t * 51.0 + idx * 0.7)
        )
        pts1 = np.stack([bx + nx * disp1, by + ny * disp1], axis=1)
        add_aa_polyline(emit_buf, pts1, c_mid * (2.0 * amp), thickness=3.8)
        add_aa_polyline(emit_buf, pts1[int(n_pts * 0.14):], (c_light * 2.8 + 0.50) * amp, thickness=1.7)

        fork_s = s[30:100]
        fork_env = np.maximum(np.sin(np.pi * np.linspace(0.0, 1.0, len(fork_s), dtype=np.float32)), 0.0)
        disp2 = disp1[30:100] + fork_env * (22.0 * (1 if idx % 2 == 0 else -1)) * (
            0.7 * np.sin(fork_s * 19.0 + t * 29.0 + idx) + 0.4
        )
        pts2 = np.stack([bx[30:100] + nx * disp2, by[30:100] + ny * disp2], axis=1)
        add_aa_polyline(emit_buf, pts2, c_light * (1.20 * amp), thickness=1.1)

    core_pulse = amp * (0.85 + 0.20 * math.sin(t * 34.0) + 0.90 * bump((t - 1.70) / 0.15))
    y0, y1 = int(CY0 - 220), int(CY0 + 220)
    yy, xx = np.mgrid[y0:y1, 0:W].astype(np.float32)
    rx, ry = xx - CX0, yy - CY0
    win_y = np.clip(1.0 - (np.abs(ry) / 210.0) ** 3, 0.0, 1.0)
    win_x = np.clip(1.0 - (np.abs(rx) / 480.0) ** 3, 0.0, 1.0)
    core = (np.exp(-(rx * rx + ry * ry) / (2.0 * 14.0 ** 2)) * 3.6
            + np.exp(-(rx * rx + ry * ry) / (2.0 * 40.0 ** 2)) * 0.80) * win_y * win_x
    ana = np.exp(-(ry ** 2) / (2.0 * 2.4 ** 2)) * np.exp(-(rx ** 2) / (2.0 * 210.0 ** 2)) * win_x * 1.75
    col_core = np.array([0.88, 0.84, 1.0], dtype=np.float32)
    col_ana = PAL["violet"][0] * 0.45 + PAL["blue"][0] * 0.55
    emit_buf[y0:y1, :] += (core[:, :, None] * col_core + ana[:, :, None] * col_ana) * core_pulse


def draw_chromatic_rings(emit_buf, rings_spec):
    """Draw (r, w_ring, amp) rings tinted smoothly around the 4 Bloom quadrants."""
    for r, w_ring, amp in rings_spec:
        if amp <= 0.002:
            continue
        rad_bound = int(math.ceil(r + w_ring * 3.0))
        x0, y0 = max(0, int(CX0) - rad_bound), max(0, int(CY0) - rad_bound)
        x1, y1 = min(W, int(CX0) + rad_bound), min(H, int(CY0) + rad_bound)
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
        dx, dy = xx - CX0, yy - CY0
        rr = np.hypot(dx, dy)
        g = np.exp(-(((rr - r) / w_ring) ** 2)) * amp
        mask = g > 0.002
        if not np.any(mask):
            continue
        ang = (np.degrees(np.arctan2(dy[mask], dx[mask])) + 180.0) % 360.0
        centers = [45.0, 135.0, 225.0, 315.0]
        cols = [PAL["violet"][0], PAL["blue"][0], PAL["green"][0], PAL["coral"][0]]
        acc_c = np.zeros((ang.shape[0], 3), dtype=np.float32)
        w_sum = np.zeros(ang.shape[0], dtype=np.float32) + 1e-6
        for c_deg, col in zip(centers, cols):
            diff = np.abs(((ang - c_deg + 180.0) % 360.0) - 180.0)
            w = np.clip(1.0 - diff / 95.0, 0.0, 1.0) ** 2
            acc_c += w[:, None] * col[None, :]
            w_sum += w
        roi = emit_buf[y0:y1, x0:x1]
        roi[mask] += g[mask, None] * (acc_c / w_sum[:, None])


def draw_bloom_detonation(t, emit_buf):
    """1.85s - 2.60s: Detonation flash + dual chromatic shockwaves."""
    if t < 1.85 or t >= 2.60:
        return
    dt = t - 1.85
    if dt < 0.20:
        fl = ((1.0 - dt / 0.20) ** 2.2) * 3.2
        y0, y1 = int(CY0 - 240), int(CY0 + 240)
        yy, xx = np.mgrid[y0:y1, 0:W].astype(np.float32)
        rx, ry = xx - CX0, yy - CY0
        win_y = np.clip(1.0 - (np.abs(ry) / 230.0) ** 3, 0.0, 1.0)
        win_x = np.clip(1.0 - (np.abs(rx) / 480.0) ** 3, 0.0, 1.0)
        core = np.exp(-(rx * rx + ry * ry) / (2.0 * 52.0 ** 2)) * win_y * win_x
        ana = np.exp(-(ry ** 2) / (2.0 * 3.0 ** 2)) * np.exp(-(rx ** 2) / (2.0 * 230.0 ** 2)) * win_x * 0.70
        emit_buf[y0:y1, :] += (core + ana)[:, :, None] * np.array([0.95, 0.92, 1.0], np.float32) * fl

    rings = []
    for delay, r_end, dur, strength in ((0.00, 445.0, 0.58, 1.50), (0.09, 325.0, 0.54, 0.82)):
        u = (dt - delay) / dur
        if 0.0 < u < 1.0:
            rings.append((50.0 + (r_end - 50.0) * ease_out_cubic(u), 5.0 + 11.0 * u, strength * ((1.0 - u) ** 1.65)))
    draw_chromatic_rings(emit_buf, rings)


def draw_expressive_wake(t, emit_buf, lockup_mark_cx, expr_w):
    """2.80s - 3.55s: Bloom wake sweeping rightward across 'Expressive'."""
    if t < 2.80 or t >= 3.55:
        return
    u = clamp01((t - 2.80) / 0.62)
    fade = smoothstep(2.80, 2.88, t) * (1.0 - smoothstep(3.28, 3.55, t))
    if fade <= 0.003:
        return
    x_start = lockup_mark_cx + 60.0
    x_head = min(W - 85.0, x_start + (expr_w + 150.0) * ease_out_cubic(u))
    x_tail = max(x_start, x_head - 320.0)
    if x_head <= x_tail + 4.0:
        return
    xs = np.linspace(x_tail, x_head, 120, dtype=np.float32)
    s = np.linspace(0.0, 1.0, len(xs), dtype=np.float32)
    env = (np.maximum(s, 0.0) ** 0.7) * np.maximum(np.sin(np.pi * np.clip(s * 0.92, 0.0, 1.0)), 0.0)
    for idx, k in enumerate(PETAL_ORDER):
        c_light, c_mid, _ = PAL[k]
        ys = CY0 + env * (26.0 * np.sin(xs * 0.015 - t * 15.0 + idx * 1.55)
                          + 11.0 * np.cos(xs * 0.031 + t * 20.0 + idx))
        pts = np.stack([xs, ys], axis=1)
        add_aa_polyline(emit_buf, pts, c_mid * (1.05 * fade), thickness=2.4)
        add_aa_polyline(emit_buf, pts[48:], c_light * (1.50 * fade), thickness=1.1)


def draw_silk_aurora_sweep(t, emit_buf):
    """3.38s - 4.95s: Sweeping 4-petal ExpressiveOS Silk Wave peaking right across f=111 (t=3.70s)!"""
    if t < 3.38 or t >= 4.95:
        return None
    u_wave = clamp01((t - 3.38) / 1.02)
    # At t=3.70s (f=111, midpoint thumbnail!), u_wave=0.314 -> crest_x ~ 745px, spanning all of ExpressiveOS!
    crest_x = 90.0 + 1240.0 * (0.32 * u_wave + 0.68 * ease_out_cubic(u_wave))
    master = smoothstep(3.38, 3.52, t) * (1.0 - smoothstep(4.22, 4.95, t))
    if master <= 0.002:
        return crest_x

    y0, y1 = 340, 980
    bh = y1 - y0
    n_x = 200
    xs = np.linspace(0.0, float(W), n_x, dtype=np.float32)
    # Smooth horizontal edge taper inside 1080px canvas
    edge_x = np.maximum(np.sin(np.pi * np.clip(xs / float(W), 0.0, 1.0)), 0.0) ** 0.75
    dx = xs - crest_x
    sigma = np.where(dx > 0.0, 165.0, 660.0)
    env_x = np.exp(-((dx / sigma) ** 2)) * edge_x

    xs_w = np.arange(W, dtype=np.float32)
    edge_w = np.maximum(np.sin(np.pi * np.clip(xs_w / float(W), 0.0, 1.0)), 0.0) ** 0.75
    dx_w = xs_w - crest_x
    sigma_w = np.where(dx_w > 0.0, 165.0, 660.0)
    env_x_w = np.exp(-((dx_w / sigma_w) ** 2)) * edge_w
    ipts_x = np.round(xs * 16.0).astype(np.int32)

    for idx, k in enumerate(PETAL_ORDER):
        c_light, c_mid, c_deep = PAL[k]
        acc_u16 = np.zeros((bh, W), dtype=np.uint16)
        phase0 = idx * 1.48
        n_strands = 16
        for j in range(n_strands):
            v = (j / (n_strands - 1)) * 2.0 - 1.0
            spine = (
                54.0 * np.sin(xs * 0.0068 - t * 4.2 + phase0)
                + 26.0 * np.sin(xs * 0.0142 - t * 6.0 - phase0 * 0.7)
            )
            twist_w = 48.0 + 22.0 * np.sin(xs * 0.0085 - t * 4.6 + phase0 * 1.3)
            twist = v * twist_w * np.cos(xs * 0.0102 - t * 5.2 + phase0 + v * 0.42)
            ys = (CY0 - y0) + (spine + twist) * (0.45 + 0.65 * env_x)

            m = np.zeros((bh, W), dtype=np.uint8)
            ipts_y = np.round(np.clip(ys, 4.0, bh - 5.0) * 16.0).astype(np.int32)
            cv2.polylines(m, [np.stack([ipts_x, ipts_y], axis=1)], False, 255,
                          thickness=1, lineType=cv2.LINE_AA, shift=4)
            acc_u16 += m

        density = (acc_u16.astype(np.float32) / 255.0) * env_x_w[None, :] * master
        if density.max() <= 0.002:
            continue
        sheet = cv2.GaussianBlur(density, (0, 0), sigmaX=8.0, sigmaY=8.0)
        caustic = np.maximum(density - 1.05, 0.0)
        emit_buf[y0:y1, :] += (
            sheet[:, :, None] * (c_deep * 0.45 + c_mid * 0.65)[None, None, :] * 0.42
            + density[:, :, None] * c_mid[None, None, :] * 0.38
            + caustic[:, :, None] * (c_light * 1.45 + 0.25)[None, None, :] * 0.56
        )

    if 60.0 <= crest_x <= W - 60.0:
        cx_i = int(crest_x)
        bx0, bx1 = max(0, cx_i - 220), min(W, cx_i + 220)
        yy, xx = np.mgrid[y0:y1, bx0:bx1].astype(np.float32)
        cy_crest = CY0 + 32.0 * math.sin(crest_x * 0.0068 - t * 4.2)
        flare = np.exp(-(((xx - crest_x) / 85.0) ** 2 + ((yy - cy_crest) / 28.0) ** 2)) * master * 0.90
        u_col = clamp01(crest_x / W) * 3.0
        ci = min(2, int(u_col))
        cf = u_col - ci
        c_crest = PAL[PETAL_ORDER[ci]][0] * (1.0 - cf) + PAL[PETAL_ORDER[ci + 1]][0] * cf
        emit_buf[y0:y1, bx0:bx1] += flare[:, :, None] * (c_crest + 0.22)[None, None, :]

    return crest_x


def draw_periodic_idle_aurora(phase_01, strength, emit_buf, ember_specs):
    """Strictly 1.0-periodic gossamer Silk Aurora veil + twinkling Bloom embers for seamless part1 loop!"""
    if strength <= 0.002:
        return
    w1 = 2.0 * math.pi * phase_01
    w2 = 4.0 * math.pi * phase_01

    y0, y1 = 440, 880
    bh = y1 - y0
    n_x = 180
    xs = np.linspace(0.0, float(W), n_x, dtype=np.float32)
    env_x = np.exp(-(((xs - CX0) / 340.0) ** 2))
    xs_w = np.arange(W, dtype=np.float32)
    env_x_w = np.exp(-(((xs_w - CX0) / 340.0) ** 2))
    ipts_x = np.round(xs * 16.0).astype(np.int32)

    for idx, k in enumerate(PETAL_ORDER):
        c_light, c_mid, c_deep = PAL[k]
        acc_u16 = np.zeros((bh, W), dtype=np.uint16)
        p0 = idx * 1.57
        n_strands = 10
        for j in range(n_strands):
            v = (j / (n_strands - 1)) * 2.0 - 1.0
            spine = 28.0 * np.sin(xs * 0.0072 - w1 + p0) + 12.0 * np.sin(xs * 0.0135 - w2 - p0 * 0.6)
            twist = v * 26.0 * np.cos(xs * 0.0092 - w1 + p0 + v * 0.38)
            ys = (CY0 - y0) + (spine + twist) * (0.45 + 0.55 * env_x)
            m = np.zeros((bh, W), dtype=np.uint8)
            ipts_y = np.round(np.clip(ys, 4.0, bh - 5.0) * 16.0).astype(np.int32)
            cv2.polylines(m, [np.stack([ipts_x, ipts_y], axis=1)], False, 255,
                          thickness=1, lineType=cv2.LINE_AA, shift=4)
            acc_u16 += m

        density = (acc_u16.astype(np.float32) / 255.0) * env_x_w[None, :] * (strength * 0.46)
        if density.max() <= 0.002:
            continue
        sheet = cv2.GaussianBlur(density, (0, 0), sigmaX=7.0, sigmaY=7.0)
        caustic = np.maximum(density - 0.55, 0.0)
        emit_buf[y0:y1, :] += (
            sheet[:, :, None] * (c_deep * 0.45 + c_mid * 0.55)[None, None, :] * 0.36
            + density[:, :, None] * c_mid[None, None, :] * 0.30
            + caustic[:, :, None] * c_light[None, None, :] * 0.42
        )

    # Periodic twinkling Bloom embers orbiting gently around the wordmark
    for (ex0, ey0, rx, ry, ph, sz, col) in ember_specs:
        tw = (0.35 + 0.65 * (0.5 + 0.5 * math.sin(w1 + ph))) * strength
        if tw <= 0.005:
            continue
        px = ex0 + rx * math.cos(w1 + ph)
        py = ey0 + ry * math.sin(w1 + ph * 1.3)
        rad = int(math.ceil(sz * 2.5)) + 2
        bx0, by0 = max(0, int(px) - rad), max(0, int(py) - rad)
        bx1, by1 = min(W, int(px) + rad + 1), min(H, int(py) + rad + 1)
        if bx1 > bx0 and by1 > by0:
            yy, xx = np.mgrid[by0:by1, bx0:bx1].astype(np.float32)
            g = np.exp(-(((xx - px) ** 2 + (yy - py) ** 2) / (2.0 * (sz * 0.85) ** 2)))
            emit_buf[by0:by1, bx0:bx1] += g[:, :, None] * (col * tw)[None, None, :]


def apply_multiscale_bloom(emit_buf):
    acc = emit_buf.copy()
    specs = [
        (2, 3.0, 0.52),
        (4, 5.2, 0.42),
        (8, 8.0, 0.28),
        (16, 9.5, 0.12),
    ]
    cur = emit_buf
    for div, sig, weight in specs:
        cur = cv2.resize(cur, (W // div, H // div), interpolation=cv2.INTER_AREA)
        blurred = cv2.GaussianBlur(cur, (0, 0), sigmaX=sig, sigmaY=sig)
        up = cv2.resize(blurred, (W, H), interpolation=cv2.INTER_CUBIC)
        acc += np.maximum(up, 0.0) * weight
    return acc


def tonemap_emissive(hdr):
    x = np.maximum(hdr, 0.0)
    lum = 0.2126 * x[..., 0] + 0.7152 * x[..., 1] + 0.0722 * x[..., 2]
    ct = np.clip((lum - 0.55) / 2.4, 0.0, 1.0)
    ct = ct * ct * (3.0 - 2.0 * ct) * 0.68
    mixed = x * (1.0 - ct[..., None]) + lum[..., None] * ct[..., None]
    return mixed / (1.0 + 0.52 * mixed)


def soft_shoulder_body(lin):
    t0 = 0.85
    over = np.maximum(lin - t0, 0.0)
    rolled = t0 + (1.0 - t0) * (1.0 - np.exp(-over / (1.0 - t0)))
    return np.where(lin <= t0, lin, rolled)


class SilkAuroraRenderer:
    def __init__(self, logo_path, font_path):
        self.mark = ShadedBloomMark(logo_path)
        self.word = FlexWordmark(font_path)
        self.particles = IntroParticleSystem(self.word.lockup_mark_cx)
        self.petal_curves = {k: sample_svg_path(PETAL_SVG_PATHS[k], n=560) for k in PETAL_ORDER}
        self.petal_polys = {i: self.petal_curves[k][0][::12].copy() for i, k in enumerate(PETAL_ORDER)}

        rng = np.random.default_rng(77123)
        self.periodic_embers = []
        for i in range(34):
            ex0 = CX0 + rng.uniform(-380.0, 380.0)
            ey0 = CY0 + rng.normal(0.0, 48.0)
            p_name = PETAL_ORDER[int(((ex0 - (CX0 - 400.0)) / 800.0) * 4.0) % 4]
            col = PAL[p_name][0 if rng.random() < 0.65 else 1] * (1.25 + rng.random() * 0.75)
            self.periodic_embers.append((
                ex0, ey0,
                6.0 + rng.random() * 12.0,
                5.0 + rng.random() * 10.0,
                rng.random() * 2.0 * math.pi,
                1.5 + rng.random() * 1.5,
                col,
            ))

    def mark_state_part0(self, t):
        if t < 1.85 or t >= 3.68:
            return None
        slide = ease_in_out_cubic(clamp01((t - 2.68) / 0.52))
        cx = CX0 + (self.word.lockup_mark_cx - CX0) * slide
        mark_w = 340.0 + (self.word.lockup_mark_w - 340.0) * slide
        breathe = 1.0 + 0.022 * math.sin((t - 2.25) * 3.8) * smoothstep(2.25, 2.50, t) * (1.0 - slide)
        mark_w *= breathe
        rot_global = 90.0 * slide

        dissolve = clamp01((t - 3.38) / 0.28)
        if dissolve > 0.0:
            rot_global += 160.0 * ease_in_cubic(dissolve)
            cx += 32.0 * ease_in_cubic(dissolve)
            mark_w *= (1.0 + 0.14 * bump(dissolve) - 0.30 * ease_in_cubic(dissolve))

        petals = {}
        for i, k in enumerate(PETAL_ORDER):
            u = (t - 1.85 - i * 0.035) / 0.34
            if u <= 0.0:
                petals[k] = (0.0, 0.0, 0.0, 0.0, 0.0)
                continue
            rot_p = -92.0 * (1.0 - ease_out_cubic(u)) + rot_global
            sc_p = (0.32 + 0.68 * ease_out_back(u, 1.38)) * (1.0 - 0.45 * ease_in_cubic(dissolve))
            al_p = clamp01(u * 4.5) * (1.0 - smoothstep(0.08, 0.96, dissolve))
            dx_d = (42.0 + i * 12.0) * ease_in_cubic(dissolve)
            dy_d = PETAL_DIRS[k][1] * 28.0 * ease_in_cubic(dissolve)
            petals[k] = (rot_p, sc_p, al_p, dx_d, dy_d)

        bloom_amt = 0.44 + 0.55 * bump(clamp01((t - 1.85) / 0.36)) + 0.68 * bump(dissolve)
        return cx, CY0, mark_w, petals, bloom_amt

    def render_part_frame(self, part, f_idx):
        emit = np.zeros((H, W, 3), dtype=np.float32)
        mark_roi = None
        word_pack = None
        silk_veil_strength = 0.14
        n_p0 = PARTS["part0"][0]
        n_p1 = PARTS["part1"][0]
        n_p2 = PARTS["part2"][0]
        t_p0_end = n_p0 / float(FPS)

        if part == "part0":
            t = f_idx / float(FPS)
            st0 = self.mark_state_part0(t)
            if st0 is not None:
                sub_n = 4 if (1.85 <= t <= 2.25 or 3.38 <= t <= 3.68) else 1
                if sub_n == 1:
                    mark_roi = self.mark.composite_pose(st0[0], st0[1], st0[2], st0[3])
                else:
                    rois = []
                    for j in range(sub_n):
                        tj = t + ((j + 0.5) / sub_n - 0.5) * (0.55 / FPS)
                        stj = self.mark_state_part0(tj)
                        if stj is not None:
                            rj = self.mark.composite_pose(stj[0], stj[1], stj[2], stj[3])
                            if rj is not None:
                                rois.append(rj)
                    if rois:
                        ux0 = min(r[0] for r in rois)
                        uy0 = min(r[1] for r in rois)
                        ux1 = max(r[0] + r[2].shape[1] for r in rois)
                        uy1 = max(r[1] + r[2].shape[0] for r in rois)
                        acc_m = np.zeros((uy1 - uy0, ux1 - ux0, 4), dtype=np.float32)
                        for rx0, ry0, arr in rois:
                            rh, rw = arr.shape[:2]
                            acc_m[ry0 - uy0:ry0 - uy0 + rh, rx0 - ux0:rx0 - ux0 + rw] += arr
                        acc_m /= len(rois)
                        mark_roi = (ux0, uy0, acc_m)
                if mark_roi is not None:
                    mx0, my0, m_rgba = mark_roi
                    mh, mw = m_rgba.shape[:2]
                    emit[my0:my0 + mh, mx0:mx0 + mw] += m_rgba[..., :3] * st0[4]

            draw_contour_trace(t, emit, self.petal_curves, 340.0)
            draw_diagonal_convergence(t, emit)
            draw_bloom_detonation(t, emit)
            draw_expressive_wake(t, emit, self.word.lockup_mark_cx, self.word.expr_w)
            crest_x = draw_silk_aurora_sweep(t, emit)

            # Fade in the periodic idle aurora so f=159 hands off seamlessly to part1 f=0!
            idle_in = smoothstep(4.25, 5.15, t)
            if idle_in > 0.002:
                phase_01 = ((f_idx - n_p0) / float(n_p1)) % 1.0
                draw_periodic_idle_aurora(phase_01, idle_in, emit, self.periodic_embers)

            if t >= 2.82:
                recenter = ease_in_out_cubic(clamp01((t - 3.48) / 0.42))
                dx_shift = self.word.lockup_dx * (1.0 - recenter)
                glyph_states = []
                for i in range(len(self.word.WORD)):
                    if i < 10:
                        u = (t - 2.84 - i * 0.040) / 0.22
                        if u <= 0.0:
                            glyph_states.append((0.0, 0.0, 0.0))
                        else:
                            glyph_states.append((0.55 + 0.45 * ease_out_back(u, 1.42),
                                                 clamp01(u * 2.8), 14.0 * (1.0 - ease_out_cubic(u))))
                    else:
                        j = i - 10
                        u = (t - 3.62 - j * 0.055) / 0.22
                        if u <= 0.0:
                            glyph_states.append((0.0, 0.0, 0.0))
                        else:
                            glyph_states.append((0.62 + 0.38 * ease_out_back(u, 1.35),
                                                 clamp01(u * 2.6), 10.0 * (1.0 - ease_out_cubic(u))))
                if t < 3.42:
                    color_mix = 0.0
                elif t >= 4.15:
                    color_mix = 1.0
                else:
                    xs = np.arange(W, dtype=np.float32)[None, :, None]
                    cx_w = crest_x if crest_x is not None else float(W)
                    color_mix = np.clip(1.0 - (xs - (cx_w - 40.0)) / 180.0, 0.0, 1.0)
                    color_mix = color_mix * color_mix * (3.0 - 2.0 * color_mix)
                wave_amp = 0.62 * smoothstep(3.45, 3.62, t) * (1.0 - smoothstep(3.98, 4.35, t))
                word_pack = self.word.render_mask_and_color(
                    glyph_states, dx_shift, color_mix, wave_crest_x=crest_x, wave_amp=wave_amp
                )
                if word_pack is not None:
                    emit[word_pack[0]:word_pack[1], :] += word_pack[4]
                if 3.42 <= t <= 4.55:
                    silk_veil_strength = 0.14 + 0.20 * (1.0 - smoothstep(4.15, 4.55, t))

            self.particles.draw(t, emit, self.petal_polys)

        elif part == "part1":
            # Strictly periodic 36-frame loop
            phase_01 = (f_idx / float(n_p1)) % 1.0
            draw_periodic_idle_aurora(phase_01, 1.0, emit, self.periodic_embers)
            rest_states = [(1.0, 1.0, 0.0)] * len(self.word.WORD)
            # Periodic specular sheen gliding smoothly across the wordmark once per loop
            sheen_u = 0.5 - 0.5 * math.cos(2.0 * math.pi * phase_01)
            sheen_x = (self.word.final_x0 - 90.0) + (self.word.full_w + 180.0) * sheen_u
            word_pack = self.word.render_mask_and_color(
                rest_states, 0.0, 1.0, sheen_x=sheen_x,
                flash_uniform=0.04 * (0.5 - 0.5 * math.cos(2.0 * math.pi * phase_01))
            )
            emit[word_pack[0]:word_pack[1], :] += word_pack[4]

        elif part == "part2":
            # Seamless handoff from part1 end (f=35 -> f=0), fading aurora to clean rest on #000000
            phase_01 = (f_idx / float(n_p1)) % 1.0
            u_out = f_idx / float(max(1, n_p2 - 1))
            aurora_fade = 1.0 - smoothstep(0.0, 0.78, u_out)
            draw_periodic_idle_aurora(phase_01, aurora_fade, emit, self.periodic_embers)

            # Double Bloom completion ripple
            rings = []
            for delay, r_end, amp0 in ((0.0, 420.0, 0.85), (0.18, 320.0, 0.45)):
                ur = (u_out - delay) / (1.0 - delay)
                if 0.0 < ur < 1.0:
                    rings.append((150.0 + (r_end - 150.0) * ease_out_cubic(ur),
                                  5.0 + 9.0 * ur, amp0 * ((1.0 - ur) ** 1.5)))
            draw_chromatic_rings(emit, rings)

            rest_states = [(1.0, 1.0, 0.0)] * len(self.word.WORD)
            fl = 0.34 * bump(clamp01(u_out / 0.72))
            word_pack = self.word.render_mask_and_color(rest_states, 0.0, 1.0, flash_uniform=fl)
            emit[word_pack[0]:word_pack[1], :] += word_pack[4]

        bloomed = apply_multiscale_bloom(emit)
        canvas = tonemap_emissive(bloomed)

        if mark_roi is not None:
            t = f_idx / float(FPS)
            mx0, my0, m_rgba = mark_roi
            mh, mw = m_rgba.shape[:2]
            ma = m_rgba[..., 3:4]
            bg_patch = canvas[my0:my0 + mh, mx0:mx0 + mw]
            flash_lift = 0.26 * bump(clamp01((t - 1.85) / 0.20)) + 0.34 * smoothstep(3.38, 3.64, t)
            canvas[my0:my0 + mh, mx0:mx0 + mw] = (
                bg_patch * (1.0 - ma) + soft_shoulder_body(m_rgba[..., :3] * (1.0 + flash_lift))
            )

        if word_pack is not None:
            wy0, wy1, w_cov, w_lin, _ = word_pack
            wa = w_cov[..., None]
            bg_patch = canvas[wy0:wy1, :]
            body = soft_shoulder_body(w_lin + bg_patch * silk_veil_strength) * wa
            canvas[wy0:wy1, :] = bg_patch * (1.0 - wa) + body

        return lin_to_srgb_u8(canvas, seed=PART_SEED_BASE[part] + f_idx)


_WORKER = None


def _init_worker(logo_path, font_path):
    global _WORKER
    cv2.setNumThreads(1)
    _WORKER = SilkAuroraRenderer(logo_path, font_path)


def _render_job(job):
    part, f_idx, out_path = job
    rgb = _WORKER.render_part_frame(part, f_idx)
    Image.fromarray(rgb, "RGB").save(out_path, format="PNG", optimize=True)
    return part, f_idx


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("logo")
    ap.add_argument("font")
    ap.add_argument("out")
    ap.add_argument("--only", default=",".join(PARTS), help="parts to render (default all)")
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 1))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    desc = f"{W} {H} {FPS}\n" + "".join(
        f"c {plays} {pause} {name} #{BG[0]:02x}{BG[1]:02x}{BG[2]:02x}\n"
        for name, (_, plays, pause) in PARTS.items()
    )
    tmp_desc = os.path.join(args.out, f".desc.txt.{os.getpid()}")
    with open(tmp_desc, "w", newline="\n") as fh:
        fh.write(desc)
    os.replace(tmp_desc, os.path.join(args.out, "desc.txt"))

    selected = [p.strip() for p in args.only.split(",") if p.strip()]
    jobs = []
    for p in selected:
        count = PARTS[p][0]
        d = os.path.join(args.out, p)
        os.makedirs(d, exist_ok=True)
        for i in range(count):
            jobs.append((p, i, os.path.join(d, f"img{i:05d}.png")))

    with concurrent.futures.ProcessPoolExecutor(
        max_workers=args.workers, initializer=_init_worker, initargs=(args.logo, args.font)
    ) as pool:
        for _ in pool.map(_render_job, jobs, chunksize=6):
            pass

    for p in selected:
        print(f"{p}: {PARTS[p][0]} frames", file=sys.stderr)


if __name__ == "__main__":
    main()
