#!/usr/bin/env python3
# ExpressiveOS's monthly update, checked (update-check.sh runs this on the build server): what
# LineageOS has added since the sources ExpressiveOS's manifest pins, and whether ExpressiveOS's
# forks would take it cleanly. Nothing in the tree changes and nothing is pushed: the fetches
# and test merges happen in scratch repos in the work folder, which borrow the tree's git
# objects (git alternates), so only the new commits are downloaded.
#
#   update.py check --top <tree> --manifest <its default.xml> --work <dir>
#                   [--lineage-base <commit of LineageOS's manifest>]
#
# Project by project (the manifest's paths):
# - LineageOS's and AOSP's projects move to what LineageOS's manifest (its branch, as named on
#   build_kernel's line of ExpressiveOS's) names for that path today: a branch's newest commit,
#   a tag or a commit. A project LineageOS's manifest doesn't have (Evolution X kept a few
#   LineageOS repos LineageOS dropped, and cheetah's kernel prebuilts) follows its own upstream.
#   Each move must descend from our commit: LineageOS never rewrites its branches.
# - ExpressiveOS's forks of LineageOS's and AOSP's repos: what LineageOS's manifest names for
#   that path, merged into the fork (git merge-tree, nothing written to the fork): clean, or the
#   files that conflict, and which of those ExpressiveOS's own changes (the kit's patches) touch.
# - ExpressiveOS's other repos (Evolution X's apps and vendor repos, cheetah's trees and blobs)
#   have nothing upstream: only their branch tip against the manifest is shown.
# Then what LineageOS's manifest itself changed since --lineage-base (projects added, removed,
# moved to another repo or branch; Google's AOSP tag), the platform security patch level before
# and after, the kernel (the kit's pins/kernel.xml against LineageOS's gs-6.1 kernel manifest
# today) and KernelSU Next's and NeoZygisk's newest releases against ksu/ksu.conf. Google's
# factory images (cheetah's firmware and vendor blobs) aren't checked here.
#
# Ends with UPDATE_CHECK=OK, or UPDATE_CHECK=INCOMPLETE and what couldn't be checked.
import argparse, base64, concurrent.futures, datetime, hashlib, json, os, re, shutil, subprocess, sys
import tempfile, threading
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

here = os.path.dirname(os.path.abspath(__file__))
kit = os.path.dirname(here)
LINEAGE_MANIFEST = "https://github.com/LineageOS/android"
# LineageOS's manifest when the 1.0 tree synced (2026-10-26): what its changes since are
# counted from, until an update records the commit it took
LINEAGE_BASE = "b51a0c449a3279ca55fb6d4d91d2143e42e2fff5"
SHA = re.compile(r"[0-9a-f]{40}")
ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_LFS_SKIP_SMUDGE="1", LC_ALL="C")

class Fail(Exception):
    pass

def fail(msg):
    sys.exit(f"FAIL: {msg}")

