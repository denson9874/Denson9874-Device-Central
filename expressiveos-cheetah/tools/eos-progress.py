#!/usr/bin/env python3
"""How the ExpressiveOS build on the server is going, a line per phone: the runner's
expressiveos-progress. Read-only, a few seconds, and fine while a build runs.

It reads these and writes nothing:
  ~/expressiveos-jobs/{build,pack}.{sh,log}: the runner's eos-build and eos-pack tmux sessions.
      The job script names the phones (its "# phones:" line, or build-devices.sh's list), and
      the log holds all that eos-images.sh and eos-pack.sh print. That includes their STEP lines
      (lib.sh's eos_step) and, from older kits, the step headers ("== prepare.sh"...). A release
      session (eos-release.sh: each phone's pack, OTA upload and web installer in turn) is kind
      publish, its steps pack, ota and web.
  ~/expressiveos-build[-<device>].log: a build started some other way (by hand, a routine). It's
      read when no session runs but an eos-images.sh does.
  ~/expressiveos/out/build_progress.pb: Soong's own count of the make's actions (total,
      finished, running, failed), rewritten as each action starts and finishes.
  The make's progress lines in the log ("[ 45% 12345/27000 20m11s remaining] ..."): ninja's
      own estimate of when the make ends, from how long the same actions took before
      (out/.ninja_log).
  This user's processes in the tree: soong_ui and ninja (when the make began),
      ota_from_target_files and the target-files packaging (the steps at the end of a full
      build's make).
  ~/expressiveos-build-times.txt: how long each step of past builds took (lib.sh's eos_step,
      a TIME line per finished step).
  ~/expressiveos-cheetah/devices/<device>.conf: which phones build their kernel (EOS_KERNEL).

It prints these. Every field is always there, "-" when unknown, and times are UTC:
  PROGRESS device=<phone> state=<queued|running|done|failed|skipped>
      step=<wait|prepare|kernel|make|target_files|ota_zip|verify|pack|ota|web|done>
      kind=<full|quick|kernel|modules|testers|release|upload|publish> fresh=<1|0> started=<ISO>
      elapsed_s=<n> done=<n> total=<n> running=<n> failed=<n> eta_s=<n> eta=<ISO>
      eta_basis=<ninja|rate|history|typical|none>
  SESSION name=<eos-build|eos-pack|-> state=<running|done|failed|none> exit=<n> started=<ISO>
  LOG device=<phone> <line>: the session log's last 40 lines (the running phone's, else the
      last phone's), with ANSI codes and control characters dropped, each cut at 400 characters
  TIME <step> device=... kind=... fresh=... at=... secs=<n> [prev=<phone>]: the last 40 lines of
      ~/expressiveos-build-times.txt as they are (prev: the phone whose make ran in the tree
      before this one, from kits since it was added; a change of phone redoes work)
  PROGRESS_OK
Then, after a blank line, the same in words for people, with US Eastern times.

One PROGRESS line goes out per phone of the session, in the order they build (queued phones
too). fresh=1 means the phone's product out wasn't there when its build began, so every module
is built. elapsed_s is the time so far, or the whole time for a phone that's finished. eta is
when the phone should be built and packed. Its basis says where the make's part came from:
  ninja    Soong's estimate (above)
  rate     the make's pace so far (build_progress.pb, since ninja started)
  history  past builds' times (~/expressiveos-build-times.txt)
  typical  this server's measured times, when nothing else is known yet
The other steps come from history, or from typical times.

  eos-progress.py
  eos-progress.py --feed   # the feed files of each phone the last release session released,
                           # from its ~/expressiveos-jobs/ota-<phone>.log as eos-ota.sh printed
                           # them: a FEED line per phone, the "===== OTA_FEED" blocks of those
                           # released, then FEED_OK (every phone released) or FEED_INCOMPLETE
"""
import calendar
import datetime
import os
import re
import statistics
import subprocess
import sys
import time

HOME = os.path.expanduser('~')
TOP = os.path.join(HOME, 'expressiveos')
JOBS = os.path.join(HOME, 'expressiveos-jobs')
KIT = os.path.join(HOME, 'expressiveos-cheetah')
TIMES = os.path.join(HOME, 'expressiveos-build-times.txt')
NOW = time.time()
LOG_LINES, LOG_WIDTH = 40, 400

