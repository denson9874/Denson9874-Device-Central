#!/usr/bin/env python3
# Tests for ../dex-refs.py on dex files it builds itself (no Android tools needed): missing
# classes, methods and fields with who uses them, link errors (static/instance, invoke kinds,
# access, final, instantiation, supertypes), shadowed classes, unimplemented abstract methods
# (re-abstraction, non-public implementations), try/catch guards and SDK_INT reads, method
# handles and call sites, payload instructions, 041 containers in each offset layout,
# multidex gaps, unreadable inputs, R8 mappings (inline stacks, moved methods, overloads, map
# ids), and the opcode width table against the dex format's list.
#   python3 -I dex-refs-test.py      (last line: DEX_REFS_TEST=OK, or DEX_REFS_TEST=FAIL and exit 1)
import importlib.util, io, os, struct, sys, contextlib, tempfile, zipfile

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dex-refs.py")
WORK = tempfile.mkdtemp(prefix="dex-refs-test.")
spec = importlib.util.spec_from_file_location("dexrefs", TOOL)
dr = importlib.util.module_from_spec(spec); spec.loader.exec_module(dr)

def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7f; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)

def sleb(n):
    out = bytearray()
    while True:
        b = n & 0x7f; n >>= 7
        if (n == 0 and not b & 0x40) or (n == -1 and b & 0x40): out.append(b); return bytes(out)
        out.append(b | 0x80)

def proto_types(p):
    args, ret = p[1:].split(")")
    out, i = [], 0
    while i < len(args):
        j = i
        while args[j] == "[": j += 1
        j = args.index(";", j) + 1 if args[j] == "L" else j + 1
        out.append(args[i:j]); i = j
    return out, ret