def git(*args, gd=None, timeout=600, ok=(0,), input=None, env=None, raw=False):
    # raw: stdout as bytes (blobs); input: str, or bytes when raw
    cmd = ["git", "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
    if gd:
        cmd += ["--git-dir", gd]
    try:
        r = subprocess.run(cmd + list(args), capture_output=True, timeout=timeout, input=input,
                           env=dict(ENV, **(env or {})), **({} if raw else
                           dict(text=True, errors="surrogateescape")))
    except (subprocess.SubprocessError, OSError) as e:
        raise Fail(f"git {' '.join(args)[:200]}: {e}")
    if r.returncode not in ok:
        err = r.stderr if isinstance(r.stderr, str) else r.stderr.decode(errors="replace")
        raise Fail(f"git {' '.join(args)[:200]} exited {r.returncode}: {err.strip()[-300:]}")
    return r

def commits(n):
    return f"{n} new commit" + ("" if n == 1 else "s")

def conf(path):
    # NAME=value lines (eos.conf, ksu.conf), nothing sourced
    out = {}
    for line in open(path):
        m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip("'\"")
    return out

# ---- manifests -------------------------------------------------------------------------

class Proj:
    def __init__(self, e, remotes, default, url_of):
        self.path = e.get("path") or e.get("name")
        self.name = e.get("name")
        self.remote = e.get("remote") or default.get("remote")
        r = remotes.get(self.remote)
        if r is None:
            raise Fail(f"{self.path}: no remote {self.remote}")
        self.fetch = url_of(r["fetch"])
        self.url = f"{self.fetch}/{self.name}"
        self.revision = e.get("revision") or r.get("revision") or default.get("revision") or ""
        self.upstream = e.get("upstream") or ""
        self.groups = ",".join(sorted(g for g in (e.get("groups") or "").split(",") if g))
        self.depth = e.get("clone-depth")
        self.kids = tuple(sorted((k.tag, k.get("src"), k.get("dest")) for k in e
                                 if k.tag in ("linkfile", "copyfile")))

def flatten(read, url):
    # A repo manifest with its <include>s, <remove-project>s and <extend-project>s applied:
    # path -> Proj. read(name) gives a file of the manifest's repo
    def url_of(fetch):
        # As repo resolves a remote's fetch (manifest_xml.py, _resolveFetchUrl)
        return urllib.parse.urljoin(url.rstrip("/"), fetch.rstrip("/")).rstrip("/")
    remotes, default, elems = {}, {}, {}
    def walk(name):
        for e in ET.fromstring(read(name)):
            if e.tag == "remote":
                remotes[e.get("name")] = dict(e.attrib)
            elif e.tag == "default":
                default.update(e.attrib)
            elif e.tag == "include":
                walk(e.get("name"))
            elif e.tag == "project":
                elems[e.get("path") or e.get("name")] = e
            elif e.tag == "remove-project":
                for p in [p for p, x in elems.items() if x.get("name") == e.get("name")
                          and e.get("path") in (None, p)]:
                    del elems[p]
            elif e.tag == "extend-project":
                for p, x in elems.items():
                    if x.get("name") == e.get("name") and e.get("path") in (None, p):
                        for k, v in e.attrib.items():
                            if k == "groups":
                                v = ",".join(filter(None, [x.get("groups"), v]))
                            if k not in ("name", "path"):
                                x.set(k, v)
                        x.extend(list(e))
    walk("default.xml")
    projs = {p: Proj(e, remotes, default, url_of) for p, e in elems.items()}
    return projs, remotes, default

def ref_of(rev):
    # A manifest revision as the ref to ask a server for (repo reads a bare name as a branch)
    if SHA.fullmatch(rev) or rev.startswith("refs/"):
        return rev
    return "refs/heads/" + rev

_ls, _ls_lock = {}, threading.Lock()
def ls_remote(url, ref):
    # The commit <ref> names on <url> today (a tag peeled), or None
    if SHA.fullmatch(ref):
        return ref
    key = (url, ref)
    with _ls_lock:
        if key in _ls:
            return _ls[key]
    want = [ref, ref + "^{}"] if ref.startswith("refs/tags/") else [ref]
    out = {}
    for line in git("ls-remote", url, *want, timeout=180).stdout.splitlines():
        sha, r = line.split("\t")
        out[r] = sha
    sha = out.get(ref + "^{}") or out.get(ref)
    with _ls_lock:
        _ls[key] = sha
    return sha

def fetch_manifest(work, sub, url, branch):
    gd = os.path.join(work, "manifests", sub)
    if not os.path.isdir(gd):
        git("init", "-q", "--bare", gd)
    git("fetch", "-q", "--no-tags", url, f"+refs/heads/{branch}:refs/heads/{branch}", gd=gd, timeout=600)
    return gd

def reader(gd, rev):
    return lambda name: git("show", f"{rev}:{name}", gd=gd).stdout

def tag_of(rev):
    return rev[len("refs/tags/"):] if rev.startswith("refs/tags/") else None

def branch_of(rev):
    return rev[len("refs/heads/"):] if rev.startswith("refs/heads/") else rev

# ---- the tree's objects, borrowed -----------------------------------------------------------

_locks, _locks_lock = {}, threading.Lock()
def name_lock(name):
    with _locks_lock:
        return _locks.setdefault(name, threading.Lock())

def scratch(work, top, p):
    # A bare repo of its own for project p, borrowing the tree's git objects for it
    objects = os.path.realpath(os.path.join(top, ".repo", "projects", p.path + ".git", "objects"))
    if not os.path.isdir(objects):
        raise Fail(f"the tree has no git objects for {p.path} ({objects})")
    gd = os.path.join(work, "git", p.name + ".git")
    if not os.path.isfile(os.path.join(gd, "HEAD")):
        git("init", "-q", "--bare", gd)
    alt = os.path.join(gd, "objects", "info", "alternates")
    have = open(alt).read().split("\n") if os.path.exists(alt) else []
    if objects not in have:
        with open(alt, "a") as f:
            f.write(objects + "\n")
    return gd

def refname(p, what):
    return "refs/eos/" + re.sub(r"[^A-Za-z0-9._/-]", "_", p.path) + "/" + what

def fetch(gd, p, url, ref, what="up"):
    # <url>'s <ref> as refs/eos/<path>/<what> in gd: only what the tree lacks is downloaded
    dst = refname(p, what)
    git("fetch", "-q", "--no-tags", "--no-write-fetch-head", url, f"+{ref}:{dst}", gd=gd, timeout=3600)
    return git("rev-parse", f"{dst}^{{commit}}", gd=gd).stdout.strip()

def count(gd, a, b):
    return int(git("rev-list", "--count", f"{a}..{b}", gd=gd).stdout.strip() or 0)

def is_ancestor(gd, a, b):
    return git("merge-base", "--is-ancestor", a, b, gd=gd, ok=(0, 1)).returncode == 0

_mt = None
def merge_tree(gd, ours, theirs):
    # (merged tree or None, conflicted paths) of merging theirs into ours, nothing written but
    # objects in gd. git 2.38+ merges in memory; older ones in a scratch worktree
    global _mt
    if _mt is None:
        r = git("merge-tree", "-h", ok=(0, 129))
        _mt = "--write-tree" in r.stdout + r.stderr
    if _mt:
        r = git("merge-tree", "--write-tree", "--name-only", "--no-messages", ours, theirs, gd=gd,
                timeout=1800, ok=(0, 1))
        lines = r.stdout.splitlines()
        return (lines[0] if r.returncode == 0 else None), [l for l in lines[1:] if l]
    wt = os.path.join(os.path.dirname(gd), os.path.basename(gd) + ".merge")
    git("worktree", "prune", gd=gd)
    git("worktree", "add", "-q", "--detach", "--force", wt, ours, gd=gd, timeout=3600)
    try:
        r = subprocess.run(["git", "-C", wt, "-c", "user.name=update check", "-c", "user.email=none@invalid",
                            "merge", "-q", "--no-commit", "--no-ff", theirs],
                           capture_output=True, text=True, env=ENV, timeout=3600)
        files = subprocess.run(["git", "-C", wt, "diff", "--name-only", "--diff-filter=U"],
                               capture_output=True, text=True, env=ENV).stdout.split("\n")
        tree = None
        if r.returncode == 0:
            tree = subprocess.run(["git", "-C", wt, "write-tree"], capture_output=True, text=True,
                                  env=ENV).stdout.strip() or None
        return tree, [f for f in files if f]
    finally:
        subprocess.run(["git", "-C", wt, "merge", "--abort"], capture_output=True, env=ENV)
        git("worktree", "remove", "--force", wt, gd=gd, ok=(0, 128))

# ---- the kit --------------------------------------------------------------------------

def kit_files():
    # tree path -> the files the kit's patches change there (patch dirs as lib.sh maps them)
    out = {}
    for sub in ("patches", "ksu/patches", "viper4android/patches"):
        root = os.path.join(kit, sub)
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            dp = os.path.join(root, d)
            if not os.path.isdir(dp):
                continue
            pf = os.path.join(dp, "PROJECT")
            path = open(pf).readline().strip() if os.path.isfile(pf) else d.replace("_", "/")
            for f in sorted(os.listdir(dp)):
                if f.endswith(".patch"):
                    for line in open(os.path.join(dp, f), errors="surrogateescape"):
                        m = re.match(r"diff --git a/(\S+) b/(\S+)", line)
                        if m:
                            out.setdefault(path, set()).update(m.groups())
    return out

def spl(gd, rev, release):
    # The platform security patch level at rev (a commit or tree): the flag value of our
    # release config (LineageOS bumps vendor/lineage's monthly), and the newest of any config
    def dates(*specs):
        r = git("grep", "-h", "-o", "-E", r"[0-9]{4}-[0-9]{2}-[0-9]{2}", rev, "--", *specs, gd=gd, ok=(0, 1))
        return sorted(set(r.stdout.split()))
    mine = dates(f":(glob)**/flag_values/{release}/RELEASE_PLATFORM_SECURITY_PATCH.textproto")
    every = dates(":(glob)**/flag_values/*/RELEASE_PLATFORM_SECURITY_PATCH.textproto")
    return (mine[-1] if mine else None), (every[-1] if every else None)

# ---- the check --------------------------------------------------------------------------

def check(a):
    top = os.path.realpath(a.top)
    work = os.path.realpath(a.work)
    eos = conf(os.path.join(kit, "eos.conf"))
    ksu = conf(os.path.join(kit, "ksu", "ksu.conf"))
    release = eos["EOS_LUNCH"].split("-")[1]
    started = datetime.datetime.now(datetime.timezone.utc)
    os.makedirs(os.path.join(work, "reports"), exist_ok=True)
    problems, lines = [], []
    def out(s=""):
        lines.append(s)
        print(s, flush=True)

    ours_rev = git("-C", os.path.dirname(a.manifest), "rev-parse", "HEAD").stdout.strip()
    gh = ls_remote(eos["EOS_MANIFEST_URL"], "refs/heads/" + eos["EOS_MANIFEST_BRANCH"])
    ours, _, odefault = flatten(lambda n: open(os.path.join(os.path.dirname(a.manifest), n)).read(),
                                eos["EOS_MANIFEST_URL"])
    lbranch = branch_of(odefault.get("revision", ""))
    if not lbranch.startswith("lineage-"):
        fail(f"the manifest's default revision is '{odefault.get('revision')}', not a LineageOS branch")
    lgd = fetch_manifest(work, "lineage.git", LINEAGE_MANIFEST, lbranch)
    lnow = git("rev-parse", f"refs/heads/{lbranch}", gd=lgd).stdout.strip()
    mdir = os.path.dirname(a.manifest)
    lid = None
    if a.lineage_base is None:
        a.lineage_base, lid = last_update(lambda n: read_file(os.path.join(mdir, n)))
    lbase = git("rev-parse", "--verify", f"{a.lineage_base}^{{commit}}", gd=lgd).stdout.strip()
    if not is_ancestor(lgd, lbase, lnow):
        fail(f"LineageOS's manifest {lbase[:12]} isn't in {lbranch}'s history")
    now, _, ndefault = flatten(reader(lgd, lnow), LINEAGE_MANIFEST)
    base, bremotes, _ = flatten(reader(lgd, lbase), LINEAGE_MANIFEST)
    _, nremotes, _ = flatten(reader(lgd, lnow), LINEAGE_MANIFEST)

    out(f"== ExpressiveOS update check, {started:%Y-%m-%d %H:%M} UTC (dry run: nothing changed or pushed)")
    out(f"tree {top}: manifest {eos['EOS_MANIFEST_URL']} ({eos['EOS_MANIFEST_BRANCH']}) at {ours_rev[:12]}"
        + ("" if gh == ours_rev else f"; GitHub has {(gh or 'nothing')[:12]}, newer than the tree's (run setup.sh)"))
    out(f"LineageOS's manifest ({lbranch}): {lnow[:12]} of {git('log', '-1', '--format=%cs', lnow, gd=lgd).stdout.strip()}, "
        f"{count(lgd, lbase, lnow)} commits since {lbase[:12]} ({'update ' + lid if lid else 'the sources base'})")
    otag = (bremotes.get("aosp") or {}).get("revision", "")
    ntag = (nremotes.get("aosp") or {}).get("revision", "")
    out(f"Google's AOSP tag in it: {tag_of(ntag) or ntag}" + ("" if ntag == otag else f" (was {tag_of(otag) or otag})"))

    patched = kit_files()
    jobs = int(os.environ.get("EOS_UPDATE_JOBS", "6"))
    results = {}

    def one(p):
        # What the update does to project p: a dict for the report
        r = {"path": p.path}
        n = now.get(p.path)
        if p.path == "evolution/manifest":
            # Evolution X's last manifest, for build_kernel's LineageOS version line: its repo's
            # expressiveos branch is ExpressiveOS's own manifest now, one commit on top of it
            r["kind"] = "own"
            return r
        if p.remote == "expressiveos":
            branch = branch_of(p.upstream or "refs/heads/expressiveos")
            tip = ls_remote(p.url, "refs/heads/" + branch)
            r["tip"] = tip
            if tip != p.revision:
                r["note"] = f"its {branch} branch is at {(tip or 'nothing')[:12]}, the manifest pins {p.revision[:12]}"
            if n is None:
                r["kind"] = "own"
                return r
            r["kind"] = "fork"
            r["upstream"] = f"{n.name} {tag_of(n.revision) or branch_of(n.revision)}"
            up = ls_remote(n.url, ref_of(n.revision))
            if not up:
                raise Fail(f"{n.url} has no {n.revision}")
            with name_lock(p.name):
                gd = scratch(work, top, p)
                git("update-ref", refname(p, "ours"), p.revision, gd=gd)
                ours_c = p.revision
                if tip and tip != p.revision:
                    ours_c = fetch(gd, p, p.url, "refs/heads/" + branch, "tip")
                    if not is_ancestor(gd, p.revision, ours_c):
                        r["note"] += " and doesn't descend from it"
                up = fetch(gd, p, n.url, ref_of(n.revision) if not SHA.fullmatch(n.revision) else n.revision)
                r["new"] = count(gd, ours_c, up)
                r["ours_only"] = count(gd, up, ours_c)
                if r["new"] == 0:
                    r["merge"] = "up to date"
                    r["tree"] = ours_c
                    return r
                tree, files = merge_tree(gd, ours_c, up)
                r["tree"] = tree
                r["merge"] = "clean" if tree else "conflicts"
                r["files"] = files
                r["kit_files"] = sorted(set(files) & patched.get(p.path, set()))
                r["last"] = git("log", "-1", "--format=%cs", up, gd=gd).stdout.strip()
                r["gd"] = gd
            return r
        r["kind"] = "upstream"
        # As the update does (plan): the project's repo and branch, unless LineageOS changed
        # them since the base
        c = los_changes(p, base.get(p.path), n)
        target = c.get("repo", p)
        ref = c.get("branch") or ref_of(p.upstream or p.revision)
        if "repo" in c:
            r["note"] = f"LineageOS's manifest now takes it from {target.name}"
        if n is None:
            r["note"] = "not in LineageOS's manifest: follows its own upstream"
        r["upstream"] = f"{target.name} {tag_of(ref) or branch_of(ref)}"
        if tag_of(ref) and tag_of(ref) == tag_of(p.upstream) and target.url == p.url:
            r["new"] = 0
            r["sha"] = p.revision
            return r
        sha = ls_remote(target.url, ref)
        if not sha:
            raise Fail(f"{target.url} has no {ref}")
        r["sha"] = sha
        if sha == p.revision:
            r["new"] = 0
            return r
        if p.depth or "googlesource.com" in target.url:
            r["new"] = None      # moves; not counted (shallow, or a whole new AOSP tag)
            return r
        with name_lock(p.name):
            gd = scratch(work, top, p)
            git("update-ref", refname(p, "ours"), p.revision, gd=gd)
            up = fetch(gd, p, target.url, ref if not SHA.fullmatch(ref) else sha)
            r["new"] = count(gd, p.revision, up)
            if not is_ancestor(gd, p.revision, up):
                r["rewritten"] = True
                problems.append(f"{p.path}: {target.name} {branch_of(ref)} doesn't contain our commit {p.revision[:12]} (rewritten?)")
            r["gd"] = gd
        return r

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(one, p): p for p in ours.values()}
        for f in concurrent.futures.as_completed(futs):
            p = futs[f]
            try:
                results[p.path] = f.result()
            except Fail as e:
                results[p.path] = {"path": p.path, "kind": "error", "error": str(e)}
                problems.append(f"{p.path}: {e}")

    forks = sorted((r for r in results.values() if r["kind"] == "fork"), key=lambda r: r["path"])
    out()
    out(f"== ExpressiveOS's forks of LineageOS's and AOSP's repos ({len(forks)}): LineageOS's commits merged into each, in memory")
    for r in forks:
        s = f"{r['path']} <- {r['upstream']}: "
        if r["merge"] == "up to date":
            s += "up to date"
        else:
            s += f"{commits(r['new'])} (newest {r['last']}), "
            if r["merge"] == "clean":
                s += "merges cleanly"
            else:
                s += f"CONFLICTS in {len(r['files'])} files: {', '.join(r['files'][:12])}"
                if len(r["files"]) > 12:
                    s += f" (+{len(r['files']) - 12} more)"
                if r["kit_files"]:
                    s += f"; ExpressiveOS's own changes touch {', '.join(r['kit_files'])}"
        if r.get("note"):
            s += f" [{r['note']}]"
        out(s)
    nconf = sum(1 for r in forks if r["merge"] == "conflicts")
    out(f"-- {sum(1 for r in forks if r['merge'] == 'up to date')} up to date, "
        f"{sum(1 for r in forks if r['merge'] == 'clean')} merge cleanly, {nconf} conflict")

    ups = sorted((r for r in results.values() if r["kind"] == "upstream"), key=lambda r: r["path"])
    moving = [r for r in ups if r["new"] != 0]
    out()
    out(f"== LineageOS's and AOSP's projects ({len(ups)}): {len(ups) - len(moving)} unchanged, {len(moving)} move")
    for r in moving:
        n = "moves (not counted)" if r["new"] is None else commits(r["new"])
        out(f"{r['path']} <- {r['upstream']}: {n}" + (f" [{r['note']}]" if r.get("note") else "")
            + (" [DOESN'T DESCEND FROM OURS]" if r.get("rewritten") else ""))
    notes = [r for r in ups if r.get("note") and r["new"] == 0]
    for r in notes:
        out(f"{r['path']}: unchanged [{r['note']}]")

    own = sorted((r for r in results.values() if r["kind"] == "own"), key=lambda r: r["path"])
    out()
    out(f"== ExpressiveOS's own repos with nothing upstream ({len(own)}): they change only by ExpressiveOS's commits")
    off = [r for r in own if r.get("note")]
    for r in off:
        out(f"{r['path']}: {r['note']}")
    out(f"-- {len(own) - len(off)} at the manifest's commit")

    # The security patch level: the release config's flag value (vendor/lineage's, where
    # LineageOS bumps it monthly; build/release has Google's)
    out()
    out(f"== Security patch level (release config {release})")
    for path in ("vendor/lineage", "build/release"):
        r = results.get(path)
        if not r or r["kind"] == "error":
            continue
        p = ours[path]
        try:
            with name_lock(p.name):
                gd = r.get("gd") or scratch(work, top, p)
                before = spl(gd, p.revision, release)
                after_rev = r.get("tree") if r["kind"] == "fork" else (r.get("sha") if r.get("new") != 0 else p.revision)
                if after_rev and r["kind"] == "upstream" and after_rev != p.revision and not r.get("gd"):
                    after_rev = None      # moves, not fetched
                after = spl(gd, after_rev, release) if after_rev else (None, None)
        except Fail as e:
            problems.append(f"security patch level in {path}: {e}")
            continue
        def show(v):
            return f"{v[0] or '-'}" + (f" (newest of any release config {v[1]})" if v[1] and v[1] != v[0] else "")
        out(f"{path}: now {show(before)}; after the update " + (show(after) if after_rev else "not known (conflicts)"))

    # LineageOS's manifest: what changed since the base
    out()
    out(f"== LineageOS's manifest since {lbase[:12]}")
    added = sorted(set(now) - set(base))
    removed = sorted(set(base) - set(now))
    changed = []
    for path in sorted(set(now) & set(base)):
        b, n = base[path], now[path]
        what = [k for k in ("url", "revision", "groups", "depth", "kids") if getattr(b, k) != getattr(n, k)]
        if what:
            changed.append((path, what, b, n))
    for path in added:
        n = now[path]
        out(f"added {path} ({n.name} {tag_of(n.revision) or branch_of(n.revision)})"
            + ("; ExpressiveOS's manifest has it already" if path in ours else ""))
    for path in removed:
        out(f"removed {path} ({base[path].name})" + ("; ExpressiveOS's manifest still has it" if path in ours else ""))
    for path, what, b, n in changed:
        d = []
        if "url" in what:
            d.append(f"{b.name} -> {n.name}")
        if "revision" in what:
            d.append(f"{b.revision} -> {n.revision}")
        d += [k for k in what if k in ("groups", "depth", "kids")]
        o = ours.get(path)
        if o is None:
            where = " (not in ExpressiveOS's manifest)"
        elif o.url == n.url and branch_of(o.upstream or o.revision) == branch_of(n.revision):
            where = "; ExpressiveOS's manifest has it already"
        elif o.remote == "expressiveos":
            where = f"; ExpressiveOS's fork {o.name} is here"
        else:
            where = ""
        out(f"changed {path}: {'; '.join(d)}{where}")
    if not (added or removed or changed):
        out("no project added, removed or changed")

    # The kernel: the kit's pins against LineageOS's kernel manifest today
    out()
    out(f"== Kernel: pins/kernel.xml against {eos['EOS_KERNEL_MANIFEST_URL']} ({eos['EOS_KERNEL_MANIFEST_BRANCH']}) today")
    try:
        kgd = fetch_manifest(work, "kernel.git", eos["EOS_KERNEL_MANIFEST_URL"], eos["EOS_KERNEL_MANIFEST_BRANCH"])
        knowrev = git("rev-parse", f"refs/heads/{eos['EOS_KERNEL_MANIFEST_BRANCH']}", gd=kgd).stdout.strip()
        know, _, _ = flatten(reader(kgd, knowrev), eos["EOS_KERNEL_MANIFEST_URL"])
        pins, _, _ = flatten(lambda n: open(os.path.join(kit, "pins", "kernel.xml")).read(),
                             eos["EOS_KERNEL_MANIFEST_URL"])
        def kernel_move(path):
            # A line for a kernel project that moves, or None
            if path not in know:
                return f"{path}: not in LineageOS's kernel manifest any more"
            n = know[path]
            if path not in pins:
                return f"{path}: new in LineageOS's kernel manifest ({n.name} {tag_of(n.revision) or branch_of(n.revision)})"
            sha = ls_remote(n.url, ref_of(n.revision))
            if sha == pins[path].revision:
                return None
            t0, t1 = tag_of(pins[path].upstream), tag_of(n.revision)
            return (f"{path}: {pins[path].revision[:12]} -> {(sha or 'nothing')[:12]}"
                    + (f" (tag {t0} -> {t1})" if t1 and t0 != t1 else f" ({branch_of(n.revision)})"))
        kmoves = kerr = 0
        for path in sorted(set(know) | set(pins)):
            try:
                line = kernel_move(path)
            except Fail as e:
                problems.append(f"kernel {path}: {e}")
                kerr += 1
                continue
            if line:
                kmoves += 1
                out(line)
        out(f"-- {kmoves} of {len(know)} kernel projects move" + (f", {kerr} couldn't be checked" if kerr else ""))
    except Fail as e:
        problems.append(f"kernel: {e}")

    # KernelSU Next and NeoZygisk: newest release tags
    out()
    out("== KernelSU Next and NeoZygisk (ksu/ksu.conf)")
    for label, url, have in (("KernelSU Next", ksu.get("src_url"), ksu.get("version")),
                             ("NeoZygisk", ksu.get("zygisk_src_url"), ksu.get("zygisk_version"))):
        try:
            tags = re.findall(r"refs/tags/(v?\d+(?:\.\d+)+)$", git("ls-remote", "--tags", url, timeout=180).stdout, re.M)
            newest = max(tags, key=lambda t: tuple(int(x) for x in t.lstrip("v").split("."))) if tags else None
            out(f"{label}: ksu.conf has {have}, newest release tag {newest}" + ("" if newest == have else " (newer)"))
        except (Fail, ValueError) as e:
            problems.append(f"{label}: {e}")
    out()
    out("Not checked here: Google's factory images for cheetah (firmware and vendor blobs; update-firmware.sh)")

    errors = sorted(r for r in results if results[r]["kind"] == "error")
    out()
    if problems:
        out("== Couldn't check, or needs a look")
        for s in problems:
            out(s)
    stamp = started.strftime("%Y%m%d-%H%M%S")
    rep = os.path.join(work, "reports", f"update-check-{stamp}.txt")
    out(f"report: {rep}; work folder {work}: {git_du(work)}")
    out(f"UPDATE_CHECK={'OK' if not problems else 'INCOMPLETE'} (forks: {nconf} conflict; "
        f"{len(moving)} other projects move; {len(errors)} errors)")
    with open(rep, "w") as f:
        f.write("\n".join(lines) + "\n")

