#!/usr/bin/env python3
# What an APK's code needs from the platform that a given platform doesn't have, read from the
# APK's dex files and the platform's jars (a phone's BOOTCLASSPATH jars, plus the jars of the
# shared libraries the APK names with <uses-library>):
#  - classes, methods and fields its code references that neither the APK nor the platform
#    defines. Running code that touches one is a NoClassDefFoundError, NoSuchMethodError or
#    NoSuchFieldError, unless an SDK check keeps it from running, so the list is for review,
#    not a verdict;
#  - classes the APK defines that the platform defines too. The platform's copy is the one
#    that loads, so what the APK's code uses on it is looked up on the platform's copy;
#  - abstract methods of platform classes and interfaces that a concrete APK class doesn't
#    implement: an AbstractMethodError when the platform calls one (a method an Android 17
#    AIDL interface added, on an APK class built against 16's).
# Expressive Launcher 5.0.5 reached a phone with one (KeyButtonRipple's
# android.companion.virtualdevice.flags.Flags, 2026-10-30): this finds them all at once.
# Reads dex itself (no dexdump), dex 035 to 041 (041's containers too). The APK, jars and
# mapping are untrusted input: run it with python3 -I and pass the paths as arguments.
#
#   dex-refs.py [--mapping <R8 mapping.txt>] <apk> <jar|apk|dex>...
#     missing-class <descriptor> refs=<n> [named-only]
#       defined nowhere; refs counts the lines under it (named-only: no code uses it, it is
#       only in signatures, catches or annotations)
#     missing-method <class>-><name><proto>
#     missing-field <class>-><name>:<type>
#       used by the APK's code and found neither on the class, its superclasses nor their
#       interfaces, one of which is a platform class
#     shadowed <class> <platform file> apk-only=<n>
#       apk-only: methods and fields the APK's copy has and the platform's lacks
#     unimplemented <platform type>-><name><proto>
#       abstract there, and implemented nowhere in the chain of the concrete APK classes
#       listed under it
#     Under each entry: "  from <APK method>" for each method whose code uses it, "  super of
#     <APK class>" or "  interface of <APK class>" for a missing class an APK class extends or
#     implements (that class can't load), "  in <APK class>" for unimplemented. APK names in
#     these lines go through the mapping when one is given (a|b: more than one name fits).
#     summary <n> missing classes, <n> methods, <n> fields, <n> shadowed, <n> unimplemented;
#       <n> platform classes from <n> files; <n> APK methods read, <n> unreadable
#   Platform files are searched in the order given, first definition wins, as on the boot
#   classpath. A method or field is looked up as ART resolves it: the class, its
#   superclasses, then their interfaces. A use whose class chain runs into a missing class is
#   listed under that class. Code in shadowed classes never runs, so it isn't read.
import re, struct, sys, zipfile

NO_INDEX = 0xffffffff
ACC_INTERFACE, ACC_ABSTRACT = 0x200, 0x400
# MethodHandle and VarHandle's signature-polymorphic methods take any proto
POLY = {"Ljava/lang/invoke/MethodHandle;", "Ljava/lang/invoke/VarHandle;"}

# Code units per opcode, and what the 16-bit index in its second unit names: t type, f field,
# m method (dex instruction formats; 0x00's payload pseudo-instructions are sized apart)
WIDTH = [1] * 256
for lo, hi, n in ((0x02, 0x02, 2), (0x03, 0x03, 3), (0x05, 0x05, 2), (0x06, 0x06, 3), (0x08, 0x08, 2),
                  (0x09, 0x09, 3), (0x13, 0x13, 2), (0x14, 0x14, 3), (0x15, 0x16, 2), (0x17, 0x17, 3),
                  (0x18, 0x18, 5), (0x19, 0x1a, 2), (0x1b, 0x1b, 3), (0x1c, 0x1c, 2), (0x1f, 0x20, 2),
                  (0x22, 0x23, 2), (0x24, 0x26, 3), (0x29, 0x29, 2), (0x2a, 0x2c, 3), (0x2d, 0x3d, 2),
                  (0x44, 0x6d, 2), (0x6e, 0x72, 3), (0x74, 0x78, 3), (0x90, 0xaf, 2), (0xd0, 0xe2, 2),
                  (0xfa, 0xfb, 4), (0xfc, 0xfd, 3), (0xfe, 0xff, 2)):
    WIDTH[lo:hi + 1] = [n] * (hi - lo + 1)
KIND = dict([(op, "t") for op in (0x1c, 0x1f, 0x20, 0x22, 0x23, 0x24, 0x25)] +
            [(op, "f") for op in range(0x52, 0x6e)] +
            [(op, "m") for op in list(range(0x6e, 0x73)) + list(range(0x74, 0x79)) + [0xfa, 0xfb]])

