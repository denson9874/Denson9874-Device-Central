#!/usr/bin/env python3
"""SukiSU's LKM patch of an init_boot ramdisk (newc cpio, uncompressed), as its ksud boot-patch
does it (userspace/ksud/src/boot_patch.rs): /init becomes /init.real, SukiSU's ksuinit is the
new /init and kernelsu.ko is /kernelsu.ko, both 0755. No ksu_config: with a module given, ksud
writes none either. Every other entry is copied byte for byte (device nodes included, which
is why this edits the archive instead of unpacking it: making those needs root).

  ramdisk-ksu.py <stock cpio> <out cpio> <ksuinit> <kernelsu.ko>
"""
import sys

def entries(data):
    off = 0
    while True:
        h = data[off:off + 110]
        if len(h) < 110 or h[:6] not in (b'070701', b'070702'):
            sys.exit('ramdisk-ksu.py: not a newc cpio at offset %d' % off)
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = f[11], f[6]
        name_end = off + 110 + namesize
        name = data[off + 110:name_end - 1].decode('utf-8', 'surrogateescape')
        body = (name_end + 3) & ~3
        end = (body + filesize + 3) & ~3
        if name == 'TRAILER!!!':
            return
        yield name, f, h[:6], data[body:body + filesize]
        off = end

def pack(magic, f, name, body):
    n = name.encode('utf-8', 'surrogateescape') + b'\0'
    f = list(f); f[11] = len(n); f[6] = len(body)
    out = magic + b''.join(b'%08X' % v for v in f) + n
    out += b'\0' * (-len(out) % 4) + body
    return out + b'\0' * (-len(out) % 4)

def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    src, dst, ksuinit, ko = sys.argv[1:]
    old = list(entries(open(src, 'rb').read()))
    names = {e[0] for e in old}
    for bad in ('kernelsu.ko', 'init.real', '.backup', 'overlay.d'):
        if bad in names:
            sys.exit('ramdisk-ksu.py: the ramdisk already has %s: not a stock init_boot' % bad)
    if 'init' not in names:
        sys.exit('ramdisk-ksu.py: the ramdisk has no init')
    ino = max(e[1][0] for e in old) + 1
    out = b''
    for name, f, magic, body in old:
        out += pack(magic, f, 'init.real' if name == 'init' else name, body)
    for name, path in (('init', ksuinit), ('kernelsu.ko', ko)):
        body = open(path, 'rb').read()
        # ino, mode (regular 0755), uid, gid, nlink, mtime, size, dev and rdev, namesize, check
        out += pack(b'070701', [ino, 0o100755, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0], name, body)
        ino += 1
    out += pack(b'070701', [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0], 'TRAILER!!!', b'')
    open(dst, 'wb').write(out)
    print('OK: init -> init.real, init = %s, kernelsu.ko = %s (%d entries)' % (ksuinit, ko, len(old) + 2))

main()
