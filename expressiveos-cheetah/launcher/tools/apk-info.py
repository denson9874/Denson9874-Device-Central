#!/usr/bin/env python3
# Print what fetch-launcher.sh checks in an APK, without aapt2 or apksigner: the package,
# version, the SHA-256 of its v2 signing certificate (first signer), and its
# <uses-permission> and <uses-library> tags, read from the binary AndroidManifest.xml.
# The APK is untrusted input: run it with python3 -I and pass the path as an argument.
# (A copy of viper4android/tools/apk-info.py, so each kit stands alone.)
#
#   apk-info.py <apk>
#     package <name> / versionName <v> / versionCode <n> / cert <sha256>
#     uses-permission <name>            (manifest order)
#     uses-library <name> required=<true|false>
#   apk-info.py --home <apk>...         (launcher-check.sh out; not in ViPER4Android's copy)
#     <apk> TAB home <package>/<activity> priority=<n> enabled=<true|false>
#       for each activity or activity-alias with an intent-filter for MAIN and HOME
#     <apk> TAB unreadable <why>
#   apk-info.py --overlay <apk>          (launcher-check.sh out; not in ViPER4Android's copy)
#     package <name>
#     overlay <targetPackage> <priority> <isStatic> <targetName>   (- for an unset attribute)
import hashlib, struct, sys, zipfile

def die(msg):
    sys.exit("apk-info: " + msg)

def v2_cert(path):
    d = open(path, "rb").read()
    eocd = d.rfind(b"PK\x05\x06")
    if eocd < 0 or eocd + 22 > len(d): die("no zip end of central directory")
    cd = struct.unpack_from("<I", d, eocd + 16)[0]
    if cd < 24 or d[cd - 16:cd] != b"APK Sig Block 42": die("no APK signing block")
    size = struct.unpack_from("<Q", d, cd - 24)[0]
    if size > cd - 8: die("bad APK signing block size")
    blk = d[cd - size - 8:cd - 24]
    def lp(b, o):
        if o + 4 > len(b): die("truncated signing block")
        n = struct.unpack_from("<I", b, o)[0]
        if o + 4 + n > len(b): die("truncated signing block")
        return b[o + 4:o + 4 + n], o + 4 + n
    pos = 8
    while pos + 12 <= len(blk):
        n, i = struct.unpack_from("<QI", blk, pos)
        v = blk[pos + 12:pos + 8 + n]
        if i == 0x7109871a:   # APK Signature Scheme v2: signers > signer > signed data > certificates
            signer, _ = lp(lp(v, 0)[0], 0); sd, _ = lp(signer, 0); _, o = lp(sd, 0)
            cert, _ = lp(lp(sd, o)[0], 0)
            return hashlib.sha256(cert).hexdigest()
        pos += 8 + n
    die("no v2 signature")

# android: attribute resource ids
R_NAME, R_REQUIRED, R_VERSION_CODE, R_VERSION_NAME = 0x01010003, 0x0101028e, 0x0101021b, 0x0101021c
R_ENABLED, R_PRIORITY = 0x0101000e, 0x0101001c

