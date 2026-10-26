#!/usr/bin/env python3
"""Look a path up in a build's binary fs_config file (out/.../etc/fs_config_files), the
table the image builders and init take file modes from. Prints "<mode> <uid> <gid>
<capabilities>" (mode in octal, capabilities in hex) for the first entry that matches:
the path itself, or a prefix ending in '*'. Exits 1 when nothing matches.

  fs-config.py <fs_config_files> <path, e.g. product/app/Foo/lib/arm64/libfoo.so>
"""
import struct
import sys

HEADER = struct.Struct('<HHHHQ')  # length, mode, uid, gid, capabilities


def entries(data):
    off = 0
    while off < len(data):
        if off + HEADER.size > len(data):
            raise ValueError('truncated entry at byte %d' % off)
        length, mode, uid, gid, caps = HEADER.unpack_from(data, off)
        if length <= HEADER.size or off + length > len(data):
            raise ValueError('bad entry length %d at byte %d' % (length, off))
        prefix = data[off + HEADER.size:off + length].split(b'\0', 1)[0].decode()
        yield prefix, mode, uid, gid, caps
        off += length


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    path = sys.argv[2]
    try:
        for prefix, mode, uid, gid, caps in entries(data):
            if prefix == path or (prefix.endswith('*') and path.startswith(prefix[:-1])):
                print('%o %d %d 0x%x' % (mode & 0o7777, uid, gid, caps))
                return 0
    except ValueError as e:
        sys.exit('%s: %s' % (sys.argv[1], e))
    return 1


if __name__ == '__main__':
    sys.exit(main())
