#!/usr/bin/env python3
# What an APK's code needs from the platform that a given platform doesn't have, read from the
# APK's dex files and the platform's jars (a phone's BOOTCLASSPATH jars, plus the jars of the
# shared libraries the APK names with <uses-library>):
#  - classes, methods and fields its code uses that neither the APK nor the platform defines:
#    NoClassDefFoundError, NoSuchMethodError, NoSuchFieldError;
#  - uses that resolve but can't link: a static member used as an instance one or the other
#    way round, the wrong invoke kind, a private, package-private or (outside a subclass)
#    protected platform member or class, a write to a final field, new-instance of an
#    abstract class, an APK class that extends a final, non-public or interface platform
#    type or overrides a final method: IncompatibleClassChangeError, IllegalAccessError,
#    InstantiationError;
#  - classes the APK defines that the platform defines too. The platform's copy is the one
#    that loads, so what the APK's code uses on it is looked up on the platform's copy;
#  - abstract methods of platform classes and interfaces that a concrete APK class doesn't
#    implement: an AbstractMethodError when the platform calls one (a method an Android 17
#    AIDL interface added, on an APK class built against 16's).
# Each is a crash only if the code runs: an SDK check or a catch may keep it from running, so
# the list is for review, not a verdict. Expressive Launcher 5.0.5 reached a phone with one
# (KeyButtonRipple's android.companion.virtualdevice.flags.Flags, 2026-10-30).
# Reads dex itself (no dexdump), dex 035 to 041 (041's containers too), including method
# handles and call sites. The APK, jars and mapping are untrusted input: run it with
# python3 -I and pass the paths as arguments.
#
#   dex-refs.py [--mapping <R8 mapping.txt>] <apk> <jar|apk|dex>...
#     missing-class <descriptor> refs=<n> [named-only]
#       defined nowhere; refs counts the lines under it (named-only: no code uses it, it is
#       only in signatures, catches or annotations)
#     missing-method <class>-><name><proto>
#     missing-field <class>-><name>:<type>
#       used by the APK's code and found neither on the class, its superclasses nor their
#       interfaces, one of which is a platform class
#     link-error <class, or class->member> <why>
#     shadowed <class> <platform file> apk-only=<n>
#       apk-only: methods and fields the APK's copy has and the platform's lacks
#     unimplemented <platform type>-><name><proto>
#       abstract there, and implemented nowhere in the chain of the concrete APK classes
#       listed under it (or only by a non-public method, which the line says)
#     unreadable-code <APK method>
#     Under each entry: "  from <APK method>" for each method whose code uses it, "  super of
#     <APK class>" or "  interface of <APK class>" for a class an APK class extends or
#     implements (that class can't load), "  in <APK class>" for an override or
#     unimplemented. A from line ends with [caught: <types>] when the use sits in a try block
#     of that method whose handlers catch the error it would throw (any: a catch-all), and
#     [reads SDK_INT] when the method reads Build.VERSION.SDK_INT (an SDK check may keep it
#     from running; a guard in a caller, or an SDK check moved into a helper, isn't seen).
#     APK names go through the mapping when one is given (a | b: more than one fits).
#     summary <n> missing classes, <n> methods, <n> fields, <n> link errors (<n> of these
#       caught everywhere), <n> shadowed, <n> unimplemented; <n> platform classes from <n>
#       files, <n> platform dexes unreadable; <n> APK methods read, <n> unreadable
#   Notes (a file it can't read, a classesN.dex ART never opens, a mapping that doesn't
#   match) go to stderr; exit 2 when a platform dex can't be read.
#   Platform files are searched in the order given, first definition wins, as on the boot
#   classpath. Members are looked up as ART resolves them: a method on the class, its
#   superclasses, then their interfaces (an interface's: its superinterfaces, then Object); a
#   field on the class, its interfaces, then its superclass. A use whose class chain runs into
#   a missing class is listed under that class. Code in shadowed classes never runs, so it
#   isn't read. APK and platform classes are in different runtime packages (different class
#   loaders), whatever their package names.
import json, re, struct, sys, zipfile

