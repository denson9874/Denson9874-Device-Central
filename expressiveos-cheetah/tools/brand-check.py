#!/usr/bin/env python3
"""Check a built ExpressiveOS tree for Evolution X branding a user could see.

usage: brand-check.py OUT            # OUT = out/target/product/cheetah

Scans, in UTF-8 and UTF-16 (resource string pools use either):
  - every APK under system, system_ext, product and vendor: resources.arsc and
    AndroidManifest.xml, and for the apps the kit rebrands every res/ XML too;
  - the dex code of the apps the kit rebrands, framework.jar and services.jar, for text
    and links;
  - system/bin, system/lib64 and the APEXes' payload images (raw bytes: they hold crash_dump
    and the apps some APEXes carry) for the same text and for the crash report header
    (debuggerd's tombstones).
Every hit must be on the allowlist below: links the build keeps on purpose, none of them
shown to users. Prints one FAIL line per other hit, then BRAND_CHECK=OK or BRAND_CHECK=FAIL.
"""
import io
import os
import re
import sys
import zipfile

# What users must never see (case-sensitive: class and resource names such as
# org.evolution.* or evolution_logo_paths are internal and stay)
PATTERNS = ["Evolution X", "EvolutionX", "Evolution-X", "evolution-x.org", "Evo Egg", "The Evolver"]
# Text kept on purpose. Each entry: (regex over the whole string found, why)
ALLOW = [
    (r"https://gitea\.com/Evolution-X/keybox/raw/branch/main/keybox\.xml",
     "the Evolver's keybox download (works as before; its summary names no one)"),
    (r"https://git\.evolution-x\.org/EvoX/keybox/raw/branch/main/keybox\.xml",
     "services.jar AxSpoofManager's keybox fetch, not shown"),
    (r"https://raw\.githubusercontent\.com/Evolution-X/www_gitres/main/devices/images/%s\.webp",
     "Settings' hardware info: the phone's photo"),
    (r"https://raw\.githubusercontent\.com/Evolution-X/vendor_themes/cnb/themes_v2\.json",
     "Theme Store's theme catalog"),
    (r"https://paste\.evolution-x\.org",
     "PastyUtils in framework.jar: nothing in the build calls it any more"),
    (r"Mozilla/5\.0 \(Linux; Android 14\) EvolutionX/HardwareInfo",
     "the Evolver's HTTP user agent, not shown"),
    # dex: internal names (classes, their source files, log tags), never shown
    (r"L[\w/$]*EvolutionX[\w$]*;", "a class name"),
    (r"^.?EvolutionX\w*\.(kt|java)$", "a class's source file name"),
    (r"^.?EvolutionXLogoPref$", "a log tag"),
]
# The apps (by APK name) whose resource XML and dex are scanned in full
REBRANDED = {"SettingsGoogle", "Settings", "Updater", "EvoEgg", "AxSandbox", "LineageParts",
             "LineageSettingsProvider", "SystemUIGoogle", "SystemUI", "framework-res",
             "org.lineageos.platform-res", "PixelSetupWizardOverlayExpressive"}
JARS = ["system/framework/framework.jar", "system/framework/services.jar"]

out = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
bad = 0
kept = {}


def strings_around(data, needle, enc):
    """The printable string around each occurrence of needle (encoded with enc) in data."""
    pat = needle.encode(enc)
    w = 2 if enc == "utf-16-le" else 1
    i = data.find(pat)
    while i >= 0:
        a, b = i, i + len(pat)
        while a - w >= 0:
            ch = data[a - w:a].decode(enc, "replace")
            if not ch.isprintable() or ch in '"\x00':
                break
            a -= w
        while b + w <= len(data):
            ch = data[b:b + w].decode(enc, "replace")
            if not ch.isprintable() or ch in '"\x00':
                break
            b += w
        yield data[a:b].decode(enc, "replace")
        i = data.find(pat, i + len(pat))


