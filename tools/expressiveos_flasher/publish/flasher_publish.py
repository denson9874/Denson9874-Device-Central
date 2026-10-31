#!/usr/bin/env -S python3 -I
"""Publish an ExpressiveOS release for the web flasher (tools/expressiveos_flasher/): its
fastboot zip (eos-pack.sh) and, for a KernelSU Next build, its stock init_boot, uploaded to
the R2 bucket the flasher's Worker reads, then listed in the device's flasher.json.

  flasher_publish.py <device> <path to ...-fastboot.zip> [--testers] [--remote r2:denson9874-ota]
                     [--rclone ~/bin/rclone] [--keep N] [--dry-run]

The zip must match the .sha256 beside it, as must <base>-init_boot-stock.img when it's there
(then the flasher offers KernelSU Next or no root; without it the build has no KernelSU Next).
The zip must hold what a clean flash needs, for this phone only (android-info.txt: 'require
board=<device>' and no other board/product line, as eos-pack.sh writes it).

R2 (tools/ota_mirror/README.md for the rclone remote), nothing else ever written:
  <remote>/expressiveos/<device>/flasher/<file> and <file>.sha256          (a release's files)
  <remote>/expressiveos/<device>/flasher/testers/<file> and <file>.sha256  (a --testers build's)
  <remote>/expressiveos/<device>/flasher.json                              (the manifest, both channels)
Each channel has its own folder, so a testers build and a release may have the same name. A
published name is never overwritten with another file: a name the run's channel folder already
holds with the same sha256 is left as it is (a re-run), with another one the run fails. What goes
to R2 is what was hashed: the stock init_boot and each .sha256 from this run's private copies,
the zip from the file itself, which must not change from its hashing to the end of its upload.
The manifest lists each channel's newest --keep releases (2 unless set); the files of
releases it no longer lists are printed as "no longer listed: <remote path>" and left in R2.
One run per device at a time (~/.expressiveos-flasher-<device>.lock).
--dry-run does every check and every read of R2 but writes nothing there.
Run it with python3 -I. The last line is FLASHER_PUBLISH=OK or FLASHER_PUBLISH=FAIL.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from typing import BinaryIO, NoReturn

DEVICES = ("cheetah", "husky", "kodiak", "grizzly", "cubs", "yogi")
DEFAULT_REMOTE = "r2:denson9874-ota"
DEFAULT_RCLONE = "~/bin/rclone"
DEFAULT_KEEP = 2
CHANNELS = ("release", "testers")
# Each channel's folder in expressiveos/<device>/, as the Worker serves them: /dl/<device>/<file>
# from flasher/, /dl/<device>/testers/<file> from flasher/testers/
CHANNEL_DIRS = {"release": "flasher", "testers": "flasher/testers"}
ROOT_KSUN = "kernelsu-next"
# What `fastboot update` and the flasher need from the zip
REQUIRED_ENTRIES = ("fastboot-info.txt", "android-info.txt", "init_boot.img", "vbmeta.img", "super_empty.img")
ZIP_SUFFIX = "-fastboot.zip"
STOCK_SUFFIX = "-init_boot-stock.img"
CHUNK = 8 << 20                 # the zips are 5-7 GB: hashed in 8 MiB reads
STOCK_MAX = 64 << 20            # an init_boot image is 8 MiB: anything past this isn't one
BOOT_MAGIC = b"ANDROID!"        # the first bytes of a boot image, init_boot's too
RCLONE_DIR_NOT_FOUND = 3        # rclone's exit status for a directory that doesn't exist (yet)
RCLONE_FILE_NOT_FOUND = 4       # and for a file that doesn't
READ_TIMEOUT = 900              # seconds, for every rclone call but an upload

REMOTE_RE = re.compile(r"[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*", re.ASCII)
# A release's name, of any device, to tell a wrong device from a wrong name
ANY_DEVICE_RE = re.compile(r"ExpressiveOS-\d+\.\d+-\d{8}-([a-z0-9]+)-[0-9][0-9.]*-[A-Za-z]+(?:-r\d+)?-fastboot\.zip", re.ASCII)
SHA_LINE_RE = re.compile(r"([0-9a-f]{64})  ([^\n\r]+)", re.ASCII)
# android-info.txt lines that say which phones the zip is for
BOARD_LINE_RE = re.compile(r"(?:^|\s)(?:board|product)\s*=", re.ASCII)
# A line AOSP fastboot reads as a requirement (ParseRequirementLine; src/fastboot/android-info.ts)
REQUIREMENT_RES = (re.compile(r"(require\s+|reject\s+)?\s*(\S+)\s*=\s*(.*)"),
                   re.compile(r"require-for-product:\s*(\S+)\s+(\S+)\s*=\s*(.*)"))
ISO_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}", re.ASCII)
ISO_TIME_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", re.ASCII)
SHA256_RE = re.compile(r"[0-9a-f]{64}", re.ASCII)
# Whatever rclone prints on a failure is shown without anything that looks like a credential
SECRET_RE = re.compile(
    r"(?i)\b(access_key_id|secret_access_key|session_token|token|password|pass|secret|key|"
    r"x-amz-credential|x-amz-signature|x-amz-security-token|signature|credential)(\s*[=:]\s*)[^\s&]+")


class Fail(Exception):
    """A check failed: main() prints 'FAIL: <message>' on stderr and FLASHER_PUBLISH=FAIL."""


def fail(msg: str) -> NoReturn:
    raise Fail(msg)


def release_re(device: str, suffix: str) -> re.Pattern[str]:
    """A release name of <device> (groups: android, yyyymmdd, version, type, -rN) ending in suffix."""
    return re.compile(r"ExpressiveOS-(\d+\.\d+)-(\d{8})-" + re.escape(device)
                      + r"-([0-9][0-9.]*)-([A-Za-z]+)(-r\d+)?" + re.escape(suffix), re.ASCII)


def is_release_file(device: str, name: str) -> bool:
    """name is one of <device>'s release files (a zip, a stock init_boot, or the .sha256 of one)."""
    return any(release_re(device, suffix + side).fullmatch(name)
               for suffix in (ZIP_SUFFIX, STOCK_SUFFIX) for side in ("", ".sha256"))


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def file_ident(st: os.stat_result) -> tuple[int, int, int, int]:
    """What a write to the file, or another file put in its place, changes. Not ctime: eos-pack.sh
    makes a testers/ zip a hard link of check/'s, and removing check/'s link on its next candidate
    run changes the link count, and so the ctime, of the file testers/ still names."""
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def hash_stream(f: BinaryIO) -> tuple[str, int]:
    """The sha256 and size of what f holds from where it is, read in CHUNK reads."""
    h = hashlib.sha256()
    size = 0
    view = memoryview(bytearray(CHUNK))
    while True:
        n = f.readinto(view)
        if not n:
            break
        h.update(view[:n])
        size += n
    return h.hexdigest(), size