# ---- the update: plan and push ------------------------------------------------------------
#
# An update is a folder of the kit, sources/updates/<id>/ (id: its month, 2026-11; 2026-11-2
# for a second one that month), committed before it runs:
#   update.conf                        LINEAGE_MANIFEST=<the commit of LineageOS's manifest it takes>
#   resolutions/<project path>.patch   how a fork's merge that conflicts is resolved
# plan makes the whole update on the build server and pushes nothing: each fork's merge of
# LineageOS's commits (a commit in its scratch repo), every other project's new commit, the
# new manifest as a commit on top of GitHub's, and the kernel pins to take. push pushes what
# the last plan of that update made, once nothing it merged into has moved: the forks' merges
# to their branches (fast-forwards, never forced), then the manifest's commit to branch
# update/<id> of ExpressiveOS's manifest, for a pull request into its own branch.
#
# A resolution's first line is "merge <fork commit> <LineageOS commit>", the merge it's for.
# Then a line "resolved <file>" for each file that merge conflicts in, any notes, and last git
# diff --binary --no-renames from the fork commit to the resolved files (and any other file the
# resolution changes). A resolved file the diff leaves out is the fork's, as it was.

UPDATE_ID = re.compile(r"[0-9]{4}-(?:0[1-9]|1[0-2])(?:-[2-9])?")
MARKER = re.compile(rb"^(?:<<<<<<<|>>>>>>>)(?: |$)", re.M)

def esc(v):
    return v.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")

