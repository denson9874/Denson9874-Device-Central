#!/usr/bin/env python3
# Tests for ../dex-refs.py on dex files it builds itself (no Android tools needed): missing
# classes, methods and fields with who uses them, method lookup as ART does it (interface
# statics, Object's methods through an interface, the most general superinterface declaration,
# uninherited superclass methods, the invoke kind first, classes listed as interfaces, interface
# chains past the recursion limit), field lookup order, link errors (static/instance, invoke
# kinds, access, final, instantiation, supertypes, invoke-super of abstract methods or
# conflicting defaults, non-public interface implementations, conflicting defaults), interfaces
# whose superclass is missing (no crash), uses of classes that can't link (and of those below
# them, for the platform's or the APK's own reason, a supertype cycle across dexes) as
# LinkageErrors (after a typed handler, can't tell), shadowed classes, unimplemented abstract
# methods (re-abstraction, masked defaults), try/catch guards (each kind of use's own error, an
# access check ART makes first, handlers that rethrow, copies (their sources too),
# registers written over (a wide write: its pair only), the error handed on (by each invoke and
# its /range form, from registers past a field's low bits), each path apart, switch cases, the
# method's own code after a handler, try blocks reached while it's held, a typed handler before a
# catch-all, code that can't be followed, walks too long or nested too deep either way and at
# each limit's edge, the catcher's cache by depth, the same output whatever the hash seed, a big
# try table in time) and SDK_INT reads, the summary (an entry caught only in part), method
# handles, call sites and method types, payload instructions, 041 containers in each offset
# layout, multidex gaps, unreadable inputs, R8 mappings (inline stacks, moved methods, overloads,
# map ids), the opcode width, register-write and wide-write tables against the dex format's
# lists, and the catch table against the error classes' superclasses.
#   python3 -I dex-refs-test.py      (last line: DEX_REFS_TEST=OK, or DEX_REFS_TEST=FAIL and exit 1)
import importlib.util, io, os, signal, struct, subprocess, sys, contextlib, tempfile, time, traceback, zipfile

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
            elif op[0] == "poly": u += [0x00fa, self.m(*op[1:4]), 0, self.p(op[4] if len(op) > 4 else "()V")]
            elif op[0] in self.FIELDS: u += [self.FIELDS[op[0]], self.f(*op[1:])]     # iget/iput/sget/sput
            elif op[0] == "t": u += [0x001c, self.t(op[1])]                  # const-class
            elif op[0] == "new": u += [0x0022, self.t(op[1])]                # new-instance
            elif op[0] == "mh": u += [0x00fe, self.h(*op[1:])]               # const-method-handle
            elif op[0] == "custom":                                          # invoke-custom {}
                self.s(op[2]); self.p(op[3])
                u += [0x00fc, self._ix(self.sites, (self.h(*op[1]), op[2], op[3])), 0]
            elif op[0] == "try":   # ("try", ops, [types], catch_all[, handler ops[, the handler's own catch_all covers it]])
                start = len(u); self.emit(op[1], u, tries); end, h = len(u), 0   # no handler ops: every handler at 0
                if len(op) > 4:   # goto past the handler, which all of the try's handlers share
                    u.append(0); h = len(u); self.emit(op[4], u, tries); u[end] = 0x28 | (len(u) - end) << 8
                    if len(op) > 5: tries.append((h, len(u) - h, [], True, h))
                tries.append((start, end - start, [self.t(t) for t in op[2]], op[3], h))
            elif op[0] == "raw": u += list(op[1])
            elif op[0] == "tryat":   # start, count, types, catch_all, handler (or a list: one per type, then the catch-all's)
                tries.append((op[1], op[2], [self.t(t) for t in op[3]], op[4], op[5]))
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
                            for _, _, types, catch_all, h in tries:
                                offs.append(len(hl))
                                hs = h if isinstance(h, list) else [h] * (len(types) + 1)
                                hl += sleb(-len(types) if catch_all else len(types))
                                for t, a in zip(types, hs): hl += uleb(t) + uleb(a)
                                if catch_all: hl += uleb(hs[-1])
                            b += b"".join(struct.pack("<IHH", st, cnt, o) for (st, cnt, _, _, _), o in zip(tries, offs)) + hl
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

def too_slow(*_): raise TimeoutError("over the time limit")

