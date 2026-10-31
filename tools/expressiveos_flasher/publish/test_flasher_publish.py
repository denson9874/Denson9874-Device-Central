#!/usr/bin/env python3
"""Tests for flasher_publish.py, run as the build server runs it (python3 -I) against a fake
rclone: a script that serves a local folder as the bucket, exiting 3 for a missing directory
as rclone does, and logging each call.

  python3 -m unittest discover -s tools/expressiveos_flasher/publish
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "flasher_publish.py")
sys.path.insert(0, HERE)
import flasher_publish as fp  # noqa: E402

REMOTE = "r2:denson9874-ota"
FLASHER = REMOTE + "/expressiveos/cheetah/flasher"

# lsf (--files-only, --format s), cat and copyto (--s3-no-check-bucket only) on <ROOT>/<remote>/<bucket>/...
# FAKE_RCLONE_FAIL=<command> makes that command fail (with a credential in its message): only
#   the calls whose arguments, joined by spaces, hold FAKE_RCLONE_FAIL_MATCH if that's set, with
#   exit status FAKE_RCLONE_FAIL_RC (1 unless set);
# FAKE_RCLONE_TRUNCATE=<suffix> makes copyto store half of a file whose remote path ends so;
# FAKE_RCLONE_HOOK=<python file> is run before and after each call, with args, phase ("before"
#   or "after"), ROOT and bucket(<remote path>), where that path is kept here.
FAKE_RCLONE = r'''
import json, os, sys
ROOT = %r
LOG = %r


def local(p):
    remote, sep, rest = p.partition(":")
    if not sep or not remote or remote.startswith("-"):
        print("ERROR : not a remote: " + p, file=sys.stderr)
        sys.exit(2)
    parts = [x for x in rest.split("/") if x]
    if any(x in (".", "..") for x in parts):
        sys.exit(2)
    return os.path.join(ROOT, remote, *parts)


def main():
    if cmd == "lsf":
        files_only, fmt, paths, i = False, None, [], 1
        while i < len(args):
            a = args[i]
            if a == "--files-only":
                files_only = True
            elif a == "--format":
                i += 1
                fmt = args[i]
            elif a.startswith("-"):
                print("unknown flag " + a, file=sys.stderr)
                sys.exit(2)
            else:
                paths.append(a)
            i += 1
        if len(paths) != 1:
            sys.exit(2)
        p = local(paths[0])

        def show(path, name):
            print(os.path.getsize(path) if fmt == "s" else name)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                q = os.path.join(p, n)
                if os.path.isdir(q):
                    if not files_only:
                        print(n + "/")
                else:
                    show(q, n)
        elif os.path.isfile(p) and not paths[0].endswith("/"):
            show(p, os.path.basename(p))
        else:
            print("ERROR : directory not found", file=sys.stderr)
            sys.exit(3)
    elif cmd == "cat":
        if len(args) != 2:
            sys.exit(2)
        p = local(args[1])
        if not os.path.isfile(p):
            print("ERROR : object not found", file=sys.stderr)
            sys.exit(3)
        with open(p, "rb") as f:
            sys.stdout.buffer.write(f.read())
    elif cmd == "copyto":
        if len(args) != 4 or args[1] != "--s3-no-check-bucket":
            print("copyto without --s3-no-check-bucket", file=sys.stderr)
            sys.exit(2)
        src, dst = args[2], local(args[3])
        with open(src, "rb") as f:
            data = f.read()
        cut = os.environ.get("FAKE_RCLONE_TRUNCATE")
        if cut and args[3].endswith(cut):
            data = data[: len(data) // 2]
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst + ".partial", "wb") as f:
            f.write(data)
        os.replace(dst + ".partial", dst)
    else:
        print("unknown command " + cmd, file=sys.stderr)
        sys.exit(2)


def hook(phase):
    path = os.environ.get("FAKE_RCLONE_HOOK")
    if path:
        with open(path) as f:
            exec(f.read(), {"args": args, "phase": phase, "ROOT": ROOT, "bucket": local, "os": os, "json": json})


args = sys.argv[1:]
with open(LOG, "a") as f:
    f.write(json.dumps(args) + "\n")
cmd = args[0] if args else ""
if os.environ.get("FAKE_RCLONE_FAIL") == cmd and os.environ.get("FAKE_RCLONE_FAIL_MATCH", "") in " ".join(args):
    print("ERROR : connection reset by peer", file=sys.stderr)
    print("ERROR : request with secret_access_key=SHOULD-NOT-SHOW failed", file=sys.stderr)
    sys.exit(int(os.environ.get("FAKE_RCLONE_FAIL_RC", "1")))
hook("before")
try:
    main()
finally:
    hook("after")
'''


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_sidecar(path: str) -> str:
    with open(path, "rb") as f:
        line = f"{sha256(f.read())}  {os.path.basename(path)}\n"
    with open(path + ".sha256", "w") as f:
        f.write(line)
    return line


class FlasherPublishTest(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(prefix="flasher-publish-test.")
        self.addCleanup(t.cleanup)
        self.tmp = t.name
        self.rel = os.path.join(self.tmp, "releases")
        self.root = os.path.join(self.tmp, "bucket")
        self.log = os.path.join(self.tmp, "rclone.log")
        os.makedirs(self.rel)
        os.makedirs(os.path.join(self.root, "r2", "denson9874-ota"))
        os.makedirs(os.path.join(self.tmp, "bin"))
        self.rclone = os.path.join(self.tmp, "bin", "rclone")
        with open(self.rclone, "w") as f:
            f.write(f"#!{sys.executable} -I\n" + FAKE_RCLONE % (self.root, self.log))
        os.chmod(self.rclone, 0o755)

    # -- helpers

    def make_release(self, *, device="cheetah", date="20261030", version="1.0", rtype="OFFICIAL", r="",
                     android="17.0", stock=True, info=None, omit=(), deflate=(), seed=b""):
        """A fake release in self.rel: its stored Zip64 fastboot zip and (stock) stock init_boot,
        each with its .sha256. Returns the zip's path."""
        base = f"ExpressiveOS-{android}-{date}-{device}-{version}-{rtype}{r}"
        if info is None:
            info = f"require board={device}\nrequire version-bootloader={device}-1.0\n\n"
        entries = {
            "fastboot-info.txt": b"version 1\nflash init_boot\nflash vbmeta\nupdate-super\nflash system\n",
            "android-info.txt": info.encode(),
            "init_boot.img": b"ANDROID! KernelSU Next init_boot " + seed,
            "vbmeta.img": b"AVB0" + seed,
            "super_empty.img": b"super_empty " + seed,
            "system.img": b"system " * 4096 + seed,
        }
        zpath = os.path.join(self.rel, base + "-fastboot.zip")
        with zipfile.ZipFile(zpath, "w") as zf:
            for n, data in entries.items():
                if n in omit:
                    continue
                zi = zipfile.ZipInfo(n, date_time=(2026, 10, 30, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED if n in deflate else zipfile.ZIP_STORED
                with zf.open(zi, "w", force_zip64=True) as f:
                    f.write(data)
        write_sidecar(zpath)
        if stock:
            spath = os.path.join(self.rel, base + "-init_boot-stock.img")
            with open(spath, "wb") as f:
                f.write(b"ANDROID! stock init_boot " + seed)
            write_sidecar(spath)
        return zpath

    def run_publish(self, *args, env=None):
        cmd = [sys.executable, "-I", SCRIPT, *args]
        if "--rclone" not in args:
            cmd += ["--rclone", self.rclone]
        e = dict(os.environ)
        e["HOME"] = self.tmp   # its lock file goes here, not in the real ~
        e.update(env or {})
        return subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=120)

    def hook(self, code):
        """A FAKE_RCLONE_HOOK file running code; returns the env that sets it."""
        path = os.path.join(self.tmp, "hook.py")
        with open(path, "w") as f:
            f.write(code)
        return {"FAKE_RCLONE_HOOK": path}

    def assertOK(self, p):
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(p.stdout.splitlines()[-1], "FLASHER_PUBLISH=OK")
        self.assertNotIn("FAIL", p.stderr)

    def assertFAIL(self, p, *parts):
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertEqual(p.stdout.splitlines()[-1], "FLASHER_PUBLISH=FAIL")
        fails = [line for line in p.stderr.splitlines() if line.startswith("FAIL: ")]
        self.assertEqual(len(fails), 1, p.stderr)
        for part in parts:
            self.assertIn(part, p.stderr)

    def bucket(self, *parts):
        return os.path.join(self.root, "r2", "denson9874-ota", "expressiveos", *parts)

    def put(self, data: bytes, *parts):
        path = self.bucket(*parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def snapshot(self):
        out = {}
        for d, _, files in os.walk(self.root):
            for n in files:
                p = os.path.join(d, n)
                with open(p, "rb") as f:
                    out[os.path.relpath(p, self.root)] = f.read()
        return out

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def uploads(self):
        """The remote paths copyto wrote, in order."""
        return [c[3] for c in self.calls() if c[0] == "copyto"]

    def manifest(self):
        with open(self.bucket("cheetah", "flasher.json"), "rb") as f:
            return json.loads(f.read())

    def flasher_files(self):
        d = self.bucket("cheetah", "flasher")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    @staticmethod
    def entry(base, channel="release", published="2026-10-01T10:00:00Z", stock=True):
        m = fp.release_re("cheetah", "").fullmatch(base)
        android, ymd, version, rtype, _ = m.groups()
        z = {"file": base + "-fastboot.zip", "size": 100, "sha256": "a" * 64}
        s = {"file": base + "-init_boot-stock.img", "size": 10, "sha256": "b" * 64} if stock else None
        return {"name": base, "channel": channel, "android": android, "version": version, "type": rtype,
                "date": f"{ymd[:4]}-{ymd[4:6]}-{ymd[6:]}", "published": published, "zip": z,
                "initBootStock": s, "root": "kernelsu-next" if stock else None,
                "requirements": ["require board=cheetah"]}

    def put_manifest(self, releases):
        m = {"schema": 1, "device": "cheetah", "updated": "2026-10-20T00:00:00Z", "releases": releases}
        self.put(json.dumps(m).encode(), "cheetah", "flasher.json")

    # -- publishing

    def test_release_published(self):
        z = self.make_release()
        name = os.path.basename(z)
        base = name[:-len("-fastboot.zip")]
        stock = base + "-init_boot-stock.img"
        p = self.run_publish("cheetah", z)
        self.assertOK(p)
        self.assertEqual(self.flasher_files(), sorted([name, name + ".sha256", stock, stock + ".sha256"]))
        # Byte for byte the local files, sidecars included
        for n in (name, name + ".sha256", stock, stock + ".sha256"):
            with open(os.path.join(self.rel, n), "rb") as a, open(self.bucket("cheetah", "flasher", n), "rb") as b:
                self.assertEqual(a.read(), b.read(), n)
        # Nothing anywhere else: only expressiveos/cheetah/flasher/ and flasher.json
        self.assertEqual(sorted(self.snapshot()),
                         sorted(os.path.join("r2", "denson9874-ota", "expressiveos", "cheetah", *x) for x in
                                [("flasher.json",)] + [("flasher", n) for n in self.flasher_files()]))
        with open(z, "rb") as f:
            zdata = f.read()
        m = self.manifest()
        self.assertEqual(m["schema"], 1)
        self.assertEqual(m["device"], "cheetah")
        self.assertRegex(m["updated"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(len(m["releases"]), 1)
        e = m["releases"][0]
        self.assertEqual(e["name"], base)
        self.assertEqual(e["channel"], "release")
        self.assertEqual((e["android"], e["version"], e["type"], e["date"]), ("17.0", "1.0", "OFFICIAL", "2026-10-30"))
        self.assertEqual(e["published"], m["updated"])
        self.assertEqual(e["zip"], {"file": name, "size": len(zdata), "sha256": sha256(zdata)})
        self.assertEqual(e["initBootStock"]["file"], stock)
        self.assertEqual(e["initBootStock"]["size"], os.path.getsize(os.path.join(self.rel, stock)))
        self.assertEqual(e["root"], "kernelsu-next")
        self.assertEqual(e["requirements"], ["require board=cheetah", "require version-bootloader=cheetah-1.0"])
        # Each .sha256 before its file, the manifest last, every copyto with --s3-no-check-bucket
        ups = self.uploads()
        self.assertEqual(ups, [f"{FLASHER}/{name}.sha256", f"{FLASHER}/{name}",
                               f"{FLASHER}/{stock}.sha256", f"{FLASHER}/{stock}",
                               REMOTE + "/expressiveos/cheetah/flasher.json"])
        self.assertTrue(all(c[1] == "--s3-no-check-bucket" for c in self.calls() if c[0] == "copyto"))
        self.assertIn(f"PUBLISHED {base} release {REMOTE}/expressiveos/cheetah/flasher.json", p.stdout)

    def test_testers_channel(self):
        p = self.run_publish("cheetah", self.make_release(date="20261030"), "--testers")
        self.assertOK(p)
        self.assertEqual([(e["name"], e["channel"]) for e in self.manifest()["releases"]],
                         [("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", "testers")])
        # A release beside it: both channels listed, newest first
        self.assertOK(self.run_publish("cheetah", self.make_release(date="20261025", seed=b"2")))
        self.assertEqual([(e["date"], e["channel"]) for e in self.manifest()["releases"]],
                         [("2026-10-30", "testers"), ("2026-10-25", "release")])

    def test_other_device_and_remote(self):
        z = self.make_release(device="kodiak")
        os.makedirs(os.path.join(self.root, "backup", "other-bucket"))
        p = self.run_publish("kodiak", z, "--remote", "backup:other-bucket")
        self.assertOK(p)
        d = os.path.join(self.root, "backup", "other-bucket", "expressiveos", "kodiak")
        self.assertEqual(sorted(os.listdir(d)), ["flasher", "flasher.json"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.root, "r2", "denson9874-ota"))), [])
        with open(os.path.join(d, "flasher.json")) as f:
            m = json.load(f)
        self.assertEqual(m["device"], "kodiak")
        self.assertEqual(m["releases"][0]["requirements"][0], "require board=kodiak")

    def test_rerun_skips_upload(self):
        z = self.make_release()
        self.assertOK(self.run_publish("cheetah", z))
        before = {k: v for k, v in self.snapshot().items() if not k.endswith("flasher.json")}
        listed = self.manifest()["releases"]
        os.remove(self.log)
        p = self.run_publish("cheetah", z)
        self.assertOK(p)
        self.assertEqual(p.stdout.count("already published: "), 2)
        self.assertEqual(self.uploads(), [REMOTE + "/expressiveos/cheetah/flasher.json"])
        self.assertEqual({k: v for k, v in self.snapshot().items() if not k.endswith("flasher.json")}, before)
        # The same release, as it was listed: its published time too
        self.assertEqual(self.manifest()["releases"], listed)
        # The same build to the other channel: still one entry, replaced, its files still listed
        p = self.run_publish("cheetah", z, "--testers")
        self.assertOK(p)
        self.assertEqual([e["channel"] for e in self.manifest()["releases"]], ["testers"])
        self.assertNotIn("no longer listed", p.stdout)

    def test_rerun_keeps_its_place(self):
        # A re-run of an older release of the day never moves it above (or drops) a newer one
        a = self.make_release(version="1.0")
        self.assertOK(self.run_publish("cheetah", a))
        m = self.manifest()
        m["releases"][0]["published"] = "2026-10-30T09:00:00Z"
        self.put(json.dumps(m).encode(), "cheetah", "flasher.json")
        self.assertOK(self.run_publish("cheetah", self.make_release(version="1.1", seed=b"b")))
        newer = self.manifest()["releases"]
        self.assertEqual([e["version"] for e in newer], ["1.1", "1.0"])
        self.assertOK(self.run_publish("cheetah", a))
        self.assertEqual(self.manifest()["releases"], newer)
        # --keep 1 lists 1.1 only: 1.0 isn't listed again over it
        before = self.snapshot()
        p = self.run_publish("cheetah", a, "--keep", "1")
        self.assertFAIL(p, "wouldn't be listed")
        self.assertNotIn("no longer listed", p.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_name_held_by_another_build(self):
        z = self.make_release()
        name = os.path.basename(z)
        self.put(b"another build", "cheetah", "flasher", name)
        self.put(f"{sha256(b'another build')}  {name}\n".encode(), "cheetah", "flasher", name + ".sha256")
        before = self.snapshot()
        p = self.run_publish("cheetah", z)
        self.assertFAIL(p, "another build holds", "never overwritten")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.uploads(), [])

    def test_stock_name_held_by_another_build(self):
        # Checked before anything is uploaded: the zip doesn't go up either
        z = self.make_release()
        stock = os.path.basename(z)[:-len("-fastboot.zip")] + "-init_boot-stock.img"
        self.put(b"other", "cheetah", "flasher", stock)
        self.put(f"{sha256(b'other')}  {stock}\n".encode(), "cheetah", "flasher", stock + ".sha256")
        before = self.snapshot()
        self.assertFAIL(self.run_publish("cheetah", z), "another build holds", stock)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.uploads(), [])

    def test_r2_file_without_its_sidecar(self):
        z = self.make_release()
        with open(z, "rb") as f:
            self.put(f.read(), "cheetah", "flasher", os.path.basename(z))
        before = self.snapshot()
        self.assertFAIL(self.run_publish("cheetah", z), "without its .sha256")
        self.assertEqual(self.snapshot(), before)

    def test_r2_sidecar_of_another_build(self):
        z = self.make_release()
        name = os.path.basename(z)
        self.put(f"{'c' * 64}  {name}\n".encode(), "cheetah", "flasher", name + ".sha256")
        before = self.snapshot()
        self.assertFAIL(self.run_publish("cheetah", z), "is another build's")
        self.assertEqual(self.snapshot(), before)

    def test_own_sidecar_from_an_upload_cut_short(self):
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        with open(z + ".sha256", "rb") as f:
            self.put(f.read(), "cheetah", "flasher", name + ".sha256")
        p = self.run_publish("cheetah", z)
        self.assertOK(p)
        self.assertEqual(self.uploads(), [f"{FLASHER}/{name}", REMOTE + "/expressiveos/cheetah/flasher.json"])
        self.assertEqual(self.flasher_files(), [name, name + ".sha256"])

    # -- local checks: each fails before rclone runs at all

    def test_bad_sha256_file(self):
        z = self.make_release()
        name = os.path.basename(z)
        with open(z, "rb") as f:
            good = sha256(f.read())
        cases = {
            "missing": None,
            "another sha256": f"{'0' * 64}  {name}\n",
            "another name": f"{good}  ExpressiveOS-other-fastboot.zip\n",
            "uppercase": f"{good.upper()}  {name}\n",
            "one space": f"{good} {name}\n",
            "binary mode": f"{good} *{name}\n",
            "two lines": f"{good}  {name}\n{good}  {name}\n",
            "short": f"{good[:63]}  {name}\n",
            "path": f"{good}  ./{name}\n",
        }
        for case, content in cases.items():
            with self.subTest(case):
                if os.path.exists(self.log):
                    os.remove(self.log)
                if content is None:
                    os.remove(z + ".sha256")
                else:
                    with open(z + ".sha256", "w") as f:
                        f.write(content)
                p = self.run_publish("cheetah", z)
                self.assertFAIL(p, name)
                self.assertEqual(self.calls(), [])
        self.assertEqual(self.snapshot(), {})

    def test_sha256_without_final_newline_is_fine(self):
        z = self.make_release(stock=False)
        with open(z + ".sha256") as f:
            line = f.read()
        with open(z + ".sha256", "w") as f:
            f.write(line.rstrip("\n"))
        self.assertOK(self.run_publish("cheetah", z))

    def test_board_lines(self):
        cases = {
            "another board": "require board=husky\n",
            "two boards": "require board=cheetah|panther\n",
            "extra board line": "require board=cheetah\nboard=panther\n",
            "second require board": "require board=cheetah\nrequire board=panther\n",
            "extra product line": "require board=cheetah\nrequire product=cheetah\n",
            "no board": "require version-bootloader=x\n",
            "unrequired board": "board=cheetah\n",
            "CRLF": "require board=cheetah\r\n",
        }
        for case, info in cases.items():
            with self.subTest(case):
                shutil.rmtree(self.rel)
                os.makedirs(self.rel)
                p = self.run_publish("cheetah", self.make_release(info=info))
                self.assertFAIL(p, "doesn't say 'require board=cheetah' only")
                self.assertEqual(self.calls(), [])

    def test_missing_required_entry(self):
        for entry in fp.REQUIRED_ENTRIES:
            with self.subTest(entry):
                shutil.rmtree(self.rel)
                os.makedirs(self.rel)
                p = self.run_publish("cheetah", self.make_release(omit=(entry,)))
                self.assertFAIL(p, f"has no {entry}")
                self.assertEqual(self.calls(), [])

    def test_compressed_entry(self):
        p = self.run_publish("cheetah", self.make_release(deflate=("system.img",)))
        self.assertFAIL(p, "stored zip", "system.img")

    def test_not_a_zip(self):
        z = os.path.join(self.rel, "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-fastboot.zip")
        with open(z, "wb") as f:
            f.write(b"not a zip at all")
        write_sidecar(z)
        self.assertFAIL(self.run_publish("cheetah", z), "as a zip")

    def test_no_stock_image(self):
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        p = self.run_publish("cheetah", z)
        self.assertOK(p)
        self.assertIn("without KernelSU Next", p.stdout)
        e = self.manifest()["releases"][0]
        self.assertIsNone(e["root"])
        self.assertIsNone(e["initBootStock"])
        self.assertEqual(self.flasher_files(), [name, name + ".sha256"])

    def test_stock_image_bad_sidecar(self):
        z = self.make_release()
        spath = z[:-len("-fastboot.zip")] + "-init_boot-stock.img"
        with open(spath, "ab") as f:
            f.write(b"changed")
        self.assertFAIL(self.run_publish("cheetah", z), "isn't the file its .sha256 names")
        os.remove(spath + ".sha256")
        self.assertFAIL(self.run_publish("cheetah", z), "no ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-init_boot-stock.img.sha256")
        self.assertEqual(self.calls(), [])

    def test_stock_sidecar_without_image(self):
        # A KernelSU Next build that lost its stock image is never listed as a rootless one
        z = self.make_release()
        os.remove(z[:-len("-fastboot.zip")] + "-init_boot-stock.img")
        self.assertFAIL(self.run_publish("cheetah", z), "would be listed as stock")
        self.assertEqual(self.calls(), [])

    def test_stock_image_not_an_init_boot(self):
        # The flasher lists no release with an empty file, and flashes this one to init_boot
        z = self.make_release()
        spath = z[:-len("-fastboot.zip")] + "-init_boot-stock.img"
        for case, data, why in (("empty", b"", "is empty"),
                                ("not a boot image", b"stock init_boot", "doesn't start with ANDROID!")):
            with self.subTest(case):
                with open(spath, "wb") as f:
                    f.write(data)
                write_sidecar(spath)
                self.assertFAIL(self.run_publish("cheetah", z), why, "not an init_boot image")
        self.assertEqual(self.calls(), [])

    def test_stock_image_gone_on_a_rerun(self):
        # A KernelSU Next build published again without its stock image is never relisted rootless
        z = self.make_release()
        spath = z[:-len("-fastboot.zip")] + "-init_boot-stock.img"
        stock = os.path.basename(spath)
        self.assertOK(self.run_publish("cheetah", z))
        os.remove(spath)
        os.remove(spath + ".sha256")
        before = self.snapshot()
        for args in ((), ("--testers",), ("--dry-run",)):
            with self.subTest(args=args):
                os.remove(self.log)
                p = self.run_publish("cheetah", z, *args)
                self.assertFAIL(p, "published as a KernelSU Next build", "listed without root")
                self.assertEqual(self.uploads(), [])
                self.assertEqual(self.snapshot(), before)
        # Listed with its stock image, which R2 no longer holds: still never relisted rootless
        listed = self.manifest()
        for n in (stock, stock + ".sha256"):
            os.remove(self.bucket("cheetah", "flasher", n))
        before = self.snapshot()
        p = self.run_publish("cheetah", z)
        self.assertFAIL(p, "published as a KernelSU Next build", "listed without root")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.manifest(), listed)
        # Its stock image in R2 but no longer listed (a run cut short, or pruned): the same
        self.assertEqual(self.make_release(), z)   # the same zip again, and its stock image
        self.assertOK(self.run_publish("cheetah", z))
        os.remove(spath)
        os.remove(spath + ".sha256")
        self.put_manifest([])
        before = self.snapshot()
        p = self.run_publish("cheetah", z)
        self.assertFAIL(p, f"holds {stock}, {stock}.sha256", "listed without root")
        self.assertEqual(self.snapshot(), before)

    # -- names, devices, arguments

    def test_device_and_name(self):
        husky = self.make_release(device="husky")
        self.assertFAIL(self.run_publish("cheetah", husky), "is a husky build, not cheetah's")
        self.assertFAIL(self.run_publish("panther", husky), "isn't one of cheetah husky kodiak grizzly cubs yogi")
        z = self.make_release()
        bad = {
            "ExpressiveOS-17.0-2026103-cheetah-1.0-OFFICIAL-fastboot.zip": "isn't named",
            "ExpressiveOS-17-20261030-cheetah-1.0-OFFICIAL-fastboot.zip": "isn't named",
            "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-fastboot.zip.bak": "isn't named",
            "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-r-fastboot.zip": "isn't named",
            "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL.zip": "isn't named",
            "ExpressiveOS-17.0-20261340-cheetah-1.0-OFFICIAL-fastboot.zip": "isn't a date",
            "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-fastboot.zip\n": "isn't named",
        }
        for n, why in bad.items():
            with self.subTest(n):
                other = os.path.join(self.rel, n)
                shutil.copy(z, other)
                self.assertFAIL(self.run_publish("cheetah", other), why)
        self.assertEqual(self.calls(), [])
        # -rN releases are fine
        self.assertOK(self.run_publish("cheetah", self.make_release(r="-r2")))
        self.assertEqual(self.manifest()["releases"][0]["name"], "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-r2")

    def test_bad_remote(self):
        z = self.make_release()
        for remote in ("r2:Denson9874-ota", "r2", "denson9874-ota", "r2:denson9874-ota/sub", "-x:denson9874-ota",
                       "--config:x", "r2:-ota", "r2: denson", "r2:denson9874-ota\n", "r2:", ":denson9874-ota", "r2:a_b"):
            with self.subTest(remote):
                # --remote=<value>: argparse would take a bare -x:... for an option
                p = self.run_publish("cheetah", z, f"--remote={remote}")
                self.assertFAIL(p, "isn't <rclone remote>:<bucket>")
        self.assertEqual(self.calls(), [])

    def test_usage_errors(self):
        z = self.make_release()
        self.assertFAIL(self.run_publish("cheetah"), "usage:")
        self.assertFAIL(self.run_publish("cheetah", z, "--keep", "0"), "--keep 0")
        self.assertFAIL(self.run_publish("cheetah", z, "--keep", "two"), "--keep")
        self.assertFAIL(self.run_publish("cheetah", z, "--bogus"), "unrecognized")
        self.assertFAIL(self.run_publish("cheetah", z, "--rclone", os.path.join(self.tmp, "no-rclone")), "no rclone at")
        self.assertFAIL(self.run_publish("cheetah", os.path.join(self.rel, "ExpressiveOS-17.0-20261031-cheetah-1.0-OFFICIAL-fastboot.zip")), "no ")
        self.assertEqual(self.calls(), [])

    def test_help_is_a_fail(self):
        # The last line rule holds for --help too: it publishes nothing
        for flag in ("-h", "--help"):
            with self.subTest(flag):
                p = self.run_publish(flag)
                self.assertFAIL(p, "nothing published")
                self.assertIn("usage: flasher_publish.py", p.stdout)
                self.assertIn("--testers", p.stdout)
        self.assertEqual(self.calls(), [])

    def test_one_run_per_device(self):
        import fcntl
        z = self.make_release()
        with open(os.path.join(self.tmp, ".expressiveos-flasher-cheetah.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            p = self.run_publish("cheetah", z)
            self.assertFAIL(p, "another flasher_publish.py run for cheetah", "one at a time")
            self.assertEqual(self.calls(), [])
            # A dry run writes nothing: it may run beside it, as may another device's run
            self.assertOK(self.run_publish("cheetah", z, "--dry-run"))
            self.assertOK(self.run_publish("kodiak", self.make_release(device="kodiak")))
        self.assertOK(self.run_publish("cheetah", z))

    # -- the manifest

    def test_invalid_existing_manifest(self):
        z = self.make_release()
        good = self.entry("ExpressiveOS-17.0-20261001-cheetah-1.0-OFFICIAL")

        def m(**kw):
            d = {"schema": 1, "device": "cheetah", "updated": "2026-10-01T00:00:00Z", "releases": [good]}
            d.update(kw)
            return json.dumps(d).encode()
        cases = {
            "not JSON": b"{not json",
            "empty": b"",
            "not UTF-8": b"\xff\xfe",
            "a list": b"[]",
            "schema 2": m(schema=2),
            "schema true": m(schema=True),
            "schema 1.0": m(schema=1.0),
            "schema '1'": m(schema="1"),
            "no schema": json.dumps({"device": "cheetah", "releases": []}).encode(),
            "another device": m(device="husky"),
            "releases not a list": m(releases={}),
            "a release's bad name": m(releases=[dict(good, name="../../etc")]),
            "another device's release": m(releases=[dict(good, name="ExpressiveOS-17.0-20261001-husky-1.0-OFFICIAL")]),
            "bad channel": m(releases=[dict(good, channel="beta")]),
            "zip file mismatch": m(releases=[dict(good, zip=dict(good["zip"], file="x-fastboot.zip"))]),
            "size a string": m(releases=[dict(good, zip=dict(good["zip"], size="100"))]),
            "size 0": m(releases=[dict(good, zip=dict(good["zip"], size=0))]),
            "stock size 0": m(releases=[dict(good, initBootStock=dict(good["initBootStock"], size=0))]),
            "root without stock": m(releases=[dict(good, initBootStock=None)]),
            "bad date": m(releases=[dict(good, date="20261001")]),
            "listed twice": m(releases=[good, good]),
        }
        for case, data in cases.items():
            with self.subTest(case):
                self.put(data, "cheetah", "flasher.json")
                if os.path.exists(self.log):
                    os.remove(self.log)
                before = self.snapshot()
                p = self.run_publish("cheetah", z)
                self.assertFAIL(p, "isn't a valid flasher manifest", "never replaced")
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(self.uploads(), [])
                # And the same with --dry-run
                self.assertFAIL(self.run_publish("cheetah", z, "--dry-run"), "isn't a valid flasher manifest")

    def test_keep_prunes_each_channel(self):
        old1 = "ExpressiveOS-17.0-20261001-cheetah-1.0-OFFICIAL"
        old2 = "ExpressiveOS-17.0-20261015-cheetah-1.0-OFFICIAL"
        tst = "ExpressiveOS-17.0-20261020-cheetah-1.0-OFFICIAL"
        self.put_manifest([self.entry(old2), self.entry(tst, channel="testers"), self.entry(old1)])
        for b in (old1, old2):
            for n in (b + "-fastboot.zip", b + "-init_boot-stock.img"):
                self.put(b"old", "cheetah", "flasher", n)
                self.put(b"old sha", "cheetah", "flasher", n + ".sha256")
        before = self.snapshot()
        z = self.make_release(date="20261030")
        p = self.run_publish("cheetah", z)
        self.assertOK(p)
        gone = [line for line in p.stdout.splitlines() if line.startswith("no longer listed: ")]
        self.assertEqual(gone, [f"no longer listed: {FLASHER}/{old1}-fastboot.zip",
                                f"no longer listed: {FLASHER}/{old1}-fastboot.zip.sha256",
                                f"no longer listed: {FLASHER}/{old1}-init_boot-stock.img",
                                f"no longer listed: {FLASHER}/{old1}-init_boot-stock.img.sha256"])
        self.assertEqual([(e["name"], e["channel"]) for e in self.manifest()["releases"]],
                         [("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", "release"), (tst, "testers"), (old2, "release")])
        # Nothing deleted: the old files are all still there
        after = self.snapshot()
        for k, v in before.items():
            if not k.endswith("flasher.json"):
                self.assertEqual(after.get(k), v, k)
        # --keep 1: one release, one testers build
        p = self.run_publish("cheetah", z, "--keep", "1")
        self.assertOK(p)
        self.assertIn(f"no longer listed: {FLASHER}/{old2}-fastboot.zip", p.stdout)
        self.assertNotIn(old1, p.stdout)   # no longer listed already
        self.assertEqual([e["name"] for e in self.manifest()["releases"]],
                         ["ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", tst])

    def test_order_by_date_then_rn_then_published(self):
        a = "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL"
        a3 = "ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-r3"
        self.put_manifest([self.entry(a, published="2026-10-30T09:00:00Z"),
                           self.entry(a3, published="2026-10-30T08:00:00Z")])
        self.assertOK(self.run_publish("cheetah", self.make_release(r="-r2"), "--keep", "5"))
        self.assertEqual([e["name"] for e in self.manifest()["releases"]], [a3, a + "-r2", a])

    def test_release_older_than_keep_is_refused(self):
        self.put_manifest([self.entry("ExpressiveOS-17.0-20261020-cheetah-1.0-OFFICIAL"),
                           self.entry("ExpressiveOS-17.0-20261025-cheetah-1.0-OFFICIAL")])
        before = self.snapshot()
        p = self.run_publish("cheetah", self.make_release(date="20261001"))
        self.assertFAIL(p, "wouldn't be listed")
        self.assertEqual(self.snapshot(), before)
        # It's another channel's place
        self.assertOK(self.run_publish("cheetah", self.make_release(date="20261001"), "--testers"))

    def test_dry_run_writes_nothing(self):
        old = "ExpressiveOS-17.0-20261001-cheetah-1.0-OFFICIAL"
        self.put_manifest([self.entry(old), self.entry("ExpressiveOS-17.0-20261015-cheetah-1.0-OFFICIAL")])
        before = self.snapshot()
        z = self.make_release()
        name = os.path.basename(z)
        p = self.run_publish("cheetah", z, "--dry-run")
        self.assertOK(p)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.uploads(), [])
        self.assertTrue(self.calls())   # it did read R2
        with open(z + ".sha256") as f:
            line = f.read().strip()
        self.assertIn(f"would upload: {z} -> {FLASHER}/{name} ", p.stdout)
        self.assertIn(f"would upload: {FLASHER}/{name}.sha256 (the line '{line}')", p.stdout)
        self.assertIn(f"no longer listed: {FLASHER}/{old}-fastboot.zip", p.stdout)
        out = p.stdout.splitlines()
        start = next(i for i, line in enumerate(out) if line.startswith("would write "))
        end = next(i for i, line in enumerate(out) if line.startswith("DRY RUN"))
        m = json.loads("\n".join(out[start + 1:end]))
        self.assertEqual([e["name"] for e in m["releases"]],
                         ["ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", "ExpressiveOS-17.0-20261015-cheetah-1.0-OFFICIAL"])
        # On an empty bucket too
        shutil.rmtree(self.bucket())
        self.assertOK(self.run_publish("cheetah", z, "--dry-run"))
        self.assertFalse(os.path.exists(self.bucket()))

    # -- rclone failing

    def test_rclone_failures(self):
        z = self.make_release()
        p = self.run_publish("cheetah", z, env={"FAKE_RCLONE_FAIL": "lsf"})
        self.assertFAIL(p, "can't reach r2:denson9874-ota", "connection reset")
        self.assertNotIn("SHOULD-NOT-SHOW", p.stdout + p.stderr)
        self.assertIn("<redacted>", p.stderr)
        self.assertEqual(self.snapshot(), {})
        p = self.run_publish("cheetah", z, env={"FAKE_RCLONE_FAIL": "copyto"})
        self.assertFAIL(p, "upload to")
        self.assertNotIn("SHOULD-NOT-SHOW", p.stdout + p.stderr)
        self.assertEqual(self.snapshot(), {})

    def test_missing_bucket(self):
        # rclone lists a missing bucket as a missing folder (exit 3): it isn't taken for an empty one
        z = self.make_release()
        for args in (("--dry-run",), ()):
            with self.subTest(args=args):
                p = self.run_publish("cheetah", z, "--remote", "r2:denson9874-otaa", *args)
                self.assertFAIL(p, "can't reach r2:denson9874-otaa", "rclone exit 3")
        self.assertEqual(self.uploads(), [])
        self.assertEqual(self.snapshot(), {})

    def test_flasher_listing_failure(self):
        # Only exit 3 is an empty flasher/: any other failure to list it is never taken for one,
        # or another build's file under this name would be written over
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        self.put(b"another build", "cheetah", "flasher", name)
        self.put(f"{sha256(b'another build')}  {name}\n".encode(), "cheetah", "flasher", name + ".sha256")
        before = self.snapshot()
        for rc in ("1", "2", "4", "5"):
            with self.subTest(rc=rc):
                p = self.run_publish("cheetah", z, env={
                    "FAKE_RCLONE_FAIL": "lsf", "FAKE_RCLONE_FAIL_RC": rc,
                    "FAKE_RCLONE_FAIL_MATCH": f"--files-only {FLASHER}/"})
                self.assertFAIL(p, f"can't list {FLASHER}/", f"rclone exit {rc}")
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(self.uploads(), [])

    def test_size_read_failure_is_not_a_missing_file(self):
        z = self.make_release(stock=False)
        p = self.run_publish("cheetah", z, env={"FAKE_RCLONE_FAIL": "lsf", "FAKE_RCLONE_FAIL_RC": "5",
                                                "FAKE_RCLONE_FAIL_MATCH": "--format s"})
        self.assertFAIL(p, f"can't read the size of {FLASHER}/{os.path.basename(z)}", "rclone exit 5", "connection reset")
        self.assertNotIn("not there", p.stderr)
        self.assertFalse(os.path.exists(self.bucket("cheetah", "flasher.json")))

    def test_upload_cut_short(self):
        z = self.make_release(stock=False)
        p = self.run_publish("cheetah", z, env={"FAKE_RCLONE_TRUNCATE": "-fastboot.zip"})
        self.assertFAIL(p, f"not {os.path.getsize(z)} bytes")
        self.assertFalse(os.path.exists(self.bucket("cheetah", "flasher.json")))

    def test_manifest_read_back_checked(self):
        p = self.run_publish("cheetah", self.make_release(), env={"FAKE_RCLONE_TRUNCATE": "flasher.json"})
        self.assertFAIL(p, "read back")

    def test_manifest_read_back_without_the_release(self):
        # Another run wrote flasher.json over it, validly, without this release
        other = {"schema": 1, "device": "cheetah", "updated": "2026-10-31T00:00:00Z",
                 "releases": [self.entry("ExpressiveOS-17.0-20261031-cheetah-2.0-OFFICIAL")]}
        env = self.hook(
            "if phase == 'after' and args[0] == 'copyto' and args[3].endswith('/flasher.json'):\n"
            f"    open(bucket(args[3]), 'w').write({json.dumps(other)!r})\n")
        p = self.run_publish("cheetah", self.make_release(), env=env)
        self.assertFAIL(p, "doesn't list ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL when read back")

    def test_manifest_read_again_after_the_uploads(self):
        # A release another run listed during the uploads stays listed
        z = self.make_release()
        self.put_manifest([])
        other = {"schema": 1, "device": "cheetah", "updated": "2026-10-31T00:00:00Z",
                 "releases": [self.entry("ExpressiveOS-17.0-20261025-cheetah-1.0-OFFICIAL", channel="testers")]}
        env = self.hook(
            "if phase == 'before' and args[0] == 'copyto' and args[3].endswith('-fastboot.zip'):\n"
            f"    open(bucket({REMOTE + '/expressiveos/cheetah/flasher.json'!r}), 'w').write({json.dumps(other)!r})\n")
        self.assertOK(self.run_publish("cheetah", z, env=env))
        self.assertEqual([e["name"] for e in self.manifest()["releases"]],
                         ["ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", "ExpressiveOS-17.0-20261025-cheetah-1.0-OFFICIAL"])

    # -- what goes to R2 is what was hashed

    def test_r2_sidecar_checked_before_the_zip_goes_up(self):
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        p = self.run_publish("cheetah", z, env={"FAKE_RCLONE_TRUNCATE": ".zip.sha256"})
        self.assertFAIL(p, f"{FLASHER}/{name}.sha256 doesn't read back")
        self.assertEqual(self.uploads(), [f"{FLASHER}/{name}.sha256"])

    def test_local_sidecar_rewritten_before_its_upload(self):
        # As a candidate run's `sha256sum ... > <zip>.sha256` leaves it while it hashes: the line
        # checked at the start is what goes up, never what the file holds by then
        z = self.make_release()
        with open(z + ".sha256", "rb") as f:
            line = f.read()
        env = self.hook(
            "if phase == 'before' and args[0] == 'copyto' and args[3].endswith('.sha256'):\n"
            f"    open({z + '.sha256'!r}, 'w').close()\n")
        self.assertOK(self.run_publish("cheetah", z, env=env))
        with open(self.bucket("cheetah", "flasher", os.path.basename(z) + ".sha256"), "rb") as f:
            self.assertEqual(f.read(), line)

    def test_stock_image_changed_during_the_zip_upload(self):
        # A candidate run's cp over the stock image while the zip goes up: R2 gets the one hashed
        z = self.make_release()
        spath = z[:-len("-fastboot.zip")] + "-init_boot-stock.img"
        with open(spath, "rb") as f:
            original = f.read()
        env = self.hook(
            "if phase == 'before' and args[0] == 'copyto' and args[3].endswith('-fastboot.zip'):\n"
            f"    f = open({spath!r}, 'r+b'); f.seek(-1, 2); f.write(b'X'); f.close()\n")
        self.assertOK(self.run_publish("cheetah", z, env=env))
        with open(spath, "rb") as f:
            self.assertNotEqual(f.read(), original)
        with open(self.bucket("cheetah", "flasher", os.path.basename(spath)), "rb") as f:
            self.assertEqual(f.read(), original)
        self.assertEqual(self.manifest()["releases"][0]["initBootStock"]["sha256"], sha256(original))

    def test_zip_changed_before_its_upload(self):
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        with open(z, "rb") as f:
            original = f.read()
        changes = {
            "written to": f"f = open({z!r}, 'r+b'); f.seek(-1, 2); b = f.read(1); f.seek(-1, 2); f.write(bytes([b[0] ^ 255])); f.close()",
            "replaced": f"open({z + '.new'!r}, 'wb').write(open({z!r}, 'rb').read()); os.replace({z + '.new'!r}, {z!r})",
            "a folder now": f"os.remove({z!r}); os.mkdir({z!r})",
        }
        for case, code in changes.items():
            with self.subTest(case):
                shutil.rmtree(self.bucket(), ignore_errors=True)
                if os.path.isdir(z):
                    os.rmdir(z)
                with open(z, "wb") as f:
                    f.write(original)
                if os.path.exists(self.log):
                    os.remove(self.log)
                env = self.hook(
                    "if phase == 'before' and args[0] == 'copyto' and args[3].endswith('-fastboot.zip.sha256'):\n"
                    f"    {code}\n")
                p = self.run_publish("cheetah", z, env=env)
                self.assertFAIL(p, "changed since it was hashed")
                self.assertEqual(self.uploads(), [f"{FLASHER}/{name}.sha256"])
                self.assertFalse(os.path.exists(self.bucket("cheetah", "flasher.json")))

    def test_zip_changed_during_its_upload(self):
        z = self.make_release(stock=False)
        name = os.path.basename(z)
        env = self.hook(
            "if phase == 'before' and args[0] == 'copyto' and args[3].endswith('-fastboot.zip'):\n"
            f"    f = open({z!r}, 'r+b'); f.seek(-1, 2); b = f.read(1); f.seek(-1, 2); f.write(bytes([b[0] ^ 255])); f.close()\n")
        p = self.run_publish("cheetah", z, env=env)
        self.assertFAIL(p, "changed while it was uploaded", f"Remove {FLASHER}/{name} and {FLASHER}/{name}.sha256")
        self.assertFalse(os.path.exists(self.bucket("cheetah", "flasher.json")))

    def test_symlinked_zip_goes_up_from_the_file_itself(self):
        z = self.make_release(stock=False)
        store = os.path.join(self.tmp, "store")
        os.makedirs(store)
        real = os.path.join(store, os.path.basename(z))
        os.replace(z, real)
        os.symlink(real, z)
        self.assertOK(self.run_publish("cheetah", z))
        ups = [c for c in self.calls() if c[0] == "copyto" and c[3].endswith("-fastboot.zip")]
        self.assertEqual([c[2] for c in ups], [os.path.realpath(real)])

    def test_existing_manifest_unreadable(self):
        self.put_manifest([])
        p = self.run_publish("cheetah", self.make_release(), env={"FAKE_RCLONE_FAIL": "cat"})
        self.assertFAIL(p, "can't read", "flasher.json")
        self.assertEqual(self.uploads(), [])


class UnitTest(unittest.TestCase):
    def test_sidecar_sha256(self):
        h = "0123456789abcdef" * 4
        self.assertEqual(fp.sidecar_sha256(f"{h}  a.zip\n".encode(), "a.zip"), h)
        self.assertEqual(fp.sidecar_sha256(f"{h}  a.zip".encode(), "a.zip"), h)
        for bad in (f"{h}  b.zip\n", f"{h} a.zip\n", f"{h}  a.zip\n\n", f"{h.upper()}  a.zip\n", f"\\{h}  a.zip\n"):
            self.assertIsNone(fp.sidecar_sha256(bad.encode(), "a.zip"), bad)

    def test_ties_put_the_new_release_first(self):
        e = FlasherPublishTest.entry("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL", published="2026-10-30T00:00:00Z")
        f = FlasherPublishTest.entry("ExpressiveOS-17.0-20261030-cheetah-1.1-OFFICIAL", published="2026-10-30T00:00:00Z")
        kept, gone = fp.plan_releases([e], f, 1)
        self.assertEqual(kept, [f])
        self.assertEqual(gone, [e["zip"]["file"], e["initBootStock"]["file"]])

    def test_replaced_release_keeps_its_files(self):
        e = FlasherPublishTest.entry("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL")
        new = dict(e, published="2026-10-31T00:00:00Z", initBootStock=None, root=None)
        kept, gone = fp.plan_releases([e], new, 2)
        self.assertEqual(kept, [new])
        self.assertEqual(gone, [e["initBootStock"]["file"]])   # the zip is still listed

    def test_hash_stream_across_chunks(self):
        with tempfile.TemporaryDirectory() as t:
            path = os.path.join(t, "big")
            data = os.urandom(1024) * (2 * fp.CHUNK // 1024) + b"tail"   # two whole 8 MiB reads and a bit
            with open(path, "wb") as f:
                f.write(data)
            with open(path, "rb") as f:
                self.assertEqual(fp.hash_stream(f), (sha256(data), len(data)))

    def test_hash_stream_reads_8_mib_at_a_time(self):
        # The zips are 5-7 GB: never read whole
        import io
        data = os.urandom(1024) * (3 * fp.CHUNK // 1024) + b"tail"

        class Reader:
            def __init__(self):
                self.f, self.sizes = io.BytesIO(data), []

            def readinto(self, b):
                self.sizes.append(len(b))
                return self.f.readinto(b)

            def read(self, *_):
                raise AssertionError("read() instead of readinto() of a CHUNK")
        r = Reader()
        self.assertEqual(fp.hash_stream(r), (sha256(data), len(data)))
        self.assertEqual(fp.CHUNK, 8 << 20)
        self.assertEqual(set(r.sizes), {fp.CHUNK})
        self.assertEqual(len(r.sizes), 5)   # 3 whole, the tail, the end

    def test_readme_publishes_from_folders_nothing_rewrites(self):
        # check/ is replaced by each candidate run: testers' builds go from testers/, as eos-pack.sh
        # --testers names them on its TESTERS line
        with open(os.path.join(HERE, "README.md")) as f:
            runs = [line for line in f if "flasher_publish.py cheetah ~/" in line]
        self.assertTrue(runs)
        for line in runs:
            self.assertNotIn("/check/", line)
        self.assertTrue(any("/testers/" in line and "--testers" in line for line in runs))

    def test_rnum(self):
        self.assertEqual(fp.rnum("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL"), 1)
        self.assertEqual(fp.rnum("ExpressiveOS-17.0-20261030-cheetah-1.0-OFFICIAL-r12"), 12)

    def test_redact(self):
        self.assertNotIn("abc", fp.redact("secret_access_key=abc access_key_id: abc X-Amz-Signature=abc&x=1"))

    def test_script_is_executable(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        with open(SCRIPT) as f:
            self.assertTrue(f.readline().startswith("#!/usr/bin/env "))


if __name__ == "__main__":
    unittest.main()
