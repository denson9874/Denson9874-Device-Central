#!/usr/bin/env python3
# What an APK's code needs from the platform that a given platform doesn't have, read from the
# APK's dex files and the platform's jars (a phone's BOOTCLASSPATH jars, plus the jars of the
# shared libraries the APK names with <uses-library>):
#  - classes, methods and fields its code uses that neither the APK nor the platform defines:
#    NoClassDefFoundError, NoSuchMethodError, NoSuchFieldError;
#  - uses that resolve but can't link: a static member used as an instance one or the other
#    way round, the wrong invoke kind, a private, package-private or (outside a subclass)
#    protected platform member or class, a method of Object's an interface lacks (not public,
#    or static) called on one, a write to a final field, new-instance of an abstract class,
#    invoke-super of a method that is abstract, or whose defaults conflict, where the call
#    lands, an APK class that gets conflicting defaults of a platform interface's:
#    IncompatibleClassChangeError, IllegalAccessError, InstantiationError, AbstractMethodError;
#    an APK class that extends a final, interface or out-of-reach (package-private, of another
#    runtime package) type, implements a class or an out-of-reach interface, overrides a final
#    method it can reach, implements an interface's method with a non-public one, or is its own
#    supertype through others (classes in two dexes that extend or implement each other) or
#    implements itself, that type the platform's or the APK's own (ART checks both alike): it
#    and its subclasses can't load, each use of them throws that error (VerifyError,
#    LinkageError, ClassCircularityError, IncompatibleClassChangeError, IllegalAccessError);
#  - classes the APK defines that the platform defines too. The platform's copy is the one
#    that loads, so what the APK's code uses on it is looked up on the platform's copy;
#  - abstract methods of platform classes and interfaces that a concrete APK class doesn't
#    implement: an AbstractMethodError when the platform calls one (a method an Android 17
#    AIDL interface added, or a default a subinterface declared abstract again, on an APK
#    class built against 16's).
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
#       (supertype cycle: the first by name of the classes on the cycle, an in line for each APK one)
#     shadowed <class> <platform file> apk-only=<n>
#       apk-only: methods and fields the APK's copy has and the platform's lacks
#     unimplemented <platform type>-><name><proto>
#       abstract there, and implemented nowhere in the chain of the concrete APK classes
#       listed under it: no class method, and no default ART would pick (an interface's
#       abstract declaration masks the defaults of the interfaces it extends)
#     unreadable-code <APK method>
#     Under each entry: "  from <APK method>" for each method whose code uses it, "  super of
#     <APK class>" or "  interface of <APK class>" for a class an APK class extends or
#     implements (that class can't load), "  in <APK class>" for an override, a class that
#     can't link (a cycle's too), conflicting defaults or unimplemented. A from line ends with
#     [caught: <type>] when the use sits in a try block of that method whose first handler for
#     the error it would throw (IllegalAccessError, where an access check ART makes before it
#     fails too; LinkageError for a class that can't load or link, whose error varies) keeps it
#     (any: a catch-all): every path from the handler returns, or goes back to the method's own
#     code, and drops the error on the way (it is followed in the register move-exception wrote
#     and in move-object copies of it, until each is written over, or none left is one the
#     method ever throws, hands on or copies). A path that throws it keeps nothing, as in
#     finally and synchronized blocks, or where the method's own code throws it after the
#     handler (Okio's use {}): the try block around that throw is looked at instead (around
#     another exception the handler throws, only a handler of anything, and that can't be told
#     with a typed handler before it; another one the method's own code throws is its own).
#     While a register holds it, what an instruction in a try block throws is followed into that
#     try's handlers too, for a throw or a hand-on of the error only (a catch in the handler
#     that throws it, a later try whose handler throws a saved copy): what else an instruction
#     in the handler throws isn't followed. [caught?: <type>] (can't tell) when only some paths
#     keep it, a typed handler comes before it for a class that can't load or link (that may
#     be of the error's own type), or a path hands the error on any other way (as a call's
#     argument, so Log.e(.., e), Kotlin's runCatching { }.getOrThrow() and try-with-resources'
#     addSuppressed too, into a field or an array, as a return value), or the handler's code
#     can't be followed (a payload, an unused opcode, a walk of over 512 steps, handlers nested
#     64 deep).
#     [reads SDK_INT] when the method reads Build.VERSION.SDK_INT (an SDK check may keep it from
#     running; a guard in a caller, or an SDK check moved into a helper, isn't seen).
#     APK names go through the mapping when one is given (a | b: more than one fits).
#     summary <n> missing classes, <n> methods, <n> fields, <n> link errors, <n> shadowed, <n>
#       unimplemented; <n> missing or link-error entries caught everywhere; <n> platform classes
#       from <n> files, <n> platform dexes unreadable; <n> APK methods read, <n> unreadable
#       (caught everywhere: every line under the entry is a from line marked [caught: ...])
#   Notes (a file it can't read, a classesN.dex ART never opens, a mapping that doesn't
#   match) go to stderr; exit 2 when a platform dex can't be read.
#   Platform files are searched in the order given, first definition wins, as on the boot
#   classpath. Members are looked up as ART resolves them: a method on the class, its
#   superclasses up to the first that declares it (if that one is private, or package-private
#   in another runtime package, an interface method copied into a class below it wins), then
#   their interfaces' virtual methods (an interface's: its own methods, its superinterfaces'
#   virtual ones, the most general first, then Object's public instance ones; the class named
#   is access-checked only when the declaring class is out of reach), after the invoke kind is
#   checked against the class; a field on the class, its interfaces, then its superclass. A
#   use whose class chain (its interfaces' superclasses too) runs into a missing class is
#   listed under that class, one of a class that can't link (or whose supertype can't: the
#   superclass's error first, then the interfaces') under that link error, whatever it uses on
#   it (ART throws the class's error first). Code in shadowed classes never runs, so it isn't
#   read; nor are access errors listed for the code of an APK class whose chain runs into a
#   missing class or a cycle. APK and platform classes are in different runtime packages
#   (different class loaders), whatever their package names.
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
# The register each opcode writes: vAA, vA ("a"), vAAAA ("a16"), none ("": check-cast leaves the
# reference as it was), None: unused. WIDE: those that write a wide pair, so the next register too
DEST = ["aa"] * 256
for w, ops in (("a", [0x01, 0x04, 0x07, 0x12, 0x20, 0x21, 0x23, *range(0x52, 0x59), *range(0x7b, 0x90), *range(0xb0, 0xd8)]),
               ("a16", [0x03, 0x06, 0x09]),
               ("", [0x00, *range(0x0e, 0x12), 0x1d, 0x1e, 0x1f, *range(0x24, 0x2d), *range(0x32, 0x3e), *range(0x4b, 0x52),
                     *range(0x59, 0x60), *range(0x67, 0x73), *range(0x74, 0x79), *range(0xfa, 0xfe)]),
               (None, [*range(0x3e, 0x44), 0x73, 0x79, 0x7a, *range(0xe3, 0xfa)])):
    for op in ops: DEST[op] = w
