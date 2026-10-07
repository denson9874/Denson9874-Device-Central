#!/usr/bin/env python3
"""
ExpressiveOS Boot Animation Generator
Renders a fluid, high-framerate Material 3 Expressive boot sequence
and packages it into an Android-compliant uncompressed bootanimation.zip.
"""

import os
import math
import shutil
import zipfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

WIDTH = 720
HEIGHT = 1600
FPS = 60

COLOR_BG = (0, 0, 0)
COLOR_EMERALD = (0, 229, 160)     # #00E5A0
COLOR_TEAL = (0, 180, 216)        # #00B4D8
COLOR_LIME = (163, 230, 53)       # #A3E635
COLOR_WHITE = (255, 255, 255)

def ease_out_cubic(x):
    return 1 - math.pow(1 - x, 3)

def ease_in_out_sine(x):
    return -(math.cos(math.pi * x) - 1) / 2

def draw_expressive_emblem(draw, cx, cy, size, alpha=1.0, glow_factor=0.0):
    """Draws the Material 3 Expressive clover / organic geometric emblem."""
    # Outer glow if requested
    glow_color = (
        int(COLOR_EMERALD[0] * alpha * 0.4),
        int(COLOR_EMERALD[1] * alpha * 0.4),
        int(COLOR_EMERALD[2] * alpha * 0.4)
    )
    
    # Draw overlapping fluid rounded petals
    petal_r = size * 0.42
    offset = size * 0.28
    
    petals = [
        (cx - offset, cy - offset, COLOR_EMERALD),
        (cx + offset, cy - offset, COLOR_TEAL),
        (cx + offset, cy + offset, COLOR_LIME),
        (cx - offset, cy + offset, COLOR_EMERALD),
    ]
    
    for px, py, col in petals:
        c = (int(col[0] * alpha), int(col[1] * alpha), int(col[2] * alpha))
        draw.ellipse([px - petal_r, py - petal_r, px + petal_r, py + petal_r], fill=c)
        
    # Center core ring
    core_r = size * 0.22
    draw.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=(0, 0, 0))
    core_inner = size * 0.14
    core_color = (int(255 * alpha), int(255 * alpha), int(255 * alpha))
    draw.ellipse([cx - core_inner, cy - core_inner, cx + core_inner, cy + core_inner], fill=core_color)

def generate_frames(output_dir):
    part0_dir = os.path.join(output_dir, "part0")
    part1_dir = os.path.join(output_dir, "part1")
    os.makedirs(part0_dir, exist_ok=True)
    os.makedirs(part1_dir, exist_ok=True)

    cx = WIDTH // 2
    cy = HEIGHT // 2 - 80

    # PART 0: INTRO (45 frames)
    print("Generating Part 0 (Intro)...")
    total_intro = 45
    for i in range(total_intro):
        progress = i / float(total_intro - 1)
        eased = ease_out_cubic(progress)

        img = Image.new("RGB", (WIDTH, HEIGHT), COLOR_BG)
        draw = ImageDraw.Draw(img)

        # Scale emblem up smoothly
        current_size = 60 + 100 * eased
        alpha = min(1.0, progress * 1.5)

        draw_expressive_emblem(draw, cx, cy, current_size, alpha=alpha)

        # Draw "ExpressiveOS" text as it fades in
        if progress > 0.4:
            text_progress = (progress - 0.4) / 0.6
            text_alpha = int(255 * ease_out_cubic(text_progress))
            # Text rendering
            text = "ExpressiveOS"
            subtext = "Android 17"
            # Draw simple vector representation of letters or clean dots
            ty = cy + 180
            draw.text((cx, ty), text, fill=(text_alpha, text_alpha, text_alpha), anchor="mm")
            draw.text((cx, ty + 40), subtext, fill=(int(text_alpha * 0.6), int(text_alpha * 0.8), int(text_alpha * 0.7)), anchor="mm")

        filename = os.path.join(part0_dir, f"{i:05d}.png")
        img.save(filename, "PNG")

    # PART 1: LOOP (30 frames)
    print("Generating Part 1 (Loop)...")
    total_loop = 30
    for i in range(total_loop):
        progress = i / float(total_loop)
        # Sine wave breathing between 155 and 165 size
        sine_val = math.sin(progress * 2 * math.pi)
        current_size = 160 + 8 * sine_val
        alpha_pulse = 0.85 + 0.15 * sine_val

        img = Image.new("RGB", (WIDTH, HEIGHT), COLOR_BG)
        draw = ImageDraw.Draw(img)

        draw_expressive_emblem(draw, cx, cy, current_size, alpha=alpha_pulse)

        # Steady text
        ty = cy + 180
        draw.text((cx, ty), "ExpressiveOS", fill=(245, 245, 245), anchor="mm")
        draw.text((cx, ty + 40), "Android 17", fill=(0, 200, 160), anchor="mm")

        # Fluid ambient ring
        ring_r = current_size * 0.95 + 15 * sine_val
        ring_col = (int(0 * alpha_pulse), int(180 * alpha_pulse * 0.3), int(216 * alpha_pulse * 0.3))
        draw.ellipse([cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r], outline=ring_col, width=2)

        filename = os.path.join(part1_dir, f"{i:05d}.png")
        img.save(filename, "PNG")

    # Write desc.txt
    desc_path = os.path.join(output_dir, "desc.txt")
    with open(desc_path, "w") as f:
        f.write(f"{WIDTH} {HEIGHT} {FPS}\n")
        f.write("c 1 0 part0\n")
        f.write("c 0 0 part1\n")

    print(f"Frames generated cleanly in {output_dir}")

def package_bootanimation(work_dir, target_zip):
    print(f"Creating uncompressed bootanimation archive: {target_zip}...")
    with zipfile.ZipFile(target_zip, "w", zipfile.ZIP_STORED) as zf:
        # desc.txt MUST be first
        desc_file = os.path.join(work_dir, "desc.txt")
        zf.write(desc_file, "desc.txt")

        for part in ["part0", "part1"]:
            part_dir = os.path.join(work_dir, part)
            for f in sorted(os.listdir(part_dir)):
                if f.endswith(".png"):
                    full_p = os.path.join(part_dir, f)
                    zf.write(full_p, f"{part}/{f}")
    print(f"bootanimation.zip created successfully! ({os.path.getsize(target_zip)} bytes)")

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    work_dir = os.path.join(script_dir, "build_frames")
    os.makedirs(work_dir, exist_ok=True)
    generate_frames(work_dir)
    zip_out = os.path.join(script_dir, "bootanimation.zip")
    package_bootanimation(work_dir, zip_out)
