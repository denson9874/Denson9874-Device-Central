#!/usr/bin/env python3
"""Whether two init_boot ramdisks (newc cpio, lz4 or gzip) hold the same entries: name, mode,
owner, device numbers and bytes, whatever their times, order or compression.

  cpio-same.py <ramdisk A> <ramdisk B>

Exit 0 when they do, 1 when not (each difference on stderr, the first 20), 2 when one can't
be read. A device node may differ in its permission bits alone, and each that does is a line
"<name> <A's bits> <B's bits>" on stdout: mkbootfs makes the nodes of the build's dev node
list (META/ramdisk_node_list: dev/console, dev/kmsg, dev/null, dev/urandom) and then gives
them fs_config's mode, which isn't the same in the build's ramdisk (mkbootfs -n before -d: the
compiled-in fs_config, 0644) and in the one target-files packs again (mkbootfs -f with its
canned fs_config, which lists no node, so they get its root entry's 0755). Neither is the
node list's 0600, and it doesn't matter which: only the kernel opens one (/dev/console, as
root, before init runs), and first-stage init mounts a tmpfs on /dev first thing.
"""
import stat
import subprocess
import sys


def entries(path):
    raw = None
    for cmd in (['lz4', '-dc', path], ['gzip', '-dc', path]):
        try:
            r = subprocess.run(cmd, capture_output=True)
        except OSError:
            continue
        if r.returncode == 0 and r.stdout:
            raw = r.stdout
            break
    if raw is None:
        print("can't decompress %s" % path, file=sys.stderr)
        sys.exit(2)
    out, i = {}, 0
    while i + 110 <= len(raw):
        if raw[i:i + 6] not in (b'070701', b'070702'):
            print('%s: not a newc cpio at byte %d' % (path, i), file=sys.stderr)
            sys.exit(2)
        f = [int(raw[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        mode, uid, gid, size, rmaj, rmin, nsz = f[1], f[2], f[3], f[6], f[9], f[10], f[11]
        n = i + 110
        name = raw[n:n + nsz - 1].decode('utf-8', 'surrogateescape')
        d = (n + nsz + 3) & ~3
        if name == 'TRAILER!!!':
            break
        out[name] = (mode, uid, gid, rmaj, rmin, raw[d:d + size])
        i = (d + size + 3) & ~3
    return out


def node_bits_only(x, y):
    """Both the same character or block device, owner and bytes, other permission bits."""
    return (stat.S_IFMT(x[0]) == stat.S_IFMT(y[0])
            and (stat.S_ISCHR(x[0]) or stat.S_ISBLK(x[0]))
            and x[1:] == y[1:])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = entries(sys.argv[1]), entries(sys.argv[2])
    bad, nodes = [], []
    for n in sorted(set(a) | set(b)):
        if a.get(n) == b.get(n):
            continue
        if n in a and n in b and node_bits_only(a[n], b[n]):
            nodes.append(n)
        else:
            bad.append(n)
    for n in nodes:
        print('%s %04o %04o' % (n, stat.S_IMODE(a[n][0]), stat.S_IMODE(b[n][0])))
    for n in bad[:20]:
        print('  differs: %s (%s)' % (n, 'only one side' if n not in a or n not in b else 'mode, owner or bytes'),
              file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
