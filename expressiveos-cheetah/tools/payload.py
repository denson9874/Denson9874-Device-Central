#!/usr/bin/env python3
"""Read an A/B OTA package's payload.bin without unpacking the zip.

  payload.py offset <ota.zip>       byte offset of payload.bin's data in the zip (it's stored),
                                    for ota_extractor -payload_offset
  payload.py partitions <ota.zip>   the partitions the payload writes, one per line, sorted
"""
import re
import struct
import sys
import zipfile


def offset(path):
    info = zipfile.ZipFile(path).getinfo('payload.bin')
    if info.compress_type != zipfile.ZIP_STORED:
        sys.exit('%s: payload.bin is compressed' % path)
    with open(path, 'rb') as f:
        f.seek(info.header_offset)
        header = f.read(30)
        if header[:4] != b'PK\x03\x04':
            sys.exit('%s: no local header for payload.bin' % path)
        name_len, extra_len = struct.unpack('<HH', header[26:30])
    return info.header_offset + 30 + name_len + extra_len


def partitions(path):
    with open(path, 'rb') as f:
        f.seek(offset(path))
        if f.read(4) != b'CrAU':
            sys.exit('%s: payload.bin has no CrAU magic' % path)
        f.read(8)  # major version
        manifest_len, = struct.unpack('>Q', f.read(8))
        f.read(4)  # metadata signature size
        manifest = f.read(manifest_len)
    # DeltaArchiveManifest.partitions (field 13) -> PartitionUpdate.partition_name (field 1)
    return sorted({m.group(2).decode() for m in re.finditer(rb'\x0a([\x02-\x20])([a-z0-9_]{2,32})', manifest)
                   if len(m.group(2)) == m.group(1)[0]})


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('offset', 'partitions'):
        sys.exit(__doc__.strip())
    if sys.argv[1] == 'offset':
        print(offset(sys.argv[2]))
    else:
        print('\n'.join(partitions(sys.argv[2])))


if __name__ == '__main__':
    main()