NO_INDEX = 0xffffffff
ACC_PUBLIC, ACC_PRIVATE, ACC_PROTECTED, ACC_STATIC, ACC_FINAL = 0x1, 0x2, 0x4, 0x8, 0x10
ACC_INTERFACE, ACC_ABSTRACT, ACC_CONSTRUCTOR = 0x200, 0x400, 0x10000
OBJECT = "Ljava/lang/Object;"
SDK_INT = {("Landroid/os/Build$VERSION;", "SDK_INT", "I"), ("Landroid/os/Build$VERSION;", "SDK_INT_FULL", "I")}

# Code units per opcode (dex instruction formats; 0x00's payload pseudo-instructions are
# sized apart)
WIDTH = [1] * 256
for lo, hi, n in ((0x02, 0x02, 2), (0x03, 0x03, 3), (0x05, 0x05, 2), (0x06, 0x06, 3), (0x08, 0x08, 2),
                  (0x09, 0x09, 3), (0x13, 0x13, 2), (0x14, 0x14, 3), (0x15, 0x16, 2), (0x17, 0x17, 3),
                  (0x18, 0x18, 5), (0x19, 0x1a, 2), (0x1b, 0x1b, 3), (0x1c, 0x1c, 2), (0x1f, 0x20, 2),
                  (0x22, 0x23, 2), (0x24, 0x26, 3), (0x29, 0x29, 2), (0x2a, 0x2c, 3), (0x2d, 0x3d, 2),
                  (0x44, 0x6d, 2), (0x6e, 0x72, 3), (0x74, 0x78, 3), (0x90, 0xaf, 2), (0xd0, 0xe2, 2),
                  (0xfa, 0xfb, 4), (0xfc, 0xfd, 3), (0xfe, 0xff, 2)):
    WIDTH[lo:hi + 1] = [n] * (hi - lo + 1)
# What the 16-bit index in an instruction's second unit names (t type, f field, m method,
# h method handle, p proto, c call site) and how the instruction uses it
OPS = {0x22: ("t", "new"), 0xfa: ("m", "poly"), 0xfb: ("m", "poly"), 0xfc: ("c", ""), 0xfd: ("c", ""),
       0xfe: ("h", ""), 0xff: ("p", "")}
for op in (0x1c, 0x1f, 0x20, 0x23, 0x24, 0x25): OPS[op] = ("t", "type")
for lo, use in ((0x52, "iget"), (0x59, "iput"), (0x60, "sget"), (0x67, "sput")):
    for op in range(lo, lo + 7): OPS[op] = ("f", use)
for i, use in enumerate(("virtual", "super", "direct", "static", "interface")):
    OPS[0x6e + i] = OPS[0x74 + i] = ("m", use)
# method_handle_item types: what a method handle uses and how
HANDLES = {0: ("f", "sput"), 1: ("f", "sget"), 2: ("f", "iput"), 3: ("f", "iget"), 4: ("m", "static"),
           5: ("m", "instance"), 6: ("m", "direct"), 7: ("m", "direct"), 8: ("m", "interface")}

# The error each kind of finding throws, as every handler type that catches it ("*" is a catch-all)
LINKAGE = {"Ljava/lang/LinkageError;", "Ljava/lang/Error;", "Ljava/lang/Throwable;", "*"}
ICCE = LINKAGE | {"Ljava/lang/IncompatibleClassChangeError;"}
CATCHES = {"class": LINKAGE | {"Ljava/lang/NoClassDefFoundError;"},
           "method": ICCE | {"Ljava/lang/NoSuchMethodError;"},
           "field": ICCE | {"Ljava/lang/NoSuchFieldError;"},
           "icce": ICCE,
           "access": ICCE | {"Ljava/lang/IllegalAccessError;"},
           "instantiation": ICCE | {"Ljava/lang/InstantiationError;"}}
NOGUARD = frozenset()

def die(msg):
    sys.exit("dex-refs: " + msg)

def note(msg):
    print("note: " + msg, file=sys.stderr)

def uleb(d, o):
    r = s = 0
    while True:
        b = d[o]; o += 1
        r |= (b & 0x7f) << s
        if b < 0x80: return r, o
        s += 7
        if s > 35: raise ValueError("bad uleb128")

def sleb(d, o):
    r, e = uleb(d, o)
    bits = 7 * (e - o)
    return (r - (1 << bits) if r >> (bits - 1) & 1 else r), e

