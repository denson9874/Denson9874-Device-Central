#!/usr/bin/env python3
"""Check rendered boot animation frames and pack them into bootanimation.zip.

usage: pack.py SRC_DIR OUT.zip

SRC_DIR holds desc.txt and one folder per part (img00000.png, img00001.png, ...).
The zip is what Android's bootanimation reads: every entry STORED (it maps PNGs straight
out of the zip), desc.txt first, fixed timestamps and order, so the same frames always
give the same bytes. Prints the zip's sha256 on the last line.
"""
import hashlib, os, re, struct, sys, zipfile, zlib

W, H = 1080, 1320
BAD_CHUNKS = {b"iCCP", b"gAMA", b"sRGB", b"cHRM"}   # would shift #141228 on some decoders
STAMP = (2026, 1, 1, 0, 0, 0)

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def png_info(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path}: not a PNG")
    pos, ihdr, chunks = 8, None, []
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if zlib.crc32(typ + body) != struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])[0]:
            fail(f"{path}: bad CRC in {typ!r}")
        chunks.append(typ)
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        pos += 12 + n
    return ihdr, chunks, data

def main():
    if len(sys.argv) != 3:
        fail("usage: pack.py SRC_DIR OUT.zip")
    src, out = sys.argv[1], sys.argv[2]
    desc_path = os.path.join(src, "desc.txt")
    desc = open(desc_path, "rb").read()
    if b"\r" in desc or not desc.endswith(b"\n"):
        fail("desc.txt must use LF line endings and end with a newline (or the last part is dropped)")
    lines = desc.decode("ascii").splitlines()
    if lines[0].split() != [str(W), str(H), "30"]:
        fail(f"desc.txt line 1 is {lines[0]!r}, expected '{W} {H} 30'")
    parts = []
    for l in lines[1:]:
        m = re.fullmatch(r"([cp]) (\d+) (\d+) (part\d) #([0-9a-f]{6})", l)
        if not m:
            fail(f"desc.txt: unexpected line {l!r}")
        parts.append(m.group(4))
    names = sorted(os.listdir(src))
    extra = set(names) - set(parts) - {"desc.txt"}
    if extra:
        fail(f"stray files in {src}: {sorted(extra)}")
    entries = [("desc.txt", desc)]
    total_frames = 0
    for p in parts:
        d = os.path.join(src, p)
        files = sorted(os.listdir(d))
        want = [f"img{i:05d}.png" for i in range(len(files))]
        if files != want:
            fail(f"{p}: frames must be img00000.png.. with no gaps or other files")
        entries.append((p + "/", None))
        for f in files:
            ihdr, chunks, data = png_info(os.path.join(d, f))
            w, h, depth, ctype = ihdr[:4]
            if (w, h) != (W, H) or depth != 8 or ctype != 2:
                fail(f"{p}/{f}: {w}x{h} depth {depth} colour type {ctype}; must be {W}x{H} 8-bit RGB")
            bad = BAD_CHUNKS.intersection(chunks)
            if bad:
                fail(f"{p}/{f}: has colour chunks {sorted(bad)}")
            entries.append((f"{p}/{f}", data))
        total_frames += len(files)
    tmp = out + ".part"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as z:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, STAMP)
            zi.compress_type = zipfile.ZIP_STORED
            zi.create_system = 3
            if data is None:
                zi.external_attr = (0o40755 << 16) | 0x10
                z.writestr(zi, b"")
            else:
                zi.external_attr = 0o100644 << 16
                z.writestr(zi, data)
    with zipfile.ZipFile(tmp) as z:
        for zi in z.infolist():
            if zi.compress_type != zipfile.ZIP_STORED:
                fail(f"{zi.filename} isn't STORED")
    os.replace(tmp, out)
    sha = hashlib.sha256(open(out, "rb").read()).hexdigest()
    print(f"{out}: {len(parts)} parts, {total_frames} frames, {os.path.getsize(out)} bytes")
    print(f"sha256 {sha}")

if __name__ == "__main__":
    main()