class Resolution:
    def __init__(self, path, data):
        self.path = path
        where = f"resolutions/{path}.patch"
        i = 0 if data.startswith(b"diff --git ") else data.find(b"\ndiff --git ")
        head, self.patch = (data, b"") if i < 0 else (data[:i], data[i:].lstrip(b"\n"))
        lines = head.decode("utf-8", "surrogateescape").split("\n")
        m = re.fullmatch(r"merge ([0-9a-f]{40}) ([0-9a-f]{40})", lines[0])
        if not m:
            raise Fail(f"{where}: the first line must be: merge <fork commit> <LineageOS commit>")
        self.ours, self.theirs = m.groups()
        self.resolved = [l[len("resolved "):] for l in lines[1:] if l.startswith("resolved ")]
        if len(set(self.resolved)) != len(self.resolved) or not all(self.resolved):
            raise Fail(f"{where}: a resolved line is empty or there twice")
        self.touched = []
        for line in self.patch.split(b"\n"):
            if not line.startswith(b"diff --git "):
                continue
            # "diff --git a/<file> b/<file>": one file, never a rename (git diff --no-renames)
            rest = line[len(b"diff --git "):].decode("utf-8", "surrogateescape")
            f = rest[2:2 + (len(rest) - 5) // 2]
            if rest != f"a/{f} b/{f}" or not f:
                raise Fail(f"{where}: can't read the file of '{line[:200].decode(errors='replace')}' "
                           f"(a rename, or a name git quotes: not supported)")
            self.touched.append(f)
        if any(l.startswith((b"rename from ", b"copy from ")) for l in self.patch.split(b"\n")):
            raise Fail(f"{where}: has a rename or copy; make it with git diff --no-renames")

class Update:
    # sources/updates/<id>/ of this kit, read and checked; digest: of all its files
    def __init__(self, uid):
        if not UPDATE_ID.fullmatch(uid):
            fail(f"'{uid}': an update's id is its month, as 2026-11 (2026-11-2 for a second one that month)")
        self.id = uid
        self.dir = os.path.join(here, "updates", uid)
        cf = os.path.join(self.dir, "update.conf")
        if not os.path.isfile(cf) or os.path.islink(cf):
            fail(f"this kit has no sources/updates/{uid}/update.conf: an update starts as a commit of it "
                 f"(README.md, \"The monthly update\")")
        c = conf(cf)
        if set(c) != {"LINEAGE_MANIFEST"} or not SHA.fullmatch(c["LINEAGE_MANIFEST"]):
            fail(f"sources/updates/{uid}/update.conf must hold LINEAGE_MANIFEST=<commit of LineageOS's manifest>, nothing else")
        self.lineage = c["LINEAGE_MANIFEST"]
        self.resolutions = {}
        h = hashlib.sha256()
        for root, dirs, files in os.walk(self.dir):
            dirs.sort()
            for f in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, self.dir)
                if os.path.islink(full) or not os.path.isfile(full):
                    fail(f"sources/updates/{uid}/{rel}: not a plain file")
                data = open(full, "rb").read()
                h.update(f"{rel}\0{len(data)}\0".encode("utf-8", "surrogateescape") + data)
                if rel == "update.conf":
                    continue
                if not (rel.startswith("resolutions" + os.sep) and rel.endswith(".patch")):
                    fail(f"sources/updates/{uid}/{rel}: an update holds update.conf and resolutions/<project path>.patch, nothing else")
                path = rel[len("resolutions" + os.sep):-len(".patch")]
                try:
                    self.resolutions[path] = Resolution(path, data)
                except Fail as e:
                    fail(f"sources/updates/{uid}/{e}")
        self.digest = h.hexdigest()

def ident_of(eos):
    m = re.fullmatch(r"([^<>]+?) <([^<>\s]+@[^<>\s]+)>", eos.get("EOS_UPDATE_IDENT", ""))
    if not m:
        fail("eos.conf's EOS_UPDATE_IDENT isn't 'Name <email>'")
    return m.groups()

