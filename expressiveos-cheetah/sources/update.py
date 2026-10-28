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
import argparse, base64, concurrent.futures, datetime, os, re, subprocess, sys, threading
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

def git(*args, gd=None, timeout=600, ok=(0,)):
    cmd = ["git", "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
    if gd:
        cmd += ["--git-dir", gd]
    try:
        r = subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=timeout,
                           env=ENV, errors="surrogateescape")
    except (subprocess.SubprocessError, OSError) as e:
        raise Fail(f"git {' '.join(args)[:200]}: {e}")
    if r.returncode not in ok:
        raise Fail(f"git {' '.join(args)[:200]} exited {r.returncode}: {r.stderr.strip()[-300:]}")
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
        self.url = f"{url_of(r['fetch'])}/{self.name}"
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
        f"{count(lgd, lbase, lnow)} commits since {lbase[:12]} (the sources' base)")
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
        if n is not None:
            target = n
            if n.url != p.url:
                r["note"] = f"LineageOS's manifest now takes it from {n.name}"
            ref = ref_of(n.revision)
        else:
            target = p
            ref = ref_of(p.upstream or p.revision)
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
    c.add_argument("--lineage-base", default=LINEAGE_BASE)
    t = sub.add_parser("token")
    t.add_argument("--work", required=True)
    a = ap.parse_args()
    try:
        {"check": check, "token": token_check}[a.cmd](a)
    except Fail as e:
        fail(str(e))

if __name__ == "__main__":
    main()