# Seconds a step takes on this server, for when no past build of the kind is recorded yet.
# From cheetah's full and quick builds of 2026-11-02 (make 13:07 and 2:28, the rest about 6 and
# 4 minutes) and husky's make from scratch of 2026-10-16 (1:05:13). The make's are only used
# when it's known whether the product out was there (fresh)
TYPICAL = {
    ('prepare', None, None): 90, ('kernel', None, None): 120,
    ('make', 'full', '0'): 790, ('make', 'full', '1'): 3900,
    ('make', 'quick', '0'): 150, ('make', 'quick', '1'): 3600,
    ('verify', 'full', None): 100, ('verify', 'quick', None): 40,
    ('pack', 'full', None): 100, ('pack', 'quick', None): 50,
    # A release's pack (cheetah's 9:11, 2026-11-09), OTA upload and web installer (about 5:30 and
    # 3:20 a phone, the runner's jobs that night)
    ('pack', 'upload', None): 550, ('ota', None, None): 330, ('web', None, None): 200,
}
# The end of a full build's make, which prints no progress: the target-files zip, then the OTA
# package, about 50 s and 250 s (cheetah, 2026-11-02)
TAIL = {'target_files': 50, 'ota_zip': 250}
MAKE_STEPS = ('make', 'target_files', 'ota_zip')
BASES = ('ninja', 'rate', 'history', 'typical')


def iso(t):
    return '-' if t is None else time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


def parse_time(s, fmt):
    try:
        return calendar.timegm(time.strptime(s, fmt))
    except ValueError:
        return None


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def read(path, limit=None):
    """The file's bytes (its last <limit> only, when given), or b'' when it can't be read."""
    try:
        with open(path, 'rb') as f:
            if limit:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - limit))
            return f.read()
    except OSError:
        return b''


def go_secs(s):
    """Seconds in a Go duration ("1h2m3s", "45s", "0s"), or None."""
    m = re.fullmatch(r'(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?', s or '')
    if not m or not s:
        return None
    h, mi, se = m.groups()
    return int(h or 0) * 3600 + int(mi or 0) * 60 + float(se or 0)


def varint(b, i):
    v = s = 0
    while i < len(b) and s <= 63:
        c = b[i]
        i += 1
        v |= (c & 0x7f) << s
        s += 7
        if not c & 0x80:
            return v, i
    return None, i


def build_progress(path):
    """Soong's BuildProgress (out/build_progress.pb: total_actions=1, finished_actions=2,
    current_actions=3, failed_actions=4, all varints), or None."""
    b, i, vals = read(path), 0, {}
    if not b:
        return None
    while i < len(b):
        key, i = varint(b, i)
        if key is None or key & 7 != 0:
            return None
        v, i = varint(b, i)
        if v is None:
            return None
        vals[key >> 3] = v
    return {'total': vals.get(1, 0), 'done': vals.get(2, 0), 'running': vals.get(3, 0), 'failed': vals.get(4, 0)}


def processes():
    """This user's processes: (pid, start time, argv, cwd)."""
    out = []
    try:
        with open('/proc/stat') as f:
            btime = next(int(line.split()[1]) for line in f if line.startswith('btime '))
        tck = os.sysconf('SC_CLK_TCK')
        pids = [p for p in os.listdir('/proc') if p.isdigit()]
    except (OSError, StopIteration, ValueError):
        return out
    uid = os.getuid()
    for p in pids:
        try:
            if os.stat('/proc/' + p).st_uid != uid:
                continue
            with open(f'/proc/{p}/cmdline', 'rb') as f:
                argv = [a.decode('utf-8', 'replace') for a in f.read().split(b'\0') if a]
            with open(f'/proc/{p}/stat') as f:
                st = f.read()
            start = btime + int(st[st.rindex(')') + 2:].split()[19]) / tck
            cwd = os.readlink(f'/proc/{p}/cwd')
        except (OSError, ValueError, IndexError):
            continue
        if argv:
            out.append((int(p), start, argv, cwd))
    return out


def environ(pid, name):
    for kv in read(f'/proc/{pid}/environ').split(b'\0'):
        if kv.startswith(name.encode() + b'='):
            return kv.split(b'=', 1)[1].decode('utf-8', 'replace')
    return None