def manifest(path, home=False, overlay=False):
    with zipfile.ZipFile(path) as z:
        info = z.getinfo("AndroidManifest.xml")
        if info.file_size > 4 << 20: die("AndroidManifest.xml is too big")
        x = z.read(info)
    if len(x) < 8 or struct.unpack_from("<HH", x, 0) != (0x0003, 8): die("not a binary XML manifest")
    strings, resmap, out = [], [], []
    stack = []
    pkg, act, filt = "", None, None
    pos = 8
    while pos + 8 <= len(x):
        typ, hsz, csz = struct.unpack_from("<HHI", x, pos)
        if csz < 8 or pos + csz > len(x): die("bad XML chunk")
        if typ == 0x0001:     # string pool
            cnt, _, flags, sstart = struct.unpack_from("<IIII", x, pos + 8)
            utf8 = flags & 0x100
            for k in range(cnt):
                o = pos + sstart + struct.unpack_from("<I", x, pos + hsz + 4 * k)[0]
                if utf8:
                    def ln(o):
                        b = x[o]
                        return (((b & 0x7f) << 8) | x[o + 1], o + 2) if b & 0x80 else (b, o + 1)
                    _, o = ln(o); n, o = ln(o)
                    strings.append(x[o:o + n].decode("utf-8", "replace"))
                else:
                    n = struct.unpack_from("<H", x, o)[0]; o += 2
                    if n & 0x8000:
                        n = ((n & 0x7fff) << 16) | struct.unpack_from("<H", x, o)[0]; o += 2
                    strings.append(x[o:o + 2 * n].decode("utf-16-le", "replace"))
        elif typ == 0x0180:   # resource ids of the attribute names
            resmap = list(struct.unpack_from("<%dI" % ((csz - hsz) // 4), x, pos + hsz))
        elif typ == 0x0102:   # start element
            ext = pos + hsz
            _, name, astart, asize, acount = struct.unpack_from("<IIHHH", x, ext)
            tag = strings[name]
            attrs, named = {}, {}
            for k in range(acount):
                a = ext + astart + k * asize
                _, aname, raw, _, _, dtype, data = struct.unpack_from("<IIIHBBI", x, a)
                key = resmap[aname] if aname < len(resmap) and resmap[aname] else strings[aname]
                if raw != 0xFFFFFFFF: val = strings[raw]
                elif dtype == 0x03: val = strings[data]
                elif dtype == 0x12: val = "true" if data else "false"
                elif dtype in (0x10, 0x11): val = str(data - (1 << 32) if data & 0x80000000 else data)
                else: val = str(data)
                attrs[key] = val
                named[strings[aname]] = val
            parent = stack[-1] if stack else None
            stack.append(tag)
            if overlay:
                if tag == "manifest" and parent is None:
                    out.append("package " + attrs.get("package", ""))
                elif tag == "overlay" and parent == "manifest":
                    out.append("overlay " + " ".join(named.get(a) or "-" for a in
                                                     ("targetPackage", "priority", "isStatic", "targetName")))
            elif home:
                if tag == "manifest" and parent is None:
                    pkg = attrs.get("package", "")
                elif tag in ("activity", "activity-alias") and parent == "application":
                    name = attrs.get(R_NAME, "")
                    act = (pkg + name if name.startswith(".") else name, attrs.get(R_ENABLED, "true"))
                elif tag == "intent-filter" and parent in ("activity", "activity-alias") and act:
                    filt = (attrs.get(R_PRIORITY, "0"), set())
                elif tag in ("action", "category") and parent == "intent-filter" and filt:
                    filt[1].add(tag + " " + attrs.get(R_NAME, ""))
            elif tag == "manifest" and parent is None:
                out.append("package " + attrs.get("package", ""))
                out.append("versionName " + attrs.get(R_VERSION_NAME, ""))
                out.append("versionCode " + attrs.get(R_VERSION_CODE, ""))
            elif tag in ("uses-permission", "uses-permission-sdk-23") and parent == "manifest":
                out.append("%s %s" % (tag, attrs.get(R_NAME, "")))
            elif tag == "uses-library" and parent == "application":
                out.append("uses-library %s required=%s" % (attrs.get(R_NAME, ""), attrs.get(R_REQUIRED, "true")))
        elif typ == 0x0103:   # end element
            tag = stack.pop() if stack else None
            if home and tag == "intent-filter" and filt and act:
                if {"action android.intent.action.MAIN", "category android.intent.category.HOME"} <= filt[1]:
                    out.append("home %s/%s priority=%s enabled=%s" % (pkg, act[0], filt[0], act[1]))
                filt = None
            elif home and tag in ("activity", "activity-alias"):
                act = None
        pos += csz
    return out

if len(sys.argv) > 2 and sys.argv[1] == "--home":
    for apk in sys.argv[2:]:
        try:
            for line in manifest(apk, home=True):
                print(apk + "\t" + line)
        except (KeyError, IndexError, struct.error, zipfile.BadZipFile, OSError, SystemExit) as e:
            print(apk + "\tunreadable " + str(e).replace("\n", " "))
    sys.exit(0)
if len(sys.argv) == 3 and sys.argv[1] == "--overlay":
    try:
        print("\n".join(manifest(sys.argv[2], overlay=True)))
    except (KeyError, IndexError, struct.error, zipfile.BadZipFile, OSError) as e:
        die("can't read %s: %s" % (sys.argv[2], e))
    sys.exit(0)
if len(sys.argv) != 2: die("usage: apk-info.py <apk> | --home <apk>... | --overlay <apk>")
try:
    lines = manifest(sys.argv[1])
    lines.insert(3, "cert " + v2_cert(sys.argv[1]))
except (KeyError, IndexError, struct.error, zipfile.BadZipFile, OSError) as e:
    die("can't read %s: %s" % (sys.argv[1], e))
print("\n".join(lines))