def commit_tree(gd, tree, parents, msg, ident, when):
    name, email = ident
    env = {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_AUTHOR_DATE": when,
           "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email, "GIT_COMMITTER_DATE": when}
    args = ["commit-tree", tree]
    for p in parents:
        args += ["-p", p]
    return git(*args, "-F", "-", gd=gd, env=env, input=msg).stdout.strip()

class Index:
    # A scratch index for building a tree in a bare repo; gone after the with
    def __enter__(self):
        self.dir = tempfile.mkdtemp(prefix="eos-index.")
        return {"GIT_INDEX_FILE": os.path.join(self.dir, "index")}
    def __exit__(self, *exc):
        shutil.rmtree(self.dir, ignore_errors=True)

def entry(gd, rev, f):
    # (mode, type, object) of file f in rev, or None
    for e in git("ls-tree", "-z", rev, "--", f, gd=gd).stdout.split("\0"):
        meta, _, name = e.partition("\t")
        if name == f:
            return tuple(meta.split())
    return None

def merge_conflicted(gd, ours, theirs):
    # (tree, conflicted files) of merging theirs into ours; on a conflict the tree has the
    # files with conflict markers
    r = git("merge-tree", "--write-tree", "--name-only", "--no-messages", ours, theirs, gd=gd,
            timeout=1800, ok=(0, 1))
    lines = r.stdout.splitlines()
    return lines[0], ([l for l in lines[1:] if l] if r.returncode == 1 else [])

def resolve(gd, tree, files, ours, res):
    # The merged tree with the resolution put in: each file it resolves or changes is the
    # fork's (or none, if the fork has none), with the resolution's diff on top
    if sorted(res.resolved) != sorted(files):
        miss = sorted(set(files) - set(res.resolved))
        extra = sorted(set(res.resolved) - set(files))
        raise Fail("the merge conflicts in files the resolution doesn't list: " + ", ".join(miss) if miss
                   else "the resolution lists files the merge doesn't conflict in: " + ", ".join(extra))
    with Index() as env:
        git("read-tree", tree, gd=gd, env=env)
        for f in sorted(set(res.resolved) | set(res.touched)):
            e = entry(gd, ours, f)
            if e and e[1] == "tree":
                raise Fail(f"{f} is a folder in the fork")
            if e:
                git("update-index", "--add", "--cacheinfo", f"{e[0]},{e[2]},{f}", gd=gd, env=env)
            else:
                # (--force-remove needs a work tree; mode 0 takes the path out of the index)
                git("update-index", "--index-info", gd=gd, env=env, input=f"0 {'0' * 40}\t{f}\n")
        if res.patch:
            git("apply", "--cached", "--whitespace=nowarn", "-", gd=gd, env=env, input=res.patch, raw=True)
        out = git("write-tree", gd=gd, env=env).stdout.strip()
    for f in sorted(set(res.resolved) | set(res.touched)):
        e = entry(gd, out, f)
        if e and e[1] == "blob":
            data = git("cat-file", "blob", e[2], gd=gd, raw=True).stdout
            if b"\0" not in data[:8000] and MARKER.search(data):
                raise Fail(f"{f} still has conflict markers after the resolution")
    return out

def show_conflicts(out, gd, path, ours, theirs, files, uid, max_lines=400):
    # For writing a resolution: the merge, each conflicting file's commits on both sides, and
    # its conflicts (zdiff3: the fork's, the merge base's, LineageOS's) with 3 lines around
    bases = git("merge-base", "--all", ours, theirs, gd=gd).stdout.split()
    out(f"--- {path}: LineageOS's {theirs} into the fork's {ours} (merge base {', '.join(bases) or 'none'})")
    out(f"    resolution: sources/updates/{uid}/resolutions/{path}.patch, starting")
    out(f"      merge {ours} {theirs}")
    for f in files:
        out(f"      resolved {f}")
    r = git("-c", "merge.conflictStyle=zdiff3", "merge-tree", "--write-tree", "--no-messages", ours, theirs,
            gd=gd, timeout=1800, ok=(0, 1))
    lines = r.stdout.split("\n")
    tree, stages = lines[0], {}
    for l in lines[1:]:
        m = re.fullmatch(r"\d+ [0-9a-f]+ (\d)\t(.*)", l)
        if m:
            stages.setdefault(m.group(2), set()).add(int(m.group(1)))
    kinds = {frozenset({1, 2, 3}): "both changed it", frozenset({2, 3}): "both added it",
             frozenset({1, 2}): "LineageOS deleted it, the fork changed it",
             frozenset({1, 3}): "the fork deleted it, LineageOS changed it"}
    for f in files:
        st = frozenset(stages.get(f, ()))
        out(f"== {path}/{f}: {kinds.get(st, 'stages ' + ','.join(map(str, sorted(st))))}")
        for side, rng in (("the fork's", f"{theirs}..{ours}"), ("LineageOS's", f"{ours}..{theirs}")):
            log = git("log", "-n", "8", "--format=%h %cs %s", rng, "--", f, gd=gd).stdout.strip()
            out(f"   {side} commits on it:" + ("" if log else " none"))
            for l in log.splitlines():
                out(f"     {l[:160]}")
        e = entry(gd, tree, f)
        if not e or e[1] != "blob":
            out("   (no file here in the merged tree)")
            continue
        data = git("cat-file", "blob", e[2], gd=gd, raw=True).stdout
        if b"\0" in data[:8000]:
            sizes = []
            for label, rev in (("fork", ours), ("LineageOS", theirs)):
                x = entry(gd, rev, f)
                sizes.append(f"{label} " + (git("cat-file", "-s", x[2], gd=gd).stdout.strip() + " bytes" if x else "none"))
            out(f"   binary ({', '.join(sizes)}): resolve by taking one side")
            continue
        text = data.decode("utf-8", "replace").split("\n")
        show, start = set(), None
        for i, line in enumerate(text):
            if line.startswith("<<<<<<< "):
                start = i
            elif line.startswith(">>>>>>> ") and start is not None:
                show.update(range(max(0, start - 3), min(len(text), i + 4)))
                start = None
        prev = None
        for n, i in enumerate(sorted(show)):
            if n == max_lines:
                out(f"   ... ({len(show) - n} more lines)")
                break
            if prev is not None and i != prev + 1:
                out("   ...")
            out(f"   {i + 1:6} {text[i][:300]}")
            prev = i

def make_resolution(a):
    # A resolution from a clone where the fork's commit has LineageOS's merged in by hand (git
    # merge --no-commit, conflicts fixed, every file git added): printed, for
    # sources/updates/<id>/resolutions/<project path>.patch
    gd = git("-C", a.repo, "rev-parse", "--absolute-git-dir").stdout.strip()
    ours = git("rev-parse", "HEAD", gd=gd).stdout.strip()
    r = git("rev-parse", "-q", "--verify", "MERGE_HEAD", gd=gd, ok=(0, 1))
    if r.returncode:
        fail(f"{a.repo} has no merge going: git merge --no-commit <LineageOS commit> there first")
    theirs = r.stdout.strip()
    if git("-C", a.repo, "diff", "--name-only", "--diff-filter=U", gd=None).stdout.strip():
        fail(f"{a.repo} has files still conflicting: fix them and git add them first")
    mtree, files = merge_conflicted(gd, ours, theirs)
    if not files:
        fail("that merge doesn't conflict: the update merges it without a resolution")
    itree = git("-C", a.repo, "write-tree").stdout.strip()
    touched = [f for f in git("diff", "-z", "--name-only", "--no-renames", mtree, itree, gd=gd).stdout.split("\0") if f]
    left = sorted(set(files) - set(touched))
    if left:
        fail(f"still as the merge left them, conflict markers and all: {', '.join(left)}")
    patch = git("diff", "--binary", "--no-renames", "--full-index", ours, itree, "--", *touched, gd=gd, raw=True).stdout
    head = f"merge {ours} {theirs}\n" + "".join(f"resolved {f}\n" for f in files)
    also = sorted(set(touched) - set(files))
    if also:
        head += "also changed: " + ", ".join(also) + "\n"
    data = head.encode("utf-8", "surrogateescape") + b"\n" + patch
    Resolution("this", data)
    sys.stdout.buffer.write(data)

# ---- the manifest as text: ExpressiveOS's default.xml, changed line by line ----------------

class ManifestText:
    # own-manifest.py's layout: a header (declaration, comment, <manifest>, remotes, default),
    # one project per line (or a line, its linkfiles/copyfiles/annotations, </project>), then
    # </manifest>. Read and written back exactly, or not at all
    PROJ = re.compile(r'  <project ((?:[A-Za-z][A-Za-z0-9_-]*="[^"]*" ?)+?)( />|>)')
    KID = re.compile(r'    <(linkfile|copyfile|annotation) ((?:[A-Za-z][A-Za-z0-9_-]*="[^"]*" ?)+?) />')
    ATTR = re.compile(r'([A-Za-z][A-Za-z0-9_-]*)="([^"]*)"')

    def __init__(self, text):
        lines = text.split("\n")
        i = next((n for n, l in enumerate(lines) if l.startswith("  <project ")), None)
        if i is None:
            raise Fail("the manifest has no project lines in own-manifest.py's layout")
        self.header, self.projects = lines[:i], []
        while i < len(lines) and lines[i].startswith("  <project "):
            m = self.PROJ.fullmatch(lines[i])
            if not m:
                raise Fail(f"can't read the manifest's line {i + 1}: {lines[i][:200]}")
            attrs = self.attrs(m.group(1), i)
            kids = []
            i += 1
            if m.group(2) == ">":
                while i < len(lines) and lines[i] != "  </project>":
                    k = self.KID.fullmatch(lines[i])
                    if not k:
                        raise Fail(f"can't read the manifest's line {i + 1}: {lines[i][:200]}")
                    kids.append((k.group(1), self.attrs(k.group(2), i)))
                    i += 1
                if i == len(lines):
                    raise Fail("a <project> in the manifest isn't closed")
                i += 1
            self.projects.append([attrs, kids, m.group(2) == ">"])
        self.footer = lines[i:]
        if self.footer != ["</manifest>", ""]:
            raise Fail(f"the manifest has something after its projects: {' '.join(self.footer)[:200]}")
        if self.text() != text:
            raise Fail("the manifest doesn't read back as it is (not own-manifest.py's layout)")

    def attrs(self, s, i):
        a = self.ATTR.findall(s)
        if " ".join(f'{k}="{v}"' for k, v in a) != s.rstrip(" ") or len({k for k, _ in a}) != len(a):
            raise Fail(f"can't read the attributes on the manifest's line {i + 1}")
        return a

    def text(self):
        out = list(self.header)
        for attrs, kids, open_ in self.projects:
            a = " ".join(f'{k}="{v}"' for k, v in attrs)
            if open_:
                out.append(f"  <project {a}>")
                out += [f"    <{t} " + " ".join(f'{k}="{v}"' for k, v in ka) + " />" for t, ka in kids]
                out.append("  </project>")
            else:
                out.append(f"  <project {a} />")
        return "\n".join(out + self.footer)

    def find(self, path):
        for p in self.projects:
            d = dict(p[0])
            if (d.get("path") or d.get("name")) == esc(path):
                return p
        return None

    @staticmethod
    def set(p, key, value, after=None):
        # value None drops the attribute; a new one goes after the attribute named by after
        attrs = p[0]
        for n, (k, _) in enumerate(attrs):
            if k == key:
                if value is None:
                    del attrs[n]
                else:
                    attrs[n] = (k, esc(value))
                return
        if value is not None:
            keys = [k for k, _ in attrs]
            attrs.insert(keys.index(after) + 1 if after in keys else len(attrs), (key, esc(value)))

    def set_remote_revision(self, name, old, new):
        for n, l in enumerate(self.header):
            if l.startswith(f'  <remote name="{esc(name)}" '):
                if f'revision="{esc(old)}"' not in l:
                    raise Fail(f"the manifest's remote {name} isn't on {old}")
                self.header[n] = l.replace(f'revision="{esc(old)}"', f'revision="{esc(new)}"')
                return
        raise Fail(f"the manifest has no remote {name}")

def manifest_problems(text):
    # What setup.sh refuses: anything but remotes, the default and projects (with linkfiles,
    # copyfiles, annotations), or a project not at a commit
    r = ET.fromstring(text)
    odd = {e.tag for e in r if e.tag not in ("remote", "default", "project", "notice", "contactinfo")}
    odd |= {"project/" + k.tag for p in r.iter("project") for k in p if k.tag not in ("linkfile", "copyfile", "annotation")}
    out = [f"has <{t}>" for t in sorted(odd)]
    out += [f"{p.get('path') or p.get('name')} isn't at a commit" for p in r.iter("project")
            if not SHA.fullmatch(p.get("revision") or "")]
    return out

# ---- plan --------------------------------------------------------------------------------

def last_update(read):
    # (LineageOS's manifest commit the last update took, its id) from the manifest repo's
    # last-update.conf, or the sources' base when no update has run yet
    try:
        text = read("last-update.conf")
    except Fail:
        return LINEAGE_BASE, None
    c = {}
    for line in text.split("\n"):
        m = re.fullmatch(r"([A-Z_]+)=(\S*)", line.strip())
        if m:
            c[m.group(1)] = m.group(2)
    if not SHA.fullmatch(c.get("LINEAGE_MANIFEST", "")):
        raise Fail("the manifest's last-update.conf has no LINEAGE_MANIFEST=<commit>")
    return c["LINEAGE_MANIFEST"], c.get("UPDATE")

def three_way(what, ours, base, now):
    # Does an update take LineageOS's change of a project's attribute from base to now? Where
    # ExpressiveOS's manifest has what LineageOS had; Fail where it has neither
    if base == now or ours == now:
        return False
    if ours == base:
        return True
    raise Fail(f"{what}: LineageOS changed it from {show(base)} to {show(now)}, ExpressiveOS's manifest has {show(ours)}")

def show(v):
    if isinstance(v, tuple):
        return "[" + ", ".join(f"{k} {s}->{d}" for k, s, d in v) + "]"
    return v or "-"

def los_changes(o, b, n):
    # What LineageOS's manifest changed for a project of ExpressiveOS's manifest that isn't
    # ExpressiveOS's own, from b (the last update's) to n (this one's): {} when nothing
    if b is None or n is None:
        return {}
    c = {}
    if three_way("its repo", o.url, b.url, n.url):
        c["repo"] = n
    if three_way("its branch", ref_of(o.upstream or o.revision), ref_of(b.revision), ref_of(n.revision)):
        c["branch"] = ref_of(n.revision)
    if three_way("its groups", o.groups, b.groups, n.groups):
        c["groups"] = n.groups
    if three_way("its clone-depth", o.depth or "", b.depth or "", n.depth or ""):
        c["depth"] = n.depth or ""
    if three_way("its linkfiles/copyfiles", o.kids, b.kids, n.kids):
        c["kids"] = n.kids
    return c

def plan(a):
    eos = conf(os.path.join(kit, "eos.conf"))
    upd = Update(a.id)
    ident = ident_of(eos)
    top = os.path.realpath(a.top)
    work = os.path.realpath(a.work)
    started = datetime.datetime.now(datetime.timezone.utc)
    when = f"@{int(started.timestamp())} +0000"
    udir = os.path.join(work, "updates", upd.id)
    os.makedirs(udir, exist_ok=True)
    os.makedirs(os.path.join(work, "reports"), exist_ok=True)
    for f in ("plan.json", "default.xml", "kernel.xml"):
        if os.path.exists(os.path.join(udir, f)):
            os.remove(os.path.join(udir, f))
    problems, lines = [], []
    def out(s=""):
        lines.append(s)
        print(s, flush=True)

    # ExpressiveOS's manifest as GitHub has it, which must be the tree's: the scratch repos
    # borrow the tree's objects, and the update's commit goes on top of GitHub's
    mbranch = eos["EOS_MANIFEST_BRANCH"]
    mgd = fetch_manifest(work, "eos.git", eos["EOS_MANIFEST_URL"], mbranch)
    parent = git("rev-parse", f"refs/heads/{mbranch}", gd=mgd).stdout.strip()
    tree_rev = git("-C", os.path.dirname(a.manifest), "rev-parse", "HEAD").stdout.strip()
    if tree_rev != parent:
        fail(f"the tree's manifest is {tree_rev[:12]}, GitHub's {mbranch} is {parent[:12]}: run expressiveos-setup "
             f"first (no build needed), so the update starts from what GitHub has")
    otext = git("show", f"{parent}:default.xml", gd=mgd).stdout
    mt = ManifestText(otext)
    ours, oremotes, odefault = flatten(reader(mgd, parent), eos["EOS_MANIFEST_URL"])
    lbase, lid = last_update(reader(mgd, parent))
    if lid == upd.id:
        fail(f"GitHub's manifest has update {upd.id} already (last-update.conf): an update runs once; the next is a new id")
    have = remote_sha(eos["EOS_MANIFEST_URL"], f"refs/heads/update/{upd.id}")
    if have:
        fail(f"{eos['EOS_MANIFEST_URL']} has a branch update/{upd.id} already ({have[:12]}): a push of this update "
             f"ran, so a new plan of it can't be pushed; merge or close that pull request, and the next update takes a new id")
    lbranch = branch_of(odefault.get("revision", ""))
    if not lbranch.startswith("lineage-"):
        fail(f"the manifest's default revision is '{odefault.get('revision')}', not a LineageOS branch")
    lgd = fetch_manifest(work, "lineage.git", LINEAGE_MANIFEST, lbranch)
    lhead = git("rev-parse", f"refs/heads/{lbranch}", gd=lgd).stdout.strip()
    if git("cat-file", "-e", f"{upd.lineage}^{{commit}}", gd=lgd, ok=(0, 1, 128)).returncode != 0 \
            or not is_ancestor(lgd, upd.lineage, lhead):
        fail(f"update.conf's LINEAGE_MANIFEST {upd.lineage[:12]} isn't on LineageOS's manifest's {lbranch}")
    if not is_ancestor(lgd, lbase, upd.lineage):
        fail(f"update.conf's LINEAGE_MANIFEST {upd.lineage[:12]} doesn't descend from {lbase[:12]}, "
             f"the LineageOS manifest the sources are on")
    now, nremotes, ndefault = flatten(reader(lgd, upd.lineage), LINEAGE_MANIFEST)
    base, bremotes, bdefault = flatten(reader(lgd, lbase), LINEAGE_MANIFEST)
    if ndefault.get("revision") != odefault.get("revision"):
        fail(f"LineageOS's manifest moved to {ndefault.get('revision')}: a new LineageOS version, not a monthly update")
    ldate = git("log", "-1", "--format=%cs", upd.lineage, gd=lgd).stdout.strip()

    out(f"== ExpressiveOS update {upd.id}: plan, {started:%Y-%m-%d %H:%M} UTC (nothing is pushed)")
    out(f"from ExpressiveOS's manifest {parent[:12]} (GitHub's {mbranch}, the tree's), LineageOS's manifest "
        f"{lbase[:12]} ({'update ' + lid if lid else 'the sources base'})")
    out(f"to LineageOS's manifest {upd.lineage[:12]} of {ldate} ({lbranch}; its branch is at {lhead[:12]} today), "
        f"commits as {ident[0]} <{ident[1]}>")
    out(f"kit: sources/updates/{upd.id} ({len(upd.resolutions)} resolution{'' if len(upd.resolutions) == 1 else 's'}, digest {upd.digest[:12]})")

    jobs = int(os.environ.get("EOS_UPDATE_JOBS", "6"))
    results, notes = {}, []
    # What LineageOS's manifest changed for the projects that follow it (not ExpressiveOS's
    # own): each follows its manifest entry's repo and branch (upstream), changed only where
    # LineageOS changed them since the last update
    changes = {}
    for path, o in ours.items():
        if o.remote == "expressiveos":
            continue
        try:
            changes[path] = los_changes(o, base.get(path), now.get(path))
        except Fail as e:
            results[path] = {"path": path, "kind": "error", "error": str(e)}
            problems.append(f"{path}: {e}")

    def one(p):
        n = now.get(p.path)
        r = {"path": p.path}
        if p.path == "evolution/manifest" or p.remote == "expressiveos" and n is None:
            r["kind"] = "own"
            r["new_rev"] = p.revision
            branch = branch_of(p.upstream or "refs/heads/expressiveos")
            tip = ls_remote(p.url, "refs/heads/" + branch)
            if p.path != "evolution/manifest" and tip != p.revision:
                r["note"] = f"its {branch} branch is at {(tip or 'nothing')[:12]}, the manifest keeps {p.revision[:12]}"
            return r
        if p.remote == "expressiveos":
            return plan_fork(p, n)
        r["kind"] = "upstream"
        c = changes[p.path]
        name, url = (c["repo"].name, c["repo"].url) if "repo" in c else (p.name, p.url)
        ref = c.get("branch") or ref_of(p.upstream or p.revision)
        if n is None:
            r["note"] = "not in LineageOS's manifest: follows its own upstream"
        if tag_of(ref) and tag_of(ref) == tag_of(p.upstream) and url == p.url:
            r["new_rev"] = p.revision
            return r
        sha = ls_remote(url, ref)
        if not sha:
            raise Fail(f"{url} has no {ref}")
        r["new_rev"] = sha
        if sha == p.revision:
            return r
        r["upstream"] = f"{name} {tag_of(ref) or branch_of(ref)}"
        if p.depth or "googlesource.com" in url:
            r["new"] = None
            return r
        with name_lock(p.name):
            gd = scratch(work, top, p)
            got = fetch(gd, p, url, ref)
            if got != sha:
                raise Fail(f"{url} {ref} moved while this ran ({sha[:12]}, then {got[:12]}); plan again")
            r["new"] = count(gd, p.revision, sha)
            if not is_ancestor(gd, p.revision, sha):
                raise Fail(f"{name} {branch_of(ref)} doesn't contain our commit {p.revision[:12]} (rewritten?)")
        return r

    def plan_fork(p, n):
        branch = branch_of(p.upstream or "refs/heads/expressiveos")
        r = {"path": p.path, "kind": "fork", "name": p.name, "url": p.url, "branch": branch,
             "upstream": f"{n.name} {tag_of(n.revision) or branch_of(n.revision)}"}
        tip = ls_remote(p.url, "refs/heads/" + branch)
        if not tip:
            raise Fail(f"{p.url} has no branch {branch}")
        up = ls_remote(n.url, ref_of(n.revision))
        if not up:
            raise Fail(f"{n.url} has no {n.revision}")
        with name_lock(p.name):
            gd = scratch(work, top, p)
            r["gd"] = gd
            git("update-ref", refname(p, "ours"), p.revision, gd=gd)
            ours_c = p.revision
            if tip != p.revision:
                ours_c = fetch(gd, p, p.url, "refs/heads/" + branch, "tip")
                if ours_c != tip:
                    raise Fail(f"its {branch} branch moved while this ran; plan again")
                if not is_ancestor(gd, p.revision, ours_c):
                    raise Fail(f"its {branch} branch ({tip[:12]}) doesn't descend from the manifest's {p.revision[:12]}")
                r["note"] = f"its {branch} branch has {count(gd, p.revision, ours_c)} commits the manifest doesn't pin yet; the update takes them"
            got = fetch(gd, p, n.url, up if SHA.fullmatch(n.revision) else ref_of(n.revision))
            if got != up:
                raise Fail(f"{n.url} {n.revision} moved while this ran; plan again")
            r["tip"], r["up"] = ours_c, up
            r["new"] = count(gd, ours_c, up)
            res = upd.resolutions.get(p.path)
            if r["new"] == 0:
                r["merge"], r["new_rev"] = None, ours_c
                if res:
                    r["status"] = "resolution unused"
                return r
            tree, files = merge_conflicted(gd, ours_c, up)
            r["files"] = files
            if files:
                if res is None:
                    r["status"] = "unresolved"
                    return r
                if (res.ours, res.theirs) != (ours_c, up):
                    r["status"] = "stale resolution"
                    r["error"] = (f"the resolution is for merging {res.theirs[:12]} into {res.ours[:12]}; "
                                  f"the merge now is {up[:12]} into {ours_c[:12]}")
                    return r
                try:
                    tree = resolve(gd, tree, files, ours_c, res)
                except Fail as e:
                    r["status"] = "bad resolution"
                    r["error"] = str(e)
                    return r
                r["also"] = sorted(set(res.touched) - set(files))
            elif res:
                r["status"] = "resolution unused"
                return r
            date = git("log", "-1", "--format=%cs", up, gd=gd).stdout.strip()
            msg = (f"Merge LineageOS {tag_of(n.revision) or branch_of(n.revision)} into {branch}\n\n"
                   f"ExpressiveOS update {upd.id}: {n.name} {tag_of(n.revision) or branch_of(n.revision)} at "
                   f"{up[:12]} ({date}), {commits(r['new'])}.\n")
            if files:
                msg += (f"\nConflicts resolved (expressiveos-cheetah/sources/updates/{upd.id}/resolutions/{p.path}.patch):\n"
                        + "".join(f"\t{f}\n" for f in files))
            merge = commit_tree(gd, tree, [ours_c, up], msg, ident, when)
            git("update-ref", refname(p, "merge"), merge, gd=gd)
            r["merge"], r["new_rev"], r["date"] = merge, merge, date
            return r

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(one, p): p for p in ours.values() if p.path not in results}
        for f in concurrent.futures.as_completed(futs):
            p = futs[f]
            try:
                results[p.path] = f.result()
            except Fail as e:
                results[p.path] = {"path": p.path, "kind": "error", "error": str(e)}
                problems.append(f"{p.path}: {e}")
    for path in sorted(set(upd.resolutions) - set(r["path"] for r in results.values() if r["kind"] == "fork")):
        problems.append(f"resolutions/{path}.patch: {path} isn't one of ExpressiveOS's forks of a LineageOS repo")

    forks = sorted((r for r in results.values() if r["kind"] == "fork"), key=lambda r: r["path"])
    out()
    out(f"== Forks of LineageOS's and AOSP's repos ({len(forks)}): LineageOS's commits merged into each")
    for r in forks:
        s = f"{r['path']} <- {r['upstream']}: "
        if r.get("status") in ("unresolved", "stale resolution", "bad resolution", "resolution unused"):
            s += f"{commits(r['new'])}, {r['status'].upper()}" + (f": {r['error']}" if r.get("error") else "")
            if r.get("files"):
                s += f" (conflicts in {len(r['files'])} file{'' if len(r['files']) == 1 else 's'})"
            problems.append(f"{r['path']}: {r['status']}")
        elif r["merge"] is None:
            s += "up to date"
        else:
            s += f"{commits(r['new'])} (newest {r['date']}), merge {r['merge'][:12]}"
            if r.get("files"):
                s += f", {len(r['files'])} conflicting file{'' if len(r['files']) == 1 else 's'} resolved"
                if r.get("also"):
                    s += f", the resolution also changes {', '.join(r['also'])}"
        if r.get("note"):
            s += f" [{r['note']}]"
        out(s)
    merged = [r for r in forks if r.get("merge")]
    out(f"-- {len(merged)} merged ({sum(1 for r in merged if r.get('files'))} with conflicts resolved), "
        f"{sum(1 for r in forks if r.get('merge') is None and not r.get('status'))} up to date")
    need = [r for r in forks if r.get("status") in ("unresolved", "stale resolution", "bad resolution")]
    if need:
        out()
        out("== Conflicts to resolve (resolutions/<path>.patch: see the top of this section of update.py)")
        for r in need:
            try:
                show_conflicts(out, r["gd"], r["path"], r["tip"], r["up"], r["files"], upd.id)
            except Fail as e:
                out(f"--- {r['path']}: can't show the conflicts: {e}")

    ups = sorted((r for r in results.values() if r["kind"] == "upstream"), key=lambda r: r["path"])
    moving = [r for r in ups if r["new_rev"] != ours[r["path"]].revision]
    out()
    out(f"== LineageOS's and AOSP's projects ({len(ups)}): {len(moving)} move")
    for r in moving:
        out(f"{r['path']} <- {r['upstream']}: {ours[r['path']].revision[:12]} -> {r['new_rev'][:12]}, "
            + ("not counted" if r["new"] is None else commits(r["new"])) + (f" [{r['note']}]" if r.get("note") else ""))
    for r in sorted((r for r in results.values() if r["kind"] == "own" and r.get("note")), key=lambda r: r["path"]):
        out(f"{r['path']} (ExpressiveOS's own, unchanged): {r['note']}")

    # The manifest: every project's new commit, and what LineageOS's manifest itself changed
    # since the last update (repos, branches, groups, depths, linkfiles; projects added),
    # where ExpressiveOS's manifest has what LineageOS had
    out()
    out(f"== ExpressiveOS's manifest: LineageOS's manifest changes since {lbase[:12]}")
    fetch_of = {name: urllib.parse.urljoin(eos["EOS_MANIFEST_URL"].rstrip("/"), r["fetch"].rstrip("/")).rstrip("/")
                for name, r in oremotes.items()}
    def our_remote(lp):
        # ExpressiveOS's remote for a project of LineageOS's manifest: the one fetching from
        # the same place
        for name in sorted(fetch_of):
            if fetch_of[name] == lp.fetch:
                return name
        raise Fail(f"ExpressiveOS's manifest has no remote for {lp.fetch}")
    expect = {path: (ours[path].url, r["new_rev"]) for path, r in results.items() if r.get("new_rev")}
    nchanges = 0
    for path in sorted(set(now) - set(base) - set(ours)):
        n = now[path]
        try:
            ref = ref_of(n.revision)
            sha = ls_remote(n.url, ref)
            if not sha:
                raise Fail(f"{n.url} has no {ref}")
            rn = our_remote(n)
            attrs = [("name", esc(n.name))] + ([] if n.path == n.name else [("path", esc(n.path))])
            attrs += [] if rn == odefault.get("remote") else [("remote", esc(rn))]
            attrs += [("revision", sha), ("upstream", esc(ref)), ("dest-branch", esc(ref))]
            attrs += [("groups", esc(n.groups))] if n.groups else []
            attrs += [("clone-depth", esc(n.depth))] if n.depth else []
            kids = [(k, [("src", esc(src)), ("dest", esc(dest))]) for k, src, dest in n.kids]
            mt.projects.append([attrs, kids, bool(kids)])
            expect[path] = (f"{fetch_of[rn]}/{n.name}", sha)
            out(f"added {path} ({n.name} {tag_of(ref) or branch_of(ref)}, {sha[:12]})")
            nchanges += 1
        except Fail as e:
            problems.append(f"manifest, adding {path}: {e}")
    for path in sorted(set(base) - set(now)):
        if path in ours and ours[path].remote != "expressiveos":
            out(f"LineageOS dropped {path}: kept, following its own upstream")
    for path in sorted(set(base) & set(now) & set(ours)):
        b, n, o = base[path], now[path], ours[path]
        if o.remote == "expressiveos":
            if (b.url, ref_of(b.revision)) != (n.url, ref_of(n.revision)):
                out(f"{path}: LineageOS takes it from {n.name} {n.revision} now (was {b.name} {b.revision}); "
                    f"ExpressiveOS's fork merged that")
            continue
        c = changes.get(path)
        if not c:
            continue
        try:
            p = mt.find(path)
            if p is None:
                raise Fail("not in the manifest's text")
            did = []
            if "repo" in c:
                ManifestText.set(p, "name", n.name)
                rn = our_remote(n)
                ManifestText.set(p, "remote", None if rn == odefault.get("remote") else rn,
                                 after="path" if "path" in dict(p[0]) else "name")
                expect[path] = (n.url, expect[path][1])
                did.append(f"repo {b.name} -> {n.name}")
            if "branch" in c:
                ManifestText.set(p, "upstream", c["branch"])
                ManifestText.set(p, "dest-branch", c["branch"], after="upstream")
                did.append(f"branch {b.revision} -> {n.revision}")
            if "groups" in c:
                ManifestText.set(p, "groups", c["groups"] or None, after="dest-branch")
                did.append("groups")
            if "depth" in c:
                ManifestText.set(p, "clone-depth", c["depth"] or None)
                did.append("clone-depth")
            if "kids" in c:
                keep = [k for k in p[1] if k[0] == "annotation"]
                p[1] = [(k, [("src", esc(src)), ("dest", esc(dest))]) for k, src, dest in c["kids"]] + keep
                p[2] = bool(p[1])
                did.append("linkfiles/copyfiles")
            out(f"changed {path}: {'; '.join(did)}")
            nchanges += 1
        except Fail as e:
            problems.append(f"manifest, {path}: {e}")
    try:
        old_tag = (bremotes.get("aosp") or {}).get("revision", "")
        new_tag = (nremotes.get("aosp") or {}).get("revision", "")
        if three_way("the aosp remote's revision", (oremotes.get("aosp") or {}).get("revision", ""), old_tag, new_tag):
            mt.set_remote_revision("aosp", old_tag, new_tag)
            out(f"Google's AOSP tag: {tag_of(old_tag) or old_tag} -> {tag_of(new_tag) or new_tag}")
            nchanges += 1
    except Fail as e:
        problems.append(f"manifest: {e}")
    if not nchanges:
        out("nothing but commits")
    for path, (url, rev) in expect.items():
        p = mt.find(path)
        if p is not None:
            ManifestText.set(p, "revision", rev)

    # The platform security patch level before and after (vendor/lineage's flag)
    release = eos["EOS_LUNCH"].split("-")[1]
    out()
    r = results.get("vendor/lineage")
    if r and r.get("gd") and r.get("new_rev"):
        try:
            before = spl(r["gd"], ours["vendor/lineage"].revision, release)[0]
            after = spl(r["gd"], r["new_rev"], release)[0]
            out(f"== Security patch level (release config {release}): {before} -> {after}"
                + ("" if before != after else " (unchanged: has LineageOS bumped it yet?)"))
        except Fail as e:
            problems.append(f"security patch level: {e}")

    # The kernel: the pins to take (the kit's pins/kernel.xml is changed by hand, from these)
    out()
    kfile = os.path.join(udir, "kernel.xml")
    try:
        kgd = fetch_manifest(work, "kernel.git", eos["EOS_KERNEL_MANIFEST_URL"], eos["EOS_KERNEL_MANIFEST_BRANCH"])
        krev = git("rev-parse", f"refs/heads/{eos['EOS_KERNEL_MANIFEST_BRANCH']}", gd=kgd).stdout.strip()
        know, _, _ = flatten(reader(kgd, krev), eos["EOS_KERNEL_MANIFEST_URL"])
        ktext = open(os.path.join(kit, "pins", "kernel.xml")).read()
        pins, _, _ = flatten(lambda n: ktext, eos["EOS_KERNEL_MANIFEST_URL"])
        if set(know) != set(pins):
            raise Fail(f"LineageOS's kernel manifest has other projects than pins/kernel.xml "
                       f"(+{sorted(set(know) - set(pins))} -{sorted(set(pins) - set(know))}): change the pins by hand")
        kmoves = []
        for path in sorted(know):
            sha = ls_remote(know[path].url, ref_of(know[path].revision))
            if not sha:
                raise Fail(f"{know[path].url} has no {know[path].revision}")
            if sha != pins[path].revision:
                kmoves.append((path, pins[path].revision, sha))
        out(f"== Kernel (LineageOS's {eos['EOS_KERNEL_MANIFEST_BRANCH']} kernel manifest, {krev[:12]}): "
            f"{len(kmoves)} of {len(know)} projects move")
        for path, old, new in kmoves:
            if ktext.count(f'revision="{old}"') != 1:
                raise Fail(f"pins/kernel.xml has {old[:12]} other than once")
            ktext = ktext.replace(f'revision="{old}"', f'revision="{new}"')
            out(f"{path}: {old[:12]} -> {new[:12]}")
        if kmoves:
            with open(kfile, "w") as f:
                f.write(ktext)
            out(f"pins/kernel.xml to take: {kfile} (the kit's update commit carries it)")
            out("----- BEGIN kernel.xml -----")
            for l in ktext.rstrip("\n").split("\n"):
                out(l)
            out("----- END kernel.xml -----")
    except Fail as e:
        notes.append(f"kernel: {e}")

    # The new manifest, checked as setup.sh will, and committed on top of GitHub's
    ntext = mt.text()
    ok = not problems
    if ok:
        try:
            bad = manifest_problems(ntext)
            if bad:
                raise Fail("; ".join(bad[:10]))
            got, _, _ = flatten(lambda n: ntext, eos["EOS_MANIFEST_URL"])
            if set(got) != set(expect):
                raise Fail(f"its projects aren't the planned ones: {sorted(set(got) ^ set(expect))[:10]}")
            wrong = [path for path, (url, rev) in expect.items() if (got[path].url, got[path].revision) != (url, rev)]
            if wrong:
                raise Fail(f"not as planned: {wrong[:10]}")
        except (Fail, ET.ParseError) as e:
            problems.append(f"the new manifest: {e}")
    out()
    if not problems:
        moved = sum(1 for path, (url, rev) in expect.items() if path not in ours or ours[path].revision != rev)
        conf_text = (f"# ExpressiveOS's last monthly update (expressiveos-cheetah/sources/update.py plan, push): the\n"
                     f"# commit of LineageOS's manifest it took. The next update takes LineageOS's changes since.\n"
                     f"UPDATE={upd.id}\nLINEAGE_MANIFEST={upd.lineage}\n")
        msg = (f"Update {upd.id}: LineageOS {lbranch} of {ldate}\n\n"
               f"LineageOS's manifest {upd.lineage[:12]} ({ldate}). {len(merged)} of ExpressiveOS's forks merge "
               f"LineageOS's commits ({sum(1 for r in merged if r.get('files'))} with conflicts resolved), "
               f"{len(moving)} of LineageOS's and AOSP's projects move; {moved} projects in all.\n"
               f"Made by expressiveos-cheetah/sources/update.py from sources/updates/{upd.id}.\n")
        with Index() as env:
            git("read-tree", parent, gd=mgd, env=env)
            for name, data in (("default.xml", ntext), ("last-update.conf", conf_text)):
                blob = git("hash-object", "-w", "--stdin", gd=mgd, input=data).stdout.strip()
                git("update-index", "--add", "--cacheinfo", f"100644,{blob},{name}", gd=mgd, env=env)
            tree = git("write-tree", gd=mgd, env=env).stdout.strip()
        mcommit = commit_tree(mgd, tree, [parent], msg, ident, when)
        git("update-ref", f"refs/eos/update/{upd.id}", mcommit, gd=mgd)
        with open(os.path.join(udir, "default.xml"), "w") as f:
            f.write(ntext)
        out(f"== The manifest's commit: {mcommit} on {parent[:12]}: {moved} projects change")
        out(f"   pushed by push as branch update/{upd.id} of {eos['EOS_MANIFEST_URL']}")

        # The pushes, asked of GitHub as push will ask: does the token reach each repo?
        token = os.environ.get("EOS_PUSH_TOKEN", "")
        urls = sorted({r["url"] for r in merged} | {eos["EOS_MANIFEST_URL"].rstrip("/")})
        https = [u for u in urls if u.startswith("https://")]
        if https and not token:
            out(f"push token: not here (EOS_PUSH_TOKEN), so the {len(https)} pushes aren't checked")
        elif https:
            denied = [u for u in https if receive_pack(u, token) != (200, "application/x-git-receive-pack-advertisement")]
            if denied:
                problems.append(f"the push token can't push to {', '.join(denied)}")
            out(f"push token: {len(https) - len(denied)} of {len(https)} repos to push to would take it")
        if not problems:
            plan_data = {"id": upd.id, "digest": upd.digest, "parent": parent, "manifest_commit": mcommit,
                         "manifest_url": eos["EOS_MANIFEST_URL"].rstrip("/"), "manifest_gd": mgd,
                         "lineage_manifest": upd.lineage, "made": started.isoformat(),
                         "forks": [{k: r[k] for k in ("path", "url", "branch", "tip", "up", "merge", "gd")}
                                   for r in merged]}
            with open(os.path.join(udir, "plan.json.tmp"), "w") as f:
                json.dump(plan_data, f, indent=1)
            os.replace(os.path.join(udir, "plan.json.tmp"), os.path.join(udir, "plan.json"))
    out()
    if notes:
        out("== Needs a look (doesn't stop the update)")
        for s in notes:
            out(s)
    if problems:
        out("== Not ready")
        for s in problems:
            out(s)
    stamp = started.strftime("%Y%m%d-%H%M%S")
    rep = os.path.join(work, "reports", f"update-plan-{upd.id}-{stamp}.txt")
    out(f"report: {rep}")
    state = "READY" if not problems else ("CONFLICTS" if need and len(problems) == len(need) else "NOT_READY")
    out(f"UPDATE_PLAN={state} ({len(merged)} forks merged, {len(need)} need a resolution, {len(problems)} problems)")
    with open(rep, "w") as f:
        f.write("\n".join(lines) + "\n")
    if problems:
        sys.exit(1)

