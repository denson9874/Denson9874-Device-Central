#!/usr/bin/env python3
"""Check an A/B OTA package's payload.bin signatures the way update_engine does, without
update_engine's code (Evolution X's delta_generator accepts any signature).

  payload-sig.py <ota.zip> <otacerts.zip | cert.x509.pem | key.pub.pem>

The metadata signature covers the payload header and manifest; the payload signature
covers everything but the two signature blobs (payload_signer.cc CalculateHashFromPayload).
Both must verify with one key of the second argument (update_engine reads the keys of
/system/etc/security/otacerts.zip). Each signature is checked with
openssl pkeyutl -verify -pkeyopt digest:sha256, the inverse of PayloadSigner.SignHashFile.
Prints one line per signature and, last, PAYLOAD_SIG=OK <cert sha256> or PAYLOAD_SIG=FAIL.
Run it with python3 -I.
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

CHUNK = 1 << 20


def fail(msg):
    print('FAIL: ' + msg)
    print('PAYLOAD_SIG=FAIL')
    sys.exit(1)


def varint(buf, i):
    v = s = 0
    while True:
        if i >= len(buf):
            raise ValueError('truncated varint')
        b = buf[i]
        i += 1
        v |= (b & 0x7f) << s
        s += 7
        if not b & 0x80:
            return v, i


def fields(buf):
    """(field number, wire type, value) of one protobuf message's top-level fields."""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            n, i = varint(buf, i)
            v, i = buf[i:i + n], i + n
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise ValueError('unsupported wire type %d' % wt)
        if i > len(buf):
            raise ValueError('truncated field %d' % num)
        yield num, wt, v


def signatures(blob):
    """Signatures.signatures -> [data truncated to unpadded_signature_size]."""
    out = []
    for num, wt, sig in fields(blob):
        if num != 1 or wt != 2:
            continue
        data, unpadded = None, None
        for n, w, v in fields(sig):
            if n == 2 and w == 2:
                data = v
            elif n == 3 and w == 5:
                unpadded, = struct.unpack('<I', v)
        if data is None:
            continue
        if unpadded is not None:
            if unpadded > len(data):
                raise ValueError('unpadded_signature_size > signature size')
            data = data[:unpadded]
        out.append(data)
    return out


def payload_range(path):
    z = zipfile.ZipFile(path)
    info = z.getinfo('payload.bin')
    if info.compress_type != zipfile.ZIP_STORED:
        fail('%s: payload.bin is compressed' % path)
    with open(path, 'rb') as f:
        f.seek(info.header_offset)
        h = f.read(30)
        if h[:4] != b'PK\x03\x04':
            fail('%s: no local header for payload.bin' % path)
        name_len, extra_len = struct.unpack('<HH', h[26:30])
    return info.header_offset + 30 + name_len + extra_len, info.file_size


def hash_ranges(f, ranges):
    h = hashlib.sha256()
    for start, length in ranges:
        f.seek(start)
        while length:
            b = f.read(min(CHUNK, length))
            if not b:
                fail('payload.bin ends early')
            h.update(b)
            length -= len(b)
    return h.digest()


def openssl(*args, data=None):
    return subprocess.run(['openssl'] + list(args), input=data, capture_output=True)


def keys(path, tmp):
    """[(label, public key PEM path)] from otacerts.zip, a certificate or a public key."""
    blobs = []
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        blobs = [(n, z.read(n)) for n in z.namelist() if not n.endswith('/')]
    else:
        with open(path, 'rb') as f:
            blobs = [(os.path.basename(path), f.read())]
    out = []
    for name, blob in blobs:
        r = openssl('x509', '-noout', '-pubkey', data=blob)
        if r.returncode == 0:
            fp = openssl('x509', '-noout', '-fingerprint', '-sha256', data=blob).stdout.decode()
            label = fp.split('=', 1)[-1].strip().replace(':', '')
            pem = r.stdout
        else:
            r = openssl('pkey', '-pubin', '-pubout', data=blob)
            if r.returncode != 0:
                fail('%s holds %s, which is neither a certificate nor a public key' % (path, name))
            label, pem = 'pubkey:' + hashlib.sha256(r.stdout).hexdigest().upper(), r.stdout
        p = os.path.join(tmp, 'key%d.pem' % len(out))
        with open(p, 'wb') as f:
            f.write(pem)
        out.append((label, p))
    if not out:
        fail('%s holds no keys' % path)
    return out


def verified(digest, sigs, key, tmp):
    hp, sp = os.path.join(tmp, 'hash'), os.path.join(tmp, 'sig')
    with open(hp, 'wb') as f:
        f.write(digest)
    for sig in sigs:
        with open(sp, 'wb') as f:
            f.write(sig)
        if openssl('pkeyutl', '-verify', '-pubin', '-inkey', key, '-pkeyopt', 'digest:sha256',
                   '-in', hp, '-sigfile', sp).returncode == 0:
            return True
    return False


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    ota, trusted = sys.argv[1:]
    base, size = payload_range(ota)
    with open(ota, 'rb') as f:
        f.seek(base)
        hdr = f.read(24)
        if len(hdr) < 24 or hdr[:4] != b'CrAU':
            fail('payload.bin has no CrAU magic')
        major, manifest_size, meta_sig_size = struct.unpack('>QQI', hdr[4:24])
        if major != 2:
            fail('payload major version %d, expected 2' % major)
        metadata_size = 24 + manifest_size
        if metadata_size + meta_sig_size > size:
            fail('metadata (%d + %d) larger than payload.bin (%d)' % (metadata_size, meta_sig_size, size))
        manifest = f.read(manifest_size)
        meta_sig_blob = f.read(meta_sig_size)
        sig_off = sig_size = None
        try:
            for num, wt, v in fields(manifest):
                if num == 4 and wt == 0:
                    sig_off = v
                elif num == 5 and wt == 0:
                    sig_size = v
        except ValueError as e:
            fail('manifest: %s' % e)
        if sig_off is None or sig_size is None:
            fail('manifest has no signatures_offset/signatures_size: payload.bin is unsigned')
        sig_abs = metadata_size + meta_sig_size + sig_off
        if sig_abs + sig_size != size:
            fail('payload signature (%d + %d) does not end payload.bin (%d)' % (sig_abs, sig_size, size))
        if not meta_sig_size:
            fail('payload.bin has no metadata signature')
        f.seek(base + sig_abs)
        payload_sig_blob = f.read(sig_size)
        meta_hash = hash_ranges(f, [(base, metadata_size)])
        payload_hash = hash_ranges(f, [(base, metadata_size),
                                       (base + metadata_size + meta_sig_size,
                                        sig_off)])
    try:
        meta_sigs, payload_sigs = signatures(meta_sig_blob), signatures(payload_sig_blob)
    except ValueError as e:
        fail('signature blob: %s' % e)
    if not meta_sigs or not payload_sigs:
        fail('payload.bin carries %d metadata and %d payload signatures' % (len(meta_sigs), len(payload_sigs)))
    with tempfile.TemporaryDirectory() as tmp:
        for label, key in keys(trusted, tmp):
            m = verified(meta_hash, meta_sigs, key, tmp)
            p = verified(payload_hash, payload_sigs, key, tmp)
            print('%s: metadata %s, payload %s' % (label, 'verified' if m else 'no', 'verified' if p else 'no'))
            if m and p:
                print('PAYLOAD_SIG=OK %s' % label)
                return
    fail('no key in %s verifies both the metadata and the payload signature' % trusted)


if __name__ == '__main__':
    main()