class W:
    """A minimal dex writer: ids in insertion order, a map list with only method handles and
    call sites, no checksum."""
    def __init__(self):
        self.strings, self.types, self.protos, self.fields, self.methods, self.classes = [], [], [], [], [], []
        self.handles, self.sites = [], []   # (handle type, field or method id, is a field); (handle, name, proto)
    def _ix(self, lst, v):
        if v not in lst: lst.append(v)
        return lst.index(v)
    def s(self, x): return self._ix(self.strings, x)
    def t(self, d): self.s(d); return self._ix(self.types, d)
    def p(self, p):
        a, r = proto_types(p); [self.t(x) for x in a]; self.t(r); self.s("V")
        return self._ix(self.protos, p)
    def f(self, c, n, t): self.t(c); self.s(n); self.t(t); return self._ix(self.fields, (c, n, t))
    def m(self, c, n, p): self.t(c); self.s(n); self.p(p); return self._ix(self.methods, (c, n, p))
    def h(self, t, member):   # a method handle: t is its type, member (class, name, proto or type)
        k = self.f(*member) if t <= 3 else self.m(*member)
        return self._ix(self.handles, (t, k, t <= 3))
    INVOKES = {"m": 0x6e, "msup": 0x6f, "md": 0x70, "ms": 0x71, "mi": 0x72}
    FIELDS = {"if": 0x52, "iput": 0x59, "f": 0x60, "fput": 0x67}
    def code(self, ops):
        u, tries = [], []
        self.emit(ops, u, tries)
        return u + [0x000e], tries                                          # return-void
    def emit(self, ops, u, tries):
        for op in ops:
            if op[0] in self.INVOKES: u += [self.INVOKES[op[0]], self.m(*op[1:]), 0]   # invoke-* {}
            elif op[0] == "poly": u += [0x00fa, self.m(*op[1:]), 0, self.p("()V")]
            elif op[0] in self.FIELDS: u += [self.FIELDS[op[0]], self.f(*op[1:])]     # iget/iput/sget/sput
            elif op[0] == "t": u += [0x001c, self.t(op[1])]                  # const-class
            elif op[0] == "new": u += [0x0022, self.t(op[1])]                # new-instance
            elif op[0] == "mh": u += [0x00fe, self.h(*op[1:])]               # const-method-handle
            elif op[0] == "custom":                                          # invoke-custom {}
                self.s(op[2]); self.p(op[3])
                u += [0x00fc, self._ix(self.sites, (self.h(*op[1]), op[2], op[3])), 0]
            elif op[0] == "try":                                             # ("try", ops, [types], catch_all)
                start = len(u); self.emit(op[1], u, tries)
                tries.append((start, len(u) - start, [self.t(t) for t in op[2]], op[3]))
            elif op[0] == "raw": u += list(op[1])
    def cls(self, name, sup, ifaces=(), flags=1, fields=(), dm=(), vm=()):
        # fields: (name, type, static[, access]); dm/vm: (name, proto, access, ops or None)
        self.t(name); sup is not None and self.t(sup); [self.t(i) for i in ifaces]
        fs = [(self.f(name, f[0], f[1]), f[2], f[3] if len(f) > 3 else 1) for f in fields]
        d = [(self.m(name, n, p), a, None if ops is None else self.code(ops)) for n, p, a, ops in dm]
        v = [(self.m(name, n, p), a, None if ops is None else self.code(ops)) for n, p, a, ops in vm]
        self.classes.append((name, sup, list(ifaces), flags, fs, d, v))
    def build(self, version=b"039", base=0, ids_rel=True, data_rel=True):
        """One dex whose header will sit at base in its file. Version 041 id section and data
        offsets are container-relative (as ART reads them) unless ids_rel/data_rel is False."""
        v41 = version >= b"041"
        off_add = base if v41 and data_rel else 0
        id_add = base if v41 and ids_rel else 0
        n = len
        sids = 0x78 if v41 else 0x70; tids = sids + 4 * n(self.strings); pids = tids + 4 * n(self.types)
        fids = pids + 12 * n(self.protos); mids = fids + 8 * n(self.fields); cdefs = mids + 8 * n(self.methods)
        data = bytearray(); dstart = cdefs + 32 * n(self.classes)
        def put(b, align=1):
            while (dstart + len(data)) % align: data.append(0)
            o = dstart + len(data); data.extend(b); return o + off_add
        sdo = [put(uleb(len(x)) + x.encode() + b"\0") for x in self.strings]
        def tl(ts):
            if not ts: return 0
            return put(struct.pack("<I", len(ts)) + b"".join(struct.pack("<H", self.types.index(x)) for x in ts), 4)
        po = [tl(proto_types(p)[0]) for p in self.protos]
        cd = []
        for name, sup, ifaces, flags, fs, d, v in self.classes:
            ifo = tl(ifaces)
            def enc_m(ms):
                out, last = b"", 0
                for idx, a, code in sorted(ms, key=lambda m: m[0]):
                    co = 0
                    if code is not None:
                        units, tries = code
                        b = struct.pack("<4HII", 4, 0, 0, len(tries), 0, len(units)) + struct.pack("<%dH" % len(units), *units)
                        if tries:
                            if len(units) % 2: b += b"\0\0"
                            hl, offs = uleb(len(tries)), []
                            for _, _, types, catch_all in tries:
                                offs.append(len(hl))
                                hl += sleb(-len(types) if catch_all else len(types))
                                for t in types: hl += uleb(t) + uleb(0)
                                if catch_all: hl += uleb(0)
                            b += b"".join(struct.pack("<IHH", st, cnt, o) for (st, cnt, _, _), o in zip(tries, offs)) + hl
                        co = put(b, 4)
                    out += uleb(idx - last) + uleb(a) + uleb(co); last = idx
                return out
            sf = sorted((i, a) for i, st, a in fs if st); inf = sorted((i, a) for i, st, a in fs if not st)
            def enc_f(xs):
                out, last = b"", 0
                for i, a in xs: out += uleb(i - last) + uleb(a); last = i
                return out
            dm_b, vm_b = enc_m(d), enc_m(v)
            cdo = put(uleb(len(sf)) + uleb(len(inf)) + uleb(len(d)) + uleb(len(v)) + enc_f(sf) + enc_f(inf) + dm_b + vm_b)
            cd.append((name, flags, sup, ifo, cdo))
        map_off = 0
        if self.handles or self.sites:
            mho = put(b"".join(struct.pack("<4H", t, 0, k, 0) for t, k, _ in self.handles), 4) - off_add + id_add
            arrays = []
            for hi, name, proto in self.sites:   # bootstrap handle, name, method type (2-byte values)
                arrays.append(put(uleb(3) + bytes([0x16 | 1 << 5]) + struct.pack("<H", hi) + bytes([0x17 | 1 << 5])
                                  + struct.pack("<H", self.strings.index(name)) + bytes([0x15 | 1 << 5])
                                  + struct.pack("<H", self.protos.index(proto))))
            cso = put(b"".join(struct.pack("<I", a) for a in arrays), 4) - off_add + id_add
            map_off = put(struct.pack("<I", 2) + struct.pack("<HHII", 0x8, 0, len(self.handles), mho)
                          + struct.pack("<HHII", 0x7, 0, len(self.sites), cso), 4)
        out = bytearray(dstart)
        size = dstart + len(data)
        out[0:8] = b"dex\n" + version + b"\0"
        struct.pack_into("<I", out, 0x20, size)
        struct.pack_into("<2I", out, 0x24, sids, 0)
        struct.pack_into("<I", out, 0x34, map_off)
        struct.pack_into("<12I", out, 0x38, n(self.strings), sids + id_add, n(self.types), tids + id_add,
                         n(self.protos), pids + id_add, n(self.fields), fids + id_add, n(self.methods), mids + id_add,
                         n(self.classes), cdefs + id_add)
        if v41: struct.pack_into("<2I", out, 0x70, 0, base)   # container_size (unused here), header_offset
        for i, o in enumerate(sdo): struct.pack_into("<I", out, sids + 4 * i, o)
        for i, x in enumerate(self.types): struct.pack_into("<I", out, tids + 4 * i, self.strings.index(x))
        for i, p in enumerate(self.protos):
            a, r = proto_types(p)
            struct.pack_into("<3I", out, pids + 12 * i, self.strings.index("V"), self.types.index(r), po[i])
        for i, (c, nm, t) in enumerate(self.fields):
            struct.pack_into("<HHI", out, fids + 8 * i, self.types.index(c), self.types.index(t), self.strings.index(nm))
        for i, (c, nm, p) in enumerate(self.methods):
            struct.pack_into("<HHI", out, mids + 8 * i, self.types.index(c), self.protos.index(p), self.strings.index(nm))
        for i, (name, flags, sup, ifo, cdo) in enumerate(cd):
            struct.pack_into("<8I", out, cdefs + 32 * i, self.types.index(name), flags,
                             0xffffffff if sup is None else self.types.index(sup), ifo, 0xffffffff, 0, cdo, 0)
        return bytes(out) + bytes(data)

