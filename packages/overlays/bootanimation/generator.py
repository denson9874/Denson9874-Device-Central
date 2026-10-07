#!/usr/bin/env python3
"""
ExpressiveOS 60fps Spinning Bloom Boot Animation Generator
Recreates the exact Easter Egg spinning bloom animation from Expressive Launcher:
- 52 bursting particle streams with dynamic velocities and quadratic gravity
- 720-degree spinning Bloom mark with 7-cycle sine pulsing
- Pulsing radiant emerald/teal glow halo
- Smooth 60fps loop sequence with continuous spin & breathing
- Packages into an uncompressed (STORED) Android bootanimation.zip
"""

import os
import math
import shutil
import zipfile
from PIL import Image, ImageDraw, ImageFont

WIDTH = 720
HEIGHT = 1600
FPS = 60

# Exact Material 3 Expressive palette from AboutEasterEgg.kt
COLOR_BG = (0, 0, 0)
COLOR_EMERALD = (0, 230, 153)    # Primary: #00E699
COLOR_TEAL = (0, 180, 216)       # Tertiary: #00B4D8
COLOR_LIME = (163, 230, 53)      # Secondary: #A3E635
COLOR_ELECTRIC = (112, 224, 0)   # InversePrimary: #70E000
PARTICLE_COLORS = [COLOR_EMERALD, COLOR_TEAL, COLOR_LIME, COLOR_ELECTRIC]

PARTICLE_COUNT = 52

BLOOM_PATH = "/Users/daryldenson/Developer/ExpressiveLauncher/docs/assets/expressive/expressive-bloom-foreground.png"

def fast_out_slow_in(t):
    """Cubic approximation of FastOutSlowInEasing."""
    return t * t * (3.0 - 2.0 * t)

def lerp_color(c1, c2, factor):
    f = max(0.0, min(1.0, factor))
    return (
        int(c1[0] + (c2[0] - c1[0]) * f),
        int(c1[1] + (c2[1] - c1[1]) * f),
        int(c1[2] + (c2[2] - c1[2]) * f)
    )

def render_particles(draw, cx, cy, progress, max_radius):
    if progress <= 0:
        return
    for i in range(PARTICLE_COUNT):
        angle = (2.0 * math.pi * i / PARTICLE_COUNT) + (i % 5) * 0.17
        speed = 0.55 + (i % 7) * 0.065
        radius = max_radius * progress * speed
        x = cx + math.cos(angle) * radius
        y = cy + math.sin(angle) * radius - (HEIGHT * 0.12 * progress * progress)
        alpha = max(0.0, min(1.0, 1.0 - progress * 0.82))
        base_color = PARTICLE_COLORS[i % len(PARTICLE_COLORS)]
        col = (
            int(base_color[0] * alpha),
            int(base_color[1] * alpha),
            int(base_color[2] * alpha)
        )
        if alpha < 0.05:
            continue

        if i % 3 == 0:
            pr = (5.0 + (i % 4) * 3.0) * (1.0 - progress * 0.3)
            draw.ellipse([x - pr, y - pr, x + pr, y + pr], fill=col)
        else:
            tail = 12.0 + (i % 5) * 5.0
            x2 = x - math.cos(angle) * tail
            y2 = y - math.sin(angle) * tail
            draw.line([(x2, y2), (x, y)], fill=col, width=max(2, int(4 * alpha)))

def render_halo(draw, cx, cy, radius, color, alpha=0.35):
    # Radial tiered glow
    r = int(radius)
    c = (int(color[0] * alpha), int(color[1] * alpha), int(color[2] * alpha))
    for step in range(4, 0, -1):
        step_r = r * (0.6 + step * 0.12)
        step_alpha = alpha * (0.2 + (5 - step) * 0.18)
        step_col = (int(color[0] * step_alpha), int(color[1] * step_alpha), int(color[2] * step_alpha))
        draw.ellipse([cx - step_r, cy - step_r, cx + step_r, cy + step_r], fill=step_col)

