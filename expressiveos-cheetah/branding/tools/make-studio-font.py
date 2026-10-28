#!/usr/bin/env python3
"""Expressive Studio's display face, cut from Google Sans Flex (packages_apps_Evolver 0005).

usage: make-studio-font.py FONT.ttf OUT.ttf

FONT.ttf is the variable Google Sans Flex (googlesansflex_variable.ttf, see README.md). OUT.ttf is
the font at its rounded terminals (ROND 100), text optical size (opsz 18), normal width and grade,
upright, with its weights from 400 to 800 still variable, and only Latin, the punctuation Studio's
strings use and the euro and trademark signs. It goes to the Evolver's
res/font/google_sans_flex_rounded.ttf.

Needs fonttools. Google Sans Flex is under the SIL Open Font License 1.1, with no Reserved Font
Name; its copyright and licence stay in the cut font's name table, and the licence's text goes with
it (the Evolver's licenses/GoogleSansFlex-OFL.txt).
"""
import argparse

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

UNICODES = (
    list(range(0x20, 0x7F))          # ASCII
    + list(range(0xA0, 0x180))       # Latin-1 Supplement, Latin Extended-A
    + [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x20AC, 0x2122]
)
FEATURES = ["kern", "liga", "calt", "tnum", "pnum", "lnum", "ccmp", "locl", "mark", "mkmk"]
AXES = {"opsz": 18, "wdth": 100, "GRAD": 0, "slnt": 0, "ROND": 100, "wght": (400, 800)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("font")
    ap.add_argument("out")
    a = ap.parse_args()

    # Subset first: instancing the whole font fails (KeyError 'l.logo', fontTools 4.x)
    # The source's timestamp, not today's, so the same font always gives the same file
    f = TTFont(a.font, lazy=False, recalcTimestamp=False)
    opts = subset.Options()
    opts.layout_features = FEATURES
    opts.name_IDs = ["*"]
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.hinting = False
    s = subset.Subsetter(opts)
    s.populate(unicodes=UNICODES)
    s.subset(f)
    f = instancer.instantiateVariableFont(f, AXES)
    f.save(a.out)


if __name__ == "__main__":
    main()