OBJ, BASE, IFOO = "Ljava/lang/Object;", "Landroid/os/Base;", "Landroid/os/IFoo;"
def platform():
    w = W()
    w.cls(OBJ, None, vm=[("toString", "()Ljava/lang/String;", 1, []), ("hashCode", "()I", 1, [])])
    w.cls("Ljava/lang/invoke/MethodHandle;", OBJ, vm=[("invoke", "([Ljava/lang/Object;)Ljava/lang/Object;", 0x181, None)])
    w.cls(IFOO, OBJ, flags=0x601, vm=[("onA", "()V", 0x401, None), ("onB", "()V", 0x401, None), ("dflt", "()V", 1, [])])
    w.cls(BASE, OBJ, [IFOO], flags=0x401, fields=[("sf", "I", True), ("inf", "I", False)],
          vm=[("onA", "()V", 1, []), ("run", "()V", 0x401, None), ("kept", "()V", 1, [])])
    w.cls("Landroid/os/Shared;", OBJ, vm=[("keep", "()V", 1, [])])
    w.cls("Ljava/lang/String;", OBJ)
    return w.build()

def platform041():
    # Two dexes in one container: the second's ids and data sit past the first
    w1, w2 = W(), W()
    w1.cls(OBJ, None, vm=[("toString", "()Ljava/lang/String;", 1, []), ("hashCode", "()I", 1, [])])
    w1.cls("Ljava/lang/invoke/MethodHandle;", OBJ, vm=[("invoke", "([Ljava/lang/Object;)Ljava/lang/Object;", 0x181, None)])
    w1.cls(IFOO, OBJ, flags=0x601, vm=[("onA", "()V", 0x401, None), ("onB", "()V", 0x401, None), ("dflt", "()V", 1, [])])
    w2.cls(BASE, OBJ, [IFOO], flags=0x401, fields=[("sf", "I", True), ("inf", "I", False)],
           vm=[("onA", "()V", 1, []), ("run", "()V", 0x401, None), ("kept", "()V", 1, [])])
    w2.cls("Landroid/os/Shared;", OBJ, vm=[("keep", "()V", 1, [])])
    w2.cls("Ljava/lang/String;", OBJ)
    d1 = w1.build(b"041", 0)
    return d1 + w2.build(b"041", len(d1))