def sidecar_sha256(data: bytes, name: str) -> str | None:
    """The sha256 in data if it's exactly the one line sha256sum writes for name, else None."""
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return None
    if text.endswith("\n"):
        text = text[:-1]
    m = SHA_LINE_RE.fullmatch(text)
    if not m or m.group(2) != name:
        return None
    return m.group(1)


def read_sidecar(path: str, name: str) -> str:
    """The sha256 the <name>.sha256 beside path names (sha256sum's one line)."""
    side = path + ".sha256"
    if not os.path.isfile(side):
        fail(f"no {name}.sha256 beside {path}")
    try:
        with open(side, "rb") as f:
            data = f.read(4097)
    except OSError as e:
        fail(f"can't read {side}: {e.strerror or e}")
    want = sidecar_sha256(data, name)
    if want is None:
        fail(f"{side} isn't the one line '<sha256>  {name}' sha256sum writes")
    return want


def open_regular(path: str) -> tuple[BinaryIO, os.stat_result]:
    """path opened for reading, and its stat, if it's a regular file (never blocks on a FIFO)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as e:
        fail(f"can't read {path}: {e.strerror or e}")
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        fail(f"{path} isn't a file")
    return os.fdopen(fd, "rb"), st


def write_private(path: str, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def wrong_hash(path: str, got: str, want: str) -> NoReturn:
    fail(f"{path} isn't the file its .sha256 names (sha256 {got}, not {want}): changed since it was packed?")


@dataclass
class LocalFile:
    path: str           # as given, absolute: what messages name
    name: str           # its name in R2, as here
    size: int
    sha256: str
    upload: str         # what rclone reads: the file itself (its real path), or this run's private copy
    ident: tuple | None  # the file's file_ident() when it was hashed; None for a private copy
    sidecar: str        # this run's private copy of its checked .sha256 line, what goes to R2

    def manifest(self) -> dict:
        return {"file": self.name, "size": self.size, "sha256": self.sha256}

    def unchanged(self) -> bool:
        """What rclone reads is still the file hashed: the same one, never written to since."""
        if self.ident is None:
            return True
        try:
            return file_ident(os.stat(self.upload, follow_symlinks=False)) == self.ident
        except OSError:
            return False


def private_sidecar(tmp: str, name: str, sha: str) -> str:
    path = os.path.join(tmp, name + ".sha256")
    write_private(path, f"{sha}  {name}\n".encode("ascii"))
    return path


def check_stock(path: str, name: str, tmp: str) -> LocalFile:
    """The stock init_boot, as its .sha256 says, read once (it's 8 MiB) into this run's private
    copy: what goes to R2 is what was hashed, whatever happens to path meanwhile."""
    want = read_sidecar(path, name)
    f, _ = open_regular(path)
    chunks, size = [], 0
    with f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            size += len(b)
            if size > STOCK_MAX:
                fail(f"{path} is over {STOCK_MAX} bytes: not an init_boot image")
            chunks.append(b)
    data = b"".join(chunks)
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        wrong_hash(path, got, want)
    # The flasher lists no release with an empty file, and flashes this one to init_boot
    if not data:
        fail(f"{path} is empty: not an init_boot image")
    if not data.startswith(BOOT_MAGIC):
        fail(f"{path} doesn't start with {BOOT_MAGIC.decode()}: not an init_boot image")
    copy = os.path.join(tmp, name)
    write_private(copy, data)
    return LocalFile(path=path, name=name, size=size, sha256=got, upload=copy, ident=None,
                     sidecar=private_sidecar(tmp, name, got))


def check_zip(zfile: BinaryIO, path: str, name: str, device: str) -> list[str]:
    """The fastboot zip holds what a clean flash needs, for <device> only. Returns
    android-info.txt's requirements (its non-empty lines, stripped)."""
    try:
        zfile.seek(0)
        with zipfile.ZipFile(zfile) as zf:
            infos = zf.infolist()
            names = [i.filename for i in infos]
            twice = sorted(n for n, c in collections.Counter(names).items() if c > 1)
            if twice:
                fail(f"{name} holds {', '.join(map(repr, twice))} more than once")
            missing = [n for n in REQUIRED_ENTRIES if n not in names]
            if missing:
                fail(f"{name} has no {', '.join(missing)}: not a fastboot update zip eos-pack.sh made")
            # eos-pack.sh stores (zip -0): the flasher reads each image straight out of the zip
            packed = [i.filename for i in infos if i.compress_type != zipfile.ZIP_STORED]
            if packed:
                fail(f"{name} compresses {', '.join(map(repr, packed[:5]))}: the flasher needs a stored zip (eos-pack.sh's zip -0)")
            info = zf.getinfo("android-info.txt")
            if info.file_size > 65536:
                fail(f"{name}'s android-info.txt is {info.file_size} bytes: not an android-info.txt")
            raw = zf.read(info)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, OSError, RuntimeError, NotImplementedError, ValueError) as e:
        fail(f"can't read {path} as a zip: {e}")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{name}'s android-info.txt isn't text")
    lines = text.split("\n")
    want = f"require board={device}"
    boards = [line.strip() for line in lines if BOARD_LINE_RE.search(line)]
    if want not in lines or len(boards) != 1:
        fail(f"{name}'s android-info.txt doesn't say '{want}' only (its board/product lines: {boards!r:.300})")
    # fastboot skips a line it can't read (a syntax error), and the flasher warns about one: a
    # broken line means a broken build, so it's caught here, before anyone installs it
    unreadable = [line for line in (x.rstrip("\r") for x in lines)
                  if line.strip() and not any(r.fullmatch(line) for r in REQUIREMENT_RES)]
    if unreadable:
        fail(f"{name}'s android-info.txt has lines that aren't requirements fastboot can read: {unreadable!r:.300}")
    return [line.strip() for line in lines if line.strip()]


