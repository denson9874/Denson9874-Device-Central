#!/usr/bin/env python3
"""Extract partitions from a full A/B OTA payload.bin: payload_extract.py <payload.bin> <outdir> <part>..."""
import bz2, lzma, struct, sys, os
sys.path.insert(0, os.path.join(os.environ.get("TREE", os.path.expanduser("~/derpfest")), "system/update_engine/scripts"))
import update_metadata_pb2 as um

path, out, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
with open(path, 'rb') as f:
    assert f.read(4) == b'CrAU'
    version, msize = struct.unpack('>QQ', f.read(16))
    sigsize = struct.unpack('>I', f.read(4))[0] if version >= 2 else 0
    m = um.DeltaArchiveManifest(); m.ParseFromString(f.read(msize))
    base = 24 + msize + sigsize
    bs = m.block_size
    Op = um.InstallOperation
    for part in m.partitions:
        if part.partition_name not in names:
            continue
        with open(os.path.join(out, part.partition_name + '.img'), 'wb') as o:
            for op in part.operations:
                f.seek(base + op.data_offset)
                data = f.read(op.data_length)
                if op.type == Op.REPLACE_XZ: data = lzma.decompress(data)
                elif op.type == Op.REPLACE_BZ: data = bz2.decompress(data)
                elif op.type == Op.ZERO: data = b'\0' * sum(e.num_blocks for e in op.dst_extents) * bs
                elif op.type != Op.REPLACE: sys.exit(f'{part.partition_name}: op {op.type} is not a full-OTA op')
                pos = 0
                for e in op.dst_extents:
                    n = e.num_blocks * bs
                    o.seek(e.start_block * bs); o.write(data[pos:pos + n]); pos += n
            o.truncate(part.new_partition_info.size)
        print(part.partition_name, part.new_partition_info.size)