def tmux_running(session):
    try:
        return subprocess.run(['tmux', 'has-session', '-t', '=' + session], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def builds_kernel(d):
    """Whether the phone builds its kernel from source (devices/<device>.conf: EOS_KERNEL=gs-6.1)."""
    conf = read(os.path.join(KIT, 'devices', d + '.conf')).decode('utf-8', 'replace')
    m = re.search(r'^EOS_KERNEL=(\S+)', conf, re.M)
    return m.group(1) == 'gs-6.1' if m else d in ('cheetah', 'husky')


TIME_RE = r'TIME (\w+) device=([a-z0-9]+) kind=(\S+) fresh=(\S+) at=\S+ secs=(\d+)(?: prev=[a-z0-9-]+)?'


def history():
    """Past builds' step times: (step, device, kind, fresh, seconds), oldest first."""
    rows = []
    for line in read(TIMES, 256 * 1024).decode('utf-8', 'replace').splitlines():
        m = re.fullmatch(TIME_RE, line.strip())
        if m:
            rows.append((m.group(1), m.group(2), m.group(3), m.group(4), int(m.group(5))))
    return rows


def recent_times(n=40):
    """The last n TIME lines of EOS_TIMES as they are (step times of the newest builds, for
    measuring where a build's time went without reading the server's files)."""
    lines = [l.strip() for l in read(TIMES, 256 * 1024).decode('utf-8', 'replace').splitlines()]
    return [l for l in lines if re.fullmatch(TIME_RE, l)][-n:]


HIST = []


def estimate(step, d, kind, fresh):
    """(seconds, basis): how long a whole <step> of this build should take: the median of the
    last 5 past ones most like it, else this server's typical time, else (None, 'none')."""
    if kind == 'publish' and step == 'pack':
        kind = 'upload'   # a release session's pack is eos-pack.sh --upload's
    rows = [r for r in HIST if r[0] == step and r[2] == kind]
    picks = []
    if fresh in ('0', '1'):
        picks.append([r for r in rows if r[1] == d and r[3] == fresh])
    # Whether the product out was there decides the make's time, not the other steps'
    if step != 'make' or fresh not in ('0', '1'):
        picks.append([r for r in rows if r[1] == d])
    if step in ('prepare', 'verify', 'pack', 'ota', 'web'):
        picks.append(rows)
    for pick in picks:
        if pick:
            return statistics.median(r[4] for r in pick[-5:]), 'history'
    for key in ((step, kind, fresh), (step, kind, None), (step, None, None)):
        if key in TYPICAL:
            return TYPICAL[key], 'typical'
    return None, 'none'


def plan(d, kind):
    """The steps a phone's run goes through, in order."""
    if kind == 'modules':
        return ['make']
    if kind == 'publish':
        return ['pack', 'ota', 'web']
    if kind in ('testers', 'release', 'upload'):
        return ['pack']
    steps = ['prepare'] + (['kernel'] if builds_kernel(d) else [])
    return steps if kind == 'kernel' else steps + ['make', 'verify', 'pack']


class Phone:
    def __init__(self, d):
        self.d = d
        self.state, self.step, self.kind, self.fresh = 'queued', '-', None, None
        self.started = self.ended = self.step_at = None
        self.stamped = False   # this kit prints STEP lines: its headers then say nothing new
        self.prog = None       # the make's last progress line: (done, total, seconds left, as of)
        self.at_end = None     # target_files or ota_zip: when it began
        self.counts = None
        self.eta = None
        self.basis = 'none'


# The lines the session's log is read for; the rest (compiler output) is skipped
WANTED = re.compile(rb'^(?:== |STEP |BUILD_EXIT=|PACK=|DEVICE |SESSION_EXIT=|MODULES_EXIT=|waiting for |'
                    rb'OK: kernel only|\[ *\d+% ).*$', re.M)
DATE = r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) UTC'