WIDE = {0x04, 0x05, 0x06, 0x0b, *range(0x16, 0x1a), 0x45, 0x53, 0x61, 0x7d, 0x7e, 0x80, 0x81, 0x83, 0x86, 0x88, 0x89, 0x8b,
        *range(0x9b, 0xa6), *range(0xab, 0xb0), *range(0xbb, 0xc6), *range(0xcb, 0xd0)}
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
           "instantiation": ICCE | {"Ljava/lang/InstantiationError;"},
           "ame": ICCE | {"Ljava/lang/AbstractMethodError;"},
           "linkage": LINKAGE,   # a class that can't load or link: VerifyError, ClassCircularityError, ... (it varies)
           "any": {"Ljava/lang/Throwable;", "*"}}   # an exception of a type not known
NOGUARD = ()
class Paths(tuple):   # a handler's paths (Dex.uses' fate): equal only to itself, so a guard hashes without walking them
    __slots__ = ()
    __hash__, __eq__, __ne__ = object.__hash__, object.__eq__, object.__ne__

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
        if t == 0x15: out += [("t", "proto", x) for x in self.proto_types[v]]   # a method type: no access check
        elif t == 0x16: out += handles[v]
        elif t == 0x18: out.append(("t", "type", self.types[v]))
        elif t in (0x19, 0x1b): out.append(("f", "ref", self.fields[v]))
        elif t == 0x1a: out.append(("m", "ref", self.methods[v]))
        return o
    def uses(self, off):
        """What a code item's instructions use, as (kind, use, value, the guard: the handlers of
        the try block around it, in order, as (type, fate)), and whether they decoded to exactly
        the code's length (a wrong opcode width would leave the walk off the end)."""
        d, o = self.d, self.data + off
        (nt,) = struct.unpack_from("<H", d, o + 6)
        (n,) = struct.unpack_from("<I", d, o + 12)
        u = struct.unpack_from("<%dH" % n, d, o + 16)
        tries = []     # (start, end, [(handler type, "*" for a catch-all, and address)]); try ranges don't overlap
        if nt:
            to = o + 16 + 2 * n + 2 * (n % 2)
            hl = to + 8 * nt
            for i in range(nt):
                start, count, ho = struct.unpack_from("<IHH", d, to + 8 * i)
                size, p = sleb(d, hl + ho)
                hs = []
                for _ in range(abs(size)):
                    t, p = uleb(d, p); a, p = uleb(d, p)
                    hs.append((self.types[t], a))
                if size <= 0: hs.append(("*", uleb(d, p)[0]))
                tries.append((start, start + count, hs))
        hands = [[]] * n   # pc -> the handlers of the try block around it, mapped once (the first in the table, if they overlap)
        for s, e, hs in reversed(tries): hands[s:e] = [hs] * len(range(s, min(e, n)))
        def s32(i): return ((u[i] | u[i + 1] << 16) ^ 1 << 31) - (1 << 31)
        def nexts(pc):   # where normal flow goes after pc ([] after a return or throw); None: can't follow it
            x = u[pc]; op = x & 0xff
            if x in (0x100, 0x200, 0x300) or pc + WIDTH[op] > n: return None   # a payload, or off the end
            if op == 0x27 or 0x0e <= op <= 0x11: return []
            if op == 0x28: return [pc + ((x >> 8) ^ 0x80) - 0x80]                         # goto
            if op == 0x29: return [pc + (u[pc + 1] ^ 0x8000) - 0x8000]                    # goto/16
            if op == 0x2a: return [pc + s32(pc + 1)]                                      # goto/32
            out = [pc + WIDTH[op]]
            if 0x32 <= op <= 0x3d: out.append(pc + (u[pc + 1] ^ 0x8000) - 0x8000)       # if-*
            elif op in (0x2b, 0x2c):                                                      # a switch: its payload's targets
                p = pc + s32(pc + 1)
                if not 0 <= p < n - 1 or u[p] != (0x100 if op == 0x2b else 0x200): return None
                k = u[p + 1]; t = p + (4 if op == 0x2b else 2 + 2 * k)
                if t + 2 * k > n: return None
                out += [pc + s32(t + 2 * i) for i in range(k)]
            return out
        normal, todo = set(), [0] if nt else []   # what the method's own code reaches from its start
        while todo:
            pc = todo.pop()
            if pc in normal or not 0 <= pc < n: continue
            normal.add(pc); todo += nexts(pc) or []
        def passed(pc):   # the registers pc hands on: a call's or a new array's, a value it stores, or returns
            x = u[pc]; op = x & 0xff
            if op in (0x24, 0xfa, 0xfc) or 0x6e <= op <= 0x72:   # {vC, vD, vE, vF, vG}
                k = x >> 12
                return [(u[pc + 2] >> 4 * i) & 0xf for i in range(min(k, 4))] + [(x >> 8) & 0xf] * (k == 5)
            if op in (0x25, 0xfb, 0xfd) or 0x74 <= op <= 0x78: return range(u[pc + 2], u[pc + 2] + (x >> 8))   # {vCCCC ..}
            if 0x59 <= op <= 0x5f: return [(x >> 8) & 0xf]   # iput vA
            if 0x0f <= op <= 0x11 or 0x4b <= op <= 0x51 or 0x67 <= op <= 0x6d: return [x >> 8]   # return, aput, sput vAA
            return ()
        def source(pc):   # the register a move-object copies from, else None
            x = u[pc]; op = x & 0xff
            return x >> 12 if op == 0x07 else u[pc + 1] if op == 0x08 else u[pc + 2] if op == 0x09 else None
        def ends(a):
            # The throws on the handler at a's paths (pc, whether of what it caught) and whether a path
            # keeps it; None: can't tell. Each path follows the registers that hold it (move-exception's,
            # and move-object copies of one; any other write to one drops it, a wide one the next too)
            # through the handler and, while one of them is held, the method's own code. A throw of one
            # passes it on; another throw is, in the handler, another exception, in the method's own code
            # its own (that path keeps it). A path that hands one on anywhere else (a call, a field, an
            # array, a return) can't be told, nor code that can't be followed or a walk that runs long.
            # While one is held, what an instruction in a try block throws takes them to the try's
            # handlers: those paths (nested) count only where they throw or hand one on (what else an
            # instruction in the handler throws isn't followed)
            x = u[a] if a < n else 0
            todo = [(a + 1, frozenset([x >> 8]), False)] if x & 0xff == 0x0d else [(a, frozenset(), False)]   # move-exception vAA
            seen, throws, keeps = set(), set(), False
            while todo:
                pc, regs, nested = todo.pop()
                if pc in normal and regs.isdisjoint(held): keeps = keeps or not nested; continue   # back in its own code, nothing lets it out
                if (pc, regs, nested) in seen: continue
                if not 0 <= pc < n or len(seen) >= 512: return None
                seen.add((pc, regs, nested))
                if not regs.isdisjoint(held): todo += [(h, regs, True) for _, h in hands[pc]]
                x, nx = u[pc], nexts(pc); op = x & 0xff
                if nx is None or DEST[op] is None or regs and not regs.isdisjoint(passed(pc)): return None
                if op == 0x27:
                    if x >> 8 in regs or pc not in normal and not nested: throws.add((pc, x >> 8 in regs))
                    else: keeps = keeps or not nested
                elif not nx: keeps = keeps or not nested
                else:
                    if DEST[op]:
                        to = (x >> 8) & 0xf if DEST[op] == "a" else x >> 8 if DEST[op] == "aa" else u[pc + 1]
                        regs = regs | {to} if source(pc) in regs else regs - {to, to + 1} if op in WIDE else regs - {to}
                    todo += [(p, regs, nested) for p in nx]
            return throws, keeps
        fates = {}
        def fate(a, busy):
            # What the handler at a does with what it catches, path by path: True, keeps it (returns,
            # loops or rejoins the method's own code); else (the guard around the throw, whether it
            # throws what it caught): passes it on (finally, synchronized) or throws another exception
            # (no guard: none around the throw, or a cycle). None: can't tell, or 64 handlers deep
            if a in busy: return Paths(((NOGUARD, True),))
            if len(busy) >= 64: return None
            if a not in fates:
                r = ends(a)
                fates[a] = None if r is None else Paths(((True,) if r[1] or not r[0] else ()) + tuple(dict.fromkeys(
                    (guard(pc, busy | {a}), same) for pc, same in sorted(r[0]))))
            return fates[a]
        def guard(pc, busy=frozenset()):
            return tuple((t, fate(a, busy)) for t, a in hands[pc]) or NOGUARD
        # held: the registers anything in the method throws, hands on or copies from (an unused opcode:
        # any its unit names); what another holds goes nowhere. out: (pc, kind, use, value)
        out, held, pc = [], set(), 0
        while pc < n:
            x = u[pc]; op = x & 0xff
            if x == 0x100: pc += 4 + 2 * u[pc + 1]; continue                  # packed-switch data
            if x == 0x200: pc += 2 + 4 * u[pc + 1]; continue                  # sparse-switch data
            if x == 0x300:                                                    # fill-array data
                pc += 4 + (u[pc + 1] * (u[pc + 2] | u[pc + 3] << 16) + 1) // 2; continue
            if nt and pc + WIDTH[op] <= n:   # (no handler: nothing to walk)
                held.update(passed(pc), [x >> 8] * (op == 0x27), [source(pc)],
                            [x >> 8, x >> 8 & 0xf, x >> 12] * (DEST[op] is None))
            if op in OPS:
                (k, use), i = OPS[op], u[pc + 1]
                if k == "t": out.append((pc, k, use, self.types[i]))
                elif k == "f": out.append((pc, k, use, self.fields[i]))
                elif k == "m":
                    out.append((pc, k, use, self.methods[i]))
                    if use == "poly": out += [(pc, "t", "proto", t) for t in self.proto_types[u[pc + 3]]]
                elif k == "p": out += [(pc, "t", "proto", t) for t in self.proto_types[i]]
                else: out += [(pc,) + y for y in self.links()[0 if k == "h" else 1][i]]
            pc += WIDTH[op]
        return [(k, use, v, guard(at)) for at, k, use, v in out], pc == n   # the guards once held is whole

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
    def ups(c):   # c's supertypes the APK defines
        return [s for s in [known[c].sup] + known[c].ifaces if s in apk and s not in plat]
    def above(c):   # the APK classes c extends or implements, through others too
        out, todo = set(), ups(c)
        while todo:
            s = todo.pop()
            if s not in out: out.add(s); todo += ups(s)
        return out
    # Supertype cycles (classes in two dexes that extend or implement each other, or an interface that
    # implements itself): ART throws ClassCircularityError loading any of them. cyc: a class on one -> its
    # entry, named by the first of the classes on a cycle with it (the same whichever way in)
    cyc = {}
    for c in apk:
        if c in plat or c in cyc: continue
        up = above(c)
        if c in up:
            ring = sorted(o for o in up if c in above(o))
            for o in ring: cyc[o] = (ring[0], "supertype cycle")
    chains = {}
    def chain(c):
        """Where ART looks for a method of c: c, its superclasses, then their interfaces (for an
        interface: itself, its superinterfaces, then Object); None and the gap if one is missing,
        or a supertype of one of the interfaces; None and a class of it (a known one) if it runs
        into a cycle of supertypes."""
        if c not in chains: chains[c] = chain1(c)
        return chains[c]
    def chain1(c):
        sups, cur = [], c
        while cur:
            if cur not in known: return None, cur   # missing
            if cur in sups: return None, min(sups[sups.index(cur):])   # a cycle (the same class whichever way in)
            sups.append(cur); cur = known[cur].sup
        ifs, queue = [], [i for s in sups for i in known[s].ifaces]
        while queue:
            i = queue.pop(0)
            if i in ifs or i in sups: continue
            if i not in known: return None, i
            ifs.append(i); queue += known[i].ifaces
        # An interface loads only if its superclass does too (Object, unless malformed; anything,
        # for a class listed as an interface)
        seen, up, more = set(sups + ifs), [known[i].sup for i in ifs], []
        while up:
            s = up.pop()
            if s is None or s in seen: continue
            if s not in known: return None, s
            seen.add(s); more.append(s); up += [known[s].sup] + known[s].ifaces
        ring = next((cyc[o][0] for o in sups + ifs + more if o in cyc), None)   # through an interface too
        if ring: return None, ring
        if known[c].flags & ACC_INTERFACE: return [c] + ifs + sups[1:], None
        return sups + ifs, None
    def same_pkg(a, b):   # same runtime package: same loader (platform or APK) and same package name
        return (a in plat) == (b in plat) and a.rpartition("/")[0] == b.rpartition("/")[0]
    def supers(c):   # c and its superclasses, c's chain whole (a class listed as an interface isn't one)
        out = []
        while c: out.append(c); c = known[c].sup
        return out
    def iftable(c):   # c's superinterfaces as ART's iftable lists them: each after those it extends (a stack: chains run deep)
        out, seen, todo = [], set(), [(c, iter(known[c].ifaces))]
        while todo:
            i = next(todo[-1][1], None)
            if i is None:
                i = todo.pop()[0]
                if todo: out.append(i)
            elif i not in seen: seen.add(i); todo.append((i, iter(known[i].ifaces)))
        return out
    def find_method(c, order, key):   # what ART resolves c->key to (FindClassMethod, FindInterfaceMethod): (class, flags)
        k = known[c]
        f = k.dm.get(key, k.vm.get(key))
        if f is not None: return c, f
        if k.flags & ACC_INTERFACE:   # superinterfaces' virtual methods (no statics, privates) in iftable order, the
            # most general first (the declarer decides the class access check), then Object's public instance ones
            for o in iftable(c) + supers(c)[1:]:
                ko = known[o]
                f = ko.vm.get(key) if ko.flags & ACC_INTERFACE else ko.dm.get(key, ko.vm.get(key))
                if f is not None and (ko.flags & ACC_INTERFACE or f & ACC_PUBLIC and not f & ACC_STATIC): return o, f
            return None
        below, unin = [c], None
        for o in supers(c)[1:]:   # superclasses: the first declaration, if c inherits it
            f = known[o].dm.get(key, known[o].vm.get(key))
            if f is None: below.append(o); continue
            if f & (ACC_PUBLIC | ACC_PROTECTED) or not f & ACC_PRIVATE and all(same_pkg(b, o) for b in below): return o, f
            unin = o, f; break
        # else an interface's virtual method copied into a class below that one (its interfaces' copies sit in it)
        skip = set(chain(unin[0])[0] or ()) if unin else ()
        for o in order:
            if known[o].flags & ACC_INTERFACE and o not in skip and key in known[o].vm: return o, known[o].vm[key]
        return unin
    def most_specific(ifs, key):   # the interfaces of ifs declaring key that no other declarer extends (ART's default pick)
        decl = [o for o in ifs if key in known[o].vm]   # (one whose own chain is broken extends nothing)
        return [o for o in decl if not any(j != o and o in (chain(j)[0] or ()) for j in decl)]
    def super_target(caller, c, key):
        # What invoke-super c->key in caller runs on ART: (class, access flags, the defaults it conflicts
        # with: ART's conflict method, which throws), or None
        if known[c].flags & ACC_INTERFACE:   # the interface's own method, else a superinterface's default
            if key in known[c].vm: return c, known[c].vm[key], []
            order = chain(c)[0][1:]
        else:   # the caller's superclass's vtable entry: a class's method, else an interface's copied into one
            order = chain(known[caller].sup)[0] if caller in known and known[caller].sup in known else None
            if not order or c not in order: return None
            for o in order:
                if not known[o].flags & ACC_INTERFACE and key in known[o].vm: return o, known[o].vm[key], []
        top = most_specific([o for o in order if known[o].flags & ACC_INTERFACE], key)
        dflt = sorted((o for o in top if not known[o].vm[key] & ACC_ABSTRACT), key=lambda o: (o not in plat, o))
        if dflt: return dflt[0], known[dflt[0]].vm[key], dflt[1:]   # two or more conflict; platform ones first
        return (top[0], known[top[0]].vm[key], []) if top else None
    def find_field(c, key):  # the class, its interfaces, then its superclass, as the JLS (depth first, a stack)
        todo, seen = [c], set()
        while todo:
            c = todo.pop()
            if c is None or c in seen or c not in known: continue
            seen.add(c); k = known[c]
            if key in k.fields: return c, k.fields[key]
            todo += reversed(k.ifaces + [k.sup])
        return None
    def extends(x, d):   # x has d as a superclass (ART lets no nested class use its outer class's protected access)
        if d == OBJECT: return True
        seen = set()
        while x in known and x not in seen:
            if x == d: return True
            seen.add(x); x = known[x].sup
        return False
    def no_access(d, f, caller):   # why a platform member of d with access flags f is out of the APK caller's reach
        if f & ACC_PUBLIC: return None
        if f & ACC_PRIVATE: return "private"
        if f & ACC_PROTECTED: return None if extends(caller, d) else "protected, and the caller isn't a subclass"
        return "package-private"
    def misuse(use, f, key):   # why invoke-<use> can't call a method with flags f
        static = f & ACC_STATIC
        direct = static or f & (ACC_PRIVATE | ACC_CONSTRUCTOR) or key[0] in ("<init>", "<clinit>")
        if use == "static": return None if static else "not static, called with invoke-static"
        if use in ("ref", "poly"): return None
        if static: return "static, called with invoke-%s" % use
        if use == "direct": return None if direct else "virtual, called with invoke-direct"
        if use == "virtual":
            return "private or a constructor, called with invoke-virtual" if direct else None
        if use == "interface":
            return "private or a constructor, called with invoke-interface" if direct else None
        if use == "super": return "a constructor, called with invoke-super" if key[0] == "<init>" else None
        return None   # instance (a method handle): only static matters

    # What each method of the APK's code uses, and who uses it
    # used: (kind, use, value) -> {(method, guard): None}, in code order (so what's settled first is the same every run)
    used, sdk, read_n, unread = {}, set(), 0, []
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
                used.setdefault((k, use, v), {})[who, g] = None
                if k == "f" and v in SDK_INT: sdk.add(who)

    catchers = {}   # (guard, error) -> its answer; (guard, error, depth) -> one that met the depth limit, for that depth only
    def catcher(guard, err, depth=0):
        # The type of the handler that keeps the error, whether it does (None: on some paths only) and whether the
        # depth limit was met below (asked from less deep, it may get further): once per handler, not per path to it
        r = catchers.get((guard, err)) or catchers.get((guard, err, depth))
        if r is None:
            r = catcher1(guard, err, depth)
            catchers[(guard, err, depth) if r[2] else (guard, err)] = r
        return r
    def catcher1(guard, err, depth):
        # No typed handler before it (that might catch another exception first, or the error of a class that can't
        # link, whose type varies)
        first = True
        for t, fate in guard:
            if t not in CATCHES[err]:
                first = first and err not in ("any", "linkage"); continue
            if fate is None: return t, None, False
            if depth >= 64: return t, None, True   # (handlers nested 64 deep, however settled)
            # Each of the handler's paths settled apart: another exception it throws is caught for sure
            # only by a handler of anything, and only if no typed handler comes before it (that one might
            # catch it first, and throw it or the error on)
            rs = [(t, True, False) if p is True else catcher(p[0], err if p[1] else "any", depth + 1) for p in fate]
            ks = {k for _, k, _ in rs}
            keeps = ks.pop() if len(ks) == 1 else None
            return (next((x for x, k, _ in rs if k is not False), t), keeps if keeps is False or first else None,
                    any(c for _, _, c in rs))
        return None, False, False
    def from_line(who, guard, err):
        line = "from " + shown(who)
        t, keeps, _ = catcher(guard, err)
        if keeps is not False: line += " [caught%s: %s]" % ("" if keeps else "?", "any" if t == "*" else t)
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
    def add(into, key, whos, err, iae=()):   # (no entry when no use is left; one in iae fails an access check ART makes first)
        for w, g in whos: into.setdefault(key, set()).add(from_line(w, g, "access" if w in iae else err))
    def loads(whos):   # the uses whose caller can load, for access checks (one that can't has its missing supertype, or cycle, listed)
        return [(w, g) for w, g in whos if not chain(w.partition("->")[0])[1]]
    def member(v, k):
        return "%s->%s%s" % v if k == "m" else "%s->%s:%s" % v
    # What keeps an APK class from linking, first: a use of one that can't is listed under why, not under what it uses
    cant = {}   # APK class -> the link errors of its own (supertypes, overrides, implementations), in the order found
    def bar(c, key, line):
        link.setdefault(key, set()).add(line); cant.setdefault(c, []).append(key)
    for c in apk.values():   # supertypes and overrides, the platform's or the APK's (ART checks both alike)
        if c.name in plat: continue
        line = "super of " + shown(c.name)
        if c.sup and c.sup not in known: missing.setdefault(c.sup, set()).add(line)
        elif c.sup:
            s = known[c.sup].flags
            if s & ACC_INTERFACE: bar(c.name, (c.sup, "an interface, extended as a class"), line)
            elif s & ACC_FINAL: bar(c.name, (c.sup, "final, extended"), line)
            if not s & ACC_PUBLIC and not same_pkg(c.name, c.sup): bar(c.name, (c.sup, "package-private class, extended"), line)
        for i in c.ifaces:
            line = "interface of " + shown(c.name)
            if i not in known: missing.setdefault(i, set()).add(line)
            else:
                s = known[i].flags
                if not s & ACC_INTERFACE: bar(c.name, (i, "a class, implemented as an interface"), line)
                if not s & ACC_PUBLIC and not same_pkg(c.name, i): bar(c.name, (i, "package-private interface, implemented"), line)
        cur, seen = c.sup, {c.name}
        while cur in known and cur not in seen:   # overriding a final method it can reach (up to a cycle)
            seen.add(cur)
            for key, f in known[cur].vm.items():
                if key in c.vm and f & ACC_FINAL and (f & (ACC_PUBLIC | ACC_PROTECTED) or not f & ACC_PRIVATE and same_pkg(c.name, cur)):
                    bar(c.name, ("%s->%s%s" % ((cur,) + key), "final, overridden"), "in " + shown(c.name))
            cur = known[cur].sup
        if c.name in cyc: link.setdefault(cyc[c.name], set()).add("in " + shown(c.name))

    unimpl = {}    # (platform type, name, proto) -> concrete APK classes that lack it
    for c in apk.values():
        if c.name in plat or c.flags & ACC_INTERFACE: continue
        order, _ = chain(c.name)
        if order is None or not any(o in plat for o in order): continue
        # The vtable as ART links it, root class first: a method overrides a slot with its name
        # and proto only when it can (public or protected, or package-private in the same runtime
        # package), else it takes a new slot; an abstract redeclaration re-abstracts the slot. A
        # slot left abstract is owed to the platform class that declared it abstract, even when an
        # APK class declares it abstract again
        sups = [o for o in order if not known[o].flags & ACC_INTERFACE]
        slots = {}   # (name, proto) -> [[declarer, flags, platform class owed], ...] in vtable order
        for k in reversed(sups):
            for m, f in known[k].vm.items():
                hit, owed = False, k if k in plat and f & ACC_ABSTRACT else None
                for s in slots.get(m, ()):
                    if s[1] & (ACC_PUBLIC | ACC_PROTECTED) or same_pkg(s[0], k):
                        s[:], hit = [k, f, owed or (s[2] if f & ACC_ABSTRACT else None)], True
                if not hit: slots.setdefault(m, []).append([k, f, owed])
        ifs = [o for o in order if known[o].flags & ACC_INTERFACE]
        # A non-public method implementing an interface's method fails the class's link
        # (IllegalAccessError), abstract class or not: ART looks at the last match in the vtable
        # for an interface the class takes on, at the class's own methods for one its superclass has
        inherited = set(chain(c.sup)[0]) if c.sup else set()
        for o in ifs:
            for m in known[o].vm:
                g = c.vm.get(m) if o in inherited else slots[m][-1][1] if m in slots else None
                if g is not None and not g & (ACC_ABSTRACT | ACC_PUBLIC):
                    bar(c.name, ("%s->%s%s" % ((o,) + m), "implemented by a non-public method"), "in " + shown(c.name))
        if c.flags & ACC_ABSTRACT: continue
        for m, ss in slots.items():
            for o, f, owed in ss:
                if owed: unimpl.setdefault((owed,) + m, set()).add(shown(c.name))
        # A platform interface's method with no class method for it (the last matching vtable
        # method, as ART searches it, is abstract or missing): ART takes the default among the most
        # specific declarations (no other declarer extends theirs), so an abstract redeclaration
        # masks the defaults above it; with none it's abstract, with two or more they conflict
        for m in {m for o in ifs if o in plat for m in known[o].vm}:
            impl = slots.get(m)
            if impl and not impl[-1][1] & ACC_ABSTRACT: continue
            dflt = sorted((o for o in most_specific(ifs, m) if not known[o].vm[m] & ACC_ABSTRACT),
                          key=lambda o: (o not in plat, o))   # platform ones first
            if len(dflt) > 1 and dflt[0] in plat:
                link.setdefault(("%s->%s%s" % ((dflt[0],) + m), "default conflicts with " + ", ".join(map(shown, dflt[1:]))),
                                set()).add("in " + shown(c.name))
            elif not dflt:
                for o in ifs:
                    if o in plat and known[o].vm.get(m, 0) & ACC_ABSTRACT:
                        unimpl.setdefault((o,) + m, set()).add(shown(c.name))
    failed = {}   # APK class -> the link error it can't load with: a supertype's (superclass first), else its own; or None
    def fails(c):   # (a stack: chains run deep; a supertype on a cycle with the class gives the cycle's, unwalked)
        if c not in apk or c in plat: return None
        todo = [c] if c not in failed else []
        while todo:
            x = todo[-1]; ring = cyc.get(x)
            up = [(s, ring if ring and cyc.get(s) == ring else None) for s in ups(x)]
            if x not in failed:
                failed[x] = None; todo += [s for s, r in reversed(up) if not r and s not in failed]; continue
            todo.pop()
            failed[x] = next((r or failed[s] for s, r in up if r or failed[s]), None) or cant.get(x, [None])[0]
        return failed[c]

    for (k, use, v), whos in used.items():
        c = elem(v) if k == "t" else v[0]
        if c is None: continue   # a primitive
        if k != "t" and c.startswith("["):   # clone() and Object's members on arrays: only the element class loads
            c, k = elem(c), "t"
            if c is None: continue
        order, g = chain(c)
        # A class that can't load or link throws why on each use, whatever is used on it (ART keeps the error, throws it
        # again): VerifyError, ClassCircularityError, ..., so only LinkageError's handlers count; with a missing supertype
        # too, whichever ART meets first
        broke = fails(c) or ((g, "supertype cycle") if g in known else None)
        if g and g not in known:
            add(missing, g, whos, "linkage" if broke else "class"); continue
        if broke:
            add(link, broke, whos, "linkage"); continue
        hidden = c in plat and not known[c].flags & ACC_PUBLIC
        if hidden and k == "t" and use in ("type", "new"):
            add(link, (c, "package-private class"), loads(whos), "access")
        if k == "t":
            if use == "new" and c in plat and known[c].flags & (ACC_ABSTRACT | ACC_INTERFACE):   # (ART checks access first)
                add(link, (c, "new-instance of an interface" if known[c].flags & ACC_INTERFACE else
                           "new-instance of an abstract class"), whos, "access" if hidden else "instantiation")
            continue
        # Only what the platform owes: a chain with no platform class in it is the APK's own business
        if not any(o in plat for o in order) or use == "poly": continue
        if k == "m":
            # ART checks the invoke kind against the class before it looks for the method
            kind = None if c not in plat else known[c].flags & ACC_INTERFACE
            if kind is not None and use == ("virtual" if kind else "interface"):
                add(link, (member(v, k), "on an interface, called with invoke-virtual" if kind else
                           "on a class, called with invoke-interface"), whos, "icce"); continue
            found = find_method(c, order, v[1:])
            if found is None:
                # ART then looks it up as a class method (FindIncompatibleMethod): on an interface, that
                # finds Object's that the interface lookup passed over: IncompatibleClassChangeError
                obj = supers(c)[1:] if known[c].flags & ACC_INTERFACE else []
                f = next((known[o].dm.get(v[1:], known[o].vm.get(v[1:])) for o in obj
                          if v[1:] in known[o].dm or v[1:] in known[o].vm), None)
                if f is None: add(mm, v, whos, "method")
                else: add(link, (member(v, k), "Object's, %s, called on an interface"
                                 % ("static" if f & ACC_STATIC else "not public")), whos, "icce")
                continue
            d, f = found
            # ART checks access (the class named, as below, then the method) before the method's kind and
            # where invoke-super lands: a use that fails it throws IllegalAccessError instead
            iae = {w for w, _ in whos if d in plat and (hidden and not known[d].flags & ACC_PUBLIC or
                                                        no_access(d, f, w.partition("->")[0]))}
            why = d in plat and misuse(use, f, v[1:])
            if why: add(link, (member(v, k), why), whos, "icce", iae); continue
            if use == "super":   # where the call lands, whoever declares what it resolved to
                for w, gd in whos:
                    t = super_target(w.partition("->")[0], c, v[1:])
                    if not t or t[0] not in plat: continue
                    if t[2]:   # IncompatibleClassChangeError
                        add(link, ("%s->%s%s" % ((t[0],) + v[1:]), "default conflicts with %s, called with invoke-super"
                                   % ", ".join(map(shown, t[2]))), [(w, gd)], "icce", iae)
                    elif t[1] & ACC_ABSTRACT:   # AbstractMethodError
                        add(link, ("%s->%s%s" % ((t[0],) + v[1:]), "abstract, called with invoke-super"), [(w, gd)], "ame", iae)
            if d not in plat: continue
        else:
            found = find_field(c, v[1:])
            if found is None:
                add(mf, v, whos, "field"); continue
            d, f = found
            if d not in plat: continue
            if use != "ref" and bool(f & ACC_STATIC) != (use in ("sget", "sput")):
                add(link, (member(v, k), ("static, used by " if f & ACC_STATIC else "an instance field, used by ") + use),
                    whos, "icce"); continue
            if use in ("iput", "sput") and f & ACC_FINAL:
                add(link, (member(v, k), "final, written by " + use), loads(whos), "access")
        if hidden and not known[d].flags & ACC_PUBLIC:   # ART checks the class named only when the declarer is out of reach
            add(link, (c, "package-private class"), loads(whos), "access")
        for w, gd in loads(whos):
            why = no_access(d, f, w.partition("->")[0])
            if why: add(link, (member(v, k), why), [(w, gd)], "access")

    named = set()
    for x in app:
        for t in x.types:
            e = elem(t)
            if e and e not in known and e not in missing: named.add(e)

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
    print("summary %d missing classes, %d methods, %d fields, %d link errors, %d shadowed, %d unimplemented; "
          "%d missing or link-error entries caught everywhere; %d platform classes from %d files, "
          "%d platform dexes unreadable; %d APK methods read, %d unreadable"
          % (len(named | set(missing)), len(mm), len(mf), len(link), len(shadowed), len(unimpl), caught,
             len(plat), files, len(bad), read_n, len(unread)))
    if bad: sys.exit(2)

if __name__ == "__main__":
    main(sys.argv)
