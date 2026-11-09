"""Picker thumbnails: a 1440x1440 square of each wallpaper, where its ribbon is, at 300x300 (the size
PixelWallpapers2026 uses). usage: thumbs.py DIR   reads and writes DIR/expressiveos_<name>[_thumbnail].png"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image

import wp

TOP = {"bloom": 1500, "dusk": 1560, "dawn": 1440, "mint": 1440}

d = sys.argv[1]
for name, y0 in TOP.items():
    im = Image.open(os.path.join(d, f"expressiveos_{name}.png")).convert("RGB")
    sq = im.crop((0, y0, wp.W, y0 + wp.W)).resize((300, 300), Image.LANCZOS)
    wp.save_png(np.asarray(sq), os.path.join(d, f"expressiveos_{name}_thumbnail.png"))
