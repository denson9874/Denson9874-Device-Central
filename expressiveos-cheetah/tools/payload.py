#!/usr/bin/env python3
"""Read an A/B OTA package's payload.bin without unpacking the zip.

  payload.py offset <ota.zip>       byte offset of payload.bin's data in the zip (it's stored),
                                    for ota_extractor -payload_offset
  payload.py partitions <ota.zip>   the partitions the payload writes, one per line, sorted
"""
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
        if 24 + manifest_len > zipfile.ZipFile(path).getinfo('payload.bin').file_size:
            sys.exit('%s: payload.bin ends inside its manifest' % path)
        manifest = f.read(manifest_len)
    # DeltaArchiveManifest.partitions (field 13) -> PartitionUpdate.partition_name (field 1).
    # Walked as protobuf: other messages have a field 1 string too (dynamic_partition_metadata's
    # group name, google_dynamic_partitions)
    names = set()
    for field, value in fields(manifest, path):
        if field == 13:
            name = [v for f, v in fields(value, path) if f == 1]
            if len(name) != 1 or not isinstance(name[0], bytes):
                sys.exit('%s: a partition in the payload manifest has no name' % path)
            names.add(name[0].decode())
    if not names:
        sys.exit('%s: the payload manifest names no partition' % path)
    return sorted(names)


def fields(data, path):
    """(field number, value) for each field of a protobuf message: an int, or bytes for a
    length-delimited field"""
    def varint():
        nonlocal i
        n = shift = 0
        while True:
            if i >= len(data) or shift > 63:
                sys.exit('%s: bad varint in the payload manifest' % path)
            b = data[i]
            i += 1
            n |= (b & 0x7f) << shift
            shift += 7
            if b < 0x80:
                return n
    i = 0
    while i < len(data):
        key = varint()
        field, wire = key >> 3, key & 7
        if wire == 0:
            value = varint()
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = int.from_bytes(data[i:i + size], 'little')
            i += size
        elif wire == 2:
            size = varint()
            value = data[i:i + size]
            i += size
        else:
            sys.exit('%s: unknown wire type %d in the payload manifest' % (path, wire))
        if i > len(data):
            sys.exit('%s: the payload manifest is cut short' % path)
        yield field, value


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('offset', 'partitions'):
        sys.exit(__doc__.strip())
    if sys.argv[1] == 'offset':
        print(offset(sys.argv[2]))
    else:
        print('\n'.join(partitions(sys.argv[2])))


if __name__ == '__main__':
    main()