class Run:
    """One session's log (or a build's own log), read into its phones."""

    def __init__(self, name, log, script, running, single=None):
        self.name, self.log, self.running = name, log, running
        self.started = self.exit = None
        self.phones = {}
        self.order = []
        self.kind = None       # from the job script: quick, kernel, modules or testers
        self.cur = None
        self.ninja_start = None
        self.data = read(log)
        self.log_time = mtime(log)
        sh = read(script).decode('utf-8', 'replace') if script else ''
        listed = []
        m = re.search(r'^# phones: ([a-z0-9 ]+)$', sh, re.M)
        if m:
            listed = m.group(1).split()
        envs = ''
        m = re.search(r'build-devices\.sh\S*\s+\S+\s+[01]\s+(.*?)--\s+([a-z0-9 ]+?)\s*;', sh)
        if m:
            envs = m.group(1)
            listed = listed or m.group(2).split()
        m = re.search(r'\benv\s+(.*?)\S*/tools/eos-images\.sh', sh)
        if m:
            envs += ' ' + m.group(1)
        if 'eos-release.sh' in sh:
            self.kind = 'publish'
        elif 'build-modules.sh' in sh:
            self.kind = 'modules'
        elif '--testers' in sh:
            self.kind = 'testers'
        elif 'KERNEL_ONLY=1' in envs:
            self.kind = 'kernel'
        elif 'EOS_QUICK=1' in envs:
            self.kind = 'quick'
        elif 'build-devices.sh' in sh or '/tools/eos-images.sh' in sh:
            self.kind = 'full'
        if single:
            listed = listed or [single]
        for d in listed:
            self.phone(d)
        # One phone: everything in the log is its own
        if len(self.order) == 1 and not re.search(r'build-devices\.sh', sh):
            self.cur = self.phones[self.order[0]]
        self.parse()

    def phone(self, d):
        if d not in self.phones:
            self.phones[d] = Phone(d)
            self.order.append(d)
            self.phones[d].kind = self.kind
        return self.phones[d]

    def set_step(self, p, step, at=None):
        if step != p.step:
            p.prog = None
            p.at_end = None
        p.step, p.step_at = step, at
        p.state = 'running'

    def parse(self):
        data = self.data.replace(b'\r', b'\n')
        for m in WANTED.finditer(data):
            t = m.group(0).decode('utf-8', 'replace').rstrip()
            p = self.cur
            if t.startswith('['):
                g = re.match(r'\[ *\d+% (\d+)/(\d+)(?: (\S+) remaining)?\]', t)
                if g and p and p.step in MAKE_STEPS:
                    p.prog = (int(g.group(1)), int(g.group(2)), go_secs(g.group(3)), m.end())
                continue
            g = re.fullmatch(r'== eos-(\w+), ' + DATE, t)
            if g:
                self.started = parse_time(g.group(2), '%Y-%m-%d %H:%M:%S')
                continue
            g = re.fullmatch(r'== ([a-z0-9]+) \((\d+) of (\d+)\): (eos-images\.sh|eos-pack\.sh|eos-ota\.sh|flasher_publish\.py), ' + DATE, t)
            if g:
                at = parse_time(g.group(5), '%Y-%m-%d %H:%M:%S')
                p = self.cur = self.phone(g.group(1))
                # A build's phone starts with eos-images.sh, a release session's with eos-pack.sh
                p.started = p.started or at
                self.set_step(p, {'eos-images.sh': 'wait', 'eos-pack.sh': 'pack', 'eos-ota.sh': 'ota',
                                  'flasher_publish.py': 'web'}[g.group(4)], at)
                continue
            g = re.match(r'== ExpressiveOS \S+ \S+ for ([a-z0-9]+) in .*, ' + DATE + r': a (full|quick) build', t)
            if g:
                at = parse_time(g.group(2), '%Y-%m-%d %H:%M:%S')
                p = self.cur = self.phone(g.group(1))
                p.started = p.started or at
                p.kind = p.kind or g.group(3)
                if not p.stamped:
                    self.set_step(p, 'prepare', at)
                continue
            g = re.fullmatch(r'STEP (\w+) device=([a-z0-9]+) kind=(\S+) fresh=(\S+) at=(\S+)', t)
            if g:
                at = parse_time(g.group(5), '%Y-%m-%dT%H:%M:%SZ')
                p = self.cur = self.phone(g.group(2))
                p.stamped = True
                self.set_step(p, g.group(1), at)
                # A release session's phone stays publish (its pack's STEP lines say upload)
                if g.group(3) != '-' and self.kind != 'publish':
                    p.kind = g.group(3)
                if g.group(4) in ('0', '1'):
                    p.fresh = g.group(4)
                if g.group(1) == 'prepare':
                    p.started = p.started or at
                continue
            if t.startswith('waiting for ') or t.startswith('== waiting for '):
                if p and p.step in ('-', 'wait', 'prepare') and not p.stamped:
                    self.set_step(p, 'wait', p.step_at)
                continue
            if t.startswith('== '):
                self.header(p, t)
                continue
            g = re.fullmatch(r'DEVICE ([a-z0-9]+): RELEASE=(OK|FAIL)(.*)', t)
            if g:
                q = self.phone(g.group(1))
                q.state = 'done' if g.group(2) == 'OK' else 'failed'
                if g.group(2) == 'OK':
                    q.step = 'done'
                for rest in re.findall(r'; not released: ([a-z0-9 ]+)', g.group(3)):
                    for d in rest.split():
                        self.phone(d).state = 'skipped'
                continue
            g = re.fullmatch(r'DEVICE ([a-z0-9]+): BUILD_EXIT=(\d)(.*)', t)
            if g:
                q = self.phone(g.group(1))
                ok = g.group(2) == '0' and 'PACK=FAIL' not in g.group(3)
                q.state = 'done' if ok else 'failed'
                if ok:
                    q.step = 'done'
                    if 'kernel only' in g.group(3):
                        q.kind = 'kernel'
                for rest in re.findall(r'; not (?:built|packed): ([a-z0-9 ]+)', g.group(3)):
                    for d in rest.split():
                        self.phone(d).state = 'skipped'
                continue
            if p is None:
                g = re.fullmatch(r'SESSION_EXIT=(\d+)', t)
                if g:
                    self.exit = int(g.group(1))
                continue
            if t == 'OK: kernel only' or t.startswith('OK: kernel only '):
                p.kind = 'kernel'
            elif t.startswith('BUILD_EXIT='):
                if t == 'BUILD_EXIT=0':
                    if p.kind == 'kernel':
                        p.state, p.step = 'done', 'done'
                    elif p.state != 'done':
                        # eos-pack.sh is next (its STEP line has the time)
                        self.set_step(p, 'pack')
                elif p.state != 'done':
                    p.state = 'failed'
            elif t in ('PACK=OK', 'PACK=FAIL'):
                p.state = 'done' if t == 'PACK=OK' else 'failed'
                if t == 'PACK=OK':
                    p.step = 'done'
            elif t.startswith('MODULES_EXIT='):
                p.state = 'done' if t == 'MODULES_EXIT=0' else 'failed'
                if t == 'MODULES_EXIT=0':
                    p.step = 'done'
            elif t.startswith('SESSION_EXIT='):
                g = re.fullmatch(r'SESSION_EXIT=(\d+)', t)
                if g:
                    self.exit = int(g.group(1))

    def header(self, p, t):
        """The kit's step headers: where a kit without STEP lines is, and a pack's phone."""
        g = re.match(r'== (?:the )?candidate: .*/releases/expressiveos-([a-z0-9]+)/', t)
        if g and p is None:
            p = self.cur = self.phone(g.group(1))
        if p is None:
            return
        g = re.fullmatch(r'== m (.+), ' + DATE, t)
        if g and self.kind == 'modules':
            self.set_step(p, 'make', parse_time(g.group(2), '%Y-%m-%d %H:%M:%S'))
            return
        if t == '== the build' or t.startswith('== the build: quick'):
            p.kind = p.kind or ('quick' if t != '== the build' else 'full')
            if p.step not in ('pack', 'done'):
                self.set_step(p, 'pack')
            return
        if p.stamped:
            return
        if t == '== prepare.sh':
            self.set_step(p, 'prepare', p.step_at)
        elif t in ('== make (eos-make.sh)', '== make (ksu-images.sh)'):   # the second: logs of builds before 2026-11-03
            self.set_step(p, 'kernel' if builds_kernel(p.d) else 'make')
        elif t.startswith(('== m installclean', '== make: ', '== make pass', '== make (stock init_boot')):
            if p.step != 'make':
                self.set_step(p, 'make')
        elif t == '== verify (eos-verify.sh)':
            self.set_step(p, 'verify')

    def finish(self, procs):
        """What the log can't say: the make's counts, phones that will never finish, times."""
        if self.exit is not None:
            self.running = False
        top = os.path.realpath(TOP)
        intree = [x for x in procs if x[3] == top or x[3].startswith(top + '/')]
        for p in self.phones.values():
            if p.state == 'running' and not self.running:
                p.state = 'failed'    # its session ended or was stopped part way
            elif p.state == 'queued' and not self.running:
                p.state = 'skipped'
            # Whether the product out is there says nothing of a release session's steps
            if p.fresh is None and p.state in ('queued', 'skipped') and p.kind != 'publish':
                p.fresh = '0' if os.path.isdir(os.path.join(TOP, 'out/target/product', p.d)) else '1'
        # Each phone ends where the next one begins; the last, when the log was last written
        starts = [self.phones[d].started for d in self.order]
        for i, d in enumerate(self.order):
            p = self.phones[d]
            if p.state in ('done', 'failed'):
                later = [s for s in starts[i + 1:] if s]
                p.ended = later[0] if later else self.log_time
        p = next((p for p in self.phones.values() if p.state == 'running'), None)
        if p is None or p.step not in MAKE_STEPS + ('kernel',):
            return
        # m runs soong_ui --build-mode, make --make-mode; lunch's --dumpvars-mode is no make
        soong = [x for x in intree if os.path.basename(x[2][0]) == 'soong_ui'
                 and any(a in ('--build-mode', '--make-mode') for a in x[2])]
        ninja = [x for x in intree if os.path.basename(x[2][0]) == 'ninja'
                 and any(re.search(r'combined-.*\.ninja$', a) for a in x[2])]
        ota = [x for x in intree if any('ota_from_target_files' in a for a in x[2][:3])]
        tfp = [x for x in intree if x not in ota and any('target_files_intermediates' in a for a in x[2])]
        if soong and p.step == 'kernel':
            self.set_step(p, 'make')   # a kit without STEP lines: its make header came first
        if p.step not in MAKE_STEPS:
            return
        if not p.stamped and soong and p.step_at is None:
            p.step_at = min(x[1] for x in soong)
        if p.kind != 'quick' and (ota or tfp):
            p.step, p.at_end = ('ota_zip', min(x[1] for x in ota)) if ota else ('target_files', min(x[1] for x in tfp))
        self.ninja_start = min(x[1] for x in ninja) if ninja else None
        pb = os.path.join(TOP, 'out/build_progress.pb')
        since = p.step_at or (min(x[1] for x in soong) if soong else None)
        if soong and since is not None and (mtime(pb) or 0) >= since - 5:
            p.counts = build_progress(pb)

    def eta(self):
        """Each phone's estimated end, in order: the running one's from where it is, each queued
        one's from the one before it."""
        # Between two phones (one done, the next not begun), the next starts about now
        prev = NOW if self.running else None
        for d in self.order:
            p = self.phones[d]
            kind = p.kind or 'full'
            if p.state == 'running':
                left, p.basis = self.left(p, kind)
                p.eta = None if left is None else NOW + left
                prev = p.eta
            elif p.state == 'queued':
                left, p.basis = whole(p.d, kind, p.fresh, plan(p.d, kind))
                p.eta = None if left is None or prev is None else prev + left
                prev = p.eta
                if p.eta is None:
                    p.basis = 'none'

    def left(self, p, kind):
        steps = plan(p.d, kind)
        cur = 'make' if p.step in MAKE_STEPS else p.step
        if p.step == 'wait' or cur not in steps:
            return None, 'none'
        rest = steps[steps.index(cur) + 1:]
        if cur == 'make':
            now_left, basis = self.make_left(p, kind)
        else:
            est, basis = estimate(cur, p.d, kind, p.fresh)
            if est is None:
                return None, 'none'
            since = p.step_at or (p.started if cur == 'prepare' else None)
            now_left = est if since is None else max(est - (NOW - since), 15)
        if now_left is None:
            return None, 'none'
        more, more_basis = whole(p.d, kind, p.fresh, rest)
        if more is None:
            return None, 'none'
        if cur != 'make' and 'make' not in rest:
            basis = 'typical' if 'typical' in (basis, more_basis) else basis
        elif cur != 'make':
            basis = more_basis
        return now_left + more, basis

    def make_left(self, p, kind):
        """(seconds, basis) until the make ends."""
        tail = TAIL['target_files'] + TAIL['ota_zip'] if kind == 'full' else 0
        # Ninja's own end time, as of the progress line the log last got (0s once it's past)
        if p.prog and p.prog[2] and self.log_time:
            left = p.prog[2] - (NOW - self.log_time)
            if left > 0:
                return left, 'ninja'
        if p.step in ('target_files', 'ota_zip') and p.at_end:
            left = max(TAIL[p.step] - (NOW - p.at_end), 15)
            return left + (TAIL['ota_zip'] if p.step == 'target_files' else 0), 'typical'
        c, start = p.counts, self.ninja_start
        if c and start and c['total'] and c['done'] >= 0.02 * c['total'] and NOW - start >= 30:
            return (c['total'] - c['done']) * (NOW - start) / c['done'] + tail, 'rate'
        est, basis = estimate('make', p.d, kind, p.fresh)
        if est is None:
            return None, 'none'
        return max(est - (NOW - p.step_at), 30) if p.step_at else est, basis

    def log_tail(self):
        """The log's last lines, for the phone that wrote them (the running one, else the last)."""
        p = next((p for p in self.phones.values() if p.state == 'running'), None)
        if p is None:
            done = [p for p in self.phones.values() if p.state in ('done', 'failed')]
            p = done[-1] if done else None
        if p is None or not self.data:
            return None, []
        text = self.data[-LOG_LINES * 2000:].decode('utf-8', 'replace')
        lines = []
        for line in re.split(r'\r\n|\r|\n', text)[-(LOG_LINES * 3):]:
            line = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]', '', line)
            line = re.sub(r'[\x00-\x1f\x7f]', '', line).rstrip()
            if line:
                lines.append(line[:LOG_WIDTH])
        return p.d, lines[-LOG_LINES:]


