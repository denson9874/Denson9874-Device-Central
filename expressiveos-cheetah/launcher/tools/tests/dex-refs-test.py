#!/usr/bin/env python3
# Tests for ../dex-refs.py on dex files it builds itself (no Android tools needed): missing
# classes, methods and fields with who uses them, shadowed classes, unimplemented abstract
# methods, payload instructions, 041 containers in each offset layout, R8 mappings, and the
# opcode width table against the dex format's list.
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
    """A minimal dex writer: ids in insertion order, no map list, no checksum."""
    def __init__(self):
        self.strings, self.types, self.protos, self.fields, self.methods, self.classes = [], [], [], [], [], []
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
    def code(self, ops):
        u = []
        for op in ops:
            if op[0] == "m": u += [0x006e, self.m(*op[1:]), 0]               # invoke-virtual {}
            elif op[0] == "ms": u += [0x0071, self.m(*op[1:]), 0]            # invoke-static {}
            elif op[0] == "poly": u += [0x00fa, self.m(*op[1:]), 0, self.p("()V")]
            elif op[0] == "f": u += [0x0060, self.f(*op[1:])]                # sget
            elif op[0] == "if": u += [0x0052, self.f(*op[1:])]               # iget
            elif op[0] == "t": u += [0x001c, self.t(op[1])]                  # const-class
            elif op[0] == "raw": u += list(op[1])
        return u + [0x000e]                                                  # return-void
    def cls(self, name, sup, ifaces=(), flags=1, fields=(), dm=(), vm=()):
        # fields: (name, type, static); dm/vm: (name, proto, access, ops or None)
        self.t(name); sup is not None and self.t(sup); [self.t(i) for i in ifaces]
        fs = [(self.f(name, n, t), st) for n, t, st in fields]
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
                for idx, a, code in sorted(ms):
                    co = 0
                    if code is not None:
                        co = put(struct.pack("<4HII", 4, 0, 0, 0, 0, len(code)) + struct.pack("<%dH" % len(code), *code), 4)
                    out += uleb(idx - last) + uleb(a) + uleb(co); last = idx
                return out
            sf = sorted(i for i, st in fs if st); inf = sorted(i for i, st in fs if not st)
            def enc_f(xs):
                out, last = b"", 0
                for i in xs: out += uleb(i - last) + uleb(1); last = i
                return out
            dm_b, vm_b = enc_m(d), enc_m(v)
            cdo = put(uleb(len(sf)) + uleb(len(inf)) + uleb(len(d)) + uleb(len(v)) + enc_f(sf) + enc_f(inf) + dm_b + vm_b)
            cd.append((name, flags, sup, ifo, cdo))
        out = bytearray(dstart)
        size = dstart + len(data)
        out[0:8] = b"dex\n" + version + b"\0"
        struct.pack_into("<I", out, 0x20, size)
        struct.pack_into("<I", out, 0x24, sids)
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

def run(args):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): dr.main(["dex-refs.py"] + args)
    return buf.getvalue()

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
summary 6 missing classes, 1 methods, 1 fields, 1 shadowed, 1 unimplemented; 6 platform classes from 1 files; {read} APK methods read, 0 unreadable
"""

def main():
    os.makedirs(WORK, exist_ok=True)
    plat = os.path.join(WORK, "plat.dex"); open(plat, "wb").write(platform())
    fails = 0
    def check(label, got, want):
        nonlocal fails
        if got == want: print("ok", label)
        else:
            fails += 1; print("FAIL", label); print("--- want\n" + want + "--- got\n" + got)
    a, b = app_parts()
    # 039: classes.dex and classes2.dex in an APK
    apk = os.path.join(WORK, "app.apk")
    with zipfile.ZipFile(apk, "w") as z:
        z.writestr("classes.dex", a.build()); z.writestr("classes2.dex", b.build())
    # Code read: Impl.run, Impl.helper, Dflt.onA, Dflt.onB (Shared's is shadowed, so never runs)
    want = EXPECT.replace("1 methods", "2 methods").replace("{plat}", plat).replace("{read}", "4")
    got = run([apk, plat])
    check("039 apk", got, want)
    # 041 containers: all offsets container-relative (ART), ids header-relative, all header-relative
    for ids_rel, data_rel in ((True, True), (False, True), (False, False)):
        a2, b2 = app_parts()
        d1 = a2.build(b"041", 0, ids_rel, data_rel)
        d2 = b2.build(b"041", len(d1), ids_rel, data_rel)
        p = os.path.join(WORK, "app041-%s-%s.dex" % (ids_rel, data_rel)); open(p, "wb").write(d1 + d2)
        check("041 container ids_rel=%s data_rel=%s" % (ids_rel, data_rel), run([p, plat]), want)
    # The platform as a 041 jar too
    pj = os.path.join(WORK, "plat041.jar")
    with zipfile.ZipFile(pj, "w") as z: z.writestr("classes.dex", platform041())
    check("041 platform jar", run([apk, pj]), want.replace(plat, pj))
    # Mapping names APK classes and methods; platform names stay
    mp = os.path.join(WORK, "mapping.txt")
    open(mp, "w").write("# comment\ncom.ex.RealImpl -> app.Impl:\n    1:4:void realRun():10:13 -> run\n"
                        "    1:4:void com.other.Inlined.x():5:8 -> run\ncom.ex.RealSub -> app.Sub:\n")
    wm = want.replace("Lapp/Impl;->run()V", "Lcom/ex/RealImpl;->realRun()V").replace("in Lapp/Impl;", "in Lcom/ex/RealImpl;").replace("in Lapp/Sub;", "in Lcom/ex/RealSub;")
    check("mapping", run(["--mapping", mp, apk, plat]), wm)
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
