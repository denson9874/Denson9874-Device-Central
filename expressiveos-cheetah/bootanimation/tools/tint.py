#!/usr/bin/env python3
"""Draw the holiday boot animation's colour masks as the phone does, for preview.sh.

usage: tint.py SRC_DIR OUT_DIR [RRGGBB,RRGGBB,RRGGBB,RRGGBB]

SRC_DIR is render.py --dynamic's output, or bootanimation_holiday.zip unpacked. OUT_DIR gets
desc.txt without its dynamic_colors line and every frame as 8-bit RGB, coloured the way
BootAnimation's dynamic-colour shader colours it (BootAnimationShaders.h): r*color1 + g*color2
+ b*color3 + a*color4, and grey, (r+g+b+a)/4, where all four channels are 0.05 or more. Parts
before desc.txt's dynamic_colors part take its start colours, parts after it the end colours,
and the part itself goes from one to the other over its transition frames.

The end colours are a holiday's four petal mids in the catalog's petal order (violet, blue,
coral, green), as the Settings.Secure key expressiveos_holiday_bootanim holds them; without
them, the start colours, which is what a phone with no persist.bootanim.color1..4 shows.
Needs numpy and Pillow.
"""
import os, re, sys
import numpy as np
from PIL import Image

THRESHOLD = 0.05                       # cWhiteMaskThreshold

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def colours(hexes):
    return np.array([[int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)] for h in hexes], np.float32)

def shade(mask, cols):
    """mask: (H, W, 4) uint8; cols: (4, 3) in 0-1. The (H, W, 3) uint8 the shader draws."""
    m = mask.astype(np.float32) / 255
    rgb = m @ cols
    grey = (m >= THRESHOLD).all(2)
    rgb[grey] = m[grey].mean(1, keepdims=True)
    return np.clip(np.rint(rgb * 255), 0, 255).astype(np.uint8)

def main():
    if len(sys.argv) not in (3, 4):
        fail("usage: tint.py SRC_DIR OUT_DIR [RRGGBB,RRGGBB,RRGGBB,RRGGBB]")
    src, out = sys.argv[1], sys.argv[2]
    lines = open(os.path.join(src, "desc.txt")).read().splitlines()
    dyn = [l for l in lines if l.startswith("dynamic_colors ")]
    if len(dyn) != 1:
        fail(f"{src}/desc.txt has no dynamic_colors line: not the holiday zip's frames")
    m = re.fullmatch(r"dynamic_colors (\S+) #(\w{6}) #(\w{6}) #(\w{6}) #(\w{6}) (\d+) (\d+)", dyn[0])
    if not m:
        fail(f"desc.txt: can't read {dyn[0]!r}")
    dpart, start, (t0, t1) = m.group(1), colours(m.groups()[1:5]), map(int, m.groups()[5:])
    end = start
    if len(sys.argv) == 4:
        if not re.fullmatch(r"[0-9A-Fa-f]{6}(,[0-9A-Fa-f]{6}){3}", sys.argv[3]):
            fail(f"colours {sys.argv[3]!r}: want four RRGGBB, comma-separated")
        end = colours(sys.argv[3].split(","))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "desc.txt"), "w", newline="\n") as fh:
        fh.write("".join(l + "\n" for l in lines if l not in dyn))
    progress = 0.0
    for l in lines[1:]:
        f = l.split()
        if f[0] not in ("c", "p"):
            continue
        part = f[3]
        os.makedirs(os.path.join(out, part), exist_ok=True)
        frames = sorted(n for n in os.listdir(os.path.join(src, part)) if n.endswith(".png"))
        for i, n in enumerate(frames):
            # BootAnimation.cpp's colorProgress
            p = min(max((i - t0) / max(t1 - t0, 1), 0), 1) if part == dpart else progress
            mask = np.asarray(Image.open(os.path.join(src, part, n)).convert("RGBA"))
            Image.fromarray(shade(mask, start + (end - start) * p), "RGB").save(os.path.join(out, part, n))
        if part == dpart:
            progress = 1.0
    print(f"{out}: drawn in {'the start colours' if len(sys.argv) == 3 else sys.argv[3]}")

if __name__ == "__main__":
    main()