def run(args, code=0):
    """The tool's stdout, checking its exit status (an exit message counts as status 1, a crash
    as its traceback)."""
    out, err = io.StringIO(), io.StringIO()
    got = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try: dr.main(["dex-refs.py"] + args)
        except SystemExit as e: got = e.code if isinstance(e.code, int) else (print(e.code, file=sys.stderr) or 1)
        except Exception: got = "a crash"; traceback.print_exc()
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
summary 6 missing classes, 2 methods, 1 fields, 0 link errors, 1 shadowed, 1 unimplemented; 0 missing or link-error entries caught everywhere; 6 platform classes from 1 files, 0 platform dexes unreadable; 4 APK methods read, 0 unreadable
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
    w.cls("Lapp/V$$ExternalSyntheticLambda0;", OBJ, vm=[("run", "()V", 1, [("m", "Lapp/V;", "prot", "()V")])])
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
    "  from Lapp/V$1;->run()V", "  from Lapp/V$$ExternalSyntheticLambda0;->run()V",   # ART has no rule for nested classes
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
    "link-error Landroid/os/I2;->go()V implemented by a non-public method", "  in Lapp/T;",   # ART fails to link T
]
UNEXPECTED2 = ["  from Lapp/V;->call()V",   # protected from a subclass
               "link-error Landroid/os/S;-><init>()V", "  from Lapp/U;->run()V [caught: Ljava/lang/NoSuchMethodError;]",
               "unimplemented Landroid/os/I2;->go()V"]

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
                ["summary 5 missing classes, 2 methods, 1 fields, 0 link errors, 1 shadowed, 1 unimplemented; "
                 "0 missing or link-error entries caught everywhere; 7 platform classes from 2 files, 2 platform dexes unreadable; 4 APK methods read, 0 unreadable"],
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

    def scenario(name, pw, aw):   # the tool's output on a platform and an APK built by W writers
        p = os.path.join(WORK, name + "-plat.dex"); open(p, "wb").write(pw.build())
        return run([apk_of(name + ".apk", [("classes.dex", aw.build())]), p])

    # Summary: the caught count covers every kind of entry, so it isn't printed as a part of the link errors; an entry
    # with a [caught: ...] line and one without (Q) isn't caught everywhere
    pw, aw = W(), W()
    pw.cls(OBJ, None); pw.cls("Ljava/lang/Throwable;", OBJ); pw.cls(S, OBJ, dm=[("st", "()V", 9, [])])
    aw.cls("Lapp/A;", OBJ, vm=[("run", "()V", 1, [("try", [("t", "Landroid/os/Missing;")], ["Ljava/lang/Throwable;"], False),
                                                  ("m", S, "st", "()V")])])
    q = ("ms", "Landroid/os/Q;", "x", "()V")
    aw.cls("Lapp/Q;", OBJ, vm=[("kept", "()V", 1, [("try", [q], [], True, [("raw", [0x010d])])]), ("bare", "()V", 1, [q])])
    check_lines("summary caught count", scenario("sum", pw, aw),
                ["  from Lapp/A;->run()V [caught: Ljava/lang/Throwable;]", "  from Lapp/A;->run()V",
                 "  from Lapp/Q;->kept()V [caught: any]", "  from Lapp/Q;->bare()V",
                 "summary 2 missing classes, 0 methods, 0 fields, 1 link errors, 0 shadowed, 0 unimplemented; "
                 "1 missing or link-error entries caught everywhere; 3 platform classes from 1 files, 0 platform dexes "
                 "unreadable; 3 APK methods read, 0 unreadable"])

    # A package-private platform class named by a member reference: ART checks it only when the
    # member's declaring class is out of reach too; a proto's types aren't access-checked
    PB, PI = "Landroid/os/PBase;", "Landroid/os/PImpl;"
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(PB, OBJ, fields=[("COUNT", "[I", True), ("inst", "I", False)], dm=[("sm", "()V", 9, [])], vm=[("pub", "()V", 1, [])])
    pw.cls(PI, PB, flags=0, vm=[("own", "()V", 1, [])])
    pw.cls("Ljava/lang/invoke/MethodHandle;", OBJ, vm=[("invoke", "([Ljava/lang/Object;)Ljava/lang/Object;", 0x181, None)])
    aw.cls("Lapp/PP;", OBJ, vm=[("a", "()V", 1, [("m", PI, "pub", "()V")]), ("b", "()V", 1, [("f", PI, "COUNT", "[I")]),
                                ("c", "()V", 1, [("ms", PI, "sm", "()V")]), ("d", "()V", 1, [("if", PI, "inst", "I")]),
                                ("e", "()V", 1, [("m", PI, "own", "()V")]), ("h", "()V", 1, [("t", PI)]),
                                ("p", "()V", 1, [("poly", "Ljava/lang/invoke/MethodHandle;", "invoke",
                                                  "([Ljava/lang/Object;)Ljava/lang/Object;", "(%s)V" % PI)]),
                                ("q", "()V", 1, [("raw", [0x00ff, aw.p("(%s)V" % PI)])]),   # const-method-type
                                ("r", "()V", 1, [("custom", (4, (PB, "sm", "()V")), "x", "(%s)V" % PI)])])   # a call site's method type
    check_lines("package-private class of a member", scenario("pkgcls", pw, aw),
                ["link-error Landroid/os/PImpl; package-private class", "  from Lapp/PP;->e()V", "  from Lapp/PP;->h()V"],
                ["  from Lapp/PP;->a()V", "  from Lapp/PP;->b()V", "  from Lapp/PP;->c()V", "  from Lapp/PP;->d()V",
                 "  from Lapp/PP;->p()V", "  from Lapp/PP;->q()V", "  from Lapp/PP;->r()V"])
    # Nor is it listed for a caller that can't load (its superclass is missing): its code never runs
    aw = W()
    aw.cls("Lapp/D;", "Landroid/os/GoneSuper;", vm=[("e", "()V", 1, [("m", PI, "own", "()V")]), ("h", "()V", 1, [("t", PI)]),
                                                    ("n", "()V", 1, [("new", PI)])])
    check_lines("package-private class from a caller that can't load", scenario("pkgcls2", pw, aw),
                ["missing-class Landroid/os/GoneSuper; refs=1", "  super of Lapp/D;"],
                ["link-error Landroid/os/PImpl; package-private class"])

    # Protected access from a class that can't load (its superclass is missing) isn't a second
    # error, nor is a write to a final field, though what its code uses that is missing is still
    # listed; Object's protected members are in every class's reach
    pw, aw = W(), W()
    pw.cls(OBJ, None, vm=[("clone", "()Ljava/lang/Object;", 0x104, [])])
    pw.cls("Landroid/view/View;", OBJ, fields=[("CONST", "I", True, 0x19)], vm=[("onDraw", "()V", 4, [])])
    clone, const = ("m", OBJ, "clone", "()Ljava/lang/Object;"), ("fput", "Landroid/view/View;", "CONST", "I")
    aw.cls("Lapp/D;", "Landroid/os/GoneSuper;", dm=[("arr", "()V", 9, [clone, ("t", "Landroid/os/Other;"),
                                                                   ("m", "Landroid/view/View;", "gone", "()V"), ("if", "Landroid/view/View;", "nf", "I")]),
                                                 ("fin", "()V", 9, [const])])
    aw.cls("Lapp/B;", "Landroid/os/GoneSuper2;"); aw.cls("Lapp/E;", "Lapp/B;", vm=[("run", "()V", 1, [clone])])
    aw.cls("Lapp/V;", "Landroid/widget/GoneView;", vm=[("onDraw", "()V", 1, [("msup", "Landroid/view/View;", "onDraw", "()V")])])
    aw.cls("Lapp/Ok;", OBJ, vm=[("run", "()V", 1, [clone])])
    aw.cls("Lapp/Other;", OBJ, vm=[("run", "()V", 1, [("m", "Landroid/view/View;", "onDraw", "()V")]), ("fin", "()V", 1, [const])])
    out = scenario("brokensup", pw, aw)
    check_lines("protected access from a class that can't load", out,
                ["missing-class Landroid/os/GoneSuper; refs=1", "  super of Lapp/D;", "  super of Lapp/V;",
                 "link-error Landroid/view/View;->onDraw()V protected, and the caller isn't a subclass", "  from Lapp/Other;->run()V",
                 "missing-class Landroid/os/Other; refs=1", "  from Lapp/D;->arr()V",
                 "link-error Landroid/view/View;->CONST:I final, written by sput", "  from Lapp/Other;->fin()V"],
                ["link-error Ljava/lang/Object;->clone()Ljava/lang/Object; protected, and the caller isn't a subclass",
                 "  from Lapp/V;->onDraw()V", "  from Lapp/D;->fin()V"])
    check("missing members from a class that can't load", str([e for e in ("missing-method Landroid/view/View;->gone()V",
                                                                            "missing-field Landroid/view/View;->nf:I")
                                                                if e + "\n  from Lapp/D;->arr()V\n" not in out]), "[]")

    # ART checks the invoke kind against the class before it looks the method up: a missing method on
    # a type that turned into an interface (or a class) is an IncompatibleClassChangeError, which a
    # catch of NoSuchMethodError doesn't catch
    X, Y = "Landroid/view/X;", "Landroid/view/Y;"
    pw, aw = W(), W()
    pw.cls(OBJ, None); pw.cls("Ljava/lang/NoSuchMethodError;", OBJ)
    pw.cls(X, OBJ, flags=0x601, vm=[("other", "()V", 0x401, None)]); pw.cls(Y, OBJ)
    aw.cls("Lapp/A;", OBJ, vm=[("run", "()V", 1, [("try", [("m", X, "gone", "()V")], ["Ljava/lang/NoSuchMethodError;"], False)]),
                               ("run2", "()V", 1, [("mi", Y, "gone", "()V")])])
    check_lines("invoke kind checked before the method", scenario("kind", pw, aw),
                ["link-error Landroid/view/X;->gone()V on an interface, called with invoke-virtual", "  from Lapp/A;->run()V",
                 "link-error Landroid/view/Y;->gone()V on a class, called with invoke-interface", "  from Lapp/A;->run2()V"],
                ["missing-method Landroid/view/X;->gone()V", "missing-method Landroid/view/Y;->gone()V"])

    # An interface's static and private methods aren't inherited: not through a class that
    # implements it, nor through a subinterface (NoSuchMethodError). An interface reference finds
    # Object's public instance methods, its constructor too; another of Object's is an
    # IncompatibleClassChangeError (ART looks it up as a class method once the interface lookup fails)
    I, J, J2, P, PQ = "Landroid/os/I;", "Landroid/os/J;", "Landroid/os/J2;", "Landroid/os/P;", "Landroid/os/PQ;"
    pw, aw = W(), W()
    pw.cls(OBJ, None, dm=[("<init>", "()V", 0x10001, []), ("st", "()V", 9, [])],
           vm=[("clone", "()Ljava/lang/Object;", 0x104, []), ("hashCode", "()I", 1, [])])
    pw.cls(I, OBJ, flags=0x601, dm=[("of", "()V", 9, []), ("sm", "()V", 9, []), ("priv", "()V", 2, [])])
    pw.cls(J, OBJ, flags=0x601, vm=[("sm", "()V", 1, []), ("priv", "()V", 1, [])])
    pw.cls(J2, OBJ, [I], flags=0x601); pw.cls(P, OBJ, [I]); pw.cls(PQ, OBJ, [I, J])
    aw.cls("Lapp/C;", OBJ, [I])
    aw.cls("Lapp/St;", OBJ, vm=[("a", "()V", 1, [("ms", P, "of", "()V")]), ("b", "()V", 1, [("ms", "Lapp/C;", "of", "()V")]),
                                ("c", "()V", 1, [("ms", J2, "of", "()V")]), ("d", "()V", 1, [("ms", I, "of", "()V")]),
                                ("e", "()V", 1, [("m", PQ, "sm", "()V")]), ("f", "()V", 1, [("m", PQ, "priv", "()V")]),
                                ("g", "()V", 1, [("md", I, "<init>", "()V")]), ("h", "()V", 1, [("mi", I, "clone", "()Ljava/lang/Object;")]),
                                ("i", "()V", 1, [("mi", J2, "hashCode", "()I")]), ("j", "()V", 1, [("ms", I, "st", "()V")])])
    check_lines("interface statics aren't inherited", scenario("istatic", pw, aw),
                ["missing-method Landroid/os/P;->of()V", "  from Lapp/St;->a()V", "missing-method Lapp/C;->of()V",
                 "  from Lapp/St;->b()V", "missing-method Landroid/os/J2;->of()V", "  from Lapp/St;->c()V",
                 "link-error Landroid/os/I;->clone()Ljava/lang/Object; Object's, not public, called on an interface",
                 "  from Lapp/St;->h()V", "link-error Landroid/os/I;->st()V Object's, static, called on an interface",
                 "  from Lapp/St;->j()V"],
                ["  from Lapp/St;->d()V", "  from Lapp/St;->e()V", "  from Lapp/St;->f()V", "  from Lapp/St;->g()V",
                 "  from Lapp/St;->i()V", "missing-method Landroid/os/I;->clone()Ljava/lang/Object;"])

    # A method two superinterfaces declare resolves to the most general declaration (ART walks the
    # iftable, where each interface comes before those that extend it), and the class access check
    # is on that declarer: a package-private interface named by the reference matters only when it
    # is out of reach too (IllegalAccessError)
    HC, HJ, PUBI, HC2, PUBJ, HI = ("Landroid/os/%s;" % x for x in ("HC", "HJ", "PubI", "HC2", "PubJ", "HI"))
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(PUBI, OBJ, flags=0x601, vm=[("m", "()V", 0x401, None)]); pw.cls(HJ, OBJ, [PUBI], flags=0x600, vm=[("m", "()V", 0x401, None)])
    pw.cls(HC, OBJ, [HJ], flags=0x600)
    pw.cls(HI, OBJ, flags=0x600, vm=[("n", "()V", 0x401, None)]); pw.cls(PUBJ, OBJ, [HI], flags=0x601, vm=[("n", "()V", 0x401, None)])
    pw.cls(HC2, OBJ, [PUBJ], flags=0x600)
    aw.cls("Lapp/U;", OBJ, vm=[("a", "()V", 1, [("mi", HC, "m", "()V")]), ("b", "()V", 1, [("mi", HC2, "n", "()V")])])
    check_lines("superinterface declarer, most general first", scenario("iftable", pw, aw),
                ["link-error Landroid/os/HC2; package-private class", "  from Lapp/U;->b()V"],
                ["link-error Landroid/os/HC; package-private class", "  from Lapp/U;->a()V"])

    # A superclass's private method isn't inherited, nor a package-private one from another runtime
    # package: a reference through a class below it finds the interface default copied into that
    # class (ART's FindClassMethod), unless the private method's own class has the copy; the first
    # interface in the chain that declares it, an APK one here (invoke-direct is the APK's business
    # then). A concrete package-private one implements the interface's (the class can't link)
    (P, PI, ID, PP, PA, IU), IA = ("Landroid/os/%s;" % x for x in ("P", "PI", "ID", "PP", "PA", "IU")), "Lapp/IA;"
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(ID, OBJ, flags=0x601, vm=[("update", "()V", 1, [])]); pw.cls(IU, OBJ, flags=0x601, vm=[("update", "()V", 0x401, None)])
    pw.cls(P, OBJ, dm=[("update", "()V", 2, [])]); pw.cls(PI, OBJ, [ID], dm=[("update", "()V", 2, [])])
    pw.cls(PP, OBJ, vm=[("update", "()V", 0, [])]); pw.cls(PA, OBJ, flags=0x401, vm=[("update", "()V", 0x400, None)])
    aw.cls(IA, OBJ, flags=0x601, vm=[("update", "()V", 1, [])])
    aw.cls("Lapp/A;", P, [ID]); aw.cls("Lapp/A2;", P); aw.cls("Lapp/A3;", PI); aw.cls("Lapp/A4;", PP, [ID])
    aw.cls("Lapp/A5;", P, [IA, IU]); aw.cls("Lapp/A6;", PA, [ID])
    aw.cls("Lapp/B;", "Lapp/A;", vm=[("update", "()V", 1, [("msup", "Lapp/A;", "update", "()V")])])
    aw.cls("Lapp/Call;", OBJ, vm=[("a", "()V", 1, [("m", "Lapp/A;", "update", "()V")]), ("a2", "()V", 1, [("m", "Lapp/A2;", "update", "()V")]),
                                  ("a3", "()V", 1, [("m", "Lapp/A3;", "update", "()V")]), ("a4", "()V", 1, [("m", "Lapp/A4;", "update", "()V")]),
                                  ("a5", "()V", 1, [("md", "Lapp/A5;", "update", "()V"), ("m", "Lapp/A5;", "update", "()V")]),
                                  ("a6", "()V", 1, [("m", "Lapp/A6;", "update", "()V")])])
    check_lines("private superclass method and a copied default", scenario("uninherited", pw, aw),
                ["link-error Lapp/A2;->update()V private or a constructor, called with invoke-virtual", "  from Lapp/Call;->a2()V",
                 "link-error Lapp/A3;->update()V private or a constructor, called with invoke-virtual", "  from Lapp/Call;->a3()V",
                 "link-error Landroid/os/ID;->update()V implemented by a non-public method", "  in Lapp/A4;", "  from Lapp/Call;->a4()V"],
                ["  from Lapp/Call;->a()V", "  from Lapp/B;->update()V", "  from Lapp/Call;->a5()V", "  from Lapp/Call;->a6()V",
                 "link-error Lapp/A4;->update()V package-private"])

    # A platform interface that is a class now is no superclass of the APK classes that implement
    # it: a method lookup on them walks only their superclasses. One whose superclass isn't in the
    # jars keeps them from loading
    X, X2 = "Landroid/os/X;", "Landroid/os/X2;"
    pw, aw = W(), W()
    pw.cls(OBJ, None); pw.cls(X, "Landroid/os/GoneBase;", flags=0x401, vm=[("foo", "()V", 0, [])])
    pw.cls(X2, OBJ, flags=0x401, vm=[("foo", "()V", 0, [])])
    aw.cls("Lapp/A;", OBJ, [X], vm=[("foo", "()V", 1, [])]); aw.cls("Lapp/Base;", OBJ)
    aw.cls("Lapp/B;", "Lapp/Base;", [X]); aw.cls("Lapp/B2;", "Lapp/Base;", [X2])
    aw.cls("Lapp/Call;", OBJ, vm=[("run", "()V", 1, [("m", "Lapp/B;", "foo", "()V")]), ("run2", "()V", 1, [("m", "Lapp/B2;", "foo", "()V")])])
    check_lines("a class implemented as an interface", scenario("classiface", pw, aw),
                ["link-error Landroid/os/X; a class, implemented as an interface", "  interface of Lapp/A;", "  interface of Lapp/B;",
                 "missing-class Landroid/os/GoneBase; refs=1", "  from Lapp/Call;->run()V",
                 "link-error Landroid/os/X2; a class, implemented as an interface", "  interface of Lapp/B2;"],
                ["link-error Lapp/B;->foo()V package-private", "link-error Lapp/B2;->foo()V package-private"])

    # A platform abstract method an APK abstract class declares abstract again is still owed by
    # the concrete class below it; a concrete platform method the APK re-abstracts is its own business
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls("Landroid/os/C;", OBJ, flags=0x401, vm=[("m", "()V", 0x401, None)]); pw.cls("Landroid/os/C2;", OBJ, vm=[("m", "()V", 1, [])])
    aw.cls("Lapp/B;", "Landroid/os/C;", flags=0x401, vm=[("m", "()V", 0x401, None)]); aw.cls("Lapp/A;", "Lapp/B;")
    aw.cls("Lapp/B2;", "Landroid/os/C2;", flags=0x401, vm=[("m", "()V", 0x401, None)]); aw.cls("Lapp/A2;", "Lapp/B2;")
    check_lines("platform abstract method declared abstract again", scenario("reabs", pw, aw),
                ["unimplemented Landroid/os/C;->m()V", "  in Lapp/A;"],
                ["unimplemented Landroid/os/C2;->m()V", "  in Lapp/A2;"])

    # A non-public method that implements a platform interface's method (abstract or default) fails
    # the link of the class that takes the interface on, abstract or not; for an interface its
    # superclass already has, only the class's own methods count. So does a non-public platform
    # method that implements an APK interface's (View gains a protected foo()), and an APK one (Own)
    IF, ID, V, MI = "Landroid/view/IF;", "Landroid/view/ID;", "Landroid/view/V;", "Lapp/Mine;"
    pw, aw = W(), W()
    pw.cls(OBJ, None); pw.cls(V, OBJ, vm=[("foo", "()V", 4, [])])
    aw.cls(MI, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Mv;", V, [MI]); aw.cls("Lapp/Av;", V, [MI], flags=0x401); aw.cls("Lapp/Sv;", "Lapp/Av;", vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Own;", "Lapp/Bf;", [MI], flags=0x401)
    pw.cls(IF, OBJ, flags=0x601, vm=[("foo", "()V", 0x401, None)]); pw.cls(ID, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/B;", OBJ, [IF], flags=0x401, vm=[("foo", "()V", 4, [])]); aw.cls("Lapp/X;", "Lapp/B;", vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Bp;", OBJ, [IF], flags=0x401, vm=[("foo", "()V", 0, [])]); aw.cls("Lapp/Xp;", "Lapp/Bp;", vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Bd;", OBJ, [IF], flags=0x401, vm=[("foo", "()V", 4, [])]); aw.cls("Lapp/Xd;", "Lapp/Bd;")
    aw.cls("Lapp/Ce;", OBJ, [ID], vm=[("foo", "()V", 4, [])])
    aw.cls("Lapp/Bf;", OBJ, flags=0x401, vm=[("foo", "()V", 4, [])]); aw.cls("Lapp/Mf;", "Lapp/Bf;", [IF], flags=0x401)
    aw.cls("Lapp/Xf;", "Lapp/Mf;", vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Ok;", "Lapp/B;", [IF], vm=[("foo", "()V", 1, [])])   # takes IF on again, with a public foo: B still fails
    check_lines("non-public interface method implementations", scenario("nonpublic", pw, aw),
                ["link-error Landroid/view/IF;->foo()V implemented by a non-public method", "  in Lapp/B;", "  in Lapp/Bp;",
                 "  in Lapp/Bd;", "  in Lapp/Mf;", "link-error Landroid/view/ID;->foo()V implemented by a non-public method",
                 "  in Lapp/Ce;", "link-error Lapp/Mine;->foo()V implemented by a non-public method", "  in Lapp/Mv;", "  in Lapp/Av;",
                 "  in Lapp/Own;"],
                ["  in Lapp/X;", "  in Lapp/Xp;", "  in Lapp/Xd;", "  in Lapp/Xf;", "  in Lapp/Ok;", "  in Lapp/Bf;",
                 "unimplemented Landroid/view/IF;->foo()V", "  in Lapp/Sv;"])

    # Default methods as ART picks them: a subinterface's abstract redeclaration masks the default
    # (AbstractMethodError), two defaults neither of which overrides the other conflict
    # (IncompatibleClassChangeError when called: the class links, so a use of it is fine), a more specific default wins
    I, J, K, L, D1, D2, A = ("Landroid/os/%s;" % x for x in ("I", "J", "K", "L", "D1", "D2", "A"))
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(I, OBJ, flags=0x601, vm=[("m", "()V", 1, [])]); pw.cls(J, OBJ, [I], flags=0x601, vm=[("m", "()V", 0x401, None)])
    pw.cls(K, OBJ, [J], flags=0x601, vm=[("m", "()V", 1, [])]); pw.cls(L, OBJ, flags=0x601, vm=[("n", "()V", 0x401, None)])
    pw.cls(D1, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])]); pw.cls(D2, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])])
    pw.cls(A, OBJ, flags=0x601, vm=[("foo", "()V", 0x401, None)])
    aw.cls("Lapp/Mine;", OBJ, flags=0x601, vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/Mine2;", OBJ, [D1], flags=0x601, vm=[("foo", "()V", 1, [])])
    aw.cls("Lapp/C;", OBJ, [J]); aw.cls("Lapp/C2;", OBJ, [I, J]); aw.cls("Lapp/Ck;", OBJ, [K]); aw.cls("Lapp/Cl;", OBJ, [L])
    aw.cls("Lapp/S1;", OBJ, [D1, "Lapp/Mine;"]); aw.cls("Lapp/S3;", OBJ, [D1, D2])
    aw.cls("Lapp/Ok1;", OBJ, [D1, A]); aw.cls("Lapp/Ok2;", OBJ, [D1, "Lapp/Mine2;"])
    aw.cls("Lapp/U;", OBJ, vm=[("mk", "()V", 1, [("new", "Lapp/S1;"), ("new", "Lapp/S3;"), ("t", "Lapp/S3;")])])
    check_lines("default method selection", scenario("defaults", pw, aw),
                ["unimplemented Landroid/os/J;->m()V", "  in Lapp/C;", "  in Lapp/C2;",
                 "unimplemented Landroid/os/L;->n()V", "  in Lapp/Cl;",
                 "link-error Landroid/os/D1;->foo()V default conflicts with Lapp/Mine;", "  in Lapp/S1;",
                 "link-error Landroid/os/D1;->foo()V default conflicts with Landroid/os/D2;", "  in Lapp/S3;"],
                ["  in Lapp/Ck;", "  in Lapp/Ok1;", "  in Lapp/Ok2;", "unimplemented Landroid/os/A;->foo()V", "  from Lapp/U;->mk()V"])

    # An interface's superclass must be Object; one that is missing keeps the classes that implement
    # the interface from loading, so a use of them is listed under it and their defaults aren't
    # looked at. One that is the interface itself makes a broken chain that extends nothing
    I, J, K, I2 = "Landroid/os/I;", "Landroid/os/J;", "Landroid/os/K;", "Landroid/os/I2;"
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(I, "Landroid/os/Gone;", flags=0x601, vm=[("m", "()V", 1, [])]); pw.cls(J, OBJ, flags=0x601, vm=[("m", "()V", 0x401, None)])
    pw.cls(K, K, flags=0x601, vm=[("m", "()V", 1, [])]); pw.cls(I2, OBJ, flags=0x601, vm=[("m", "()V", 1, [])])
    aw.cls("Lapp/J;", "Lapp/Gone;", flags=0x601, vm=[("m", "()V", 1, [])])
    aw.cls("Lapp/C;", OBJ, [I, J]); aw.cls("Lapp/C2;", OBJ, ["Lapp/J;", I2]); aw.cls("Lapp/C3;", OBJ, [K, J])
    aw.cls("Lapp/Use;", OBJ, vm=[("run", "()V", 1, [("m", "Lapp/C2;", "m", "()V")])])
    check_lines("interfaces whose superclass is missing", scenario("ifacesup", pw, aw),
                ["missing-class Lapp/Gone; refs=2", "  super of Lapp/J;", "  from Lapp/Use;->run()V"],
                ["  in Lapp/C;", "  in Lapp/C2;", "  in Lapp/C3;"])

    # A use of an APK class that can't link, or of one below it, throws what kept it from linking (VerifyError for a final
    # superclass, IncompatibleClassChangeError, IllegalAccessError, LinkageError for a final override, public or protected),
    # whatever it uses on it (XF2 and XF3 below XF, XJ2 and XJ3 below an interface that can't; the superclass's error
    # first, then an interface's, then its own: XB, XOF), so it is listed under that link error, where only LinkageError's
    # handlers keep it: not a NoSuchMethodError's (nor an IncompatibleClassChangeError's), and one after a typed handler
    # can't be told (it may be of the error's own type, and throw it on: ifcfirst, gapfirst, nest). With a missing
    # interface too, a NoClassDefFoundError's doesn't (XG's superclass fails first, XD's interface J1 is on a cycle). A cycle
    # of supertypes across two dexes (superclasses A and B, interfaces J1 and J2, SI implementing itself, platform PA and
    # PB, met at PB from P0) is a ClassCircularityError: not missing, nor kept by a NoClassDefFoundError's handler (and A's
    # final fm() overrides nothing of its own). The code of a class that can't load has what it uses that can't link
    # listed (A's bad()), not its access errors (acc(), fin(), CJ's acc())
    LE, NCDFE, NSME, ICCE, THR = ("Ljava/lang/%s;" % x for x in ("LinkageError", "NoClassDefFoundError", "NoSuchMethodError",
                                                                 "IncompatibleClassChangeError", "Throwable"))
    FIN, IFC, OPEN, OPEN2, HID, KLS, HIDI, I2 = ("Landroid/os/%s;" % x for x in ("Fin", "Iface", "Open", "Open2", "Hid", "Klass",
                                                                                "HidI", "I2"))
    pw, a, b = W(), W(), W()
    pw.cls(OBJ, None); [pw.cls(e, OBJ) for e in (LE, NCDFE, NSME, ICCE, THR)]
    pw.cls(FIN, OBJ, flags=0x11); pw.cls(IFC, OBJ, flags=0x601); pw.cls(OPEN, OBJ, vm=[("done", "()V", 0x11, [])])
    pw.cls(OPEN2, OBJ, vm=[("done", "()V", 0x14, [])]); pw.cls(HID, OBJ, flags=0)
    pw.cls(KLS, OBJ, fields=[("f", "I", True, 0x8), ("F", "I", True, 0x19)]); pw.cls(HIDI, OBJ, flags=0x600)
    pw.cls(I2, OBJ, flags=0x601, vm=[("go", "()V", 0x401, None)])
    pw.cls("Landroid/os/PA;", "Landroid/os/PB;"); pw.cls("Landroid/os/PB;", "Landroid/os/PA;"); pw.cls("Landroid/os/P0;", "Landroid/os/PB;")
    a.cls("Lapp/XF;", FIN); a.cls("Lapp/XI;", IFC); a.cls("Lapp/XO;", OPEN, vm=[("done", "()V", 1, [])]); a.cls("Lapp/XH;", HID)
    a.cls("Lapp/XK;", OBJ, [KLS]); a.cls("Lapp/XJ;", OBJ, [HIDI]); a.cls("Lapp/XT;", OBJ, [I2], vm=[("go", "()V", 4, [])])
    a.cls("Lapp/XF2;", "Lapp/XF;", vm=[("ok", "()V", 1, [])]); a.cls("Lapp/XG;", "Lapp/XF;", ["Landroid/os/Gone;"])
    a.cls("Lapp/IJ;", OBJ, [HIDI], flags=0x601); a.cls("Lapp/XJ2;", OBJ, ["Lapp/IJ;"])
    a.cls("Lapp/XF3;", "Lapp/XF2;"); a.cls("Lapp/IJ2;", OBJ, ["Lapp/IJ;"], flags=0x601); a.cls("Lapp/XJ3;", OBJ, ["Lapp/IJ2;"])
    a.cls("Lapp/XB;", "Lapp/XF;", ["Lapp/IJ;"]); a.cls("Lapp/XOF;", "Lapp/XF;", [HIDI]); a.cls("Lapp/XP;", OPEN2, vm=[("done", "()V", 1, [])])
    a.cls("Lapp/A;", "Lapp/B;", dm=[("acc", "()V", 9, [("f", KLS, "f", "I")]), ("fin", "()V", 9, [("fput", KLS, "F", "I")]),
                                    ("bad", "()V", 9, [("ms", "Lapp/XF;", "gone", "()V")])], vm=[("fm", "()V", 0x11, [])])
    b.cls("Lapp/B;", "Lapp/A;"); a.cls("Lapp/A2;", "Lapp/A;")   # each dex's order is fine alone
    a.cls("Lapp/J1;", OBJ, ["Lapp/J2;"], flags=0x601); b.cls("Lapp/J2;", OBJ, ["Lapp/J1;"], flags=0x601)
    a.cls("Lapp/CJ;", OBJ, ["Lapp/J1;"], dm=[("acc", "()V", 9, [("f", KLS, "f", "I")])]); a.cls("Lapp/XD;", OBJ, ["Lapp/J1;", "Landroid/os/Gone;"])
    a.cls("Lapp/SI;", OBJ, ["Lapp/SI;"], flags=0x601)
    def kept(t, op): return [("try", [op], [t], False, [("raw", [0x010d])])]   # try { op } catch (t e) { }
    def first(t, op):   # try { op } catch (t e) { throw e; } catch (LinkageError e) { }
        u = []; a.emit([op], u, [])
        return [("raw", u + [0x000e, 0x010d, 0x0127, 0x010d]), ("tryat", 0, len(u), [t, LE], False, [len(u) + 1, len(u) + 3])]
    # try { try { XI.gone() } catch (LinkageError e) { throw e; } } catch (IncompatibleClassChangeError e) { throw e; }
    # catch (Throwable t) { }
    nest = [("raw", [0x0071, a.m("Lapp/XI;", "gone", "()V"), 0, 0x000e, 0x010d, 0x0127, 0x010d, 0x0127, 0x010d]),
            ("tryat", 0, 3, [LE], False, [4]), ("tryat", 5, 1, [ICCE, THR], False, [6, 8])]
    shapes = [("fin", NSME, ("ms", "Lapp/XF;", "gone", "()V")), ("ifc", NSME, ("ms", "Lapp/XI;", "gone", "()V")),
              ("ovr", ICCE, ("ms", "Lapp/XO;", "gone", "()V")), ("hid", NSME, ("ms", "Lapp/XH;", "gone", "()V")),
              ("kls", NSME, ("ms", "Lapp/XK;", "gone", "()V")), ("hidi", NSME, ("ms", "Lapp/XJ;", "gone", "()V")),
              ("impl", NSME, ("ms", "Lapp/XT;", "gone", "()V")), ("sub", NSME, ("m", "Lapp/XF2;", "ok", "()V")),
              ("ifsub", NSME, ("ms", "Lapp/XJ2;", "gone", "()V")), ("deep", NSME, ("ms", "Lapp/XF3;", "gone", "()V")),
              ("ideep", NSME, ("ms", "Lapp/XJ3;", "gone", "()V")), ("both", NSME, ("ms", "Lapp/XB;", "gone", "()V")),
              ("own", NSME, ("ms", "Lapp/XOF;", "gone", "()V")), ("ovrp", NSME, ("ms", "Lapp/XP;", "gone", "()V")),
              ("gap", NCDFE, ("t", "Lapp/XG;")), ("cyc", NCDFE, ("new", "Lapp/A;")), ("cycsub", NCDFE, ("new", "Lapp/A2;")),
              ("icyc", NSME, ("ms", "Lapp/CJ;", "gone", "()V")), ("self", NSME, ("ms", "Lapp/SI;", "gone", "()V")),
              ("cycgap", NCDFE, ("t", "Lapp/XD;")), ("pcyc", NSME, ("ms", "Landroid/os/PA;", "gone", "()V")),
              ("pcycsub", NSME, ("ms", "Landroid/os/P0;", "gone", "()V"))]
    a.cls("Lapp/C;", OBJ, dm=[(n + x, "()V", 9, kept(LE if x else t, op)) for n, t, op in shapes for x in ("", "le")] +
          [("ifcfirst", "()V", 9, first(ICCE, ("ms", "Lapp/XI;", "gone", "()V"))), ("gapfirst", "()V", 9, first(NCDFE, ("t", "Lapp/XG;"))),
           ("nest", "()V", 9, nest)])
    p = os.path.join(WORK, "cantlink-plat.dex"); open(p, "wb").write(pw.build())
    out = run([apk_of("cantlink.apk", [("classes.dex", a.build()), ("classes2.dex", b.build())]), p])
    def lines(*ns): return "".join("  from Lapp/C;->%s()V\n  from Lapp/C;->%sle()V [caught: %s]\n" % (n, n, LE) for n in ns)
    def maybe(n, t=LE): return "  from Lapp/C;->%s()V [caught?: %s]\n" % (n, t)
    check("uses of a class that can't link", out, "missing-class Landroid/os/Gone; refs=7\n" + lines("cycgap") +
          "  from Lapp/C;->gap()V\n" + maybe("gapfirst") + "  from Lapp/C;->gaple()V [caught: %s]\n" % LE +
          "  interface of Lapp/XD;\n  interface of Lapp/XG;\n" +
          "link-error Landroid/os/Fin; final, extended\n  from Lapp/A;->bad()V\n" + lines("both", "deep", "fin", "own", "sub") +
          "  super of Lapp/XF;\n"
          "link-error Landroid/os/Hid; package-private class, extended\n" + lines("hid") + "  super of Lapp/XH;\n"
          "link-error Landroid/os/HidI; package-private interface, implemented\n" + lines("hidi", "ideep", "ifsub") +
          "  interface of Lapp/IJ;\n  interface of Lapp/XJ;\n  interface of Lapp/XOF;\n"
          "link-error Landroid/os/I2;->go()V implemented by a non-public method\n" + lines("impl") + "  in Lapp/XT;\n"
          "link-error Landroid/os/Iface; an interface, extended as a class\n  from Lapp/C;->ifc()V\n" + maybe("ifcfirst") +
          "  from Lapp/C;->ifcle()V [caught: %s]\n" % LE + maybe("nest", THR) + "  super of Lapp/XI;\n"
          "link-error Landroid/os/Klass; a class, implemented as an interface\n" + lines("kls") + "  interface of Lapp/XK;\n"
          "link-error Landroid/os/Open2;->done()V final, overridden\n" + lines("ovrp") + "  in Lapp/XP;\n"
          "link-error Landroid/os/Open;->done()V final, overridden\n" + lines("ovr") + "  in Lapp/XO;\n"
          "link-error Landroid/os/PA; supertype cycle\n" + lines("pcyc", "pcycsub") +
          "link-error Lapp/A; supertype cycle\n" + lines("cyc", "cycsub") + "  in Lapp/A;\n  in Lapp/B;\n"
          "link-error Lapp/J1; supertype cycle\n" + lines("icyc") + "  in Lapp/J1;\n  in Lapp/J2;\n"
          "link-error Lapp/SI; supertype cycle\n" + lines("self") + "  in Lapp/SI;\n"
          "summary 1 missing classes, 0 methods, 0 fields, 12 link errors, 0 shadowed, 0 unimplemented; 0 missing or link-error "
          "entries caught everywhere; 17 platform classes from 1 files, 0 platform dexes unreadable; 56 APK methods read, 0 unreadable\n")
    # The same for an APK supertype (ART checks the APK's classes as it does the platform's): an APK final or interface
    # superclass, an APK class implemented as an interface, a package-private APK class or interface of another package
    # extended or implemented, an APK final method overridden (public, or package-private from its own package), an APK
    # interface's method implemented by a non-public one. Within its package, or a package-private final method of another
    # package, is fine (Ok, YQ)
    pw, a = W(), W()
    pw.cls(OBJ, None); [pw.cls(e, OBJ) for e in (LE, NSME)]
    a.cls("Lapp/F;", OBJ, flags=0x11); a.cls("Lapp/IY;", OBJ, flags=0x601); a.cls("Lapp/q/H;", OBJ, flags=0); a.cls("Lapp/q/HI;", OBJ, flags=0x600)
    a.cls("Lapp/O;", OBJ, vm=[("done", "()V", 0x11, []), ("pf", "()V", 0x10, [])]); a.cls("Lapp/q/P;", OBJ, vm=[("pf", "()V", 0x10, [])])
    a.cls("Lapp/IM;", OBJ, flags=0x601, vm=[("m", "()V", 0x401, None)])
    a.cls("Lapp/YF;", "Lapp/F;"); a.cls("Lapp/YI;", "Lapp/IY;"); a.cls("Lapp/YK;", OBJ, ["Lapp/F;"]); a.cls("Lapp/YH;", "Lapp/q/H;")
    a.cls("Lapp/YO;", "Lapp/O;", vm=[("done", "()V", 1, [])]); a.cls("Lapp/YP;", "Lapp/O;", vm=[("pf", "()V", 1, [])])
    a.cls("Lapp/YM;", OBJ, ["Lapp/IM;"], vm=[("m", "()V", 0, [])])
    a.cls("Lapp/YJ;", OBJ, ["Lapp/q/HI;"]); a.cls("Lapp/q/Ok;", "Lapp/q/H;", ["Lapp/q/HI;"]); a.cls("Lapp/YQ;", "Lapp/q/P;", vm=[("pf", "()V", 1, [])])
    shapes = [(n, NSME, ("ms", c, "gone", "()V")) for n, c in (
        ("yfin", "Lapp/YF;"), ("yifc", "Lapp/YI;"), ("ykls", "Lapp/YK;"), ("yhid", "Lapp/YH;"), ("yovr", "Lapp/YO;"),
        ("ypkg", "Lapp/YP;"), ("yimpl", "Lapp/YM;"), ("yhidi", "Lapp/YJ;"), ("ok", "Lapp/q/Ok;"), ("okq", "Lapp/YQ;"))]
    a.cls("Lapp/C;", OBJ, dm=[(n + x, "()V", 9, kept(LE if x else t, op)) for n, t, op in shapes for x in ("", "le")])
    def caught(n): return "  from Lapp/C;->%s()V [caught: %s]\n  from Lapp/C;->%sle()V [caught: %s]\n" % (n, NSME, n, LE)
    check("uses of an APK class that can't link for the APK's own reason", scenario("cantlinkapk", pw, a),
          "missing-method Lapp/YQ;->gone()V\n" + caught("okq") + "missing-method Lapp/q/Ok;->gone()V\n" + caught("ok") +
          "link-error Lapp/F; a class, implemented as an interface\n" + lines("ykls") + "  interface of Lapp/YK;\n"
          "link-error Lapp/F; final, extended\n" + lines("yfin") + "  super of Lapp/YF;\n"
          "link-error Lapp/IM;->m()V implemented by a non-public method\n" + lines("yimpl") + "  in Lapp/YM;\n"
          "link-error Lapp/IY; an interface, extended as a class\n" + lines("yifc") + "  super of Lapp/YI;\n"
          "link-error Lapp/O;->done()V final, overridden\n" + lines("yovr") + "  in Lapp/YO;\n"
          "link-error Lapp/O;->pf()V final, overridden\n" + lines("ypkg") + "  in Lapp/YP;\n"
          "link-error Lapp/q/H; package-private class, extended\n" + lines("yhid") + "  super of Lapp/YH;\n"
          "link-error Lapp/q/HI; package-private interface, implemented\n" + lines("yhidi") + "  interface of Lapp/YJ;\n"
          "summary 0 missing classes, 2 methods, 0 fields, 8 link errors, 0 shadowed, 0 unimplemented; 2 missing or link-error "
          "entries caught everywhere; 3 platform classes from 1 files, 0 platform dexes unreadable; 27 APK methods read, 0 unreadable\n")

    # invoke-super runs the caller's superclass's method (or the named interface's): abstract there,
    # AbstractMethodError, though a reference R8 rebound to the declaring class is fine when a class
    # between it and the caller implements the method
    P, P2, IB, IC = "Landroid/view/P;", "Landroid/view/P2;", "Landroid/view/IB;", "Landroid/view/IC;"
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    pw.cls(P, OBJ, flags=0x401, vm=[("onFoo", "()V", 0x401, None)]); pw.cls(P2, P, vm=[("onFoo", "()V", 1, [])])
    pw.cls(IB, OBJ, flags=0x601, vm=[("onBar", "()V", 0x401, None), ("onBaz", "()V", 1, [])])
    pw.cls(IC, OBJ, [IB], flags=0x601, vm=[("onBaz", "()V", 0x401, None)])
    aw.cls("Lapp/A;", P, [IB, IC], vm=[("onFoo", "()V", 1, [("msup", P, "onFoo", "()V")]), ("onBar", "()V", 1, [("msup", IB, "onBar", "()V")]),
                                       ("onBaz", "()V", 1, [("msup", IC, "onBaz", "()V")]), ("ok", "()V", 1, [("msup", IB, "onBaz", "()V")])])
    aw.cls("Lapp/A2;", P2, vm=[("onFoo", "()V", 1, [("msup", P, "onFoo", "()V")])])
    # Where it lands on defaults that conflict (a platform default added next to the APK's), the
    # conflict method there: IncompatibleClassChangeError, in whichever order the interfaces come
    D1, MI, MK = "Landroid/view/D1;", "Lapp/Mine;", "Lapp/MineK;"
    pw.cls(D1, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])])
    aw.cls(MI, OBJ, flags=0x601, vm=[("foo", "()V", 1, [])]); aw.cls(MK, OBJ, [D1, MI], flags=0x601)
    def sup(c): return [("foo", "()V", 1, [("msup", c, "foo", "()V")])]
    aw.cls("Lapp/B;", OBJ, [D1, MI], flags=0x401); aw.cls("Lapp/C;", "Lapp/B;", vm=sup("Lapp/B;"))
    aw.cls("Lapp/B2;", OBJ, [MI, D1], flags=0x401); aw.cls("Lapp/C2;", "Lapp/B2;", vm=sup("Lapp/B2;"))
    aw.cls("Lapp/Ck;", OBJ, [MK], vm=sup(MK))
    aw.cls("Lapp/B3;", OBJ, [D1], flags=0x401); aw.cls("Lapp/C3;", "Lapp/B3;", vm=sup("Lapp/B3;"))   # one default: fine
    check_lines("invoke-super of an abstract method", scenario("superabs", pw, aw),
                ["link-error Landroid/view/P;->onFoo()V abstract, called with invoke-super", "  from Lapp/A;->onFoo()V",
                 "link-error Landroid/view/IB;->onBar()V abstract, called with invoke-super", "  from Lapp/A;->onBar()V",
                 "link-error Landroid/view/IC;->onBaz()V abstract, called with invoke-super", "  from Lapp/A;->onBaz()V",
                 "link-error Landroid/view/D1;->foo()V default conflicts with Lapp/Mine;, called with invoke-super",
                 "  from Lapp/C;->foo()V", "  from Lapp/C2;->foo()V", "  from Lapp/Ck;->foo()V"],
                ["  from Lapp/A2;->onFoo()V", "  from Lapp/A;->ok()V", "  from Lapp/C3;->foo()V"])
    # ART checks access first (new-instance's class before whether it can be instantiated, a method before
    # its kind or where invoke-super lands): a use that fails it too throws IllegalAccessError, which a
    # handler of the error it is listed under (also, or only) doesn't keep. And each other kind of use
    # (Lapp/K;) throws its own error, which a handler of another one (an IllegalAccessError's that throws it
    # on, before an IncompatibleClassChangeError's) doesn't keep
    IE, AME, IAE, ICCE, NSME, NCDFE = ("Ljava/lang/%s;" % x for x in ("InstantiationError", "AbstractMethodError", "IllegalAccessError",
                                                                       "IncompatibleClassChangeError", "NoSuchMethodError",
                                                                       "NoClassDefFoundError"))
    AH, AP, PB, HC = "Landroid/os/AbsHidden;", "Landroid/os/AbsPub;", "Landroid/os/PubBase;", "Landroid/os/HidCls;"
    CL, IN, DA, DB, DJ = ("Landroid/os/%s;" % x for x in ("Cl", "In", "DA", "DB", "DJ"))
    pw, aw = W(), W()
    pw.cls(OBJ, None, vm=[("clone", "()" + OBJ, 0x104, [])]); [pw.cls(e, OBJ) for e in (IE, AME, IAE, ICCE, NSME)]
    pw.cls(AH, OBJ, flags=0x400); pw.cls(AP, OBJ, flags=0x401)                     # abstract: package-private, public
    pw.cls(PB, OBJ, flags=0x401, dm=[("hid", "()V", 8, []), ("st", "()V", 9, [])],   # static: package-private, public
           vm=[("hook", "()V", 0x400, None), ("pub", "()V", 0x401, None)])           # abstract: package-private, public
    pw.cls(HC, OBJ, flags=0, dm=[("st", "()V", 9, [])])                              # public static, of a package-private class
    pw.cls(CL, OBJ, fields=[("inf", "I", False), ("CONST", "I", True, 0x19)], dm=[("priv", "()V", 0xa, [])], vm=[("m", "()V", 1, [])])
    pw.cls(IN, OBJ, flags=0x601, vm=[("m", "()V", 0x401, None)])
    pw.cls(DA, OBJ, flags=0x601, vm=[("d", "()V", 1, [])]); pw.cls(DB, OBJ, flags=0x601, vm=[("d", "()V", 1, [])])
    pw.cls(DJ, OBJ, [DA, DB], flags=0x601)
    def kept(t, op): return [("try", [op], [t], False, [("raw", [0x010d])])]         # try { op } catch (t e) { }
    def iae(op):   # try { op } catch (IllegalAccessError e) { throw e; } catch (IncompatibleClassChangeError e) { }
        u = []; aw.emit([op], u, [])
        return [("raw", u + [0x000e, 0x010d, 0x0127, 0x010d]), ("tryat", 0, len(u), [IAE, ICCE], False, [len(u) + 1, len(u) + 3])]
    def iv(c, m): return ("m", c, m, "()V")                                           # invoke-virtual c.m()
    aw.cls("Lapp/A;", OBJ, dm=[("make", "()V", 9, kept(IE, ("new", AH))), ("make2", "()V", 9, kept(IE, ("new", AP))),
                               ("hid", "()V", 9, iae(iv(PB, "hid"))), ("st", "()V", 9, iae(iv(PB, "st"))),
                               ("hidst", "()V", 9, iae(iv(HC, "st")))])
    aw.cls("Lapp/Sub;", PB, flags=0x401, vm=[("hook", "()V", 1, kept(AME, ("msup", PB, "hook", "()V"))),
                                             ("pub", "()V", 1, kept(AME, ("msup", PB, "pub", "()V")))])
    aw.cls("Lapp/K;", OBJ, [DJ], vm=[
        ("k1", "()V", 1, kept(ICCE, ("ms", "Landroid/os/Gone;", "x", "()V"))),   # NoClassDefFoundError
        ("k19", "()V", 1, kept(NCDFE, ("ms", "Landroid/os/Gone;", "x", "()V"))),  # ... which its own handler keeps
        ("k2", "()V", 1, iae(("t", HC))),                                         # const-class of a package-private class: IAE
        ("k5", "()V", 1, kept(IAE, ("mi", CL, "m", "()V"))),                      # invoke-interface on a class: ICCE
        ("k7", "()V", 1, kept(IAE, ("mi", IN, "clone", "()" + OBJ))),             # Object's protected clone() on an interface: ICCE
        ("k10", "()V", 1, kept(IAE, ("msup", DJ, "d", "()V"))),                   # invoke-super of conflicting defaults: ICCE
        ("k14", "()V", 1, kept(NSME, ("f", CL, "gone", "I"))),                    # NoSuchFieldError
        ("k15", "()V", 1, kept(IAE, ("f", CL, "inf", "I"))),                      # sget of an instance field: ICCE
        ("k16", "()V", 1, iae(("fput", CL, "CONST", "I"))),                       # sput of a final field: IAE
        ("k17", "()V", 1, iae(("ms", HC, "st", "()V"))),                          # a member of a package-private class: IAE
        ("k18", "()V", 1, iae(("ms", CL, "priv", "()V")))])                       # a private method: IAE
    out = scenario("accessfirst", pw, aw)
    check_lines("access checked first", out,
                ["link-error Landroid/os/AbsHidden; new-instance of an abstract class", "  from Lapp/A;->make()V",
                 "link-error Landroid/os/AbsPub; new-instance of an abstract class", "  from Lapp/A;->make2()V [caught: %s]" % IE,
                 "link-error Landroid/os/PubBase;->hook()V abstract, called with invoke-super", "  from Lapp/Sub;->hook()V",
                 "link-error Landroid/os/PubBase;->pub()V abstract, called with invoke-super", "  from Lapp/Sub;->pub()V [caught: %s]" % AME,
                 "link-error Landroid/os/PubBase;->hid()V static, called with invoke-virtual", "  from Lapp/A;->hid()V",
                 "link-error Landroid/os/PubBase;->st()V static, called with invoke-virtual", "  from Lapp/A;->st()V [caught: %s]" % ICCE,
                 "link-error Landroid/os/HidCls;->st()V static, called with invoke-virtual", "  from Lapp/A;->hidst()V"],
                ["  from Lapp/A;->make()V [caught: %s]" % IE, "  from Lapp/Sub;->hook()V [caught: %s]" % AME,
                 "  from Lapp/A;->hid()V [caught: %s]" % ICCE, "  from Lapp/A;->hidst()V [caught: %s]" % ICCE])
    check("each kind of use's own error", str([e for e in (
        "missing-class Landroid/os/Gone; refs=2\n  from Lapp/K;->k1()V\n  from Lapp/K;->k19()V [caught: %s]" % NCDFE,
        "missing-field Landroid/os/Cl;->gone:I\n  from Lapp/K;->k14()V",
        "link-error Landroid/os/HidCls; package-private class\n  from Lapp/K;->k17()V\n  from Lapp/K;->k2()V",
        "link-error Landroid/os/DA;->d()V default conflicts with Landroid/os/DB;, called with invoke-super\n  from Lapp/K;->k10()V",
        "link-error Landroid/os/Cl;->CONST:I final, written by sput\n  from Lapp/K;->k16()V",
        "link-error Landroid/os/Cl;->inf:I an instance field, used by sget\n  from Lapp/K;->k15()V",
        "link-error Landroid/os/Cl;->m()V on a class, called with invoke-interface\n  from Lapp/K;->k5()V",
        "link-error Landroid/os/Cl;->priv()V private\n  from Lapp/K;->k18()V",
        "link-error Landroid/os/In;->clone()Ljava/lang/Object; Object's, not public, called on an interface\n  from Lapp/K;->k7()V")
        if e + "\n" not in out]), "[]")
    check("access checked first, caught everywhere", str("; 3 missing or link-error entries caught everywhere;" in out), "True")

    # A handler that passes the error on (finally, synchronized: move-exception, cleanup, throw)
    # doesn't catch it; the try block around its throw might (around a copy of it too; around
    # another exception, only a handler that catches anything). One whose paths only sometimes
    # rethrow is [caught?: ...] and doesn't count as caught; which handlers catch it is settled
    # path by path. A handler that goes back to the method's own code keeps it unless that code
    # throws a register still holding it (one written since holds something else, whatever else
    # that code throws is its own); one whose walk runs long or can't be followed can't be told
    pw, aw = W(), W()
    THR, LE, NSFE, RTE = "Ljava/lang/Throwable;", "Ljava/lang/LinkageError;", "Ljava/lang/NoSuchFieldError;", "Ljava/lang/RuntimeException;"
    MH, ERR = "Ljava/lang/invoke/MethodHandle;", "Ljava/lang/Error;"
    pw.cls(OBJ, None); [pw.cls(e, OBJ, dm=[("<init>", "()V", 0x10001, [])]) for e in (THR, LE, NSFE, RTE, IAE, ERR)]
    pw.cls(MH, OBJ, vm=[("invoke", "([%s)%s" % (OBJ, OBJ), 0x181, None)])
    L, mv, thr, ret = "Lapp/L;", ("raw", [0x010d]), ("raw", [0x0127]), ("raw", [0x000e])   # move-exception v1, throw v1, return-void
    take, now, hand = aw.m(L, "take", "(J)V"), aw.m(L, "now", "()J"), aw.m(L, "hand", "(%s)V" % THR)
    def gone(i): return [("ms", "Landroid/os/M%d;" % i, "x", "()V")]
    cleanup, copy = ("ms", L, "cleanup", "()V"), ("raw", [0x1207, 0x0227])   # move-object v2, v1; throw v2
    def outer(t, inner): return ("try", [inner], t, not t, [("raw", [0x030d]), ret])   # move-exception v3; return-void
    def okio(i, n, eqz):   # Okio's use {}: v1 = null; try { gone } catch (t) { v1 = t }; if (v1 != null) throw v1; n cleanups
        tail = [("raw", [0x0138, 3, 0x0127])] + [cleanup] * n if eqz else \
            [("raw", [0x0139, 3 + 3 * n])] + [cleanup] * n + [("raw", [0x000e, 0x0127])]
        return [("raw", [0x0112]), ("try", gone(i), [], True, [mv])] + tail
    aw.cls("Lapp/L2;", OBJ, vm=[
        ("later", "(Ljava/lang/Object;)V", 1, [("try", gone(11), [THR], False, [mv, cleanup]),   # catch (Throwable t) { cleanup(); }
                                               ("raw", [0x0339, 5]), ("new", THR), ("raw", [0x0027])]),   # if (arg == null) throw ...
        ("later0", "(Ljava/lang/Object;)V", 1, [("try", gone(27), [THR], False, [("raw", [0x000d]), cleanup]),   # the same, the new
                                                ("raw", [0x0339, 5]), ("new", THR), ("raw", [0x0027])]),   # Throwable in v0 too
        # later's with v1 handed on before the try (hand(null)): v1 is followed into the code the handler
        # rejoins, where the new Throwable from v0 is the method's own
        ("laterlog", "(Ljava/lang/Object;)V", 1, [("raw", [0x0112, 0x1071, hand, 0x0001]), ("try", gone(83), [THR], False, [mv, cleanup]),
                                                  ("raw", [0x0339, 5]), ("new", THR), ("raw", [0x0027])]),
        # then 600 cleanups: v1 is never thrown, handed on or copied, so it goes nowhere (or it is written
        # over); one the method throws somewhere, if not on the way, is followed, so that walk reaches its limit
        ("long", "()V", 1, [("try", gone(12), [THR], False, [mv, cleanup])] + [cleanup] * 600),
        ("longdrop", "()V", 1, [("try", gone(45), [THR], False, [mv, ("raw", [0x0112]), cleanup])] + [cleanup] * 600),   # const/4 v1, 0
        ("longheld", "()V", 1, [("try", gone(80), [THR], False, [mv, cleanup])] + [cleanup] * 600 + [ret, thr]),
        # unless that code throws it after all (if-eqz v1: return, else throw v1), with 600 instructions
        # down the other branch too (the walk reaches its limit whichever branch it takes first)
        ("later2", "()V", 1, [("try", gone(22), [], True, [mv]), ("raw", [0x0138, 3, 0x0127])]),
        ("eqz", "()V", 1, okio(41, 600, True)), ("nez", "()V", 1, okio(42, 600, False)),
        # a register written since holds something else (move-object v1, v2: what it caught is dropped; a
        # long written to v0 writes v1 too, so {v0, v1} hands no reference on); check-cast leaves it as it was
        ("dropped", "()V", 1, [("raw", [0x0212]), ("try", gone(28) + [("raw", [0x0112])], [], True, [("raw", [0x010d, 0x2107])]),
                               ("raw", [0x0138, 3, 0x0127])]),
        ("cast", "()V", 1, [("raw", [0x0112]), ("try", gone(29), [], True, [mv]), ("raw", [0x011f, aw.t(THR), 0x0127])]),
        ("wide", "()V", 1, [("try", gone(46), [], True, [mv]), ("raw", [0x0016, 5, 0x2071, take, 0x0010])]),   # const-wide/16 v0; {v0, v1}
        ("result", "()V", 1, [("try", gone(47), [], True, [mv]), ("raw", [0x0071, now, 0, 0x000b, 0x2071, take, 0x0010])]),   # move-result-wide v0
        ("widerange", "()V", 1, [("try", gone(48), [], True, [mv]), ("raw", [0x0016, 5, 0x0277, take, 0x0000])]),   # {v0 .. v1}
        ("high", "()V", 1, [("try", gone(84), [], True, [("raw", [0x140d])]), ("raw", [0x1427])]),   # move-exception v20; throw v20
        # a handler that jumps into a payload (goto +2: past the return, to a fill-array-data), or
        # runs an unused opcode (what it writes isn't known)
        ("lost", "()V", 1, [("try", gone(43), [], True, [mv, ("raw", [0x0228])]), ("raw", [0x000e, 0x0300, 1, 0, 0])]),
        ("unused", "()V", 1, [("try", gone(44), [], True, [mv, ("raw", [0x003e])])]),
        ("unused2", "()V", 1, [("try", gone(81), [], True, [mv]), ("raw", [0x013e])]),   # in its own code, naming v1
        ("nsfe", "()V", 1, [("try", gone(13), [], True, [mv, ("try", [thr], [NSFE], False, [ret])])]),
        ("mixed", "()V", 1, [("try", gone(14), [], True, [mv, ("raw", [0x0038, 3]), ("raw", [0x0227]),   # if-eqz v0: rethrow, else throw v2
                                                           ("try", [thr], [NSFE], False, [ret])])]),
        ("two", "()V", 1, [("try", gone(15), [], True, [mv, ("raw", [0x0038, 5]), ("try", [thr], [THR], False, [ret]),
                                                         ("try", [thr], [LE], False, [ret])])]),
        ("copy", "()V", 1, [outer([], ("try", gone(16), [], True, [mv, copy]))]),
        ("copy2", "()V", 1, [outer([LE], ("try", gone(17), [], True, [mv, copy]))]),
        ("wrapin", "()V", 1, [outer([], ("try", gone(18), [], True, [mv, ("new", THR), ("raw", [0x0227])]))]),
        ("wrapin2", "()V", 1, [outer([LE], ("try", gone(19), [], True, [mv, ("new", THR), ("raw", [0x0227])]))]),
        # later's, reached through a switch case (packed-switch v0 at 0; its payload at 18, one target: 4)
        ("sw", "()V", 1, [("raw", [0x002b, 18, 0, 0x000e]), ("try", gone(20), [THR], False, [mv, cleanup]),
                          ("raw", [0x0339, 5]), ("new", THR), ("raw", [0x0027, 0x000e, 0x0100, 1, 0, 0, 4, 0])]),
        # a switch in the handler, each way returning (packed-switch v0 at 5; payload at 10, one target: 9)
        ("swh", "()V", 1, [("try", gone(21), [], True, [mv, ("raw", [0x002b, 5, 0, 0x000e, 0x000e, 0x0100, 1, 0, 0, 4, 0])])]),
        # or the second of two cases throwing it (switch v0 at 5: default 8, cases 9 return, 10 throw v1; payload at 12)
        ("swsparse", "()V", 1, gone(85) + [("raw", [0x000e, 0x010d, 0x002c, 7, 0, 0x000e, 0x000e, 0x0127, 0x0000,
                                                    0x0200, 2, 1, 0, 2, 0, 4, 0, 5, 0]), ("tryat", 0, 3, [], True, 4)]),   # keys 1, 2
        ("swpacked", "()V", 1, gone(86) + [("raw", [0x000e, 0x010d, 0x002b, 7, 0, 0x000e, 0x000e, 0x0127, 0x0000,
                                                    0x0100, 2, 1, 0, 4, 0, 5, 0]), ("tryat", 0, 3, [], True, 4)]),
        # a handler whose code can't be followed another way: a switch whose payload offset names no payload (packed-switch
        # v0: a return-void), or whose payload's 5 targets run past the end, a goto past the end, an instruction cut off by
        # it (const v0, 3 units: 2 left; that method is unreadable too)
        ("badsw", "()V", 1, [("try", gone(88), [], True, [mv, ("raw", [0x002b, 3, 0, 0x000e])])]),
        ("swend", "()V", 1, [("try", gone(89), [], True, [mv, ("raw", [0x002b, 3, 0, 0x0100, 5, 0, 0])])]),
        ("offend", "()V", 1, [("try", gone(90), [], True, [mv, ("raw", [0x0029, 100])])]),   # goto/16 +100
        ("cutoff", "()V", 1, [("try", gone(91), [], True, [mv, ("raw", [0x0014])])])])
    aw.cls(L, OBJ, dm=[("cleanup", "()V", 9, []), ("take", "(J)V", 9, []), ("now", "()J", 9, []), ("hand", "(%s)V" % THR, 9, [])], vm=[
        ("sync", "()V", 1, [("try", gone(1), [], True, [mv, ("raw", [0x001e]), thr])]),             # monitor-exit v0
        ("fin", "()V", 1, [("try", gone(2), [], True, [mv, ("ms", L, "cleanup", "()V"), thr])]),
        ("swallow", "()V", 1, [("try", gone(3), [], True, [mv, ret])]),
        ("thr", "()V", 1, [("try", gone(4), ["Ljava/lang/Throwable;"], False, [mv, thr])]),
        ("nested", "()V", 1, [("try", gone(5), [], True, [mv, ("try", [thr], [], True, [("raw", [0x020d]), ret])])]),
        ("maybe", "()V", 1, [("try", gone(6), [], True, [mv, ("raw", [0x0038, 3]), thr, ret])]),   # if-eqz v0: return, else throw
        ("branch", "()V", 1, [("try", gone(7), [], True, [mv, ("raw", [0x0038, 5]), ("ms", L, "cleanup", "()V"), thr])]),
        ("cycle", "()V", 1, [("try", gone(8), [], True, [mv, ("raw", [0x001e]), thr], True)]),
        ("wrap", "()V", 1, [("try", gone(9), [], True, [mv, ("new", "Ljava/lang/Throwable;"), ("raw", [0x0227])])])])   # throw v2
    # A path that passes it on other than by a throw can't be told: as a call's argument (Kotlin's
    # runCatching { }.getOrThrow(), as kotlinc emits it and with R8's inlining: wrapped in a
    # Result$Failure, thrown back from its field), into a field, an array or a new array, as a
    # return value; a copy of it too, in the handler or in the code it rejoins. Another register is fine
    RK, RF, L4 = "Lkotlin/ResultKt;", "Lkotlin/Result$Failure;", "Lapp/L4;"
    mcf, mtof = aw.m(RK, "createFailure", "(%s)%s" % (THR, OBJ)), aw.m(RK, "throwOnFailure", "(%s)V" % OBJ)
    minit, mlog, tRF, fEx = aw.m(RF, "<init>", "(%s)V" % THR), aw.m(L4, "log", "(%s)V" % THR), aw.t(RF), aw.f(RF, "exception", THR)
    log5, minv, pT = aw.m(L4, "log5", "(%s%s)V" % (OBJ * 4, THR)), aw.m(MH, "invoke", "([%s)%s" % (OBJ, OBJ)), aw.p("(%s)V" % THR)
    aw.s("go"); site = aw._ix(aw.sites, (aw.h(4, (L4, "log", "(%s)V" % THR)), "go", "(%s)V" % THR))
    aw.cls(RK, OBJ, dm=[("createFailure", "(%s)%s" % (THR, OBJ), 9, []), ("throwOnFailure", "(%s)V" % OBJ, 9, [])])
    aw.cls(RF, OBJ, fields=[("exception", THR, False)], dm=[("<init>", "(%s)V" % THR, 0x10001, [])])
    passes = [   # (name, the handler after move-exception v1, the code it rejoins)
        ("kotlinc", [0x1071, mcf, 0x0001, 0x000c], [0x1071, mtof, 0x0000]),   # invoke-static {v1}; move-result-object v0 / invoke-static {v0}
        ("r8", [0x0022, tRF, 0x2070, minit, 0x0010],                          # new-instance v0; invoke-direct {v0, v1} / if (v0 instanceof
         [0x0220, tRF, 0x0238, 7, 0x001f, tRF, 0x0054, fEx, 0x0027]),         # Result$Failure) throw v0.exception
        ("own", [], [0x1071, mlog, 0x0001]), ("copy", [0x1207, 0x1071, mlog, 0x0002], []),   # invoke-static {v1}; move-object v2, v1, {v2}
        ("range", [0x0177, mlog, 0x0001], []), ("field", [0x215b, aw.f(L4, "err", THR)], []),   # invoke-static/range {v1}; iput-object v1, v2
        ("static", [0x0169, aw.f(L4, "last", THR)], []), ("array", [0x014d, 0x0302], []),      # sput-object v1; aput-object v1, v2, v3
        ("newarray", [0x1024, aw.t("[" + THR), 0x0001], []), ("ret", [0x0111], []),            # filled-new-array {v1}; return-object v1
        ("newarrayrange", [0x0125, aw.t("[" + THR), 0x0001], []),                                 # filled-new-array/range {v1}
        ("five", [0x5171, log5, 0x0000], []), ("poly", [0x20fa, minv, 0x0010, pT], []),         # {v0, v0, v0, v0, v1}; invoke-polymorphic {v0, v1}
        ("custom", [0x10fc, site, 0x0001], []), ("polyrange", [0x02fb, minv, 0x0000, pT], []),   # invoke-custom {v1}; invoke-polymorphic/range {v0 .. v1}
        ("customrange", [0x01fd, site, 0x0001], []),                                              # invoke-custom/range {v1}
        ("from16", [0x1408, 0x0001, 0x0177, mlog, 0x0014], []),                                   # move-object/from16 v20, v1; invoke-static/range {v20}
        # each other invoke (log.warn(msg, e) through a class or an interface, e.printStackTrace()), each /range form: (the
        # tool reads only the registers) invoke-virtual {v2, v1}, invoke-super {v0, v1}, invoke-interface {v2, v1}, {v0 .. v1}
        ("virtual", [0x206e, mlog, 0x0012], []), ("super", [0x206f, mlog, 0x0010], []), ("interface", [0x2072, mlog, 0x0012], []),
        ("virtualrange", [0x0274, mlog, 0x0000], []), ("superrange", [0x0275, mlog, 0x0000], []),
        ("directrange", [0x0276, mlog, 0x0000], []), ("interfacerange", [0x0278, mlog, 0x0000], [])]
    rethrows = [("from16throw", [0x0208, 0x0001], [0x0227]),                # Okio's through a copy (untagged): move-object/from16 v2, v1 / throw v2;
                ("m16throw", [0x0009, 300, 1], [0x0009, 2, 300, 0x0227]),   # move-object/16 v300, v1 / move-object/16 v2, v300; throw v2;
                ("srccopy", [0x1207], [0x0127]),                            # the copy's source still holds it: move-object v2, v1 / throw v1;
                ("widebelow", [], [0x0216, 5, 0x0127])]                     # a wide write drops its pair only: const-wide/16 v2, 5; throw v1
    aw.cls(L4, OBJ, fields=[("err", THR, False), ("last", THR, True)], dm=[("log", "(%s)V" % THR, 9, []), ("log5", "(%s%s)V" % (OBJ * 4, THR), 9, [])],
           vm=[(n, "()" + (OBJ if n == "ret" else "V"), 1, [("try", gone(100 + i), [], True, [mv, ("raw", h)]), ("raw", o)])
               for i, (n, h, o) in enumerate(passes + rethrows)]
           + [("other", "()V", 1, [("try", gone(40), [], True, [mv, ("raw", [0x1071, mlog, 0x0002])])])])   # invoke-static {v2}
    # The same with it in a register past a field's low bits: v9 in a call's or an iput's nibble, v20 in a vAA (sput, aput,
    # return), a move to v9 in the code it rejoins (Okio's), copies from v9 and v300; a copy writes only its vA
    L12 = "Lapp/L12;"
    highs = [   # (name, code before the try, the handler, the code it rejoins)
        ("call9", [], [0x090d, 0x1071, mlog, 0x0009], []),                       # move-exception v9; invoke-static {v9}
        ("iput9", [], [0x090d, 0x295b, aw.f(L4, "err", THR)], []),               # iput-object v9, v2
        ("sput20", [], [0x140d, 0x1469, aw.f(L4, "last", THR)], []),             # move-exception v20; sput-object v20
        ("aput20", [], [0x140d, 0x144d, 0x0302], []), ("ret20", [], [0x140d, 0x1411], []),   # aput-object v20, v2, v3; return-object v20
        ("okio9", [0x0112], [0x010d], [0x2901, 0x0138, 3, 0x0127]),              # v1 = null; .. v1 = t / move v9, v2; if (v1 != null) throw v1
        ("copy9", [0x0212], [0x090d, 0x9207], [0x0238, 3, 0x0227]),              # v2 = null; .. v9 = t; v2 = v9 / if (v2 != null) throw v2
        ("copy300", [0x0212], [0x010d, 0x0009, 300, 1, 0x0208, 300], [0x0238, 3, 0x0227]),   # v300 = v1 (/16); v2 = v300 (/from16)
        ("copies", [0x0312], [0x010d, 0x1307, 0x1207], [0x0338, 3, 0x0327])]    # v3 = null; .. v3 = v1; v2 = v1 / if (v3 != null) throw v3
    aw.cls(L12, OBJ, vm=[(n, "()" + (THR if n == "ret20" else "V"), 1, [("raw", b), ("try", gone(140 + i), [], True, [("raw", h)]), ("raw", o)])
                         for i, (n, b, h, o) in enumerate(highs)])
    # While a register holds it, what an instruction in a try block throws carries it into that try's
    # handlers: a catch in the handler that throws it, a later try in the method's own code whose handler
    # throws it (saved before, or not written over when the call throws), a retry that throws the first
    # error on the way round; a plain catch inside a synchronized block still keeps it. Another exception
    # the handler throws, with a typed handler before the handler of anything: that one might catch it
    # first and throw it (or the error) on
    L6 = "Lapp/L6;"
    mc6, mcomp, tR, iR, tT, iT = (aw.m(L6, "cleanup", "()V"), aw.m(L6, "compute", "()" + THR), aw.t(RTE), aw.m(RTE, "<init>", "()V"),
                                  aw.t(THR), aw.m(THR, "<init>", "()V"))
    def gm(i, n="x"): return aw.m("Landroid/os/M%d;" % i, n, "()V")
    def at(*a): return ("tryat",) + a
    l6 = [   # (name, code, its tries)
        # catch (e) { try { cleanup(); } catch (x) { throw e; } }
        ("nestedthrow", [0x0071, gm(50), 0, 0x000e, 0x010d, 0x0071, mc6, 0, 0x000e, 0x020d, 0x0127], [at(0, 3, [], True, 4), at(5, 3, [], True, 9)]),
        # err = null; try { M51.x(); } catch (t) { err = t; } try { M52.y(); } catch (t2) { if (err != null) throw err; throw t2; }
        ("savedthen", [0x0012, 0x0071, gm(51), 0, 0x0071, gm(52, "y"), 0, 0x000e, 0x010d, 0x1007, 0xfa28, 0x020d, 0x0038, 3, 0x0027, 0x0227],
         [at(1, 3, [], True, 8), at(4, 3, [], True, 11)]),
        # saved = null; L1: if (saved != null) throw saved; L4: try { M53.x(); } catch (e) { if (saved != null) goto L1 + 2; saved = e; goto L4; }
        ("retry", [0x0212, 0x0238, 3, 0x0227, 0x0071, gm(53), 0, 0x000e, 0x010d, 0x0239, 4, 0x1207, 0xf828, 0xf628], [at(4, 3, [], True, 8)]),
        # synchronized (v0) { try { M54.x(); } catch (Throwable t) { cleanup(); } }
        ("syncplain", [0x001d, 0x0071, gm(54), 0, 0x001e, 0x000e, 0x010d, 0x0071, mc6, 0, 0xfa28, 0x020d, 0x001e, 0x0227],
         [at(1, 3, [THR], True, 6), at(4, 1, [], True, 11), at(6, 5, [], True, 11), at(11, 2, [], True, 11)]),
        # err = null; try { M55.x(); } catch (t) { err = t; } try { err = compute(); } catch (x) { } if (err != null) throw err;
        ("exc", [0x0212, 0x0071, gm(55), 0, 0x0228, 0x020d, 0x0071, mcomp, 0, 0x020c, 0x0238, 3, 0x0227, 0x000e, 0xfc28],
         [at(1, 3, [], True, 5), at(6, 3, [], True, 14)]),
        # the same with try { cleanup(); } catch (x) { goto check; } err = null; check: if (err != null) throw err;
        ("exc2", [0x0212, 0x0071, gm(56), 0, 0x0228, 0x020d, 0x0071, mc6, 0, 0x0212, 0x0238, 3, 0x0227, 0x000e, 0xfc28],
         [at(1, 3, [], True, 5), at(6, 3, [], True, 14)]),
        # try { try { M57.x(); } catch (e) { throw new RuntimeException(); } } catch (RuntimeException r) { throw r; } catch (t) { }
        ("wraprte", [0x0071, gm(57), 0, 0x000e, 0x010d, 0x0222, tR, 0x1070, iR, 0x0002, 0x0227, 0x000d, 0x0027, 0x000d, 0x000e],
         [at(0, 3, [], True, 4), at(5, 6, [RTE], True, [11, 13])]),
        # the same, the RuntimeException handler throws e
        ("rtecatch", [0x0071, gm(58), 0, 0x000e, 0x010d, 0x0222, tR, 0x1070, iR, 0x0002, 0x0227, 0x000d, 0x0127, 0x000d, 0x000e],
         [at(0, 3, [], True, 4), at(5, 6, [RTE], True, [11, 13])]),
        # catch (e) { try { throw new Throwable(); } catch (x) { try { throw e; } catch (LinkageError l) { throw l; } catch (t) { } } }
        ("nestedown", [0x0071, gm(59), 0, 0x000e, 0x010d, 0x0222, tT, 0x1070, iT, 0x0002, 0x0227, 0x030d, 0x0127, 0x000d, 0x0027, 0x000d, 0x000e],
         [at(0, 3, [], True, 4), at(5, 6, [], True, 11), at(12, 1, [LE], True, [13, 15])]),
        # catch (e) { try { cleanup(); } catch (x) { e = x; goto end; } throw e; } end: return: what cleanup() throws isn't followed
        ("dropcleanup", [0x0071, gm(82), 0, 0x000e, 0x010d, 0x0071, mc6, 0, 0x0127, 0x010d, 0xf928], [at(0, 3, [], True, 4), at(5, 3, [], True, 9)]),
        # catch (e) { try { cleanup(); } catch (RuntimeException r) { } catch (NoSuchFieldError f) { throw e; } catch (Throwable x) { } }
        ("middle", [0x0071, gm(87), 0, 0x000e, 0x010d, 0x0071, mc6, 0, 0x000e, 0x020d, 0x000e, 0x020d, 0x0127, 0x020d, 0x000e],
         [at(0, 3, [], True, 4), at(5, 3, [RTE, NSFE, THR], False, [9, 11, 13])]),
        # catch (e) { try { cleanup(); } catch (x) { log(e); } }: a nested path that hands it on
        ("innerlog", [0x0071, gm(92), 0, 0x000e, 0x010d, 0x0071, mc6, 0, 0x000e, 0x020d, 0x1071, mlog, 0x0001, 0x000e],
         [at(0, 3, [], True, 4), at(5, 3, [], True, 9)]),
        # catch (e) { if (v0 == 0) { try { cleanup(); } catch -> 13; return; } 13: throw new Throwable(); } (then a dead throw e):
        # 13 is walked first as cleanup()'s handler, then as the handler's own code, the same registers held
        ("shared", [0x0071, gm(93), 0, 0x000e, 0x010d, 0x0038, 4, 0x0628, 0x000e, 0x0071, mc6, 0, 0x000e,
                    0x0222, tT, 0x1070, iT, 0x0002, 0x0227, 0x0127], [at(0, 3, [], True, 4), at(9, 3, [], True, 13)]),
        # try { M94.x(); } catch (LinkageError l) { } try { M95.x(); } catch (e) { throw new RuntimeException(); } with that
        # throw in a try: catch (LinkageError l) { }: one handler list asked about the error, then about another exception
        ("two", [0x0071, gm(94), 0, 0x0071, gm(95), 0, 0x000e, 0x010d, 0x0222, tR, 0x1070, iR, 0x0002, 0x0227, 0x030d, 0x000e],
         [at(0, 3, [LE], False, 14), at(3, 3, [], True, 7), at(13, 1, [LE], False, 14)]),
        # handlers that don't catch the error: try { RuntimeException.gone(); } catch (IllegalAccessError e) { }; try { M96.x(); }
        # catch (Throwable e) { throw new RuntimeException(); } with that throw in a try: catch (Error r) { }
        ("iaegone", [0x0071, aw.m(RTE, "gone", "()V"), 0, 0x000e, 0x010d, 0x000e], [at(0, 3, [IAE], False, 4)]),
        ("wraperr", [0x0071, gm(96), 0, 0x000e, 0x010d, 0x0222, tR, 0x1070, iR, 0x0002, 0x0227, 0x030d, 0x000e],
         [at(0, 3, [THR], False, 4), at(10, 1, [ERR], False, 11)])]
    aw.cls(L6, OBJ, dm=[("cleanup", "()V", 9, []), ("compute", "()" + THR, 9, [])] + [(n, "()V", 9, [("raw", c)] + t) for n, c, t in l6])
    out = scenario("handlers", pw, aw)
    check_lines("rethrowing handlers", out,
                ["  from Lapp/L;->sync()V", "  from Lapp/L;->fin()V", "  from Lapp/L;->swallow()V [caught: any]",
                 "  from Lapp/L;->thr()V", "  from Lapp/L;->nested()V [caught: any]", "  from Lapp/L;->maybe()V [caught?: any]",
                 "  from Lapp/L;->branch()V", "  from Lapp/L;->cycle()V", "  from Lapp/L;->wrap()V",
                 "  from Lapp/L2;->later(Ljava/lang/Object;)V [caught: Ljava/lang/Throwable;]",
                 "  from Lapp/L2;->later0(Ljava/lang/Object;)V [caught: Ljava/lang/Throwable;]",
                 "  from Lapp/L2;->laterlog(Ljava/lang/Object;)V [caught: Ljava/lang/Throwable;]", "  from Lapp/L2;->high()V",
                 "  from Lapp/L2;->long()V [caught: Ljava/lang/Throwable;]", "  from Lapp/L2;->longdrop()V [caught: Ljava/lang/Throwable;]",
                 "  from Lapp/L2;->longheld()V [caught?: Ljava/lang/Throwable;]", "  from Lapp/L2;->unused2()V [caught?: any]",
                 "  from Lapp/L2;->nsfe()V", "  from Lapp/L2;->mixed()V",
                 "  from Lapp/L2;->two()V [caught: Ljava/lang/Throwable;]", "  from Lapp/L2;->copy()V [caught: any]",
                 "  from Lapp/L2;->copy2()V [caught: Ljava/lang/LinkageError;]", "  from Lapp/L2;->wrapin()V [caught: any]",
                 "  from Lapp/L2;->wrapin2()V", "  from Lapp/L2;->sw()V [caught: Ljava/lang/Throwable;]",
                 "  from Lapp/L2;->swh()V [caught: any]", "  from Lapp/L2;->swsparse()V [caught?: any]",
                 "  from Lapp/L2;->swpacked()V [caught?: any]", "  from Lapp/L2;->later2()V [caught?: any]",
                 "  from Lapp/L2;->eqz()V [caught?: any]", "  from Lapp/L2;->nez()V [caught?: any]",
                 "  from Lapp/L2;->dropped()V [caught: any]", "  from Lapp/L2;->cast()V", "  from Lapp/L2;->lost()V [caught?: any]",
                 "  from Lapp/L2;->unused()V [caught?: any]", "  from Lapp/L2;->wide()V [caught: any]",
                 "  from Lapp/L2;->result()V [caught: any]", "  from Lapp/L2;->widerange()V [caught: any]",
                 "  from Lapp/L4;->other()V [caught: any]"]
                + ["  from Lapp/L2;->%s()V [caught?: any]" % n for n in ("badsw", "swend", "offend", "cutoff")]
                + ["unreadable-code Lapp/L2;->swend()V", "unreadable-code Lapp/L2;->cutoff()V"]
                + ["  from Lapp/L4;->%s()%s [caught?: any]" % (n, OBJ if n == "ret" else "V") for n, _, _ in passes]
                + ["  from Lapp/L4;->%s()V" % n for n, _, _ in rethrows]
                + ["  from Lapp/L12;->%s()%s [caught?: any]" % (n, THR if n == "ret20" else "V") for n, _, _, _ in highs]
                + ["  from Lapp/L6;->%s()V [caught?: any]" % n for n in ("nestedthrow", "savedthen", "retry", "exc", "exc2", "wraprte",
                                                                       "rtecatch", "nestedown", "middle", "innerlog", "shared")]
                + ["  from Lapp/L6;->savedthen()V", "  from Lapp/L6;->syncplain()V [caught: Ljava/lang/Throwable;]", "  from Lapp/L6;->dropcleanup()V",
                   "  from Lapp/L6;->two()V [caught: Ljava/lang/LinkageError;]", "  from Lapp/L6;->two()V", "  from Lapp/L6;->iaegone()V",
                   "  from Lapp/L6;->wraperr()V"])
    check("rethrowing handlers caught everywhere", str("; 20 missing or link-error entries caught everywhere;" in out), "True")
    # A chain of handlers that each pass it on from two try blocks with different handler lists,
    # both leading to the next handler: each handler is settled once, not once per path (2^24),
    # within 10 s (a walk of every path is stopped there, where the platform has SIGALRM)
    aw = W()
    ops = gone(23) + [ret, ("tryat", 0, 3, [], True, 4)]
    for h in range(4, 4 + 5 * 24, 5):   # move-exception v1; if-eqz v0, +3; throw v1; throw v1
        ops += [("raw", [0x010d, 0x0038, 3, 0x0127, 0x0127]), ("tryat", h + 3, 1, [LE], True, h + 5), ("tryat", h + 4, 1, [], True, h + 5)]
    aw.cls("Lapp/L3;", OBJ, vm=[("deep", "()V", 1, ops + [mv])])   # the last one returns
    alarm, t0 = hasattr(signal, "SIGALRM"), time.time()
    if alarm: signal.signal(signal.SIGALRM, too_slow); signal.alarm(10)
    out = scenario("deep", pw, aw)
    if alarm: signal.alarm(0)
    check_lines("handlers settled once each", out, ["  from Lapp/L3;->deep()V [caught: Ljava/lang/LinkageError;]"])
    check("handlers settled once each, in time", str(time.time() - t0 < 10), "True")
    # Handlers nested past the limit (200, each passing it on to the next; the last returns) can't be
    # told, and the method is still read
    aw = W()
    ops = gone(26) + [ret, ("tryat", 0, 3, [], True, 4)]
    for h in range(4, 4 + 2 * 200, 2):   # move-exception v1; throw v1
        ops += [("raw", [0x010d, 0x0127]), ("tryat", h + 1, 1, [], True, h + 2)]
    aw.cls("Lapp/L5;", OBJ, vm=[("deep", "()V", 1, ops + [mv])])
    check_lines("handlers nested too deep", scenario("deeper", pw, aw), ["  from Lapp/L5;->deep()V [caught?: any]"],
                ["unreadable-code Lapp/L5;->deep()V"])
    # ... or past it from paths settled 63 deep: 72 that each pass it on, the last unguarded (it leaves the method), a use
    # guarded by the first and one by the 64th (the first's paths are settled first, and the 64th's with them)
    aw = W()
    ops = gone(97) + gone(98) + [ret, ("tryat", 0, 3, [], True, 7), ("tryat", 3, 3, [], True, 7 + 2 * 63)]
    for h in range(7, 7 + 2 * 71, 2):   # move-exception v1; throw v1
        ops += [("raw", [0x010d, 0x0127]), ("tryat", h + 1, 1, [], True, h + 2)]
    aw.cls("Lapp/L9;", OBJ, dm=[("first", "()V", 9, gone(98))]); aw.cls("Lapp/L10;", OBJ, vm=[("deep", "()V", 1, ops + [mv, thr])])
    out = scenario("deepmid", pw, aw)
    check_lines("handlers nested too deep, settled from the middle", out,
                ["missing-class Landroid/os/M97; refs=1", "  from Lapp/L10;->deep()V [caught?: any]", "missing-class Landroid/os/M98; refs=2"],
                ["  from Lapp/L10;->deep()V [caught: any]"])
    check("handlers nested too deep, settled from the middle, caught everywhere", str("; 0 missing or link-error entries caught everywhere;" in out), "True")
    # The same the other way round, 600 deep (the deepest handler's code first, a use in each handler's
    # try, the outermost use's entry looked at first: an earlier method uses its class unguarded)
    aw, K = W(), 600
    def h(k): return 4 + 4 * (K - 1 - k) if k < K else 2   # h_K (returns) at 2, then h_{K-1} .. h_0
    ops = [("raw", [0x0029, 4 + 4 * K, 0x010d, 0x000e])]    # goto/16 past them; h_K: move-exception v1; return-void
    for k in range(K - 1, -1, -1):                            # h_k: move-exception v1; const-class v2, X_k; throw v1
        ops.append(("raw", [0x010d, 0x021c, aw.t("Landroid/os/X%d;" % k), 0x0127]))
    ops += gone(49) + [("tryat", h(k) + 1, 3, [], True, h(k + 1)) for k in range(K - 1, -1, -1)] + [("tryat", 4 + 4 * K, 3, [], True, h(0))]
    aw.cls("Lapp/L7;", OBJ, dm=[("first", "()V", 9, gone(49))]); aw.cls("Lapp/L8;", OBJ, dm=[("deep", "()V", 9, ops)])
    out = scenario("deepest", pw, aw)
    check_lines("handlers nested too deep, settled from the deepest", out, ["  from Lapp/L8;->deep()V [caught?: any]", "  from Lapp/L7;->first()V"])
    check("handlers nested too deep, settled from the deepest, summary", str(any(l.startswith("summary ") for l in out.splitlines()[-1:])), "True")
    # (each X_k's chain is settled whole: what was met at the limit from the outermost use isn't kept as their answer)
    check("handlers nested too deep, settled from the deepest, caught everywhere", str("; 600 missing or link-error entries caught everywhere;" in out), "True")
    # The same with two paths from each handler to the next (if-eqz v0: throw v1 in a try with a catch-all, else in one with
    # LinkageError's first), 100 deep: what's met at the limit is settled once per handler and depth, not per path (2^64)
    aw, K = W(), 100
    def h(k): return 4 + 7 * (K - 1 - k) if k < K else 2
    ops = [("raw", [0x0029, 4 + 7 * K, 0x010d, 0x000e])]
    for k in range(K - 1, -1, -1):   # h_k: move-exception v1; if-eqz v0, +5; const-class v2, X_k; throw v1; throw v1
        ops += [("raw", [0x010d, 0x0038, 5, 0x021c, aw.t("Landroid/os/X%d;" % k), 0x0127, 0x0127]),
                ("tryat", h(k) + 3, 3, [], True, h(k + 1)), ("tryat", h(k) + 6, 1, [LE], True, h(k + 1))]
    ops += gone(49) + [("tryat", 4 + 7 * K, 3, [], True, h(0))]
    aw.cls("Lapp/L7;", OBJ, dm=[("first", "()V", 9, gone(49))]); aw.cls("Lapp/L8;", OBJ, dm=[("deep", "()V", 9, ops)])
    t0 = time.time()
    if alarm: signal.alarm(10)
    out = scenario("deeptwo", pw, aw)
    if alarm: signal.alarm(0)
    check_lines("handlers nested too deep, two paths each", out, ["missing-class Landroid/os/M49; refs=2", "  from Lapp/L8;->deep()V [caught?: any]"])
    check("handlers nested too deep, two paths each, caught everywhere", str("; 100 missing or link-error entries caught everywhere;" in out), "True")
    check("handlers nested too deep, two paths each, in time", str(time.time() - t0 < 10), "True")
    # The limits at their edges. ladder: after a goto/16 to the method's own code, h_K (returns), then h_{K-1} .. h_0, each
    # passing it on to the next (move-exception v1; throw v1 in a catch-all try); below: with a const-class of Object (a use
    # that prints nothing) in that try, so each handler's fate is settled from below as the code is read, else from the top
    def ladder(u, tries, K, below=True):
        at = {K: len(u)}; u += [0x010d, 0x000e]
        for k in range(K - 1, -1, -1):
            at[k] = len(u); u += [0x010d] + [0x021c, aw.t(OBJ)] * below + [0x0127]
            tries.append(("tryat", at[k] + 1, 1 + 2 * below, [], True, at[k + 1]))
        return at
    def use(u, tries, c, h, types=()):   # invoke-static c.x() in a try: handlers of types, then a catch-all, at h
        tries.append(("tryat", len(u), 3, list(types), True, h)); u += [0x0071, aw.m(c, "x", "()V"), 0]
    def method(u, tries): return [("raw", u)] + tries
    # The handler that returns met 63 deep, settled from below, and 64 deep (catcher1's limit); settled from the top by a use
    # guarded by h_0, h_K's fate met 63 and 64 handlers busy (fate()'s), and from a second use guarded by h_1, 62 and 63 deep.
    # A handler's walk of 511 steps and of 512; a handler that loops for good (no throw, no return) keeps it
    aw = W()
    for K in (63, 64):
        u, tries = [0x0029, 0], []; at = ladder(u, tries, K); u[1] = len(u); use(u, tries, "Landroid/os/C%d;" % K, at[0])
        aw.cls("Lapp/C%d;" % K, OBJ, dm=[("run", "()V", 9, method(u, tries))])
        u, tries = [0x0029, 0], []; at = ladder(u, tries, K, False); u[1] = len(u)
        use(u, tries, "Landroid/os/F%da;" % K, at[0]); use(u, tries, "Landroid/os/F%db;" % K, at[1])
        aw.cls("Lapp/F%d;" % K, OBJ, dm=[("run", "()V", 9, method(u, tries))])
    cl = aw.m("Lapp/E;", "cleanup", "()V")
    aw.cls("Lapp/E;", OBJ, dm=[("cleanup", "()V", 9, [])], vm=[
        ("loop", "()V", 1, [("try", gone(130), [], True, [("raw", [0x010d, 0x0071, cl, 0, 0xfd28])])]),   # L: cleanup(); goto L
        ("nops511", "()V", 1, gone(131) + [("raw", [0x000e, 0x010d] + [0x0000] * 511 + [0x000e]), ("tryat", 0, 3, [], True, 4)]),
        ("nops512", "()V", 1, gone(132) + [("raw", [0x000e, 0x010d] + [0x0000] * 512 + [0x000e]), ("tryat", 0, 3, [], True, 4)])])
    out = scenario("limits", pw, aw)
    def entry(c, w, tag): return "missing-class Landroid/os/%s; refs=1\n  from %s [%s: any]\n" % (c, w, tag)
    check("limits at their edges", str([e for e in (
        entry("C63", "Lapp/C63;->run()V", "caught"), entry("C64", "Lapp/C64;->run()V", "caught?"),
        entry("F63a", "Lapp/F63;->run()V", "caught"), entry("F63b", "Lapp/F63;->run()V", "caught"),
        entry("F64a", "Lapp/F64;->run()V", "caught?"), entry("F64b", "Lapp/F64;->run()V", "caught?"),
        entry("M130", "Lapp/E;->loop()V", "caught"), entry("M131", "Lapp/E;->nops511()V", "caught"),
        entry("M132", "Lapp/E;->nops512()V", "caught?")) if e not in out]), "[]")
    check("limits at their edges, caught everywhere", str("; 5 missing or link-error entries caught everywhere;" in out), "True")
    # The catcher's cache keeps a full answer for any depth and one that met the limit for its depth (and error) only, as met
    # on any path. K1: a 64 chain settled from below; KA (h_0) meets the limit at h_64, KB (h_1) settles h_1 .. h_64 whole, KC's
    # handler throws into h_1, which KA left met at depth 1. K2: g is catch (LinkageError) { return; } then a catch-all into a
    # 70 chain; KU1's handler throws another exception in g (g asked about it at depth 1: met in the chain), KU2's throws the
    # error in g (asked about the error at depth 1). K3: P's paths go into a 40 chain or a handler that returns; KP1 meets P
    # 30 handlers deep (its chain's end past the limit), KP2 is guarded by P
    RTE, aw = "Ljava/lang/RuntimeException;", W()
    u, tries = [0x0029, 0], []; at = ladder(u, tries, 64)
    hp = len(u); u += [0x010d, 0x021c, aw.t(OBJ), 0x0127]; tries.append(("tryat", hp + 1, 3, [], True, at[1]))
    u[1] = len(u); use(u, tries, "Landroid/os/KA;", at[0]); use(u, tries, "Landroid/os/KB;", at[1]); use(u, tries, "Landroid/os/KC;", hp)
    aw.cls("Lapp/K1;", OBJ, dm=[("run", "()V", 9, method(u, tries))])
    u, tries = [0x0029, 0], []; at = ladder(u, tries, 70)
    hs = len(u); u += [0x030d, 0x000e]
    ha = len(u); u += [0x010d, 0x0222, aw.t(RTE), 0x1070, aw.m(RTE, "<init>", "()V"), 0x0002, 0x0227]   # throw new RuntimeException()
    hb = len(u); u += [0x010d, 0x0127]                                                                     # throw e
    tries += [("tryat", ha + 6, 1, [LE], True, [hs, at[0]]), ("tryat", hb + 1, 1, [LE], True, [hs, at[0]])]
    u[1] = len(u); use(u, tries, "Landroid/os/KU1;", ha); use(u, tries, "Landroid/os/KU2;", hb)
    aw.cls("Lapp/K2;", OBJ, dm=[("run", "()V", 9, method(u, tries))])
    u, tries = [0x0029, 0], []; at = ladder(u, tries, 40)
    hr = len(u); u += [0x030d, 0x000e]
    hp = len(u); u += [0x010d, 0x021c, aw.t(OBJ), 0x0038, 3, 0x0127, 0x0127]   # if-eqz v0: throw v1 (into the chain), else throw v1
    tries += [("tryat", hp + 5, 1, [], True, at[0]), ("tryat", hp + 6, 1, [], True, hr)]
    q = {30: hp}
    for k in range(29, -1, -1):   # q_k: move-exception v1; const-class; throw v1, to q_{k+1}
        q[k] = len(u); u += [0x010d, 0x021c, aw.t(OBJ), 0x0127]; tries.append(("tryat", q[k] + 1, 3, [], True, q[k + 1]))
    u[1] = len(u); use(u, tries, "Landroid/os/KP1;", q[0]); use(u, tries, "Landroid/os/KP2;", hp)
    aw.cls("Lapp/K3;", OBJ, dm=[("run", "()V", 9, method(u, tries))])
    out = scenario("cache", pw, aw)
    check("catcher cache", str([e for e in (
        entry("KA", "Lapp/K1;->run()V", "caught?"), entry("KB", "Lapp/K1;->run()V", "caught"), entry("KC", "Lapp/K1;->run()V", "caught"),
        entry("KU1", "Lapp/K2;->run()V", "caught?"), entry("KU2", "Lapp/K2;->run()V", "caught").replace("any", LE),
        entry("KP1", "Lapp/K3;->run()V", "caught?"), entry("KP2", "Lapp/K3;->run()V", "caught")) if e not in out]), "[]")
    check("catcher cache, caught everywhere", str("; 4 missing or link-error entries caught everywhere;" in out), "True")
    # The same output whatever order sets iterate in (the hash seed): one missing method used twice in a method, at 0 in a
    # try whose handler starts 40 that pass it on, then one that returns; at 3 in one whose 30 end in those 40. The use at 0
    # is settled first, whole, so the one at 3 is settled with it (from 3, the limit is met 34 handlers into those 40)
    aw = W()
    u = [0x0071, aw.m("Landroid/os/Gone;", "x", "()V"), 0, 0x0071, aw.m("Landroid/os/Gone;", "x", "()V"), 0, 0x000e]
    ha = len(u); u += [0x010d, 0x0127] * 40 + [0x010d, 0x000e]
    hb = len(u); u += [0x010d, 0x0127] * 30
    ops = [("raw", u), ("tryat", 0, 3, [], True, ha), ("tryat", 3, 3, [], True, hb)]
    ops += [("tryat", ha + 2 * k + 1, 1, [], True, ha + 2 * k + 2) for k in range(40)]
    ops += [("tryat", hb + 2 * k + 1, 1, [], True, hb + 2 * k + 2 if k < 29 else ha) for k in range(30)]
    aw.cls("Lapp/N;", OBJ, dm=[("run", "()V", 9, ops)])
    p = os.path.join(WORK, "seeds-plat.dex"); open(p, "wb").write(pw.build())
    a, cwd = apk_of("seeds.apk", [("classes.dex", aw.build())]), os.path.join(WORK, "seeds"); os.makedirs(cwd)
    # (python3 -I and -E ignore PYTHONHASHSEED: -s and, from 3.11, -P, in an empty directory, with nothing else in the
    # environment; without -P the tool's own directory leads sys.path, and nothing there shadows what it imports)
    flags = ["-s"] + ["-P"] * (sys.version_info >= (3, 11))
    runs = [subprocess.run([sys.executable] + flags + [TOOL, a, p], capture_output=True, text=True, cwd=cwd,
                           env={"PYTHONHASHSEED": seed}) for seed in ("0", "1", "2", "3", "4", "5", "6", "7")]
    check("hash seeds, each run", "".join("seed %s: exit %d\n%s" % (seed, r.returncode, r.stderr)
                                          for seed, r in zip("01234567", runs) if r.returncode), "")
    outs = {r.stdout for r in runs}
    check("hash seeds, one output", str(len(outs)), "1")
    check_lines("hash seeds", min(outs), ["missing-class Landroid/os/Gone; refs=1", "  from Lapp/N;->run()V [caught: any]"],
                ["  from Lapp/N;->run()V [caught?: any]"])
    # A method with a big try table: 100 handlers that rejoin its code still holding what they caught (thrown at its end),
    # then 8000 calls each in its own try: each walked state finds its try block without a scan of the table (5 s)
    aw, ops = W(), []
    for k in range(100):   # try { M99.x(); } catch (e) { v0 = e; } (move-exception v0; goto next)
        ops += gone(99) + [("raw", [0x0328, 0x000d, 0x0128]), ("tryat", 6 * k, 3, [], True, 6 * k + 4)]
    for k in range(8000): ops += [("ms", "Lapp/L11;", "ok", "()V"), ("tryat", 600 + 3 * k, 3, [], True, 600 + 3 * 8000 + 4)]
    ops += [("raw", [0x0038, 3, 0x0027, 0x000e, 0x030d])]   # if-eqz v0, +3; throw v0; return-void; their handler: move-exception v3
    aw.cls("Lapp/L11;", OBJ, dm=[("ok", "()V", 9, []), ("run", "()V", 9, ops)])
    t0 = time.time()
    if alarm: signal.alarm(5)
    out = scenario("bigtries", pw, aw)
    if alarm: signal.alarm(0)
    check_lines("big try table", out, ["missing-class Landroid/os/M99; refs=1", "  from Lapp/L11;->run()V [caught?: any]"])
    check("big try table, in time", str(time.time() - t0 < 5), "True")

    # A platform interface chain past Python's recursion limit, each extending the one before: a method
    # and a field looked up through it
    pw, aw = W(), W()
    pw.cls(OBJ, None)
    for k in range(1200):
        pw.cls("Landroid/os/I%d;" % k, OBJ, ["Landroid/os/I%d;" % (k - 1)] if k else [], flags=0x601,
               fields=[] if k else [("F", "I", True, 0x19)], vm=[] if k else [("m", "()V", 0x401, None)])
    top = "Landroid/os/I1199;"
    aw.cls("Lapp/U;", OBJ, vm=[("run", "()V", 1, [("mi", top, "m", "()V"), ("mi", top, "gone", "()V"), ("f", top, "F", "I"), ("f", top, "nf", "I")])])
    check_lines("interface chain past the recursion limit", scenario("ifdeep", pw, aw),
                ["missing-method Landroid/os/I1199;->gone()V", "missing-field Landroid/os/I1199;->nf:I", "  from Lapp/U;->run()V"],
                ["missing-method Landroid/os/I1199;->m()V", "missing-field Landroid/os/I1199;->F:I"])
    # A field is looked up on the class, its interfaces (theirs first), then its superclass: the
    # interface's static F, not the superclass's instance one
    FB, FI, FJ, FC = "Landroid/os/FB;", "Landroid/os/FI;", "Landroid/os/FJ;", "Landroid/os/FC;"
    pw, aw = W(), W()
    pw.cls(OBJ, None); pw.cls(FB, OBJ, fields=[("F", "I", False)]); pw.cls(FJ, OBJ, flags=0x601, fields=[("F", "I", True, 0x19)])
    pw.cls(FI, OBJ, [FJ], flags=0x601); pw.cls(FC, FB, [FI])
    aw.cls("Lapp/U;", OBJ, vm=[("run", "()V", 1, [("f", FC, "F", "I")]), ("run2", "()V", 1, [("if", FC, "F", "I")])])
    check_lines("field lookup order", scenario("forder", pw, aw),
                ["link-error Landroid/os/FC;->F:I static, used by iget", "  from Lapp/U;->run2()V"],
                ["link-error Landroid/os/FC;->F:I an instance field, used by sget"])

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
    # Register-write table: the opcodes that write their first register, by format (where vA, vAA
    # or vAAAA sits); the others write none, the unused ones are unknown
    writers = {"12x": [0x01, 0x04, 0x07, 0x21] + list(range(0x7b, 0x90)) + list(range(0xb0, 0xd0)), "11n": [0x12],
               "22c": [0x20, 0x23] + list(range(0x52, 0x59)), "22s": list(range(0xd0, 0xd8)), "32x": [0x03, 0x06, 0x09],
               "22x": [0x02, 0x05, 0x08], "11x": list(range(0x0a, 0x0e)), "21s": [0x13, 0x16], "31i": [0x14, 0x17],
               "21h": [0x15, 0x19], "51l": [0x18], "21c": [0x1a, 0x1c, 0x22] + list(range(0x60, 0x67)) + [0xfe, 0xff],
               "31c": [0x1b], "23x": list(range(0x2d, 0x32)) + list(range(0x44, 0x4b)) + list(range(0x90, 0xb0)),
               "22b": list(range(0xd8, 0xe3))}
    field = {"12x": "a", "11n": "a", "22c": "a", "22s": "a", "32x": "a16"}   # else vAA
    dest = {op: field.get(f, "aa") for f, ops in writers.items() for op in ops}
    unused = list(range(0x3e, 0x44)) + [0x73, 0x79, 0x7a] + list(range(0xe3, 0xfa))
    bad = [hex(op) for op in range(256) if dr.DEST[op] != (None if op in unused else dest.get(op, ""))]
    check("register writes", str(bad), "[]")
    # ... and those that write a wide pair: move-wide*, move-result-wide, const-wide*, aget/iget/sget-wide,
    # the unops with a long or double result, the long and double binops (int: 11, long: 11, float: 5, double: 5)
    unops = ("neg-int not-int neg-long not-long neg-float neg-double int-to-long int-to-float int-to-double long-to-int "
             "long-to-float long-to-double float-to-int float-to-long float-to-double double-to-int double-to-long "
             "double-to-float int-to-byte int-to-char int-to-short").split()
    wide = {0x04, 0x05, 0x06, 0x0b, 0x16, 0x17, 0x18, 0x19, 0x45, 0x53, 0x61} | {0x7b + i for i, u in enumerate(unops) if u.endswith(("long", "double"))}
    for base in (0x90, 0xb0): wide |= set(range(base + 11, base + 22)) | set(range(base + 27, base + 32))
    check("wide register writes", str(sorted(map(hex, dr.WIDE ^ wide))), "[]")
    # Catch table: each kind of finding's error, as every handler type that catches it: the error, its superclasses and a
    # catch-all ("any", an exception of a type not known: only Throwable's)
    sup = {"NoClassDefFoundError": "LinkageError", "IncompatibleClassChangeError": "LinkageError", "LinkageError": "Error",
           "Error": "Throwable", **dict.fromkeys(("NoSuchMethodError", "NoSuchFieldError", "IllegalAccessError",
                                                 "InstantiationError", "AbstractMethodError"), "IncompatibleClassChangeError")}
    kinds = {"class": "NoClassDefFoundError", "method": "NoSuchMethodError", "field": "NoSuchFieldError",
             "icce": "IncompatibleClassChangeError", "access": "IllegalAccessError", "instantiation": "InstantiationError",
             "ame": "AbstractMethodError", "linkage": "LinkageError", "any": "Throwable"}
    def catches(e): return {"*", "Ljava/lang/%s;" % e} | (catches(sup[e]) if e in sup else set())
    check("catch table", str([k for k in sorted(set(dr.CATCHES) | set(kinds)) if k not in kinds or dr.CATCHES.get(k) != catches(kinds[k])]), "[]")
    import shutil; shutil.rmtree(WORK, ignore_errors=True)
    print("DEX_REFS_TEST=" + ("FAIL" if fails else "OK"))
    sys.exit(1 if fails else 0)

main()