def whole(d, kind, fresh, steps):
    """(seconds, basis) for <steps> from their start: the make's basis, else the weakest one."""
    total, bases = 0, []
    for s in steps:
        est, basis = estimate(s, d, kind, fresh)
        if est is None:
            return None, 'none'
        total += est
        bases.append(basis)
    if not bases:
        return 0, 'history'
    if 'make' in steps:
        return total, bases[steps.index('make')]
    return total, max(bases, key=BASES.index)


def pick_run(procs):
    """The run to report on: a running session (eos-build first), else a build started some other
    way that's running, else the session whose log was written last."""
    sessions = []
    for name in ('build', 'pack'):
        log = os.path.join(JOBS, name + '.log')
        running = tmux_running('eos-' + name)
        if running or os.path.exists(log):
            sessions.append((running, mtime(log) or 0, name, log))
    live = [s for s in sessions if s[0]]
    if live:
        s = live[0]
        return Run('eos-' + s[2], s[3], os.path.join(JOBS, s[2] + '.sh'), True, session_phone(s[2], procs))
    for pid, start, argv, cwd in procs:
        if any(re.search(r'/tools/eos-(images|pack)\.sh$', a) for a in argv[:2]):
            d = environ(pid, 'EOS_DEVICE') or 'cheetah'
            if re.fullmatch(r'[a-z0-9]+', d):
                log = os.path.join(HOME, 'expressiveos-build.log' if d == 'cheetah' else f'expressiveos-build-{d}.log')
                r = Run('-', log, None, True, d)
                r.started = r.started or start
                return r
    if sessions:
        s = max(sessions, key=lambda s: s[1])
        return Run('eos-' + s[2], s[3], os.path.join(JOBS, s[2] + '.sh'), False)
    return None