class Cls:
    """A class definition: its supertypes, flags and members, and the file it came from."""
    __slots__ = ("name", "sup", "ifaces", "flags", "vm", "dm", "fields", "src")
    def __init__(self, name, sup, ifaces, flags):
        self.name, self.sup, self.ifaces, self.flags = name, sup, ifaces, flags
        # vm, dm: (name, proto) -> access flags of the virtual and direct methods; fields: (name, type) -> flags
        self.vm, self.dm, self.fields, self.src = {}, {}, {}, None

class Dex:
    """One dex (or one dex of a 041 container): its ids, class definitions and code offsets."""
    def __init__(self, d, base, name):
        self.d, self.name, self.base, self._links = d, name, base, None
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
        ids = self.ids = base if self.version < 41 or sids_o < base else 0
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
        self.protos, self.proto_types = [], []   # proto_types: its parameter types and return type
        for i in range(pids_n):
            _, ret, po = struct.unpack_from("<3I", d, ids + pids_o + 12 * i)
            ps = self.type_list(po)
            self.protos.append("(" + "".join(ps) + ")" + self.types[ret])
            self.proto_types.append(ps + [self.types[ret]])
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
                for count, kind in ((nsf, "s"), (nif, "i"), (ndm, "d"), (nvm, "v")):
                    idx = 0
                    for _ in range(count):
                        diff, o = uleb(d, o); idx += diff
                        mac, o = uleb(d, o)
                        if kind in "si":
                            _, fn, ft = self.fields[idx]
                            k.fields[(fn, ft)] = mac | ACC_STATIC if kind == "s" else mac & ~ACC_STATIC
                            continue
                        code, o = uleb(d, o)
                        _, mn, mp = self.methods[idx]
                        (k.dm if kind == "d" else k.vm)[(mn, mp)] = mac
                        if code: self.code.append((k.name, mn, mp, code))
            self.classes.append(k)
    def type_list(self, off):
        if not off: return []
        o = self.data + off
        (n,) = struct.unpack_from("<I", self.d, o)
        return [self.types[x] for x in struct.unpack_from("<%dH" % n, self.d, o + 4)]
    def links(self):
        """The method handles and call sites, each as the list of what it uses ((kind, use, value))."""
        if self._links is None:
            d, handles, sites = self.d, [], []
            (mo,) = struct.unpack_from("<I", d, self.base + 0x34)
            items = {}
            if mo:
                o = self.data + mo
                (n,) = struct.unpack_from("<I", d, o)
                for i in range(n):
                    t, _, size, off = struct.unpack_from("<HHII", d, o + 4 + 12 * i)
                    items[t] = (size, off)
            size, off = items.get(0x8, (0, 0))      # method_handle_item
            for i in range(size):
                t, _, mid, _ = struct.unpack_from("<4H", d, self.ids + off + 8 * i)
                k, use = HANDLES[t]
                handles.append([(k, use, self.fields[mid] if k == "f" else self.methods[mid])])
            size, off = items.get(0x7, (0, 0))      # call_site_id_item -> encoded_array_item
            for i in range(size):
                (co,) = struct.unpack_from("<I", d, self.ids + off + 4 * i)
                out = []
                n, p = uleb(d, self.data + co)
                for _ in range(n): p = self.value(p, out, handles)
                sites.append(out)
            self._links = handles, sites
        return self._links
    def value(self, o, out, handles, depth=0):
        """Add what the encoded_value at o uses to out; the offset after it."""
        if depth > 64: raise ValueError("encoded values nested too deep")
        d = self.d
        b = d[o]; o += 1
        t, arg = b & 0x1f, b >> 5
        if t == 0x1c:                                   # array
            n, o = uleb(d, o)
            for _ in range(n): o = self.value(o, out, handles, depth + 1)
            return o
        if t == 0x1d:                                   # annotation
            ti, o = uleb(d, o); n, o = uleb(d, o)
            out.append(("t", "type", self.types[ti]))
            for _ in range(n):
                _, o = uleb(d, o); o = self.value(o, out, handles, depth + 1)
            return o
        if t >= 0x1e: return o                          # null, boolean
        v = int.from_bytes(d[o:o + arg + 1], "little"); o += arg + 1
        if t == 0x15: out += [("t", "type", x) for x in self.proto_types[v]]
        elif t == 0x16: out += handles[v]
        elif t == 0x18: out.append(("t", "type", self.types[v]))
        elif t in (0x19, 0x1b): out.append(("f", "ref", self.fields[v]))
        elif t == 0x1a: out.append(("m", "ref", self.methods[v]))
        return o
    def uses(self, off):
        """What a code item's instructions use, as (kind, use, value, the handler types of the
        try block around it), and whether they decoded to exactly the code's length (a wrong
        opcode width would leave the walk off the end)."""
        d, o = self.d, self.data + off
        (nt,) = struct.unpack_from("<H", d, o + 6)
        (n,) = struct.unpack_from("<I", d, o + 12)
        u = struct.unpack_from("<%dH" % n, d, o + 16)
        tries = []     # (start, end, handler types); dex try ranges don't overlap
        if nt:
            to = o + 16 + 2 * n + 2 * (n % 2)
            hl = to + 8 * nt
            for i in range(nt):
                start, count, ho = struct.unpack_from("<IHH", d, to + 8 * i)
                size, p = sleb(d, hl + ho)
                caught = []
                for _ in range(abs(size)):
                    t, p = uleb(d, p); _, p = uleb(d, p)
                    caught.append(self.types[t])
                if size <= 0: caught.append("*")
                tries.append((start, start + count, frozenset(caught)))
        out, pc = [], 0
        while pc < n:
            x = u[pc]; op = x & 0xff
            if x == 0x100: pc += 4 + 2 * u[pc + 1]; continue                  # packed-switch data
            if x == 0x200: pc += 2 + 4 * u[pc + 1]; continue                  # sparse-switch data
            if x == 0x300:                                                    # fill-array data
                pc += 4 + (u[pc + 1] * (u[pc + 2] | u[pc + 3] << 16) + 1) // 2; continue
            if op in OPS:
                g = next((g for a, b, g in tries if a <= pc < b), NOGUARD)
                (k, use), i = OPS[op], u[pc + 1]
                if k == "t": out.append((k, use, self.types[i], g))
                elif k == "f": out.append((k, use, self.fields[i], g))
                elif k == "m":
                    out.append((k, use, self.methods[i], g))
                    if use == "poly": out += [("t", "type", t, g) for t in self.proto_types[u[pc + 3]]]
                elif k == "p": out += [("t", "type", t, g) for t in self.proto_types[i]]
                else: out += [x + (g,) for x in self.links()[0 if k == "h" else 1][i]]
            pc += WIDTH[op]
        return out, pc == n