# Payload pseudo-instructions after the return: packed-switch (2 keys), sparse-switch (1), fill-array (3 bytes)
PAYLOADS = [0x000e, 0x0100, 2, 0, 0, 1, 0, 2, 0, 0x0200, 1, 5, 0, 1, 0, 0x0300, 1, 3, 0, 0x0201, 0x0003]
def app_parts():
    a, b = W(), W()
    a.cls("Lapp/Impl;", BASE, vm=[("run", "()V", 1, [
        ("m", BASE, "kept", "()V"), ("m", BASE, "gone", "()V"), ("f", BASE, "sf", "I"), ("if", BASE, "nf", "I"),
        ("if", "Lapp/Impl;", "inf", "I"),   # inherited from Base: fine
        ("t", "Landroid/os/Missing;"), ("ms", "Landroid/os/Gone2;", "x", "()V"),
        ("m", "[I", "clone", "()Ljava/lang/Object;"), ("poly", "Ljava/lang/invoke/MethodHandle;", "invoke", "(I)V"),
        ("m", "Landroid/os/Shared;", "extra", "()V"), ("m", "Landroid/os/Shared;", "keep", "()V"),
        ("m", "Lapp/Impl;", "toString", "()Ljava/lang/String;"),   # Object's
        ("raw", PAYLOADS)])],
        dm=[("helper", "(Landroid/os/OnlyNamed;)V", 2, [])])
    a.cls("Lapp/Abs;", BASE, flags=0x401)
    a.cls("Landroid/os/Shared;", OBJ, vm=[("keep", "()V", 1, []), ("extra", "()V", 1, [("t", "Landroid/os/NeverRuns;")])])
    b.cls("Lapp/Sub;", "Lapp/Impl;")
    b.cls("Lapp/Broken;", "Landroid/os/NoSuch;")
    b.cls("Lapp/Broken2;", OBJ, ["Landroid/os/NoIface;"])
    b.cls("Lapp/Dflt;", OBJ, [IFOO], vm=[("onA", "()V", 1, []), ("onB", "()V", 1, [])])  # dflt from the interface
    return a, b

def run(args, code=0):
    """The tool's stdout, checking its exit status (an exit message counts as status 1)."""
    out, err = io.StringIO(), io.StringIO()
    got = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try: dr.main(["dex-refs.py"] + args)
        except SystemExit as e: got = e.code if isinstance(e.code, int) else (print(e.code, file=sys.stderr) or 1)
    if got != code: return "exit %s (want %s)\n%s%s" % (got, code, out.getvalue(), err.getvalue())
    return out.getvalue()
def run_err(args):
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        try: dr.main(["dex-refs.py"] + args)
        except SystemExit as e: print(e.code, file=sys.stderr)
    return err.getvalue()