# ---- push --------------------------------------------------------------------------------

def remote_sha(url, ref):
    # What <ref> is on <url> now (no cache), or None
    out = git("ls-remote", url, ref, timeout=180).stdout.split()
    return out[0] if out else None

# git asks this for a login to github.com: the token from the environment, never written down
HELPER = '!f() { test "$1" = get || exit 0; echo username=x-access-token; printf "password=%s\\n" "$EOS_PUSH_TOKEN"; }; f'

def push_one(gd, url, sha, ref):
    cfg = ["-c", "credential.helper=", "-c", "core.hooksPath=/dev/null"]
    if url.startswith("https://github.com/"):
        cfg += ["-c", f"credential.https://github.com.helper={HELPER}"]
    git(*cfg, "push", "--porcelain", "--no-verify", url, f"{sha}:{ref}", gd=gd, timeout=3600)

def push(a):
    eos = conf(os.path.join(kit, "eos.conf"))
    upd = Update(a.id)
    work = os.path.realpath(a.work)
    started = datetime.datetime.now(datetime.timezone.utc)
    pf = os.path.join(work, "updates", upd.id, "plan.json")
    if not os.path.isfile(pf):
        fail(f"no ready plan of update {upd.id} on this server ({pf}): run plan {upd.id} first")
    plan_data = json.load(open(pf))
    print(f"== ExpressiveOS update {upd.id}: push, {started:%Y-%m-%d %H:%M} UTC, the plan of {plan_data['made'][:16]}")
    if plan_data.get("pushed"):
        print(f"(pushed before, {plan_data['pushed'][:16]}: what's there already is left as it is)")
    if plan_data["digest"] != upd.digest:
        fail(f"this kit's sources/updates/{upd.id} isn't what the plan was made from: plan again")
    if plan_data["manifest_url"] != eos["EOS_MANIFEST_URL"].rstrip("/"):
        fail("the plan is for another manifest")
    token = os.environ.get("EOS_PUSH_TOKEN", "")
    urls = [f["url"] for f in plan_data["forks"]] + [plan_data["manifest_url"]]
    if any(u.startswith("https://") for u in urls) and not token:
        fail("EOS_PUSH_TOKEN is empty: the Actions secret EXPRESSIVEOS_PUSH_TOKEN isn't set")

    # Nothing pushed until every push is known to fit: GitHub's manifest and each fork where
    # the plan left them (or, for a fork, at the plan's merge already: a push run before)
    mbranch = eos["EOS_MANIFEST_BRANCH"]
    gh = remote_sha(plan_data["manifest_url"], f"refs/heads/{mbranch}")
    if gh != plan_data["parent"]:
        fail(f"GitHub's manifest {mbranch} is at {(gh or 'nothing')[:12]}, the plan was made on {plan_data['parent'][:12]}: plan again")
    todo, done = [], []
    for f in plan_data["forks"]:
        cur = remote_sha(f["url"], "refs/heads/" + f["branch"])
        if cur == f["merge"]:
            done.append(f)
            continue
        if cur != f["tip"]:
            fail(f"{f['path']}: {f['url']} {f['branch']} is at {(cur or 'nothing')[:12]}, the plan merged into {f['tip'][:12]}: plan again")
        git("cat-file", "-e", f"{f['merge']}^{{commit}}", gd=f["gd"])
        todo.append(f)
    mref = f"refs/heads/update/{upd.id}"
    have = remote_sha(plan_data["manifest_url"], mref)
    if have and have != plan_data["manifest_commit"]:
        fail(f"{plan_data['manifest_url']} has a branch update/{upd.id} already, at {have[:12]}, not the plan's "
             f"{plan_data['manifest_commit'][:12]}: plan again with a new update id")
    git("cat-file", "-e", f"{plan_data['manifest_commit']}^{{commit}}", gd=plan_data["manifest_gd"])
    print(f"{len(todo)} forks to push, {len(done)} pushed before; the manifest's branch update/{upd.id}: "
          + ("there already" if have else "to push"))
    for f in todo:
        push_one(f["gd"], f["url"], f["merge"], "refs/heads/" + f["branch"])
        print(f"{f['path']}: {f['url']} {f['branch']} {f['tip'][:12]} -> {f['merge'][:12]}")
    if not have:
        push_one(plan_data["manifest_gd"], plan_data["manifest_url"], plan_data["manifest_commit"], mref)
        print(f"manifest: {plan_data['manifest_url']} update/{upd.id} = {plan_data['manifest_commit'][:12]}")
    if todo or not have:
        plan_data["pushed"] = started.isoformat()
    with open(pf + ".tmp", "w") as f:
        json.dump(plan_data, f, indent=1)
    os.replace(pf + ".tmp", pf)
    print(f"pull request: {plan_data['manifest_url']}/compare/{mbranch}...update/{upd.id}?expand=1")
    print(f"UPDATE_PUSH=OK ({len(todo)} forks pushed now, {len(done)} before; the manifest's update/{upd.id})")