def dexes(path):
    """Every dex in an APK, jar or bare dex file that ART opens, why any of them couldn't be
    read, and notes."""
    blobs, errs, notes = [], [], []
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            present, names = set(z.namelist()), []
            while True:   # classes.dex, classes2.dex, ... up to the first one missing, as ART opens them
                n = "classes%s.dex" % (len(names) + 1 if names else "")
                if n not in present: break
                names.append(n)
            skipped = sorted(n for n in present if re.fullmatch(r"classes\d*\.dex", n) and n not in names)
            if skipped: notes.append("%s: ART never opens %s (it stops at the first missing classesN.dex)"
                                     % (path, " ".join(skipped)))
            for n in names:
                try: blobs.append((n, z.read(n)))
                except Exception as e: errs.append("%s!%s: %s" % (path, n, e))
    else:
        with open(path, "rb") as f: blobs = [(path, f.read())]
    out = []
    for n, d in blobs:
        base = 0
        while base + 0x70 <= len(d) and (base == 0 or d[base:base + 4] == b"dex\n"):
            name = "%s!%s@%d" % (path, n, base) if base else "%s!%s" % (path, n)
            ver = d[base + 4:base + 7]
            (size,) = struct.unpack_from("<I", d, base + 0x20)
            try: out.append(Dex(d, base, name))
            except Exception as e: errs.append("%s: %s" % (name, e))
            if not (ver.isdigit() and int(ver) >= 41) or size <= 0: break
            base += size
    return out, errs, notes

JTYPES = {"void": "V", "boolean": "Z", "byte": "B", "char": "C", "short": "S", "int": "I", "long": "J",
          "float": "F", "double": "D"}