def scan(where, data):
    global bad
    for enc in ("utf-8", "utf-16-le"):
        for p in PATTERNS:
            for s in set(strings_around(data, p, enc)):
                why = next((w for r, w in ALLOW if re.search(r, s)), None)
                if why:
                    kept.setdefault((s, why), set()).add(where)
                else:
                    bad += 1
                    print(f"FAIL: {where}: {s!r}")


apks = []
for part in ("system", "system_ext", "product", "vendor"):
    for root, dirs, files in os.walk(os.path.join(out, part)):
        apks += [os.path.join(root, f) for f in files if f.endswith(".apk")]
if not apks:
    sys.exit(f"FAIL: no APKs under {out}\nBRAND_CHECK=FAIL")
n = 0
for apk in sorted(apks):
    name = os.path.basename(apk)[:-4]
    rel = os.path.relpath(apk, out)
    try:
        z = zipfile.ZipFile(apk)
    except zipfile.BadZipFile:
        continue
    for e in z.namelist():
        full = name in REBRANDED
        if e in ("resources.arsc", "AndroidManifest.xml") or (full and (
                (e.startswith("res/") and e.endswith(".xml")) or re.fullmatch(r"classes\d*\.dex", e))):
            scan(f"{rel}!{e}", z.read(e))
            n += 1
for jar in JARS:
    p = os.path.join(out, jar)
    if not os.path.exists(p):
        bad += 1
        print(f"FAIL: no {jar}")
        continue
    z = zipfile.ZipFile(p)
    for e in z.namelist():
        if re.fullmatch(r"classes\d*\.dex", e):
            scan(f"{jar}!{e}", z.read(e))
            n += 1


def apex_payload(path):
    """An .apex's payload image (a .capex's from its original_apex), or None."""
    try:
        z = zipfile.ZipFile(path)
        if "original_apex" in z.namelist():
            z = zipfile.ZipFile(io.BytesIO(z.read("original_apex")))
        return z.read("apex_payload.img") if "apex_payload.img" in z.namelist() else None
    except (zipfile.BadZipFile, KeyError):
        return None


# debuggerd writes "<ROM> Version: '...'" at the top of every tombstone and bug report: the
# linkers and pbtombstone in system/bin, crash_dump in the runtime APEX
header = False
blobs = []
for d in ("system/bin", "system/lib64"):
    for root, dirs, files in os.walk(os.path.join(out, d)):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p) and os.path.isfile(p):
                blobs.append(os.path.relpath(p, out))
napex = 0
for part in ("system", "system_ext", "product", "vendor"):
    d = os.path.join(out, part, "apex")
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.endswith((".apex", ".capex")):
            blobs.append(os.path.join(part, "apex", f))
for rel in blobs:
    data = open(os.path.join(out, rel), "rb").read()
    if rel.endswith((".apex", ".capex")):
        data = apex_payload(os.path.join(out, rel))
        if data is None:
            print(f"note: {rel} has no payload image to read")
            continue
        napex += 1
        # The payload is a file system image: the apps inside keep their string pools as is
        scan(f"{rel}!apex_payload.img", data)
        n += 1
    if b"Evolution X Version" in data:
        bad += 1
        print(f"FAIL: {rel}: tombstones say 'Evolution X Version'")
    header = header or b"ExpressiveOS Version" in data
if not header:
    bad += 1
    print("FAIL: no binary or APEX writes 'ExpressiveOS Version' in tombstones (patches/system_core)")

for (s, why), wheres in sorted(kept.items()):
    print(f"note: kept {s!r} ({why}) in {', '.join(sorted(wheres))}")
print(f"OK: {len(apks)} APKs and {napex} APEX payloads, {n} entries scanned" if bad == 0
      else f"{bad} Evolution X strings found")
print("BRAND_CHECK=OK" if bad == 0 else "BRAND_CHECK=FAIL")
sys.exit(1 if bad else 0)