def session_phone(name, procs):
    """The phone a running session's scripts build or pack (their EOS_DEVICE, cheetah unless set),
    for a job script from before its "# phones:" line."""
    for pid, start, argv, cwd in procs:
        if any(re.search(r'/tools/eos-(images|pack)\.sh$', a) for a in argv[:2]):
            d = environ(pid, 'EOS_DEVICE') or 'cheetah'
            return d if re.fullmatch(r'[a-z0-9]+', d) else None
    return None


def eastern(t):
    try:
        from zoneinfo import ZoneInfo
        dt = datetime.datetime.fromtimestamp(t, ZoneInfo('America/New_York'))
    except Exception:
        dt = datetime.datetime.fromtimestamp(t, datetime.timezone(datetime.timedelta(hours=-5), 'EST'))
    return dt.strftime('%I:%M %p').lstrip('0') + ' ' + dt.tzname()


def span(s):
    s = int(round(s))
    if s < 60:
        return 'under a minute'
    h, m = divmod(s // 60, 60)
    return f'{h} h {m} min' if h else f'{m} min'


WORDS = {'ninja': "Soong's own estimate", 'rate': "the make's pace so far", 'history': 'past builds',
         'typical': "this server's typical times"}


def words(p):
    kind = {'quick': 'quick build', 'kernel': 'kernel-only build', 'modules': 'compile check',
            'testers': 'upload for testers', 'publish': 'release'}.get(p.kind, 'full build')
    if p.state == 'running':
        what = {'wait': 'waiting for another build to finish', 'prepare': 'preparing the tree',
                'kernel': 'building the kernel', 'make': 'compiling', 'target_files': 'zipping the target-files',
                'ota_zip': 'making the OTA package', 'verify': 'checking the build', 'pack': 'packing the zip',
                'ota': 'making and uploading the OTA packages', 'web': 'publishing to the web installer'}.get(p.step, p.step)
        if p.step in MAKE_STEPS and (p.counts or p.prog):
            done, total = (p.counts['done'], p.counts['total']) if p.counts else p.prog[:2]
            if total:
                what += f' ({100 * done // total}%, {done:,} of {total:,} actions)'
        s = f'{p.d}: {kind}, {what}'
        if p.started:
            s += f', started {eastern(p.started)}, {span(NOW - p.started)} so far'
        if p.eta:
            s += f'; about {span(p.eta - NOW)} left, done around {eastern(p.eta)} ({WORDS[p.basis]})'
        return s + '.'
    if p.state == 'queued':
        s = f'{p.d}: {kind}, waiting its turn' + (' (its first build since its build output was removed: every module is built)' if p.fresh == '1' else '')
        return s + (f'; done around {eastern(p.eta)} ({WORDS[p.basis]}).' if p.eta else '.')
    if p.state == 'done':
        s = f'{p.d}: {kind}, ' + ('released: packed, OTA packages uploaded, on the web installer' if p.kind == 'publish'
                                  else 'built and packed' if p.kind not in ('kernel', 'modules', 'testers') else 'done')
        if p.started and p.ended:
            s += f' in {span(p.ended - p.started)} ({eastern(p.started)} to {eastern(p.ended)})'
        return s + '.'
    if p.state == 'failed':
        s = f'{p.d}: {kind}, failed at {p.step}' if p.step not in ('-', 'done') else f'{p.d}: {kind}, failed'
        if p.started and p.ended:
            s += f' after {span(p.ended - p.started)} ({eastern(p.ended)})'
        return s + '. Its last log lines (LOG, above) and expressiveos-status say why.'
    if p.kind == 'publish':
        return f'{p.d}: not released (a phone before it failed, or the session was stopped).'
    return f'{p.d}: not built (a phone before it failed, or the session was stopped).'


def feed():
    """The feed files of the last release session's phones, for the feed's pull request."""
    sh = read(os.path.join(JOBS, 'pack.sh')).decode('utf-8', 'replace')
    m = re.search(r'^# phones: ([a-z0-9 ]+)$', sh, re.M)
    if 'eos-release.sh' not in sh or not m:
        print('FEED none: the last eos-pack session (~/expressiveos-jobs/pack.sh) was no release session')
        print('FEED_INCOMPLETE')
        return
    since = mtime(os.path.join(JOBS, 'pack.sh')) or 0
    phones, ok = m.group(1).split(), []
    for d in phones:
        log = os.path.join(JOBS, f'ota-{d}.log')
        lines = read(log).decode('utf-8', 'replace').splitlines()
        last = next((l for l in reversed(lines) if l.strip()), '')
        if not lines:
            print(f'FEED device={d} none (no ~/expressiveos-jobs/ota-{d}.log: its OTA step never ran)')
        elif (mtime(log) or 0) < since:
            print(f'FEED device={d} none (ota-{d}.log is older than the session)')
        elif last != 'OTA=OK':
            print(f'FEED device={d} none (its OTA step ended {last[:100]!r})')
        else:
            print(f'FEED device={d} ready')
            ok.append((d, lines))
    for d, lines in ok:
        inside = False
        for line in lines:
            if line.startswith('===== OTA_FEED '):
                inside = True
            if inside or line.startswith(('UPLOADED_OTA ', 'OTA_FEED_READY ')):
                print(line)
            if line == '===== OTA_FEED_END':
                inside = False
    print('FEED_OK' if len(ok) == len(phones) else 'FEED_INCOMPLETE')


def main():
    if sys.argv[1:] == ['--feed']:
        feed()
        return
    if len(sys.argv) > 1:
        sys.exit('usage: eos-progress.py [--feed]')
    global HIST
    HIST = history()
    procs = processes()
    run = pick_run(procs)
    if run is None:
        print('SESSION name=- state=none exit=- started=-')
        print('PROGRESS_OK')
        print('\nNo ExpressiveOS build has run from the runner yet, and none is running.')
        return
    run.finish(procs)
    run.eta()
    v = lambda x: '-' if x is None else str(x)
    for d in run.order:
        p = run.phones[d]
        c = p.counts or {}
        prog = p.prog if p.state == 'running' and p.step in MAKE_STEPS else None
        done = c.get('done', prog[0] if prog else None) if p.state == 'running' else None
        total = c.get('total', prog[1] if prog else None) if p.state == 'running' else None
        if p.state in ('done', 'failed'):
            elapsed = int(p.ended - p.started) if p.started and p.ended else None
        elif p.state == 'running' and p.started:
            elapsed = int(NOW - p.started)
        else:
            elapsed = None
        print(f'PROGRESS device={p.d} state={p.state} step={p.step if p.state != "skipped" else "-"} '
              f'kind={p.kind or "-"} fresh={v(p.fresh)} started={iso(p.started)} elapsed_s={v(elapsed)} '
              f'done={v(done)} total={v(total)} running={v(c.get("running"))} failed={v(c.get("failed"))} '
              f'eta_s={v(None if p.eta is None else max(0, int(p.eta - NOW)))} eta={iso(p.eta)} '
              f'eta_basis={p.basis if p.eta is not None else "none"}')
    if run.running:
        state = 'running'
    elif run.exit is None:
        state = 'failed'   # stopped part way: no SESSION_EXIT
    else:
        state = 'done' if run.exit == 0 else 'failed'
    print(f'SESSION name={run.name} state={state} exit={v(run.exit)} started={iso(run.started)}')
    d, lines = run.log_tail()
    for line in lines:
        print(f'LOG device={d} {line}')
    for line in recent_times():
        print(line)
    print('PROGRESS_OK')
    print()
    head ={'running': 'is running', 'done': 'has finished', 'failed': 'ended without finishing'}[state]
    who = f'The {run.name} session' if run.name != '-' else 'A build started by hand (no runner session)'
    print(f'{who} {head}' + (f', since {eastern(run.started)}' if run.started and state == 'running' else '') + '.')
    for name in run.order:
        print(words(run.phones[name]))
    etas = [run.phones[x].eta for x in run.order if run.phones[x].state in ('running', 'queued')]
    if len(etas) > 1 and all(etas):
        print(f'All of them done around {eastern(etas[-1])}.')


if __name__ == '__main__':
    main()
