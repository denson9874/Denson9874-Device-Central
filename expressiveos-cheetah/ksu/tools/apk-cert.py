#!/usr/bin/env python3
# Print the SHA-256 of an APK's v2 signing certificate (the first signer's):
# KernelSU Next's kernel module only trusts the manager signed by
# ksu.conf's manager_cert_sha256. Run it with python3 -I.
#
#   apk-cert.py <apk>
import hashlib, struct, sys
d = open(sys.argv[1], "rb").read()
eocd = d.rfind(b"PK\x05\x06"); cd = struct.unpack("<I", d[eocd + 16:eocd + 20])[0]
if d[cd - 16:cd] != b"APK Sig Block 42": sys.exit("no APK signing block")
size = struct.unpack("<Q", d[cd - 24:cd - 16])[0]; blk = d[cd - size - 8:cd - 24]; pos = 8
def lp(b, o): n = struct.unpack("<I", b[o:o + 4])[0]; return b[o + 4:o + 4 + n], o + 4 + n
while pos < len(blk):
    n, i = struct.unpack("<QI", blk[pos:pos + 12]); v = blk[pos + 12:pos + 8 + n]
    if i == 0x7109871a:   # APK Signature Scheme v2: signers > signer > signed data > certificates
        signer, _ = lp(lp(v, 0)[0], 0); sd, _ = lp(signer, 0); _, o = lp(sd, 0); cert, _ = lp(lp(sd, o)[0], 0)
        print(hashlib.sha256(cert).hexdigest()); sys.exit()
    pos += 8 + n
sys.exit("no v2 signature")