EXPECT = """missing-class Landroid/os/Gone2; refs=1
  from Lapp/Impl;->run()V
missing-class Landroid/os/Missing; refs=1
  from Lapp/Impl;->run()V
missing-class Landroid/os/NeverRuns; refs=0 named-only
missing-class Landroid/os/NoIface; refs=1
  interface of Lapp/Broken2;
missing-class Landroid/os/NoSuch; refs=1
  super of Lapp/Broken;
missing-class Landroid/os/OnlyNamed; refs=0 named-only
missing-method Landroid/os/Base;->gone()V
  from Lapp/Impl;->run()V
missing-method Landroid/os/Shared;->extra()V
  from Lapp/Impl;->run()V
missing-field Landroid/os/Base;->nf:I
  from Lapp/Impl;->run()V
shadowed Landroid/os/Shared; {plat} apk-only=1
unimplemented Landroid/os/IFoo;->onB()V
  in Lapp/Impl;
  in Lapp/Sub;
summary 6 missing classes, 2 methods, 1 fields, 0 link errors (0 of these caught everywhere), 1 shadowed, 1 unimplemented; 6 platform classes from 1 files, 0 platform dexes unreadable; 4 APK methods read, 0 unreadable
"""

# Link errors, guards, handles: platform and APK for the scenario test
S, I2 = "Landroid/os/S;", "Landroid/os/I2;"
def platform2():
    w = W()
    w.cls(OBJ, None, vm=[("toString", "()Ljava/lang/String;", 1, [])])
    w.cls("Ljava/lang/String;", OBJ)
    for e in ("Ljava/lang/LinkageError;", "Ljava/lang/NoSuchMethodError;"): w.cls(e, OBJ)
    w.cls("Landroid/os/Build$VERSION;", OBJ, fields=[("SDK_INT", "I", True, 0x19)])
    w.cls(S, OBJ, fields=[("sf", "I", True), ("inf", "I", False), ("CONST", "I", True, 0x19)],
          dm=[("sm", "()V", 0x9, []), ("pm", "()V", 0x2, []), ("<init>", "()V", 0x10001, [])],
          vm=[("vm", "()V", 1, []), ("pkg", "()V", 0, []), ("prot", "()V", 4, []), ("fin", "()V", 0x11, [])])
    w.cls("Landroid/os/Fin;", OBJ, flags=0x11)
    w.cls("Landroid/os/Hidden;", OBJ, flags=0)
    w.cls(I2, OBJ, flags=0x601, vm=[("go", "()V", 0x401, None)])
    w.cls("Landroid/os/Abs;", OBJ, flags=0x401)
    w.cls("Landroid/os/P1;", OBJ, vm=[("m", "()V", 1, [])])
    w.cls("Landroid/os/P2;", "Landroid/os/P1;", flags=0x401, vm=[("m", "()V", 0x401, None)])
    return w.build()
def app2():
    w = W()
    w.cls("Lapp/U;", OBJ, vm=[("run", "()V", 1, [
        ("if", S, "sf", "I"), ("f", S, "inf", "I"), ("fput", S, "CONST", "I"), ("iput", S, "inf", "I"),
        ("m", S, "sm", "()V"), ("ms", S, "vm", "()V"), ("m", S, "pm", "()V"), ("md", S, "pm", "()V"),
        ("m", S, "pkg", "()V"), ("m", S, "prot", "()V"), ("t", "Landroid/os/Hidden;"), ("m", I2, "go", "()V"),
        ("mi", S, "vm", "()V"), ("new", "Landroid/os/Abs;"), ("new", I2), ("md", S, "<init>", "()V"),
        ("m", "[Landroid/os/ArrGone;", "clone", "()Ljava/lang/Object;"),
        ("try", [("m", S, "gone", "()V")], ["Ljava/lang/LinkageError;"], False),
        ("try", [("t", "Landroid/os/Guarded;")], ["Ljava/lang/NoSuchMethodError;"], False),
        ("try", [("if", S, "nf2", "I")], [], True),
        ("raw", [0x0000] * 3)])])   # odd code length, so the tries need padding
    w.cls("Lapp/V;", S, vm=[("call", "()V", 1, [("m", S, "prot", "()V")]), ("fin", "()V", 1, [])])
    w.cls("Lapp/V$1;", OBJ, vm=[("run", "()V", 1, [("m", S, "prot", "()V")])])
    w.cls("Lapp/W;", "Landroid/os/Fin;")
    w.cls("Lapp/X;", "Landroid/os/Hidden;")
    w.cls("Lapp/Y;", OBJ, [S])
    w.cls("Lapp/R;", "Landroid/os/P2;")
    w.cls("Lapp/T;", OBJ, [I2], vm=[("go", "()V", 4, [])])
    w.cls("Lapp/Sdk;", OBJ, vm=[("run", "()V", 1, [("f", "Landroid/os/Build$VERSION;", "SDK_INT", "I"),
                                                   ("m", S, "gone4", "()V")])])
    w.cls("Lapp/H;", OBJ, vm=[("run", "()V", 1, [
        ("mh", 4, (S, "gone5", "()V")), ("custom", (4, ("Landroid/os/Boot;", "bsm", "()V")), "name", "()V"),
        ("mh", 1, (S, "inf", "I"))])])
    return w.build()