# ---- the push token -----------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def receive_pack(url, token):
    # GitHub's answer to a git push's first request (the refs it would update) for <url>:
    # 200 only for a login that may push there, 401 without one, 403 for one that may not.
    # Nothing is sent or changed
    req = urllib.request.Request(url + ".git/info/refs?service=git-receive-pack",
                                 headers={"User-Agent": "git/expressiveos-update"})
    if token is not None:
        # Unredirected: never sent on to another address
        req.add_unredirected_header("Authorization", "Basic " + base64.b64encode(
            f"x-access-token:{token}".encode()).decode())
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=60) as r:
            return r.status, r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except (urllib.error.URLError, OSError) as e:
        return None, str(e)

def token_check(a):
    # Can EOS_PUSH_TOKEN push to every repo of ExpressiveOS's (its manifest's repos and the
    # manifest's own)? Asks GitHub as a push would, and stops there: nothing is pushed
    eos = conf(os.path.join(kit, "eos.conf"))
    token = os.environ.get("EOS_PUSH_TOKEN", "")
    print("== The push token (EOS_PUSH_TOKEN, the runner's EXPRESSIVEOS_PUSH_TOKEN secret): may it push to "
          "ExpressiveOS's repos? Asked as a git push asks, nothing pushed")
    if not token:
        fail("EOS_PUSH_TOKEN is empty: the Actions secret EXPRESSIVEOS_PUSH_TOKEN isn't set in this repo")
    if token != token.strip() or any(c.isspace() for c in token):
        fail("the token has spaces or line breaks in it: save the secret again with the token alone")
    kind = ("a fine-grained token" if token.startswith("github_pat_") else
            "a classic token (it reaches every repo you can push to: a fine-grained one for ExpressiveOS is safer)"
            if token.startswith("ghp_") else "not a GitHub personal access token as far as its form shows")
    print(f"token: {kind}, {len(token)} characters")
    gd = fetch_manifest(a.work, "eos.git", eos["EOS_MANIFEST_URL"], eos["EOS_MANIFEST_BRANCH"])
    rev = git("rev-parse", f"refs/heads/{eos['EOS_MANIFEST_BRANCH']}", gd=gd).stdout.strip()
    ours, _, _ = flatten(reader(gd, rev), eos["EOS_MANIFEST_URL"])
    urls = sorted({eos["EOS_MANIFEST_URL"].rstrip("/")} | {p.url for p in ours.values() if p.remote == "expressiveos"})
    print(f"{len(urls)} repos: {eos['EOS_MANIFEST_URL']} and the projects its {eos['EOS_MANIFEST_BRANCH']} branch "
          f"({rev[:12]}) takes from ExpressiveOS")
    # Without a login GitHub must refuse, or a 200 below wouldn't mean the token may push
    code, _ = receive_pack(urls[0], None)
    if code != 401:
        fail(f"{urls[0]} answered {code} to a push request without a login (401 expected), so its answer can't tell what the token may do")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        answers = dict(zip(urls, ex.map(lambda u: receive_pack(u, token), urls)))
    meaning = {401: "token refused (wrong, expired or revoked)",
               403: "no push access (the token's repository access or Contents permission, or the organization hasn't approved it)",
               404: "not found (or not visible to the token)"}
    bad = 0
    for u in urls:
        code, ctype = answers[u]
        if code == 200 and ctype == "application/x-git-receive-pack-advertisement":
            continue
        bad += 1
        print(f"{u}: {meaning.get(code, f'answered {code} {ctype}'.strip())}")
    print(f"-- {len(urls) - bad} of {len(urls)} repos would take a push")
    print(f"TOKEN_CHECK={'OK' if not bad else 'FAIL'}")
    if bad:
        sys.exit(1)