def rnum(name: str) -> int:
    """A release name's -rN (a second release of the day is -r2...), 1 without one."""
    m = re.search(r"-r(\d+)\Z", name, re.ASCII)
    return int(m.group(1)) if m else 1


def sort_key(entry: dict) -> tuple:
    """Newest first (reversed): the build's date, then when it was first published, then -rN.
    -rN counts only the zips of one name (one Android version, ExpressiveOS version and type) on
    one day, so a 1.1 built after 1.0-r3 that day has none: the publish time orders them."""
    return (entry["date"], entry["published"], rnum(entry["name"]))


def key(e: dict) -> tuple[str, str]:
    """What tells a manifest's entries apart: a name may be in both channels."""
    return (e["name"], e["channel"])


def entry_error(e: object, device: str) -> str | None:
    """Why e isn't a release entry of <device>'s flasher.json, or None."""
    if not isinstance(e, dict):
        return "a release isn't an object"
    name = e.get("name")
    if not isinstance(name, str) or not release_re(device, "").fullmatch(name):
        return f"a release's name {name!r:.120} isn't an ExpressiveOS {device} release's"
    if e.get("channel") not in CHANNELS:
        return f"{name}'s channel {e.get('channel')!r:.40} isn't one of {', '.join(CHANNELS)}"
    for k in ("android", "version", "type"):
        if not isinstance(e.get(k), str):
            return f"{name} has no {k}"
    if not isinstance(e.get("date"), str) or not ISO_DATE_RE.fullmatch(e["date"]):
        return f"{name}'s date isn't YYYY-MM-DD"
    if not isinstance(e.get("published"), str) or not ISO_TIME_RE.fullmatch(e["published"]):
        return f"{name}'s published time isn't YYYY-MM-DDTHH:MM:SSZ"

    def file_error(f: object, want: str) -> str | None:
        if not isinstance(f, dict) or f.get("file") != want:
            return f"isn't {want}"
        # As the flasher reads it: a release with an empty file isn't listed
        if type(f.get("size")) is not int or f["size"] <= 0:
            return "has no size"
        if not isinstance(f.get("sha256"), str) or not SHA256_RE.fullmatch(f["sha256"]):
            return "has no sha256"
        return None

    why = file_error(e.get("zip"), name + ZIP_SUFFIX)
    if why:
        return f"{name}'s zip {why}"
    stock = e.get("initBootStock", "missing")
    if stock is not None:
        why = file_error(stock, name + STOCK_SUFFIX)
        if why:
            return f"{name}'s initBootStock {why}"
    want_root = None if stock is None else ROOT_KSUN
    if e.get("root", "missing") != want_root:
        return f"{name}'s root isn't {json.dumps(want_root)}, as its initBootStock says"
    reqs = e.get("requirements")
    if not isinstance(reqs, list) or not all(isinstance(r, str) for r in reqs):
        return f"{name}'s requirements aren't a list of lines"
    return None