def draw_branding(draw, cx, y_base, alpha=1.0):
    if alpha <= 0.02:
        return
    title_col = (int(255 * alpha), int(255 * alpha), int(255 * alpha))
    sub_col = (int(COLOR_EMERALD[0] * alpha * 0.85), int(COLOR_EMERALD[1] * alpha * 0.85), int(COLOR_EMERALD[2] * alpha * 0.85))

    font_title = None
    font_sub = None
    for p in ["/System/Library/Fonts/SFPro-Bold.ttf", "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        if os.path.exists(p):
            try:
                font_title = ImageFont.truetype(p, 36)
                font_sub = ImageFont.truetype(p, 18)
                break
            except Exception:
                pass
    if not font_title:
        font_title = ImageFont.load_default()
        font_sub = ImageFont.load_default()

    t_title = "ExpressiveOS"
    t_sub = "Android 17"

    bbox1 = draw.textbbox((0, 0), t_title, font=font_title)
    w1 = bbox1[2] - bbox1[0]
    draw.text((cx - w1 / 2, y_base), t_title, font=font_title, fill=title_col)

    bbox2 = draw.textbbox((0, 0), t_sub, font=font_sub)
    w2 = bbox2[2] - bbox2[0]
    draw.text((cx - w2 / 2, y_base + 46), t_sub, font=font_sub, fill=sub_col)

def main():
    root = os.path.dirname(os.path.abspath(__file__))
    frames_dir = os.path.join(root, "build_frames")
    part0_dir = os.path.join(frames_dir, "part0")
    part1_dir = os.path.join(frames_dir, "part1")
    zip_path = os.path.join(root, "bootanimation.zip")

    shutil.rmtree(frames_dir, ignore_errors=True)
    os.makedirs(part0_dir, exist_ok=True)
    os.makedirs(part1_dir, exist_ok=True)

    print(f"Loading Bloom artwork from {BLOOM_PATH}...")
    bloom_src = Image.open(BLOOM_PATH).convert("RGBA")
    # Base size for the bloom mark
    base_dim = 260
    bloom_base = bloom_src.resize((base_dim, base_dim), Image.Resampling.LANCZOS)

    cx = WIDTH / 2.0
    cy = HEIGHT / 2.0 - 50.0

    print("Rendering Part 0 (Easter Egg 720° Spinning Bloom & Particle Burst - 60 frames)...")
    num_part0 = 60
    for frame in range(num_part0):
        t_raw = frame / float(num_part0 - 1)
        progress = fast_out_slow_in(t_raw)

        im = Image.new("RGB", (WIDTH, HEIGHT), COLOR_BG)
        draw = ImageDraw.Draw(im)

        # Entrance scale & rotation (exact 720° spin from AboutEasterEgg.kt)
        entrance = max(0.0, min(1.0, t_raw / 0.22))
        rotation = progress * 720.0
        # Exact 7-cycle sine pulse from AboutEasterEgg.kt
        pulse = 1.0 + math.sin(progress * math.pi * 7.0) * 0.08
        current_scale = (0.70 + 0.30 * entrance) * pulse
        current_dim = max(16, int(base_dim * current_scale))

        # Render 52 exploding particles
        render_particles(draw, cx, cy, progress, WIDTH * 0.65)

        # Radiant glowing halo behind Bloom
        halo_color = lerp_color(COLOR_EMERALD, COLOR_TEAL, progress)
        render_halo(draw, cx, cy, current_dim * 0.85, halo_color, alpha=0.35 * entrance)

        # Rotate and scale Bloom mark
        b_scaled = bloom_base.resize((current_dim, current_dim), Image.Resampling.LANCZOS)
        b_rot = b_scaled.rotate(-rotation, resample=Image.Resampling.BICUBIC, expand=False)

        bx = int(cx - current_dim / 2.0)
        by = int(cy - current_dim / 2.0)
        im.paste(b_rot, (bx, by), b_rot)

        # Branding text fade in
        brand_alpha = max(0.0, min(1.0, (t_raw - 0.55) / 0.40))
        draw_branding(draw, cx, cy + base_dim / 2.0 + 70.0, brand_alpha)

        out_path = os.path.join(part0_dir, f"{frame:05d}.png")
        im.save(out_path, format="PNG", compress_level=3)

    print("Rendering Part 1 (Continuous 60fps Spinning Bloom Loop - 60 frames)...")
    num_part1 = 60
    for frame in range(num_part1):
        tau = frame / float(num_part1)
        im = Image.new("RGB", (WIDTH, HEIGHT), COLOR_BG)
        draw = ImageDraw.Draw(im)

        # Continuous smooth 360° spin per second
        rotation = tau * 360.0
        pulse = 1.0 + math.sin(tau * 2.0 * math.pi) * 0.04
        current_dim = int(base_dim * pulse)

        # Ambient floating sparkles around the Bloom
        for s in range(16):
            s_angle = tau * 2.0 * math.pi + (2.0 * math.pi * s / 16.0)
            s_rad = (base_dim * 0.72) + math.sin(tau * 4.0 * math.pi + s) * 24.0
            sx = cx + math.cos(s_angle) * s_rad
            sy = cy + math.sin(s_angle) * s_rad
            s_alpha = 0.4 + 0.5 * math.sin(tau * 2.0 * math.pi + s)
            s_col = PARTICLE_COLORS[s % len(PARTICLE_COLORS)]
            sc = (int(s_col[0] * s_alpha), int(s_col[1] * s_alpha), int(s_col[2] * s_alpha))
            draw.ellipse([sx - 3, sy - 3, sx + 3, sy + 3], fill=sc)

        # Glowing breathing halo
        halo_color = lerp_color(COLOR_EMERALD, COLOR_TEAL, (math.sin(tau * 2.0 * math.pi) + 1.0) / 2.0)
        render_halo(draw, cx, cy, current_dim * 0.85, halo_color, alpha=0.32)

        # Rotate and paste Bloom
        b_scaled = bloom_base.resize((current_dim, current_dim), Image.Resampling.LANCZOS)
        b_rot = b_scaled.rotate(-rotation, resample=Image.Resampling.BICUBIC, expand=False)

        bx = int(cx - current_dim / 2.0)
        by = int(cy - current_dim / 2.0)
        im.paste(b_rot, (bx, by), b_rot)

        # Stationary branding text
        draw_branding(draw, cx, cy + base_dim / 2.0 + 70.0, 1.0)

        out_path = os.path.join(part1_dir, f"{frame:05d}.png")
        im.save(out_path, format="PNG", compress_level=3)

    print("Writing desc.txt (720 1600 60)...")
    desc_path = os.path.join(frames_dir, "desc.txt")
    with open(desc_path, "w", newline="\n") as f:
        f.write(f"{WIDTH} {HEIGHT} {FPS}\n")
        f.write("p 1 0 part0\n")
        f.write("p 0 0 part1\n")

    print(f"Packaging uncompressed ZIP: {zip_path}...")
    if os.path.exists(zip_path):
        os.remove(zip_path)

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.write(desc_path, "desc.txt")
        for f in sorted(os.listdir(part0_dir)):
            zf.write(os.path.join(part0_dir, f), f"part0/{f}")
        for f in sorted(os.listdir(part1_dir)):
            zf.write(os.path.join(part1_dir, f), f"part1/{f}")

    sz = os.path.getsize(zip_path)
    print(f"✓ Created bootanimation.zip ({sz / 1024:.1f} KB, 120 frames at 60fps)")

if __name__ == "__main__":
    main()