def read_file(path):
    try:
        return open(path).read()
    except OSError as e:
        raise Fail(f"can't read {path}: {e}")

def git_du(path):
    try:
        return subprocess.run(["du", "-sh", path], capture_output=True, text=True).stdout.split()[0]
    except (IndexError, OSError):
        return "?"

def main():
    ap = argparse.ArgumentParser(description="ExpressiveOS's monthly update, checked (a dry run)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--top", required=True)
    c.add_argument("--manifest", required=True)
    c.add_argument("--work", required=True)
    c.add_argument("--lineage-base", default=None,
                   help="LineageOS's manifest commit to count from (default: the manifest's last-update.conf, else the sources' base)")
    t = sub.add_parser("token")
    t.add_argument("--work", required=True)
    pl = sub.add_parser("plan")
    pl.add_argument("id")
    pl.add_argument("--top", required=True)
    pl.add_argument("--manifest", required=True)
    pl.add_argument("--work", required=True)
    pu = sub.add_parser("push")
    pu.add_argument("id")
    pu.add_argument("--work", required=True)
    mr = sub.add_parser("resolution", help="print the resolution of a merge fixed by hand in a clone")
    mr.add_argument("repo")
    a = ap.parse_args()
    try:
        {"check": check, "token": token_check, "plan": plan, "push": push,
         "resolution": make_resolution}[a.cmd](a)
    except Fail as e:
        fail(str(e))

if __name__ == "__main__":
    main()