def die(msg):
    sys.exit("dex-refs: " + msg)

def uleb(d, o):
    r = s = 0
    while True:
        b = d[o]; o += 1
        r |= (b & 0x7f) << s
        if b < 0x80: return r, o
        s += 7
        if s > 35: raise ValueError("bad uleb128")

class Cls:
    """A class definition: its supertypes, flags and members, and the file it came from."""
    __slots__ = ("name", "sup", "ifaces", "flags", "vm", "dm", "fields", "src")
    def __init__(self, name, sup, ifaces, flags):
        self.name, self.sup, self.ifaces, self.flags = name, sup, ifaces, flags
        self.vm, self.dm, self.fields, self.src = {}, set(), set(), None  # vm: (name, proto) -> access flags

class Dex:
    """One dex (or one dex of a 041 container): its ids, class definitions and code offsets."""
    def __init__(self, d, base, name):
        self.d, self.name = d, name
        ver = d[base + 4:base + 7]
        if d[base:base + 4] != b"dex\n" or not ver.isdigit(): raise ValueError("not a dex")
        self.version = int(ver)
        (self.file_size,) = struct.unpack_from("<I", d, base + 0x20)
        (sids_n, sids_o, tids_n, tids_o, pids_n, pids_o, fids_n, fids_o, mids_n, mids_o,
         cdefs_n, cdefs_o) = struct.unpack_from("<12I", d, base + 0x38)
        # Before 041 every offset is relative to the dex's header. ART reads a 041 container's
        # offsets relative to the container; a dex whose id sections or data are relative to
        # its own header is read too. A dex's id sections follow its header, so an offset
        # below the header's says which; for the data, the layout that gives well-formed
        # strings (each one's UTF-16 length as its prefix says) is the one used.
        def strings_ok(data):
            for i in range(min(sids_n, 64)):
                (so,) = struct.unpack_from("<I", d, ids + sids_o + 4 * i)
                try:
                    n, o = uleb(d, data + so); e = d.index(b"\0", o)
                except (ValueError, IndexError): return False
                if sum(1 for b in d[o:e] if b & 0xc0 != 0x80) != n: return False
            return True
        ids = base if self.version < 41 or sids_o < base else 0
        if ids + sids_o + 4 * sids_n > len(d): raise ValueError("string ids outside the file")
        for self.data in ([base] if self.version < 41 else [0, base]):
            if strings_ok(self.data): break
        else: raise ValueError("no layout gives readable strings")
        self.strings = []
        for i in range(sids_n):
            (so,) = struct.unpack_from("<I", d, ids + sids_o + 4 * i)
            n, o = uleb(d, self.data + so)
            e = d.index(b"\0", o)
            self.strings.append(d[o:e].decode("utf-8", "surrogateescape"))
        self.types = [self.strings[struct.unpack_from("<I", d, ids + tids_o + 4 * i)[0]] for i in range(tids_n)]
        self.protos = []
        for i in range(pids_n):
            _, ret, po = struct.unpack_from("<3I", d, ids + pids_o + 12 * i)
            self.protos.append("(" + "".join(self.type_list(po)) + ")" + self.types[ret])
        self.fields = []   # (class, name, type)
        for i in range(fids_n):
            c, t, n = struct.unpack_from("<HHI", d, ids + fids_o + 8 * i)
            self.fields.append((self.types[c], self.strings[n], self.types[t]))
        self.methods = []  # (class, name, proto)
        for i in range(mids_n):
            c, p, n = struct.unpack_from("<HHI", d, ids + mids_o + 8 * i)
            self.methods.append((self.types[c], self.strings[n], self.protos[p]))
        self.classes, self.code = [], []  # code: (class, name, proto, code_off)
        for i in range(cdefs_n):
            c, acc, sup, ifo, _, _, cdo, _ = struct.unpack_from("<8I", d, ids + cdefs_o + 32 * i)
            k = Cls(self.types[c], None if sup == NO_INDEX else self.types[sup], self.type_list(ifo), acc)
            if cdo:
                o = self.data + cdo
                nsf, o = uleb(d, o); nif, o = uleb(d, o); ndm, o = uleb(d, o); nvm, o = uleb(d, o)
                for count, kind in ((nsf, "f"), (nif, "f"), (ndm, "d"), (nvm, "v")):
                    idx = 0
                    for _ in range(count):
                        diff, o = uleb(d, o); idx += diff
                        mac, o = uleb(d, o)
                        if kind == "f":
                            _, fn, ft = self.fields[idx]; k.fields.add((fn, ft)); continue
                        code, o = uleb(d, o)
                        _, mn, mp = self.methods[idx]
                        if kind == "d": k.dm.add((mn, mp))
                        else: k.vm[(mn, mp)] = mac
                        if code: self.code.append((k.name, mn, mp, code))
            self.classes.append(k)
    def type_list(self, off):
        if not off: return []
        o = self.data + off
        (n,) = struct.unpack_from("<I", self.d, o)
        return [self.types[x] for x in struct.unpack_from("<%dH" % n, self.d, o + 4)]
    def uses(self, off):
        """What a code item's instructions name, as ("t"|"f"|"m", id), and whether they decoded
        to exactly the code's length (a wrong opcode width would leave the walk off the end)."""
        d, o = self.d, self.data + off
        (n,) = struct.unpack_from("<I", d, o + 12)
        u = struct.unpack_from("<%dH" % n, d, o + 16)
        out, pc = [], 0
        while pc < n:
            x = u[pc]; op = x & 0xff
            if x == 0x100: pc += 4 + 2 * u[pc + 1]; continue                  # packed-switch data
            if x == 0x200: pc += 2 + 4 * u[pc + 1]; continue                  # sparse-switch data
            if x == 0x300:                                                    # fill-array data
                pc += 4 + (u[pc + 1] * (u[pc + 2] | u[pc + 3] << 16) + 1) // 2; continue
            k = KIND.get(op)
            if k: out.append((k, u[pc + 1]))
            pc += WIDTH[op]
        return out, pc == n