def jdesc(t):
    dims = 0
    while t.endswith("[]"): t, dims = t[:-2], dims + 1
    return "[" * dims + JTYPES.get(t, "L" + t.replace(".", "/") + ";")

def read_mapping(path):
    """An R8 mapping.txt as {obfuscated class: original}, {(obfuscated class, obfuscated
    method name): {(original class or None, original name, original proto): count}} and its
    pg_map_id. Of an inline stack (lines with the same range and obfuscated name), only the
    last line, the method itself, counts; a qualified name is a method moved from that class."""
    cls, meth, mid, cur, last = {}, {}, None, None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                m = re.match(r"#\s*pg_map_id:\s*(\S+)", line)
                if m: mid = m.group(1)
                continue
            if not line.strip(): continue
            if not line[0].isspace():
                m = re.match(r"(\S+) -> (\S+):$", line)
                cur, last = (jdesc(m.group(2)) if m else None), None
                if m: cls[cur] = jdesc(m.group(1))
                continue
            # "    [a:b:]type [holder.]name(args)[:c[:d]] -> obf"
            m = re.match(r"\s+(?:(\d+:\d+):)?(\S+) ((?:[^\s(]+\.)?[^\s(.]+)\(([^)]*)\)(?::\d+)*(?::\d+)? -> (\S+)$", line)
            if not cur or not m:
                last = None; continue
            rng, ret, name, args, obf = m.groups()
            holder, dot, short = name.rpartition(".")
            entry = (jdesc(holder) if dot else None, short,
                     "(" + "".join(jdesc(a.strip()) for a in args.split(",") if a.strip()) + ")" + jdesc(ret))
            key = (cur, obf)
            cands = meth.setdefault(key, {})
            if rng and last and last[:2] == (key, rng):
                cands[last[2]] -= 1   # the line before was inlined into this one
            cands[entry] = cands.get(entry, 0) + 1
            last = (key, rng, entry) if rng else None
    return cls, meth, mid