def parse_manifest(data: bytes, device: str, where: str) -> list[dict]:
    """flasher.json's releases. Anything else is a failure: an invalid manifest is never replaced."""
    def bad(why: str) -> NoReturn:
        fail(f"{where} isn't a valid flasher manifest ({why}): it's never replaced, fix or remove it by hand")
    try:
        m = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        bad(f"not JSON: {e}")
    if not isinstance(m, dict):
        bad("not a JSON object")
    # The integer 1, as the flasher reads it (never true or 1.0)
    if type(m.get("schema")) is not int or m["schema"] != 1:
        bad(f"schema {m.get('schema')!r:.40}, not 1")
    if m.get("device") != device:
        bad(f"device {m.get('device')!r:.40}, not {device!r}")
    if not isinstance(m.get("releases"), list):
        bad("no releases list")
    # A name may be in both channels (each has its own folder), only once in each
    seen = set()
    for e in m["releases"]:
        why = entry_error(e, device)
        if why:
            bad(why)
        if key(e) in seen:
            bad(f"{e['name']} is listed twice in the {e['channel']} channel")
        seen.add(key(e))
    return m["releases"]


def plan_releases(existing: list[dict], entry: dict, keep: int) -> tuple[list[dict], list[tuple[str, str]]]:
    """The releases the manifest lists with entry (newest first, each channel's newest keep),
    and the files no release listed any more (those of dropped or replaced releases), each as
    (channel, file): the channels' files are in different folders, so one is no longer listed
    when no kept release of its own channel lists it."""
    others = [e for e in existing if key(e) != key(entry)]
    replaced = [e for e in existing if key(e) == key(entry)]
    # Stable: the new release goes first among equals
    ordered = sorted([entry] + others, key=sort_key, reverse=True)
    kept, dropped = [], []
    count: collections.Counter[str] = collections.Counter()
    for e in ordered:
        count[e["channel"]] += 1
        (kept if count[e["channel"]] <= keep else dropped).append(e)

    def files(e: dict) -> list[tuple[str, str]]:
        out = [(e["channel"], e["zip"]["file"])]
        if e.get("initBootStock"):
            out.append((e["channel"], e["initBootStock"]["file"]))
        return out
    listed = {f for e in kept for f in files(e)}
    gone: list[tuple[str, str]] = []
    for e in dropped + replaced:
        for f in files(e):
            if f not in listed and f not in gone:
                gone.append(f)
    return kept, gone


def redact(text: str) -> str:
    return SECRET_RE.sub(r"\1\2<redacted>", text)


def tail(stderr: bytes, n: int = 3) -> str:
    lines = stderr.decode("utf-8", "replace").strip().splitlines()[-n:]
    return "\n".join("  " + redact(line)[:300] for line in lines)