EXPECT2 = [   # lines that must be in the scenario output
    "link-error Landroid/os/S;->sf:I static, used by iget", "link-error Landroid/os/S;->inf:I an instance field, used by sget",
    "link-error Landroid/os/S;->CONST:I final, written by sput", "link-error Landroid/os/S;->sm()V static, called with invoke-virtual",
    "link-error Landroid/os/S;->vm()V not static, called with invoke-static",
    "link-error Landroid/os/S;->pm()V private or a constructor, called with invoke-virtual",
    "link-error Landroid/os/S;->pm()V private", "link-error Landroid/os/S;->pkg()V package-private",
    "link-error Landroid/os/S;->prot()V protected, and the caller isn't a subclass",
    "link-error Landroid/os/Hidden; package-private class",
    "link-error Landroid/os/I2;->go()V on an interface, called with invoke-virtual",
    "link-error Landroid/os/S;->vm()V on a class, called with invoke-interface",
    "link-error Landroid/os/Abs; new-instance of an abstract class", "link-error Landroid/os/I2; new-instance of an interface",
    "link-error Landroid/os/Fin; final, extended", "  super of Lapp/W;",
    "link-error Landroid/os/Hidden; package-private class, extended", "  super of Lapp/X;",
    "link-error Landroid/os/S; a class, implemented as an interface", "  interface of Lapp/Y;",
    "link-error Landroid/os/S;->fin()V final, overridden", "  in Lapp/V;",
    "missing-class Landroid/os/ArrGone; refs=1", "missing-class Landroid/os/Guarded; refs=1",
    "missing-method Landroid/os/S;->gone()V", "  from Lapp/U;->run()V [caught: Ljava/lang/LinkageError;]",
    "missing-field Landroid/os/S;->nf2:I", "  from Lapp/U;->run()V [caught: any]",
    "missing-method Landroid/os/S;->gone4()V", "  from Lapp/Sdk;->run()V [reads SDK_INT]",
    "missing-method Landroid/os/S;->gone5()V", "  from Lapp/H;->run()V",
    "missing-class Landroid/os/Boot; refs=1",
    "unimplemented Landroid/os/P2;->m()V", "  in Lapp/R;",
    "unimplemented Landroid/os/I2;->go()V", "  in Lapp/T; (only a non-public method: IllegalAccessError)",
]
UNEXPECTED2 = ["  from Lapp/V;->call()V", "  from Lapp/V$1;->run()V",   # protected from a subclass and its nested class
               "link-error Landroid/os/S;-><init>()V", "  from Lapp/U;->run()V [caught: Ljava/lang/NoSuchMethodError;]"]