def dexes(path):
    """Every dex in an APK, jar or bare dex file."""
    blobs = []
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = sorted((n for n in z.namelist() if n.startswith("classes") and n.endswith(".dex")),
                           key=lambda n: (len(n), n))
            blobs = [(n, z.read(n)) for n in names]
    else:
        blobs = [(path, open(path, "rb").read())]
    out = []
    for n, d in blobs:
        base = 0
        while base + 0x70 <= len(d) and (base == 0 or d[base:base + 4] == b"dex\n"):
            x = Dex(d, base, "%s!%s@%d" % (path, n, base) if base else "%s!%s" % (path, n))
            out.append(x)
            if x.version < 41 or x.file_size <= 0: break
            base += x.file_size
    return out

def read_mapping(path):
    """An R8 mapping.txt as {obfuscated class: original} and {(obfuscated class, obfuscated
    method name): {original names}}, all classes as descriptors."""
    desc = lambda j: "L" + j.replace(".", "/") + ";"
    cls, meth, cur = {}, {}, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#") or not line.strip(): continue
            if not line[0].isspace():
                m = re.match(r"(\S+) -> (\S+):$", line)
                cur = desc(m.group(2)) if m else None
                if m: cls[cur] = desc(m.group(1))
                continue
            # "    [a:b:]type name(args)[:c[:d]] -> obf"; a qualified name was inlined from elsewhere
            m = re.match(r"\s+(?:\d+:\d+:)?\S+ ([^\s(.]+)\([^)]*\)(?::\d+)*(?::\d+)? -> (\S+)$", line)
            if cur and m: meth.setdefault((cur, m.group(2)), set()).add(m.group(1))
    return cls, meth