def take_lock(device: str) -> int:
    """One run per device at a time on this server: two would each write flasher.json without
    the other's release, or both take a name. Held until the process ends."""
    path = os.path.join(os.path.expanduser("~"), f".expressiveos-flasher-{device}.lock")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError as e:
        fail(f"can't open {path}: {e.strerror or e}")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        fail(f"another flasher_publish.py run for {device} holds {path}: one at a time, run this again after it")
    except OSError as e:
        os.close(fd)
        fail(f"can't lock {path}: {e.strerror or e}")
    return fd


class R2:
    """The device's part of the bucket, through rclone, for one channel's run: nothing but the
    manifest and the files directly in that channel's folder is ever written."""

    def __init__(self, rclone: str, remote: str, device: str, channel: str, dry_run: bool):
        self.rclone = rclone
        self.remote = remote
        self.dry_run = dry_run
        self.device = device
        self.channel = channel
        self.device_dir = f"{remote}/expressiveos/{device}"
        self.channel_dir = self.dir_of(channel)
        self.manifest = f"{self.device_dir}/flasher.json"

    def dir_of(self, channel: str) -> str:
        """A channel's folder: flasher/ for release, flasher/testers/ for testers."""
        return f"{self.device_dir}/{CHANNEL_DIRS[channel]}"

    def path(self, name: str, channel: str | None = None) -> str:
        """Where a file of this run's channel (or of another channel) is in R2."""
        return f"{self.dir_of(channel or self.channel)}/{name}"

    def _run(self, args: list[str], timeout: float | None = READ_TIMEOUT) -> subprocess.CompletedProcess:
        try:
            return subprocess.run([self.rclone, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            fail(f"rclone {args[0]} {args[-1]} didn't finish in {timeout} s")
        except OSError as e:
            fail(f"can't run {self.rclone}: {e.strerror or e}")

    def _failed(self, p: subprocess.CompletedProcess, what: str) -> NoReturn:
        if p.stderr.strip():
            print(tail(p.stderr), file=sys.stderr)
        fail(f"{what} (rclone exit {p.returncode})")

    def reach(self) -> None:
        """The remote and its bucket are there: a missing bucket lists as an empty folder below."""
        p = self._run(["lsf", self.remote])
        if p.returncode != 0:
            self._failed(p, f"can't reach {self.remote} (rclone's {self.remote.split(':')[0]}: remote and its bucket, tools/ota_mirror/README.md)")

    def list_files(self, d: str) -> set[str]:
        """The files directly in d; none while d doesn't exist (rclone exits 3). Never a folder
        in d, such as flasher/'s testers/ (lsf prints a folder with a trailing slash)."""
        p = self._run(["lsf", "--files-only", d + "/"])
        if p.returncode == RCLONE_DIR_NOT_FOUND:
            return set()
        if p.returncode != 0:
            self._failed(p, f"can't list {d}/ (rclone's remote, tools/ota_mirror/README.md)")
        return {line for line in p.stdout.decode("utf-8", "replace").splitlines() if line and not line.endswith("/")}

    def cat(self, path: str) -> bytes:
        p = self._run(["cat", path])
        if p.returncode != 0:
            self._failed(p, f"can't read {path}")
        return p.stdout

    def size(self, path: str) -> int | None:
        """path's size in R2; None when it isn't there. Any other rclone failure is a failure."""
        p = self._run(["lsf", "--format", "s", path])
        if p.returncode in (RCLONE_DIR_NOT_FOUND, RCLONE_FILE_NOT_FOUND):
            return None
        if p.returncode != 0:
            self._failed(p, f"can't read the size of {path}")
        out = p.stdout.decode("ascii", "replace").split()
        if len(out) != 1 or not out[0].isdigit():
            return None
        return int(out[0])

    def copyto(self, local: str, remote: str) -> None:
        # Only ever the manifest, or a release's file directly in this run's channel folder (named as
        # the Worker serves them): never target-files/, never another device's, never the other
        # channel's folder, never flasher/'s testers/ itself
        folder, _, name = remote.rpartition("/")
        inside = folder == self.channel_dir and is_release_file(self.device, name)
        if self.dry_run or not (remote == self.manifest or inside):
            fail(f"internal error: refusing to write {remote}")
        p = self._run(["copyto", "--s3-no-check-bucket", local, remote], timeout=None)
        if p.returncode != 0:
            self._failed(p, f"the upload to {remote} failed")

    def remote_sha256(self, name: str) -> str | None:
        return sidecar_sha256(self.cat(self.path(name + ".sha256")), name)

    def state(self, f: LocalFile) -> str:
        """Where the run's channel folder stands with f's name: 'new' (neither it nor its .sha256
        there), 'sidecar' (only its .sha256, ours: an upload cut short) or 'published' (both there,
        ours). Another file under its name, or a .sha256 that isn't ours, is a failure: a name is
        never overwritten. The other channel's folder is never looked at: its names are its own."""
        listing = self.list_files(self.channel_dir)
        remote, side = self.path(f.name), f.name + ".sha256"
        if f.name in listing:
            if side not in listing:
                fail(f"R2 holds {remote} without its .sha256: which build it is can't be told, and a published name is never overwritten (look at it)")
            theirs = self.remote_sha256(f.name)
            if theirs != f.sha256:
                fail(f"another build holds {remote} (its .sha256 says {theirs or 'something else'}, not {f.sha256}): a published name is never overwritten")
            return "published"
        if side in listing:
            theirs = self.remote_sha256(f.name)
            if theirs != f.sha256:
                fail(f"R2's {remote}.sha256 is another build's ({theirs or 'not a sha256sum line'}, not {f.sha256}): a published name is never overwritten")
            return "sidecar"
        return "new"

    def check_size(self, f: LocalFile) -> None:
        size = self.size(self.path(f.name))
        if size != f.size:
            fail(f"R2's {self.path(f.name)} is {'not there' if size is None else f'{size} bytes'}, not {f.size} bytes")

    def publish(self, f: LocalFile) -> None:
        """f and its .sha256 in the channel's folder, unless they're there already. The .sha256 goes
        first, checked: a name is claimed before the long upload, and a cut-short run can be run again."""
        st = self.state(f)
        remote = self.path(f.name)
        if st == "published":
            self.check_size(f)
            print(f"already published: {remote} ({f.size} bytes, the same sha256)")
            return
        if self.dry_run:
            if st == "new":
                print(f"would upload: {remote}.sha256 (the line '{f.sha256}  {f.name}')")
            print(f"would upload: {f.path} -> {remote} ({f.size} bytes)")
            return
        changed = (f"{f.path} changed since it was hashed (written to, or another file put in its place): "
                   "publish from a folder nothing writes into (the release folder or testers/, never check/)")
        if not f.unchanged():
            fail(changed)
        if st == "new":
            self.copyto(f.sidecar, remote + ".sha256")
            if self.remote_sha256(f.name) != f.sha256:
                fail(f"R2's {remote}.sha256 doesn't read back as '{f.sha256}  {f.name}' after its upload")
        if not f.unchanged():
            fail(changed)
        self.copyto(f.upload, remote)
        if not f.unchanged():
            fail(f"{f.path} changed while it was uploaded: R2's {remote} may not be the file its .sha256 names, "
                 f"and flasher.json doesn't list it. Remove {remote} and {remote}.sha256 from R2 by hand "
                 "(rclone deletefile) before running this again")
        # All of it: R2 has its size and the same .sha256
        self.check_size(f)
        if self.remote_sha256(f.name) != f.sha256:
            fail(f"R2's {remote}.sha256 isn't '{f.sha256}  {f.name}' any more")
        print(f"uploaded: {remote} ({f.size} bytes)")

    def read_manifest(self, device: str) -> list[dict] | None:
        """flasher.json's releases, None while there's none (never a failure to read it)."""
        if "flasher.json" not in self.list_files(self.device_dir):
            return None
        return parse_manifest(self.cat(self.manifest), device, f"R2's {self.manifest}")


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:   # a usage error is a FAIL like any other
        fail(f"{message}\n{self.format_usage().rstrip()}")

    def exit(self, status: int = 0, message: str | None = None) -> NoReturn:   # --help: nothing published
        fail(message.strip() if message else "nothing published (--help)")


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = Parser(prog="flasher_publish.py", description=(
        "Publish an ExpressiveOS release for the web flasher. Its files go to R2's expressiveos/<device>/flasher/ "
        "(a testers build's to flasher/testers/), and expressiveos/<device>/flasher.json lists it."))
    p.add_argument("device", help=" | ".join(DEVICES))
    p.add_argument("zip", help="the release's ...-fastboot.zip (eos-pack.sh), its .sha256 beside it")
    p.add_argument("--testers", action="store_true",
                   help="the testers channel, its files in flasher/testers/ (default: the release channel, in flasher/)")
    p.add_argument("--remote", default=DEFAULT_REMOTE, help=f"rclone remote:bucket (default {DEFAULT_REMOTE})")
    p.add_argument("--rclone", default=DEFAULT_RCLONE, help=f"rclone (default {DEFAULT_RCLONE})")
    p.add_argument("--keep", type=int, default=DEFAULT_KEEP, help=f"releases listed per channel (default {DEFAULT_KEEP})")
    p.add_argument("--dry-run", action="store_true", help="check and read R2, write nothing")
    return p.parse_args(argv)


def run(argv: list[str] | None) -> None:
    a = parse_args(argv)
    device = a.device
    if device not in DEVICES:
        fail(f"device {device!r:.40} isn't one of {' '.join(DEVICES)}")
    zip_path = os.path.abspath(a.zip)
    name = os.path.basename(zip_path)
    m = release_re(device, ZIP_SUFFIX).fullmatch(name)
    if not m:
        other = ANY_DEVICE_RE.fullmatch(name)
        if other and other.group(1) != device:
            fail(f"{name} is a {other.group(1)} build, not {device}'s")
        fail(f"{name!r:.200} isn't named ExpressiveOS-<android>-<yyyymmdd>-{device}-<version>-<type>[-rN]{ZIP_SUFFIX}")
    android, ymd, version, rtype, _ = m.groups()
    try:
        date = datetime.datetime.strptime(ymd, "%Y%m%d").date().isoformat()
    except ValueError:
        fail(f"{name}'s date {ymd} isn't a date")
    base = name[:-len(ZIP_SUFFIX)]
    # Its own folder of the bucket, as eos-pack.sh's EOS_R2_REMOTE (and no rclone flag)
    if not REMOTE_RE.fullmatch(a.remote) or a.remote.startswith("-"):
        fail(f"--remote {a.remote!r:.80} isn't <rclone remote>:<bucket>")
    if a.keep < 1:
        fail(f"--keep {a.keep}: the manifest lists at least 1 release per channel")
    rclone = os.path.abspath(os.path.expanduser(a.rclone))
    if not (os.path.isfile(rclone) and os.access(rclone, os.X_OK)):
        fail(f"no rclone at {rclone} (tools/ota_mirror/README.md)")
    if not os.path.isfile(zip_path):
        fail(f"no {zip_path}")
    if not a.dry_run:
        take_lock(device)
    with tempfile.TemporaryDirectory(prefix="flasher-publish.") as tmp:
        publish(a, device, zip_path, name, base, (android, date, version, rtype), rclone, tmp)


def publish(a: argparse.Namespace, device: str, zip_path: str, name: str, base: str,
            meta: tuple[str, str, str, str], rclone: str, tmp: str) -> None:
    android, date, version, rtype = meta
    print(f"== the release: {zip_path}")
    want = read_sidecar(zip_path, name)
    # The zip is opened once: hashed, then read as a zip, from that one file. rclone reads it
    # by its real path, and it must stay that file, unwritten, until its upload has ended
    real = os.path.realpath(zip_path)
    zfile, st = open_regular(real)
    with zfile:
        got, size = hash_stream(zfile)
        ident = file_ident(os.fstat(zfile.fileno()))
        if ident != file_ident(st) or size != st.st_size:
            fail(f"{zip_path} changed while it was hashed: publish from a folder nothing writes into")
        if got != want:
            wrong_hash(zip_path, got, want)
        z = LocalFile(path=zip_path, name=name, size=size, sha256=got, upload=real, ident=ident,
                      sidecar=private_sidecar(tmp, name, got))
        print(f"OK: {name}: {z.size} bytes, sha256 {z.sha256}, as its .sha256 says")
        stock_name = base + STOCK_SUFFIX
        stock_path = os.path.join(os.path.dirname(zip_path), stock_name)
        stock = None
        if os.path.lexists(stock_path):
            if not os.path.isfile(stock_path):
                fail(f"{stock_path} isn't a file")
            stock = check_stock(stock_path, stock_name, tmp)
            print(f"OK: {stock_name}: {stock.size} bytes, sha256 {stock.sha256}: KernelSU Next, or no root with the stock init_boot")
        elif os.path.lexists(stock_path + ".sha256"):
            # A KernelSU Next build whose stock init_boot is gone: never listed as one without root
            fail(f"{stock_name}.sha256 is beside the zip but {stock_name} isn't (cleaned up?): the zip's init_boot would be listed as stock")
        else:
            print(f"note: no {stock_name}: a build without KernelSU Next (root null)")
        requirements = check_zip(zfile, zip_path, name, device)
        if file_ident(os.fstat(zfile.fileno())) != ident:
            fail(f"{zip_path} changed while it was read: publish from a folder nothing writes into")
    if not z.unchanged():
        fail(f"{zip_path} changed since it was hashed: publish from a folder nothing writes into")
    print(f"OK: {name} holds {', '.join(REQUIRED_ENTRIES)}, stored; android-info.txt requires board={device} only")
    channel = "testers" if a.testers else "release"

    r2 = R2(rclone, a.remote, device, channel, a.dry_run)
    files = [z] + ([stock] if stock else [])
    no_stock = (f"{base} was published as a KernelSU Next build, with {stock_name}, which isn't beside {zip_path}: "
                "it would be listed without root. Publish it from the folder that holds its stock init_boot")

    def entry(now: str) -> dict:
        return {
            "name": base,
            "channel": channel,
            "android": android,
            "version": version,
            "type": rtype,
            "date": date,
            "published": now,
            "zip": z.manifest(),
            "initBootStock": stock.manifest() if stock else None,
            "root": ROOT_KSUN if stock else None,
            "requirements": requirements,
        }

    def plan(existing: list[dict] | None) -> tuple[dict, list[str]]:
        now = utc_now()
        new = entry(now)
        why = entry_error(new, device)
        if why:
            fail(f"internal error: {why}")
        # This channel's entry of the name: the other channel's is another build's
        old = next((e for e in existing or [] if key(e) == (base, channel)), None)
        if old is not None and stock is None and old["initBootStock"] is not None:
            fail(no_stock)
        if old is not None and all(old.get(k) == v for k, v in new.items() if k != "published"):
            # The same release again (a re-run): it keeps its place among the others
            new["published"] = old["published"]
        releases, gone = plan_releases(existing or [], new, a.keep)
        if not any(e is new for e in releases):
            fail(f"{base} wouldn't be listed: flasher.json's {channel} channel has {a.keep} newer releases (--keep {a.keep})")
        return {"schema": 1, "device": device, "updated": now, "releases": releases}, gone

    print(f"== R2: {r2.channel_dir}/ and {r2.manifest} ({channel} channel){' (dry run: nothing is written)' if a.dry_run else ''}")
    r2.reach()
    existing = r2.read_manifest(device)
    print(f"OK: {r2.manifest} lists {len(existing)} releases" if existing is not None
          else f"note: no {r2.manifest} yet: a new one")
    # Before anything is uploaded: a bad manifest, or one that wouldn't list this release, fails
    # here, and so does a name another build holds (each is checked again just before its upload)
    plan(existing)
    if stock is None:
        held = r2.list_files(r2.channel_dir) & {stock_name, stock_name + ".sha256"}
        if held:
            fail(f"R2's {r2.channel_dir}/ holds {', '.join(sorted(held))}: {no_stock}")
    for f in files:
        r2.state(f)
    for f in files:
        r2.publish(f)

    print("== manifest")
    if not a.dry_run:
        # Again: the uploads took a while
        existing = r2.read_manifest(device)
    manifest, gone = plan(existing)
    for ch, f in gone:
        print(f"no longer listed: {r2.path(f, ch)}")
        print(f"no longer listed: {r2.path(f, ch)}.sha256")
    text = json.dumps(manifest, indent=2) + "\n"
    if a.dry_run:
        print(f"would write {r2.manifest}:")
        print(text, end="")
        print(f"DRY RUN: {base} not published; nothing was written to R2")
        return
    local = os.path.join(tmp, "flasher.json")
    write_private(local, text.encode("utf-8"))
    r2.copyto(local, r2.manifest)
    back = parse_manifest(r2.cat(r2.manifest), device, f"R2's {r2.manifest} (read back)")
    if not any(key(e) == (base, channel) and e["zip"]["sha256"] == z.sha256 for e in back):
        fail(f"R2's {r2.manifest} doesn't list {base} ({channel}) when read back (written over by another run?)")
    print(f"OK: {r2.manifest} lists {len(back)} releases, {base} ({channel}) among them")
    print(f"PUBLISHED {base} {channel} {r2.manifest}")


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    try:
        run(argv)
    except Fail as e:
        print(f"FAIL: {e}", file=sys.stderr)
        print("FLASHER_PUBLISH=FAIL")
        return 1
    except KeyboardInterrupt:
        print("FAIL: interrupted", file=sys.stderr)
        print("FLASHER_PUBLISH=FAIL")
        return 1
    except Exception as e:  # a bug here: still a FAIL, never a half-told success
        print(f"FAIL: unexpected error: {type(e).__name__}: {redact(str(e))}", file=sys.stderr)
        print("FLASHER_PUBLISH=FAIL")
        return 1
    print("FLASHER_PUBLISH=OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