def main():
    os.makedirs(WORK, exist_ok=True)
    plat = os.path.join(WORK, "plat.dex"); open(plat, "wb").write(platform())
    fails = 0
    def check(label, got, want):
        nonlocal fails
        if got == want: print("ok", label)
        else:
            fails += 1; print("FAIL", label); print("--- want\n" + want + "--- got\n" + got)
    def check_lines(label, got, want, unwanted=()):
        nonlocal fails
        lines = got.splitlines()
        miss = [l for l in want if l not in lines]
        extra = [l for l in unwanted if l in lines]
        if not miss and not extra: print("ok", label); return
        fails += 1; print("FAIL", label)
        for l in miss: print("  missing: " + l)
        for l in extra: print("  unwanted: " + l)
        print("--- got\n" + got)
    def apk_of(name, dexes):
        path = os.path.join(WORK, name)
        with zipfile.ZipFile(path, "w") as z:
            for n, d in dexes: z.writestr(n, d)
        return path
    a, b = app_parts()
    # 039: classes.dex and classes2.dex in an APK
    apk = apk_of("app.apk", [("classes.dex", a.build()), ("classes2.dex", b.build())])
    # Code read: Impl.run, Impl.helper, Dflt.onA, Dflt.onB (Shared's is shadowed, so never runs)
    want = EXPECT.replace("{plat}", plat)
    check("039 apk", run([apk, plat]), want)
    # 041 containers: all offsets container-relative (ART), ids header-relative, all header-relative
    for ids_rel, data_rel in ((True, True), (False, True), (False, False)):
        a2, b2 = app_parts()
        d1 = a2.build(b"041", 0, ids_rel, data_rel)
        d2 = b2.build(b"041", len(d1), ids_rel, data_rel)
        p = os.path.join(WORK, "app041-%s-%s.dex" % (ids_rel, data_rel)); open(p, "wb").write(d1 + d2)
        check("041 container ids_rel=%s data_rel=%s" % (ids_rel, data_rel), run([p, plat]), want)
    # The platform as a 041 jar too
    pj = apk_of("plat041.jar", [("classes.dex", platform041())])
    check("041 platform jar", run([apk, pj]), want.replace(plat, pj))
    # Mapping: an inline stack's last line is the method; platform names stay
    mp = os.path.join(WORK, "mapping.txt")
    open(mp, "w").write("# comment\ncom.ex.RealImpl -> app.Impl:\n    1:4:void com.other.Inlined.x():5:8 -> run\n"
                        "    1:4:void realRun():10:13 -> run\ncom.ex.RealSub -> app.Sub:\n")
    wm = want.replace("Lapp/Impl;->run()V", "Lcom/ex/RealImpl;->realRun()V").replace("in Lapp/Impl;", "in Lcom/ex/RealImpl;").replace("in Lapp/Sub;", "in Lcom/ex/RealSub;")
    check("mapping", run(["--mapping", mp, apk, plat]), wm)

    # Link errors, guards, SDK_INT, method handles and call sites, arrays of missing classes
    p2 = os.path.join(WORK, "plat2.dex"); open(p2, "wb").write(platform2())
    apk2 = apk_of("app2.apk", [("classes.dex", app2())])
    check_lines("link errors, guards, handles", run([apk2, p2]), EXPECT2, UNEXPECTED2)

    # Multidex stops at the first missing classesN.dex, as ART's loader does
    m1, m3 = W(), W()
    m1.cls("Lapp/Main;", OBJ, vm=[("run", "()V", 1, [("ms", "Lapp/Lost;", "go", "()V")])])
    m3.cls("Lapp/Lost;", OBJ, dm=[("go", "()V", 9, [])])
    gap = apk_of("gap.apk", [("classes.dex", m1.build()), ("classes3.dex", m3.build())])
    check_lines("multidex gap", run([gap, plat]), ["missing-class Lapp/Lost; refs=1", "  from Lapp/Main;->run()V"])
    check("multidex gap note", str("ART never opens classes3.dex" in run_err([gap, plat])), "True")

    # Unreadable platform input: a bad dex in a jar keeps the jar's good one; a corrupt deflated
    # jar is a note, not a traceback; exit 2 either way
    g = W(); g.cls("Landroid/os/Gone2;", OBJ, dm=[("x", "()V", 9, [])])
    part = apk_of("part.jar", [("classes.dex", g.build()), ("classes2.dex", b"dex\n039\0" + b"\xff" * 200)])
    bad = os.path.join(WORK, "bad.jar")
    with zipfile.ZipFile(bad, "w", zipfile.ZIP_DEFLATED) as z: z.writestr("classes.dex", platform() * 4)
    raw = bytearray(open(bad, "rb").read())
    for i in range(60, 120): raw[i] ^= 0x5a
    open(bad, "wb").write(bytes(raw))
    out = run([apk, plat, part, bad], code=2)
    check_lines("unreadable platform dexes", out,
                ["summary 5 missing classes, 2 methods, 1 fields, 0 link errors (0 of these caught everywhere), 1 shadowed, "
                 "1 unimplemented; 7 platform classes from 2 files, 2 platform dexes unreadable; 4 APK methods read, 0 unreadable"],
                ["missing-class Landroid/os/Gone2; refs=1"])

    # Mapping ids: another build's mapping stops the run; the right one passes
    k = W(); k.s('~~R8{"compilation-mode":"release","pg-map-id":"abc1234"}')
    k.cls("La;", OBJ, vm=[("a", "()V", 1, [("t", "Landroid/os/Gone3;")]), ("c", "()V", 1, [("t", "Landroid/os/Gone3;")]),
                          ("b", "(I)V", 1, [("t", "Landroid/os/Gone3;")])])
    kapk = apk_of("k.apk", [("classes.dex", k.build())])
    body = ("com.ex.Foo -> a:\n    1:3:void bind():10:12 -> a\n    4:4:void updateIcon():40:40 -> a\n"
            "    4:4:void bind():13 -> a\n    1:2:void com.ex.Other.refresh():20:21 -> c\n"
            "    void load(int) -> b\n    void load(java.lang.String) -> b\n")
    open(mp, "w").write("# compiler: R8\n# pg_map_id: def5678\n" + body)
    check("mapping of another build", str("another build's mapping" in run_err(["--mapping", mp, kapk, plat])), "True")
    open(mp, "w").write("# pg_map_id: abc1234\n" + body)
    check_lines("mapping inline stack, moved method, overload", run(["--mapping", mp, kapk, plat]),
                ["  from Lcom/ex/Foo;->bind()V", "  from Lcom/ex/Other;->refresh()V", "  from Lcom/ex/Foo;->load(I)V"],
                ["  from Lcom/ex/Foo;->bind | updateIcon()V", "  from Lcom/ex/Foo;->c()V"])

    # Width table: every opcode's width matches the dex format spec's list
    spec_w = {1: [0x00, 0x01, 0x04, 0x07] + list(range(0x0a, 0x13)) + [0x1d, 0x1e, 0x21, 0x27, 0x28] + list(range(0x3e, 0x44))
              + [0x73, 0x79, 0x7a] + list(range(0x7b, 0x90)) + list(range(0xb0, 0xd0)) + list(range(0xe3, 0xfa)),
              2: [0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1a, 0x1c, 0x1f, 0x20, 0x22, 0x23, 0x29] + list(range(0x2d, 0x3e))
              + list(range(0x44, 0x6e)) + list(range(0x90, 0xb0)) + list(range(0xd0, 0xe3)) + [0xfe, 0xff],
              3: [0x03, 0x06, 0x09, 0x14, 0x17, 0x1b, 0x24, 0x25, 0x26, 0x2a, 0x2b, 0x2c] + list(range(0x6e, 0x73))
              + list(range(0x74, 0x79)) + [0xfc, 0xfd],
              4: [0xfa, 0xfb], 5: [0x18]}
    flat = {op: w for w, ops in spec_w.items() for op in ops}
    check("opcode table covers 256", str(sorted(flat) == list(range(256))), "True")
    bad = [hex(op) for op in range(256) if dr.WIDTH[op] != flat.get(op)]
    check("opcode widths", str(bad), "[]")
    import shutil; shutil.rmtree(WORK, ignore_errors=True)
    print("DEX_REFS_TEST=" + ("FAIL" if fails else "OK"))
    sys.exit(1 if fails else 0)

main()