def main(argv):
    args, mapping = argv[1:], None
    if args[:1] == ["--mapping"]:
        if len(args) < 2: die("--mapping needs a file")
        try: mapping = read_mapping(args[1])
        except OSError as e: die("can't read %s: %s" % (args[1], e))
        args = args[2:]
    if len(args) < 2: die("usage: dex-refs.py [--mapping <mapping.txt>] <apk> <jar|apk|dex>...")
    bad_input = (OSError, ValueError, IndexError, KeyError, struct.error, zipfile.BadZipFile)
    try:
        app = dexes(args[0])
    except bad_input as e:
        die("can't read %s: %s" % (args[0], e))
    if not app: die("%s has no dex" % args[0])
    plat, files = {}, 0
    for p in args[1:]:
        try:
            ds = dexes(p)
        except bad_input as e:
            print("note: can't read %s: %s" % (p, e)); continue
        if not ds: print("note: %s has no dex (stripped?): its classes count as missing" % p); continue
        files += 1
        for x in ds:
            for c in x.classes:
                if c.name not in plat: c.src = p; plat[c.name] = c
    if not plat: die("no platform classes read")
    apk = {}
    for x in app:
        for c in x.classes: apk.setdefault(c.name, c)
    # Parent first, as on the phone: a platform class wins over the APK's copy
    known = dict(apk); known.update(plat)

    def elem(t):   # the class an array or class type names, or None for a primitive
        t = t.lstrip("[")
        return t if t.startswith("L") else None
    def chain(c):  # the class, its superclasses, then their interfaces; None and the gap if a link is missing
        seen, order, ifaces, cur = set(), [], [], c
        while cur:
            if cur not in known: return None, cur
            seen.add(cur); order.append(cur)
            ifaces += known[cur].ifaces
            cur = known[cur].sup
        while ifaces:
            i = ifaces.pop(0)
            if i in seen: continue
            if i not in known: return None, i
            seen.add(i); order.append(i); ifaces += known[i].ifaces
        return order, None
    def shown(s):  # an APK name or member through the mapping
        if not mapping: return s
        cls, meth = mapping
        c, sep, rest = s.partition("->")
        out = cls.get(c, c)
        if sep:
            name, paren, proto = rest.partition("(")
            names = sorted(meth.get((c, name), ())) or [name]
            out += sep + "|".join(names) + paren + re.sub(r"L[^;]+;", lambda m: cls.get(m.group(0), m.group(0)), proto)
        return out

    # What each method of the APK's code uses, and who uses it
    used, read_n, unread = {}, 0, []
    for x in app:
        for cname, mn, mp, off in x.code:
            if cname in plat or apk.get(cname) is None: continue
            who = "%s->%s%s" % (cname, mn, mp)
            try:
                us, ok = x.uses(off)
                vals = [(k, x.types[i] if k == "t" else x.fields[i] if k == "f" else x.methods[i]) for k, i in us]
            except (IndexError, struct.error):
                vals, ok = [], False
            if ok: read_n += 1
            else: unread.append(who)
            for v in vals: used.setdefault(v, set()).add(who)

    missing, mm, mf = {}, {}, {}   # missing: class -> lines under it
    def gap(c, line):
        order, g = chain(c)
        if g: missing.setdefault(g, set()).add(line)
        return order
    for (k, v), whos in used.items():
        lines = {"from " + shown(w) for w in whos}
        if k == "t":
            e = elem(v)
            if e:
                for line in lines: gap(e, line)
            continue
        c = v[0]
        if c.startswith("["): continue   # clone() and Object's methods on arrays
        order = None
        for line in lines: order = gap(c, line)
        if order is None or not any(o in plat for o in order): continue
        # Only what the platform owes: a chain with no platform class in it is the APK's own business
        if k == "m":
            if any(o in POLY for o in order): continue
            if not any(v[1:] in known[o].vm or v[1:] in known[o].dm for o in order): mm[v] = lines
        elif not any(v[1:] in known[o].fields for o in order): mf[v] = lines
    for c in apk.values():
        if c.name in plat: continue
        if c.sup and c.sup not in known: missing.setdefault(c.sup, set()).add("super of " + shown(c.name))
        for i in c.ifaces:
            if i not in known: missing.setdefault(i, set()).add("interface of " + shown(c.name))
    named = set()
    for x in app:
        for t in x.types:
            e = elem(t)
            if e and e not in known and e not in missing: named.add(e)

    unimpl = {}    # (platform type, name, proto) -> concrete APK classes that lack it
    for c in apk.values():
        if c.name in plat or c.flags & (ACC_INTERFACE | ACC_ABSTRACT): continue
        order, _ = chain(c.name)
        if order is None or not any(o in plat for o in order): continue
        have = {m for o in order for m, f in known[o].vm.items() if not f & ACC_ABSTRACT}
        for o in order:
            if o not in plat: continue
            for m, f in known[o].vm.items():
                if f & ACC_ABSTRACT and m not in have: unimpl.setdefault((o,) + m, set()).add(shown(c.name))

    def under(lines):
        for line in sorted(lines): print("  " + line)
    for c in sorted(named | set(missing)):
        print("missing-class %s refs=%d%s" % (c, len(missing.get(c, ())), "" if c in missing else " named-only"))
        under(missing.get(c, ()))
    for v in sorted(mm):
        print("missing-method %s->%s%s" % v); under(mm[v])
    for v in sorted(mf):
        print("missing-field %s->%s:%s" % v); under(mf[v])
    shadowed = sorted(c for c in apk if c in plat)
    for c in shadowed:
        a, p = apk[c], plat[c]
        extra = len((set(a.vm) | a.dm) - (set(p.vm) | p.dm)) + len(a.fields - p.fields)
        print("shadowed %s %s apk-only=%d" % (c, p.src, extra))
    for v in sorted(unimpl):
        print("unimplemented %s->%s%s" % v); under("in " + c for c in unimpl[v])
    for w in sorted(unread): print("unreadable-code %s" % shown(w))
    print("summary %d missing classes, %d methods, %d fields, %d shadowed, %d unimplemented; "
          "%d platform classes from %d files; %d APK methods read, %d unreadable"
          % (len(named | set(missing)), len(mm), len(mf), len(shadowed), len(unimpl),
             len(plat), files, read_n, len(unread)))

if __name__ == "__main__":
    main(sys.argv)