def main(argv):
    args, mpath = argv[1:], None
    if args[:1] == ["--mapping"]:
        if len(args) < 2: die("--mapping needs a file")
        mpath, args = args[1], args[2:]
    if len(args) < 2: die("usage: dex-refs.py [--mapping <mapping.txt>] <apk> <jar|apk|dex>...")
    try:
        app, errs, notes = dexes(args[0])
    except Exception as e:
        die("can't read %s: %s" % (args[0], e))
    if errs: die("can't read %s" % "; ".join(errs))
    for n in notes: note(n)
    if not app: die("%s has no dex" % args[0])
    mapping = None
    if mpath:
        try: mapping = read_mapping(mpath)
        except Exception as e: die("can't read %s: %s" % (mpath, e))
    plat, files, bad = {}, 0, []
    for p in args[1:]:
        try:
            ds, errs, notes = dexes(p)
        except Exception as e:
            ds, errs, notes = [], ["%s: %s" % (p, e)], []
        for n in notes: note(n)
        for e in errs: note("can't read " + e)
        bad += errs
        if not ds:
            if not errs: note("%s has no dex (stripped?): its classes count as missing" % p)
            continue
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

    cmap, mmap = {}, {}
    if mapping:
        cmap, mmap, mid = mapping
        if not cmap: die("%s has no class lines: not an R8 mapping.txt" % mpath)
        ids = set()   # the APK's map ids: R8's ~~R8{...} marker and r8-map-id-<id> source files
        for x in app:
            for s in x.strings:
                if s.startswith("~~R8{"):
                    try: ids.add(str(json.loads(s[4:]).get("pg-map-id", "")))
                    except (ValueError, AttributeError): pass
                m = re.fullmatch(r"r8-map-id-([0-9a-f]+)", s)
                if m: ids.add(m.group(1))
        ids.discard("")
        if mid and ids and not any(i.startswith(mid) or mid.startswith(i) for i in ids):
            die("%s is another build's mapping: its pg_map_id %s isn't the APK's (%s)" % (mpath, mid, ", ".join(sorted(ids))))
        if not (mid and ids): note("can't match %s to the APK by map id: its names may be another build's" % mpath)
        if not any(c in apk for c in cmap): note("no APK class has an obfuscated name from %s: it maps nothing" % mpath)

    def elem(t):   # the class an array or class type names, or None for a primitive
        t = t.lstrip("[")
        return t if t.startswith("L") else None
    chains = {}
    def chain(c):
        """Where ART looks for a method of c: c, its superclasses, then their interfaces (for an
        interface: itself, its superinterfaces, then Object); None and the gap if one is missing."""
        if c not in chains: chains[c] = chain1(c)
        return chains[c]
    def chain1(c):
        sups, cur = [], c
        while cur:
            if cur not in known or cur in sups: return None, cur   # missing (or a cycle: can't load)
            sups.append(cur); cur = known[cur].sup
        ifs, queue = [], [i for s in sups for i in known[s].ifaces]
        while queue:
            i = queue.pop(0)
            if i in ifs or i in sups: continue
            if i not in known: return None, i
            ifs.append(i); queue += known[i].ifaces
        if known[c].flags & ACC_INTERFACE: return [c] + ifs + sups[1:], None
        return sups + ifs, None
    def find_method(order, key):   # the first declaration in that order: (class, access flags)
        for o in order:
            k = known[o]
            f = k.dm.get(key, k.vm.get(key))
            if f is not None: return o, f
        return None
    def find_field(c, key, seen):  # the class, its interfaces, then its superclass, as the JLS
        if c is None or c in seen or c not in known: return None
        seen.add(c); k = known[c]
        if key in k.fields: return c, k.fields[key]
        for i in k.ifaces + [k.sup]:
            r = find_field(i, key, seen)
            if r: return r
        return None
    def outers(c):   # c and the classes it's nested in (Outer$Inner)
        out, b = [c], c[:-1]
        while "$" in b.rpartition("/")[2][1:]:
            b = b[:b.rindex("$")]; out.append(b + ";")
        return out
    def extends(x, d):   # x, or a class x is nested in, has d as a superclass
        for o in outers(x):
            seen = set()
            while o in known and o not in seen:
                if o == d: return True
                seen.add(o); o = known[o].sup
        return False
    def no_access(d, f, caller):   # why a platform member of d with access flags f is out of the APK caller's reach
        if f & ACC_PUBLIC: return None
        if f & ACC_PRIVATE: return "private"
        if f & ACC_PROTECTED: return None if extends(caller, d) else "protected, and the caller isn't a subclass"
        return "package-private"
    def misuse(use, c, d, f, key):   # why invoke-<use> can't call the method of d with flags f, found from c
        static = f & ACC_STATIC
        direct = static or f & (ACC_PRIVATE | ACC_CONSTRUCTOR) or key[0] in ("<init>", "<clinit>")
        c_iface = known[c].flags & ACC_INTERFACE
        if use == "static": return None if static else "not static, called with invoke-static"
        if use in ("ref", "poly"): return None
        if static: return "static, called with invoke-%s" % use
        if use == "direct": return None if direct else "virtual, called with invoke-direct"
        if use == "virtual":
            if c in plat and c_iface: return "on an interface, called with invoke-virtual"
            return "private or a constructor, called with invoke-virtual" if direct else None
        if use == "interface":
            if c in plat and not c_iface: return "on a class, called with invoke-interface"
            return "private or a constructor, called with invoke-interface" if direct else None
        if use == "super": return "a constructor, called with invoke-super" if key[0] == "<init>" else None
        return None   # instance (a method handle): only static matters

    # What each method of the APK's code uses, and who uses it
    used, sdk, read_n, unread = {}, set(), 0, []   # used: (kind, use, value) -> {(method, handler types)}
    for x in app:
        for cname, mn, mp, off in x.code:
            if cname in plat or apk.get(cname) is None: continue
            who = "%s->%s%s" % (cname, mn, mp)
            try:
                us, ok = x.uses(off)
            except Exception:
                us, ok = [], False
            if ok: read_n += 1
            else: unread.append(who)
            for k, use, v, g in us:
                used.setdefault((k, use, v), set()).add((who, g))
                if k == "f" and v in SDK_INT: sdk.add(who)

    def from_line(who, guard, err):
        line = "from " + shown(who)
        caught = sorted("any" if g == "*" else g for g in guard & CATCHES[err])
        if caught: line += " [caught: %s]" % " ".join(caught)
        return line + (" [reads SDK_INT]" if who in sdk else "")
    def shown(s):  # an APK name or member through the mapping
        if not mapping: return s
        c, sep, rest = s.partition("->")
        holder = cmap.get(c, c)
        if not sep: return holder
        name, paren, proto = rest.partition("(")
        proto = re.sub(r"L[^;]+;", lambda m: cmap.get(m.group(0), m.group(0)), paren + proto)
        cands = [e for e, n in mmap.get((c, name), {}).items() if n > 0]
        fit = [e for e in cands if e[2] == proto] or cands
        if not fit: return holder + "->" + name + proto
        return " | ".join(sorted("%s->%s%s" % (h or holder, n, proto) for h, n, _ in fit))
    missing, mm, mf, link = {}, {}, {}, {}   # class / member / (target, why) -> lines under it
    def add(into, key, whos, err):
        into.setdefault(key, set()).update(from_line(w, g, err) for w, g in whos)
    def member(v, k):
        return "%s->%s%s" % v if k == "m" else "%s->%s:%s" % v
    for (k, use, v), whos in used.items():
        c = elem(v) if k == "t" else v[0]
        if c is None: continue   # a primitive
        if k != "t" and c.startswith("["):   # clone() and Object's members on arrays: only the element class loads
            c, k = elem(c), "t"
            if c is None: continue
        order, g = chain(c)
        if g:
            add(missing, g, whos, "class"); continue
        if c in plat and not known[c].flags & ACC_PUBLIC:
            add(link, (c, "package-private class"), whos, "access")
        if k == "t":
            if use == "new" and c in plat and known[c].flags & (ACC_ABSTRACT | ACC_INTERFACE):
                add(link, (c, "new-instance of an interface" if known[c].flags & ACC_INTERFACE else
                           "new-instance of an abstract class"), whos, "instantiation")
            continue
        # Only what the platform owes: a chain with no platform class in it is the APK's own business
        if not any(o in plat for o in order) or use == "poly": continue
        if k == "m":
            found = find_method(order, v[1:])
            if found is None:
                add(mm, v, whos, "method"); continue
            d, f = found
            if d not in plat: continue
            why = misuse(use, c, d, f, v[1:])
            if why: add(link, (member(v, k), why), whos, "icce"); continue
        else:
            found = find_field(c, v[1:], set())
            if found is None:
                add(mf, v, whos, "field"); continue
            d, f = found
            if d not in plat: continue
            if use != "ref" and bool(f & ACC_STATIC) != (use in ("sget", "sput")):
                add(link, (member(v, k), ("static, used by " if f & ACC_STATIC else "an instance field, used by ") + use),
                    whos, "icce"); continue
            if use in ("iput", "sput") and f & ACC_FINAL:
                add(link, (member(v, k), "final, written by " + use), whos, "access")
        for w, gd in whos:
            why = no_access(d, f, w.partition("->")[0])
            if why: add(link, (member(v, k), why), [(w, gd)], "access")

    for c in apk.values():   # supertypes and overrides
        if c.name in plat: continue
        line = "super of " + shown(c.name)
        if c.sup and c.sup not in known: missing.setdefault(c.sup, set()).add(line)
        elif c.sup in plat:
            s = known[c.sup].flags
            if s & ACC_INTERFACE: link.setdefault((c.sup, "an interface, extended as a class"), set()).add(line)
            elif s & ACC_FINAL: link.setdefault((c.sup, "final, extended"), set()).add(line)
            if not s & ACC_PUBLIC: link.setdefault((c.sup, "package-private class, extended"), set()).add(line)
        for i in c.ifaces:
            line = "interface of " + shown(c.name)
            if i not in known: missing.setdefault(i, set()).add(line)
            elif i in plat:
                s = known[i].flags
                if not s & ACC_INTERFACE: link.setdefault((i, "a class, implemented as an interface"), set()).add(line)
                if not s & ACC_PUBLIC: link.setdefault((i, "package-private interface, implemented"), set()).add(line)
        cur, seen = c.sup, set()
        while cur in known and cur not in seen:   # overriding a final platform method
            seen.add(cur)
            if cur in plat:
                for key, f in known[cur].vm.items():
                    if key in c.vm and f & ACC_FINAL and f & (ACC_PUBLIC | ACC_PROTECTED):
                        link.setdefault(("%s->%s%s" % ((cur,) + key), "final, overridden"), set()).add("in " + shown(c.name))
            cur = known[cur].sup

    named = set()
    for x in app:
        for t in x.types:
            e = elem(t)
            if e and e not in known and e not in missing: named.add(e)

    unimpl = {}    # (platform type, name, proto) -> concrete APK classes that lack it
    def same_pkg(a, b):   # same runtime package: same loader (platform or APK) and same package name
        return (a in plat) == (b in plat) and a.rpartition("/")[0] == b.rpartition("/")[0]
    for c in apk.values():
        if c.name in plat or c.flags & (ACC_INTERFACE | ACC_ABSTRACT): continue
        order, _ = chain(c.name)
        if order is None or not any(o in plat for o in order): continue
        # The vtable as ART links it, root class first: a method overrides a slot with its name
        # and proto only when it can (public or protected, or package-private in the same runtime
        # package), else it takes a new slot; an abstract redeclaration re-abstracts the slot
        sups = [o for o in order if not known[o].flags & ACC_INTERFACE]
        slots = {}   # (name, proto) -> [[declarer, flags], ...] in vtable order
        for k in reversed(sups):
            for m, f in known[k].vm.items():
                hit = False
                for s in slots.get(m, ()):
                    if s[1] & (ACC_PUBLIC | ACC_PROTECTED) or same_pkg(s[0], k): s[0], s[1], hit = k, f, True
                if not hit: slots.setdefault(m, []).append([k, f])
        for m, ss in slots.items():
            for o, f in ss:
                if f & ACC_ABSTRACT and o in plat: unimpl.setdefault((o,) + m, set()).add(shown(c.name))
        ifs = [o for o in order if known[o].flags & ACC_INTERFACE]
        for o in ifs:
            if o not in plat: continue
            for m, f in known[o].vm.items():
                if not f & ACC_ABSTRACT: continue
                impl = slots.get(m)
                if impl:   # the last matching vtable method, as ART searches it
                    _, g = impl[-1]
                    if g & ACC_ABSTRACT: unimpl.setdefault((o,) + m, set()).add(shown(c.name))
                    elif not g & ACC_PUBLIC:
                        unimpl.setdefault((o,) + m, set()).add(shown(c.name) + " (only a non-public method: IllegalAccessError)")
                elif not any(m in known[j].vm and not known[j].vm[m] & ACC_ABSTRACT for j in ifs):
                    unimpl.setdefault((o,) + m, set()).add(shown(c.name))

    def under(lines):
        for line in sorted(lines): print("  " + line)
    for c in sorted(named | set(missing)):
        print("missing-class %s refs=%d%s" % (c, len(missing.get(c, ())), "" if c in missing else " named-only"))
        under(missing.get(c, ()))
    for v in sorted(mm):
        print("missing-method %s->%s%s" % v); under(mm[v])
    for v in sorted(mf):
        print("missing-field %s->%s:%s" % v); under(mf[v])
    for t, why in sorted(link):
        print("link-error %s %s" % (t, why)); under(link[(t, why)])
    shadowed = sorted(c for c in apk if c in plat)
    for c in shadowed:
        a, p = apk[c], plat[c]
        extra = len((set(a.vm) | set(a.dm)) - (set(p.vm) | set(p.dm))) + len(set(a.fields) - set(p.fields))
        print("shadowed %s %s apk-only=%d" % (c, p.src, extra))
    for v in sorted(unimpl):
        print("unimplemented %s->%s%s" % v); under("in " + c for c in unimpl[v])
    for w in sorted(unread): print("unreadable-code %s" % shown(w))
    caught = sum(1 for lines in list(missing.values()) + list(mm.values()) + list(mf.values()) + list(link.values())
                 if lines and all("[caught: " in line for line in lines))
    print("summary %d missing classes, %d methods, %d fields, %d link errors (%d of these caught everywhere), "
          "%d shadowed, %d unimplemented; %d platform classes from %d files, %d platform dexes unreadable; "
          "%d APK methods read, %d unreadable"
          % (len(named | set(missing)), len(mm), len(mf), len(link), caught, len(shadowed), len(unimpl),
             len(plat), files, len(bad), read_n, len(unread)))
    if bad: sys.exit(2)

if __name__ == "__main__":
    main(sys.argv)
