#!/usr/bin/env python3
"""ExpressiveOS 2.0 pure-AOSP monthly Android Security Bulletin (ASB) updater.

Replaces LineageOS-tracking update.py for EOS 2.0 (Path A, pure AOSP android-17.0.0_r1 base).
Because Google's monthly android-security-17.0.0_r* branch diverged from android-17.0.0_r1
around April 2026, this tool NEVER switches <default revision> to the security tag. Instead:

  check              Query AOSP platform/manifest tags (android-security-17.0.0_r* and
                     android-17.0.0_r*), diff AOSP_SEC_TAG..TARGET_SEC_TAG (--no-merges)
                     for every changed repo, and classify each repo as CLEAN, CONFLICTS,
                     or NEW_FORK_NEEDED. Ends with UPDATE_CHECK=OK|INCOMPLETE.

  plan <id>          Stage ASB cherry-picks (applying sources/updates/<id>/resolutions/
                     when present), bump RELEASE_PLATFORM_SECURITY_PATCH.textproto in
                     vendor/expressiveos, emit 40-hex pinned default.xml + last-update.conf
                     + plan.json, and lint the result. Ends with UPDATE_PLAN=READY|CONFLICTS.

  create-repos <id>  Mac-side least-privilege admin command: idempotently creates any
                     NEW_FORK_NEEDED repos under github.com/ExpressiveOS via
                     `gh api -X POST orgs/ExpressiveOS/repos` (public, default branch
                     expressiveos-2.0 once pushed). Ends with CREATE_REPOS=OK.

  push <id>          Fast-forward push staged commits to each ExpressiveOS fork on branch
                     expressiveos-2.0 (never force-push) and push manifest branch
                     update/<id> for PR review. Ends with UPDATE_PUSH=OK.

  token              Read-only check that EOS_PUSH_TOKEN has git-receive-pack push access
                     to ExpressiveOS/manifest and every remote="expressiveos" repo on
                     expressiveos-2.0. Ends with TOKEN_CHECK=OK|FAIL.

  verify <id>        Verify merged manifest + fork heads + SPL match plan.json.
                     Ends with UPDATE_VERIFY=OK|DIFFERS.

  lint [manifest]    Strict EOS 2.0 manifest validator: every <project> pinned to 40-hex
                     SHA, zero <include>/<submanifest>/<extend-project>, zero lineage/github
                     remotes or LineageOS project names, valid SPL textproto if provided.
                     Ends with MANIFEST_LINT=OK|FAIL.
"""

import argparse
import base64
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
KIT = HERE.parent

DEFAULT_AOSP_BASE_URL = "https://android.googlesource.com"
DEFAULT_AOSP_MANIFEST_URL = "https://android.googlesource.com/platform/manifest"
DEFAULT_EOS_ORG = "ExpressiveOS"
DEFAULT_EOS_BRANCH = "expressiveos-2.0"
DEFAULT_EOS_MANIFEST_URL = "https://github.com/ExpressiveOS/manifest"
SPL_REL_PATH = "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
UPDATE_ID_RE = re.compile(r"^[0-9]{4}-(?:0[1-9]|1[0-2])(?:-[2-9])?$")
SPL_DATE_RE = re.compile(r"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])$")
SEC_TAG_RE = re.compile(r"^android-security-17\.0\.0_r([0-9]+)$")
REL_TAG_RE = re.compile(r"^android-17\.0\.0_r([0-9]+)$")
IDENT_RE = re.compile(r"^([^<>]+?)\s+<([^<>\s]+@[^<>\s]+)>$")

ALLOWED_MANIFEST_TAGS = {"remote", "default", "project", "notice", "contactinfo"}
ALLOWED_PROJECT_CHILDREN = {"linkfile", "copyfile", "annotation"}
ALLOWED_REMOTES = {"aosp", "expressiveos"}
FORBIDDEN_REMOTE_NAMES = {"lineage", "lineageos", "github"}

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
BASE_ENV = dict(
    os.environ,
    GIT_TERMINAL_PROMPT="0",
    GIT_LFS_SKIP_SMUDGE="1",
    LC_ALL="C",
)
PURE_CFG = [
    "-c", f"core.attributesFile={os.devnull}",
    "-c", f"attr.tree={EMPTY_TREE}",
    "-c", "merge.renormalize=false",
]
PURE_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_ATTR_NOSYSTEM": "1",
}

# git credential helper reading EOS_PUSH_TOKEN from the environment only, never written to disk or argv.
PUSH_CRED_HELPER = '!f() { test "$1" = get || exit 0; echo username=x-access-token; printf "password=%s\\n" "$EOS_PUSH_TOKEN"; }; f'

STOPPED = None


class UpdateError(Exception):
    pass


def die(msg):
    if STOPPED:
        clean = " ".join(str(msg).split())[:300]
        print(f"{STOPPED} (stopped: {clean})", flush=True)
    sys.exit(f"FAIL: {msg}")


def run_cmd(cmd, cwd=None, timeout=120, ok=(0,), env=None, input_data=None):
    merged_env = dict(BASE_ENV)
    if env:
        merged_env.update(env)
    try:
        proc = subprocess.run(
            list(cmd),
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            errors="surrogateescape",
            timeout=timeout,
            env=merged_env,
            input=input_data,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise UpdateError(f"command {' '.join(cmd)[:180]} failed: {exc}") from exc
    if proc.returncode not in ok:
        err = (proc.stderr or proc.stdout or "").strip()[-400:]
        raise UpdateError(f"command {' '.join(cmd)[:180]} exited {proc.returncode}: {err}")
    return proc


def git(*args, cwd=None, git_dir=None, timeout=180, ok=(0,), env=None, pure=False, input_data=None):
    cmd = [
        "git",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "-c", "color.ui=false",
        "-c", "core.quotePath=false",
    ]
    if pure:
        cmd += PURE_CFG
    if git_dir:
        cmd += ["--git-dir", str(git_dir)]
    cmd += list(args)
    extra_env = dict(PURE_ENV) if pure else {}
    if env:
        extra_env.update(env)
    return run_cmd(cmd, cwd=cwd, timeout=timeout, ok=ok, env=extra_env, input_data=input_data)


def parse_kv_file(path):
    out = {}
    p = Path(path)
    if not p.is_file():
        return out
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        out[k.strip()] = v
    return out


def parse_ident(ident_str):
    m = IDENT_RE.fullmatch((ident_str or "").strip())
    if not m:
        raise UpdateError(f"invalid git identity (expected 'Name <email>'): {ident_str!r}")
    return m.group(1), m.group(2)


def eos_repo_name_for_path(path):
    """Map an AOSP path (e.g. packages/apps/ManagedProvisioning) to ExpressiveOS repo name."""
    return path.strip("/").replace("/", "_")


def parse_manifest(manifest_path):
    """Parse a repo manifest XML into structured remotes, default, and projects by path."""
    try:
        tree = ET.parse(str(manifest_path))
    except (ET.ParseError, OSError) as exc:
        raise UpdateError(f"cannot parse manifest {manifest_path}: {exc}") from exc
    root = tree.getroot()
    remotes = {}
    for elem in root.findall("remote"):
        name = elem.get("name")
        if name:
            remotes[name] = dict(elem.attrib)
    default_elem = root.find("default")
    default_attrs = dict(default_elem.attrib) if default_elem is not None else {}
    default_remote = default_attrs.get("remote", "")
    default_rev = default_attrs.get("revision", "")

    projects = {}
    for elem in root.findall("project"):
        name = elem.get("name")
        path = elem.get("path") or name
        if not name or not path:
            continue
        remote = elem.get("remote") or default_remote
        rev = elem.get("revision") or remotes.get(remote, {}).get("revision") or default_rev
        projects[path] = {
            "name": name,
            "path": path,
            "remote": remote,
            "revision": rev,
            "upstream": elem.get("upstream", ""),
            "dest_branch": elem.get("dest-branch", ""),
            "elem": elem,
        }
    return {
        "tree": tree,
        "root": root,
        "remotes": remotes,
        "default": default_attrs,
        "projects": projects,
    }


def lint_manifest_data(manifest_path, spl_file=None):
    """Return list of lint error strings (empty list means valid)."""
    errors = []
    try:
        tree = ET.parse(str(manifest_path))
    except (ET.ParseError, OSError) as exc:
        return [f"XML parse error in {manifest_path}: {exc}"]
    root = tree.getroot()
    if root.tag != "manifest":
        errors.append(f"root element is <{root.tag}>, expected <manifest>")
        return errors

    for child in root:
        if child.tag not in ALLOWED_MANIFEST_TAGS:
            errors.append(f"forbidden manifest element <{child.tag}>")

    remotes = {}
    for rem in root.findall("remote"):
        rname = rem.get("name", "")
        fetch = rem.get("fetch", "")
        rrev = rem.get("revision", "")
        if rname.lower() in FORBIDDEN_REMOTE_NAMES or "lineage" in rname.lower():
            errors.append(f"forbidden remote name '{rname}'")
        if rname not in ALLOWED_REMOTES:
            errors.append(f"unexpected remote '{rname}' (allowed: {sorted(ALLOWED_REMOTES)})")
        if "lineage" in fetch.lower() or "lineage" in rrev.lower():
            errors.append(f"remote '{rname}' references LineageOS ({fetch} / {rrev})")
        remotes[rname] = dict(rem.attrib)

    default_elem = root.find("default")
    if default_elem is None:
        errors.append("missing <default> element")
    else:
        drem = default_elem.get("remote", "")
        drev = default_elem.get("revision", "")
        if drem not in ALLOWED_REMOTES:
            errors.append(f"<default> remote '{drem}' not in {sorted(ALLOWED_REMOTES)}")
        if "lineage" in drev.lower():
            errors.append(f"<default> revision references LineageOS: '{drev}'")

    seen_paths = set()
    proj_count = 0
    for proj in root.findall("project"):
        proj_count += 1
        name = proj.get("name", "")
        path = proj.get("path") or name
        rev = proj.get("revision", "")
        rem = proj.get("remote") or (default_elem.get("remote", "") if default_elem is not None else "")
        upstream = proj.get("upstream", "")
        dest_branch = proj.get("dest-branch", "")

        for sub in proj:
            if sub.tag not in ALLOWED_PROJECT_CHILDREN:
                errors.append(f"project '{path}' has forbidden child <{sub.tag}>")

        if not name:
            errors.append("project missing name attribute")
        if not path:
            errors.append(f"project '{name}' missing path")
        elif path in seen_paths:
            errors.append(f"duplicate project path '{path}'")
        else:
            seen_paths.add(path)

        if not SHA_RE.fullmatch(rev):
            errors.append(f"project '{path}' revision '{rev}' is not a 40-hex commit SHA")
        if rem not in ALLOWED_REMOTES:
            errors.append(f"project '{path}' remote '{rem}' not in {sorted(ALLOWED_REMOTES)}")
        if "lineageos/" in name.lower() or "lineage-" in upstream.lower() or "lineage-" in dest_branch.lower():
            errors.append(f"project '{path}' references LineageOS ({name} / {upstream} / {dest_branch})")
        if path in ("lineage-sdk", "vendor/lineage", "device/lineage/sepolicy"):
            errors.append(f"forbidden LineageOS project path '{path}'")

    if proj_count == 0:
        errors.append("manifest has zero <project> elements")

    if spl_file:
        spl_errors = validate_spl_textproto(Path(spl_file))
        errors.extend(spl_errors)

    return errors


def validate_spl_textproto(spl_path):
    if not spl_path.is_file():
        return [f"missing SPL file: {spl_path}"]
    text = spl_path.read_text(encoding="utf-8")
    if 'name: "RELEASE_PLATFORM_SECURITY_PATCH"' not in text:
        return [f"{spl_path} does not declare RELEASE_PLATFORM_SECURITY_PATCH"]
    m = re.search(r'string_value:\s*"([^"]+)"', text)
    if not m:
        return [f"{spl_path} missing string_value"]
    val = m.group(1)
    if not SPL_DATE_RE.fullmatch(val):
        return [f"{spl_path} has invalid SPL date '{val}' (expected YYYY-MM-DD)"]
    return []


def write_spl_textproto(spl_path, spl_date):
    if not SPL_DATE_RE.fullmatch(spl_date):
        raise UpdateError(f"invalid TARGET_SPL '{spl_date}' (expected YYYY-MM-DD)")
    spl_path.parent.mkdir(parents=True, exist_ok=True)
    content = (
        'name: "RELEASE_PLATFORM_SECURITY_PATCH"\n'
        "value: {\n"
        f'  string_value: "{spl_date}"\n'
        "}\n"
    )
    spl_path.write_text(content, encoding="utf-8")


def list_remote_tags(manifest_url, timeout=60):
    """Query git ls-remote --tags and return sorted (sec_tags, rel_tags)."""
    proc = git("ls-remote", "--tags", "--refs", manifest_url, timeout=timeout)
    sec_tags = []
    rel_tags = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        ref = parts[1].strip()
        if not ref.startswith("refs/tags/"):
            continue
        tag = ref[len("refs/tags/"):]
        m_sec = SEC_TAG_RE.fullmatch(tag)
        if m_sec:
            sec_tags.append((int(m_sec.group(1)), tag))
            continue
        m_rel = REL_TAG_RE.fullmatch(tag)
        if m_rel:
            rel_tags.append((int(m_rel.group(1)), tag))
    sec_tags.sort()
    rel_tags.sort()
    return [t for _, t in sec_tags], [t for _, t in rel_tags]


def fetch_manifest_at_tag(manifest_url, tag, work_dir, timeout=90):
    """Clone/fetch platform/manifest at a specific tag and return path to its default.xml."""
    repo_dir = Path(work_dir) / "aosp-manifest.git"
    if not repo_dir.exists():
        repo_dir.mkdir(parents=True, exist_ok=True)
        git("init", "--bare", str(repo_dir), timeout=30)
    git(
        "fetch", "--depth=1", manifest_url, f"refs/tags/{tag}:refs/tags/{tag}",
        git_dir=repo_dir, timeout=timeout,
    )
    blob = git("show", f"refs/tags/{tag}:default.xml", git_dir=repo_dir, timeout=30).stdout
    out_xml = Path(work_dir) / f"manifest-{tag}.xml"
    out_xml.write_text(blob, encoding="utf-8")
    return out_xml


def aosp_repo_url(base_url, project_name):
    base = base_url.rstrip("/")
    return f"{base}/{project_name}"


def eos_repo_url(org_base, repo_name):
    base = org_base.rstrip("/")
    return f"{base}/{repo_name}"


def resolve_local_or_remote_url(aosp_base, eos_base, proj_info, top_dir=None):
    """Return fetch URL (and optional local reference dir) for a project."""
    if proj_info["remote"] == "expressiveos":
        url = eos_repo_url(eos_base, proj_info["name"])
    else:
        url = aosp_repo_url(aosp_base, proj_info["name"])
    local_dir = None
    if top_dir:
        cand = Path(top_dir) / proj_info["path"]
        if (cand / ".git").exists():
            local_dir = cand
    return url, local_dir


def refs_resolve_identical(aosp_url, old_ref, new_ref, timeout=30):
    """Fast-path check via ls-remote: return True if two symbolic refs resolve to the same commit."""
    if not old_ref or not new_ref:
        return False
    if SHA_RE.fullmatch(old_ref) and SHA_RE.fullmatch(new_ref):
        return old_ref == new_ref
    ls = git("ls-remote", aosp_url, old_ref, new_ref, ok=(0, 128), timeout=timeout)
    if ls.returncode != 0:
        return False
    resolved = {}
    for line in ls.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            sha, ref = parts[0].strip(), parts[1].strip()
            if ref.endswith("^{}"):
                resolved[ref[:-3]] = sha
            else:
                resolved.setdefault(ref, sha)
    def lookup(r):
        return resolved.get(r) or resolved.get(f"refs/tags/{r}")
    o_sha, n_sha = lookup(old_ref), lookup(new_ref)
    return bool(o_sha and n_sha and o_sha == n_sha)


def diff_security_manifests(from_xml, to_xml):
    """Compare two AOSP security manifests and return changed projects keyed by path."""
    old_m = parse_manifest(from_xml)
    new_m = parse_manifest(to_xml)
    changed = {}
    for path, new_p in sorted(new_m["projects"].items()):
        old_p = old_m["projects"].get(path)
        old_rev = old_p["revision"] if old_p else None
        new_rev = new_p["revision"]
        if old_rev != new_rev:
            changed[path] = {
                "path": path,
                "aosp_name": new_p["name"],
                "old_rev": old_rev,
                "new_rev": new_rev,
            }
    return changed


def prepare_scratch_repo(scratch_dir, base_url, base_rev, aosp_url, from_ref, to_ref,
                         local_dir=None, timeout=180):
    """Create a scratch git worktree at base_rev and fetch from_ref..to_ref ASB commits."""
    if scratch_dir.exists():
        shutil.rmtree(scratch_dir)
    scratch_dir.mkdir(parents=True, exist_ok=True)
    git("init", str(scratch_dir), timeout=30)

    if local_dir is not None:
        git("remote", "add", "local", str(local_dir), cwd=scratch_dir, timeout=30)
        git("fetch", "local", base_rev, cwd=scratch_dir, timeout=timeout, ok=(0, 128))

    git("remote", "add", "eos_base", base_url, cwd=scratch_dir, timeout=30)
    have_base = git("cat-file", "-e", f"{base_rev}^{{commit}}", cwd=scratch_dir, ok=(0, 1, 128), timeout=15).returncode == 0
    if not have_base:
        git("fetch", "eos_base", base_rev, cwd=scratch_dir, timeout=timeout)

    git("checkout", "--detach", base_rev, cwd=scratch_dir, timeout=60)

    git("remote", "add", "aosp_sec", aosp_url, cwd=scratch_dir, timeout=30)
    if from_ref:
        # Fetch refs explicitly so both raw 40-hex SHAs and symbolic tags work
        git("fetch", "aosp_sec",
            f"{from_ref}:refs/eos/sec_from", f"{to_ref}:refs/eos/sec_to",
            cwd=scratch_dir, timeout=timeout)
        rev_range = "refs/eos/sec_from..refs/eos/sec_to"
    else:
        git("fetch", "aosp_sec", f"{to_ref}:refs/eos/sec_to", cwd=scratch_dir, timeout=timeout)
        rev_range = "refs/eos/sec_to"

    commits = [
        line.strip()
        for line in git("rev-list", "--reverse", "--no-merges", rev_range,
                        cwd=scratch_dir, timeout=60).stdout.splitlines()
        if line.strip()
    ]
    return commits


def try_cherry_picks(scratch_dir, commits, ident_name, ident_email, resolution_patch=None, timeout=120):
    """Attempt cherry-picking commits onto HEAD in scratch_dir.

    Returns dict: {"status": "CLEAN"|"CONFLICTS"|"RESOLVED", "head": sha, "applied": [...], "conflict_commit": sha|None, "error": str}
    """
    env = {
        "GIT_COMMITTER_NAME": ident_name,
        "GIT_COMMITTER_EMAIL": ident_email,
    }
    orig_head = git("rev-parse", "HEAD", cwd=scratch_dir, timeout=15).stdout.strip()
    applied = []
    for sha in commits:
        # Skip if already an ancestor of HEAD
        anc = git("merge-base", "--is-ancestor", sha, "HEAD", cwd=scratch_dir, ok=(0, 1), timeout=15)
        if anc.returncode == 0:
            continue
        res = git("cherry-pick", "--allow-empty", sha, cwd=scratch_dir, env=env, ok=(0, 1), pure=True, timeout=timeout)
        if res.returncode == 0:
            applied.append(sha)
            continue
        # Conflict! Abort and try resolution patch (generated from base_rev..resolved) if supplied
        git("cherry-pick", "--abort", cwd=scratch_dir, ok=(0, 1, 128), timeout=30)
        if resolution_patch and Path(resolution_patch).is_file():
            git("reset", "--hard", orig_head, cwd=scratch_dir, timeout=30)
            am_res = git("am", "--3way", str(resolution_patch), cwd=scratch_dir, env=env, ok=(0, 1, 128), pure=True, timeout=timeout)
            if am_res.returncode == 0:
                head = git("rev-parse", "HEAD", cwd=scratch_dir, timeout=15).stdout.strip()
                return {
                    "status": "RESOLVED",
                    "head": head,
                    "applied": applied,
                    "conflict_commit": sha,
                    "error": "",
                }
            git("am", "--abort", cwd=scratch_dir, ok=(0, 1, 128), timeout=30)
        return {
            "status": "CONFLICTS",
            "head": git("rev-parse", "HEAD", cwd=scratch_dir, timeout=15).stdout.strip(),
            "applied": applied,
            "conflict_commit": sha,
            "error": (res.stderr or res.stdout or "").strip()[-300:],
        }

    head = git("rev-parse", "HEAD", cwd=scratch_dir, timeout=15).stdout.strip()
    return {
        "status": "CLEAN",
        "head": head,
        "applied": applied,
        "conflict_commit": None,
        "error": "",
    }


def load_eos_config(kit_dir):
    return parse_kv_file(Path(kit_dir) / "eos.conf")


def find_manifest_path(args):
    if getattr(args, "manifest", None):
        p = Path(args.manifest)
        if not p.is_file():
            raise UpdateError(f"manifest not found: {p}")
        return p
    if getattr(args, "top", None):
        p = Path(args.top) / ".repo" / "manifests" / "default.xml"
        if p.is_file():
            return p
    raise UpdateError("pass --manifest <default.xml> or --top <tree>")


def cmd_check(args):
    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    eos_conf = load_eos_config(KIT)
    ident_name, ident_email = parse_ident(eos_conf.get("EOS_UPDATE_IDENT", "Daryl Denson <9751141+denson9874@users.noreply.github.com>"))
    manifest_path = find_manifest_path(args)
    eos_manifest = parse_manifest(manifest_path)

    aosp_manifest_url = args.aosp_manifest_url or os.environ.get("EOS_AOSP_MANIFEST_URL", DEFAULT_AOSP_MANIFEST_URL)
    aosp_base_url = args.aosp_base_url or os.environ.get("EOS_AOSP_BASE_URL", DEFAULT_AOSP_BASE_URL)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL", f"https://github.com/{DEFAULT_EOS_ORG}")

    last_conf = parse_kv_file(manifest_path.parent / "last-update.conf")
    sec_tags, rel_tags = list_remote_tags(aosp_manifest_url)
    print(f"AOSP android-17.0.0_r* tags: {len(rel_tags)} (latest: {rel_tags[-1] if rel_tags else 'none'})")
    print(f"AOSP android-security-17.0.0_r* tags: {len(sec_tags)} (latest: {sec_tags[-1] if sec_tags else 'none'})")

    from_tag = args.from_sec_tag or last_conf.get("AOSP_SEC_TAG") or (sec_tags[-2] if len(sec_tags) >= 2 else None)
    to_tag = args.to_sec_tag or (sec_tags[-1] if sec_tags else None)
    if not from_tag or not to_tag:
        print("UPDATE_CHECK=INCOMPLETE (missing AOSP_SEC_TAG or TARGET_SEC_TAG)")
        return 1

    print(f"Diffing AOSP security tags: {from_tag} .. {to_tag}")
    from_xml = fetch_manifest_at_tag(aosp_manifest_url, from_tag, work)
    to_xml = fetch_manifest_at_tag(aosp_manifest_url, to_tag, work)
    changed = diff_security_manifests(from_xml, to_xml)
    print(f"Changed AOSP repos between {from_tag} and {to_tag}: {len(changed)}")

    clean_repos = []
    conflict_repos = []
    new_forks = []
    problems = []

    for path, ch in sorted(changed.items()):
        proj = eos_manifest["projects"].get(path)
        if proj is None:
            continue  # Repo not in EOS manifest (e.g., unused/dropped AOSP path)

        aosp_url = aosp_repo_url(aosp_base_url, ch["aosp_name"])
        from_ref = ch["old_rev"] or from_tag
        to_ref = ch["new_rev"] or to_tag
        if refs_resolve_identical(aosp_url, from_ref, to_ref):
            continue
        base_url, local_dir = resolve_local_or_remote_url(aosp_base_url, eos_org_base, proj, args.top)
        scratch = work / "check-repos" / eos_repo_name_for_path(path)
        try:
            commits = prepare_scratch_repo(
                scratch, base_url, proj["revision"], aosp_url,
                from_ref, to_ref,
                local_dir=local_dir,
            )
            if not commits:
                continue
            res = try_cherry_picks(scratch, commits, ident_name, ident_email)
            is_existing_fork = (proj["remote"] == "expressiveos")
            if not is_existing_fork:
                new_forks.append({
                    "path": path,
                    "repo": eos_repo_name_for_path(path),
                    "commits": len(commits),
                    "apply_status": res["status"],
                })
                if res["status"] == "CONFLICTS":
                    conflict_repos.append(path)
            elif res["status"] == "CLEAN":
                clean_repos.append({"path": path, "commits": len(commits)})
            else:
                conflict_repos.append(path)
            kind = "NEW_FORK_NEEDED" if not is_existing_fork else res["status"]
            print(f"  [{kind}] {path} ({len(commits)} ASB commit(s); cherry-pick={res['status']})")
        except UpdateError as exc:
            problems.append(f"{path}: {exc}")
            print(f"  [ERROR] {path}: {exc}", file=sys.stderr)

    status = "OK" if not problems else "INCOMPLETE"
    print(
        f"UPDATE_CHECK={status} (clean={len(clean_repos)}, conflicts={len(conflict_repos)}, "
        f"new_forks={len(new_forks)}, problems={len(problems)})"
    )
    return 0 if not problems else 1


def update_manifest_xml(manifest_path, out_xml_path, repo_updates, branch=DEFAULT_EOS_BRANCH):
    """Rewrite default.xml pinning updated revisions and converting new forks to remote='expressiveos'."""
    tree = ET.parse(str(manifest_path))
    root = tree.getroot()
    for proj in root.findall("project"):
        name = proj.get("name")
        path = proj.get("path") or name
        if path in repo_updates:
            upd = repo_updates[path]
            proj.set("remote", "expressiveos")
            proj.set("name", upd["eos_repo"])
            proj.set("revision", upd["new_head"])
            proj.set("upstream", f"refs/heads/{branch}")
            proj.set("dest-branch", f"refs/heads/{branch}")
    ET.indent(tree, space="  ")
    tree.write(str(out_xml_path), encoding="utf-8", xml_declaration=True)
    with open(out_xml_path, "a", encoding="utf-8") as fh:
        fh.write("\n")


def cmd_plan(args):
    upd_id = args.id
    if not UPDATE_ID_RE.fullmatch(upd_id):
        raise UpdateError(f"invalid update id '{upd_id}' (expected YYYY-MM or YYYY-MM-N)")

    work = Path(args.work).resolve() / upd_id
    work.mkdir(parents=True, exist_ok=True)

    eos_conf = load_eos_config(KIT)
    ident_name, ident_email = parse_ident(eos_conf.get("EOS_UPDATE_IDENT", "Daryl Denson <9751141+denson9874@users.noreply.github.com>"))
    branch = args.branch or eos_conf.get("EOS_MANIFEST_BRANCH", DEFAULT_EOS_BRANCH)

    upd_dir = Path(args.updates_dir) / upd_id if args.updates_dir else (HERE / "updates" / upd_id)
    uconf = parse_kv_file(upd_dir / "update.conf")
    from_tag = args.from_sec_tag or uconf.get("AOSP_SEC_TAG")
    to_tag = args.to_sec_tag or uconf.get("TARGET_SEC_TAG")
    target_spl = args.target_spl or uconf.get("TARGET_SPL")
    if not from_tag or not to_tag or not target_spl:
        raise UpdateError(f"need AOSP_SEC_TAG, TARGET_SEC_TAG, and TARGET_SPL (in {upd_dir / 'update.conf'} or CLI flags)")
    if not SPL_DATE_RE.fullmatch(target_spl):
        raise UpdateError(f"invalid TARGET_SPL '{target_spl}' (expected YYYY-MM-DD)")

    manifest_path = find_manifest_path(args)
    eos_manifest = parse_manifest(manifest_path)

    aosp_manifest_url = args.aosp_manifest_url or os.environ.get("EOS_AOSP_MANIFEST_URL", DEFAULT_AOSP_MANIFEST_URL)
    aosp_base_url = args.aosp_base_url or os.environ.get("EOS_AOSP_BASE_URL", DEFAULT_AOSP_BASE_URL)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL", f"https://github.com/{DEFAULT_EOS_ORG}")

    from_xml = fetch_manifest_at_tag(aosp_manifest_url, from_tag, work)
    to_xml = fetch_manifest_at_tag(aosp_manifest_url, to_tag, work)
    changed = diff_security_manifests(from_xml, to_xml)

    resolutions_dir = upd_dir / "resolutions"
    repo_updates = {}
    new_repos = []
    conflicts = []

    for path, ch in sorted(changed.items()):
        proj = eos_manifest["projects"].get(path)
        if proj is None:
            continue
        safe = eos_repo_name_for_path(path)
        aosp_url = aosp_repo_url(aosp_base_url, ch["aosp_name"])
        from_ref = ch["old_rev"] or from_tag
        to_ref = ch["new_rev"] or to_tag
        if refs_resolve_identical(aosp_url, from_ref, to_ref):
            continue
        base_url, local_dir = resolve_local_or_remote_url(aosp_base_url, eos_org_base, proj, args.top)
        scratch = work / "repos" / safe
        commits = prepare_scratch_repo(
            scratch, base_url, proj["revision"], aosp_url,
            from_ref, to_ref,
            local_dir=local_dir,
        )
        if not commits:
            continue
        res_patch = resolutions_dir / f"{safe}.patch"
        res = try_cherry_picks(
            scratch, commits, ident_name, ident_email,
            resolution_patch=res_patch if res_patch.is_file() else None,
        )
        eos_repo = proj["name"] if proj["remote"] == "expressiveos" else safe
        if res["status"] == "CONFLICTS":
            conflicts.append({"path": path, "eos_repo": eos_repo, "commit": res["conflict_commit"], "error": res["error"]})
            print(f"  [CONFLICTS] {path} at {res['conflict_commit']}: {res['error']}")
            continue

        is_new = proj["remote"] != "expressiveos"
        if is_new:
            new_repos.append(eos_repo)
        repo_updates[path] = {
            "path": path,
            "eos_repo": eos_repo,
            "old_rev": proj["revision"],
            "new_head": res["head"],
            "is_new_fork": is_new,
            "status": res["status"],
            "scratch_dir": str(scratch),
            "asb_commits": commits,
        }
        print(f"  [{res['status']}{' NEW_FORK' if is_new else ''}] {path} -> {res['head'][:12]}")

    # Stage SPL bump in vendor/expressiveos
    ve_proj = eos_manifest["projects"].get("vendor/expressiveos")
    if ve_proj is None:
        raise UpdateError("manifest lacks vendor/expressiveos project")
    ve_url, ve_local = resolve_local_or_remote_url(aosp_base_url, eos_org_base, ve_proj, args.top)
    ve_scratch = work / "repos" / ve_proj["name"]
    if ve_scratch.exists():
        shutil.rmtree(ve_scratch)
    ve_scratch.mkdir(parents=True, exist_ok=True)
    git("init", str(ve_scratch), timeout=30)
    if ve_local is not None:
        git("remote", "add", "local", str(ve_local), cwd=ve_scratch, timeout=30)
        git("fetch", "local", ve_proj["revision"], cwd=ve_scratch, ok=(0, 128), timeout=120)
    git("remote", "add", "eos_base", ve_url, cwd=ve_scratch, timeout=30)
    if git("cat-file", "-e", f"{ve_proj['revision']}^{{commit}}", cwd=ve_scratch, ok=(0, 1, 128), timeout=15).returncode != 0:
        git("fetch", "eos_base", ve_proj["revision"], cwd=ve_scratch, timeout=120)
    git("checkout", "--detach", ve_proj["revision"], cwd=ve_scratch, timeout=60)

    spl_path = ve_scratch / SPL_REL_PATH
    write_spl_textproto(spl_path, target_spl)
    git("add", SPL_REL_PATH, cwd=ve_scratch, timeout=30)
    diff_rc = git("diff", "--cached", "--quiet", cwd=ve_scratch, ok=(0, 1), timeout=15).returncode
    if diff_rc == 1:
        git(
            "commit", "-m", f"release: Bump Security String to {target_spl} ({upd_id})",
            cwd=ve_scratch,
            env={
                "GIT_AUTHOR_NAME": ident_name,
                "GIT_AUTHOR_EMAIL": ident_email,
                "GIT_COMMITTER_NAME": ident_name,
                "GIT_COMMITTER_EMAIL": ident_email,
            },
            timeout=30,
        )
    ve_head = git("rev-parse", "HEAD", cwd=ve_scratch, timeout=15).stdout.strip()
    repo_updates["vendor/expressiveos"] = {
        "path": "vendor/expressiveos",
        "eos_repo": ve_proj["name"],
        "old_rev": ve_proj["revision"],
        "new_head": ve_head,
        "is_new_fork": False,
        "status": "SPL_BUMP",
        "scratch_dir": str(ve_scratch),
        "asb_commits": [],
    }

    out_xml = work / "default.xml"
    update_manifest_xml(manifest_path, out_xml, repo_updates, branch=branch)
    lint_errs = lint_manifest_data(out_xml, spl_file=spl_path)
    if lint_errs:
        raise UpdateError("generated manifest failed lint: " + "; ".join(lint_errs[:5]))

    last_update_path = work / "last-update.conf"
    last_update_path.write_text(
        f"UPDATE={upd_id}\n"
        f"AOSP_SEC_TAG={to_tag}\n"
        f"PREV_AOSP_SEC_TAG={from_tag}\n"
        f"SPL={target_spl}\n",
        encoding="utf-8",
    )

    plan_doc = {
        "id": upd_id,
        "branch": branch,
        "from_sec_tag": from_tag,
        "to_sec_tag": to_tag,
        "target_spl": target_spl,
        "eos_org": args.org or DEFAULT_EOS_ORG,
        "manifest_out": str(out_xml),
        "last_update_out": str(last_update_path),
        "new_repos": sorted(set(new_repos)),
        "updates": repo_updates,
        "conflicts": conflicts,
    }
    (work / "plan.json").write_text(json.dumps(plan_doc, indent=2) + "\n", encoding="utf-8")

    state = "CONFLICTS" if conflicts else "READY"
    print(
        f"UPDATE_PLAN={state} (staged={len(repo_updates)}, new_repos={len(plan_doc['new_repos'])}, "
        f"conflicts={len(conflicts)}, spl={target_spl})"
    )
    return 0 if not conflicts else 2


def cmd_create_repos(args):
    upd_id = args.id
    if not UPDATE_ID_RE.fullmatch(upd_id):
        raise UpdateError(f"invalid update id '{upd_id}'")
    plan_path = Path(args.work).resolve() / upd_id / "plan.json"
    if not plan_path.is_file():
        raise UpdateError(f"no plan.json at {plan_path} (run plan {upd_id} first)")
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    org = args.org or plan.get("eos_org") or DEFAULT_EOS_ORG
    branch = plan.get("branch", DEFAULT_EOS_BRANCH)
    gh_bin = os.environ.get("EOS_GH_BIN", "gh")

    created = 0
    existing = 0
    for repo in plan.get("new_repos", []):
        check = run_cmd([gh_bin, "api", "-X", "GET", f"repos/{org}/{repo}"], ok=(0, 1), timeout=30)
        if check.returncode == 0:
            print(f"  exists: {org}/{repo}")
            existing += 1
            continue
        if args.dry_run:
            print(f"  would create: {org}/{repo} (public, target branch {branch})")
            created += 1
            continue
        run_cmd(
            [
                gh_bin, "api", "-X", "POST", f"orgs/{org}/repos",
                "-f", f"name={repo}",
                "-f", f"description=ExpressiveOS 2.0 ASB fork ({branch})",
                "-F", "private=false",
                "-F", "auto_init=false",
            ],
            timeout=60,
        )
        print(f"  created: {org}/{repo}")
        created += 1

    print(f"CREATE_REPOS=OK (created={created}, existing={existing}, dry_run={args.dry_run})")
    return 0


def is_github_https(url):
    return (url or "").startswith("https://github.com/")


def validate_push_urls_and_token(urls):
    off = [u for u in urls if not is_github_https(u) and not u.startswith("file://")]
    if off:
        raise UpdateError(
            f"not on GitHub (https://github.com/), the only place EOS_PUSH_TOKEN goes: {', '.join(off)}"
        )
    if any(is_github_https(u) for u in urls):
        token = os.environ.get("EOS_PUSH_TOKEN", "")
        if not token:
            raise UpdateError("EOS_PUSH_TOKEN is empty: the Actions secret EXPRESSIVEOS_PUSH_TOKEN isn't set")
        if token != token.strip() or any(c.isspace() for c in token):
            raise UpdateError("EOS_PUSH_TOKEN has spaces or line breaks in it: save the secret again with the token alone")
        return token
    return ""


def git_push_cfg(url):
    cfg = ["-c", "credential.helper=", "-c", f"core.hooksPath={os.devnull}"]
    if is_github_https(url):
        cfg += ["-c", f"credential.https://github.com.helper={PUSH_CRED_HELPER}"]
    return cfg


def receive_pack_check(repo_url, token, timeout=30):
    base = repo_url.rstrip("/")
    if not base.endswith(".git"):
        base += ".git"
    req = urllib.request.Request(
        f"{base}/info/refs?service=git-receive-pack",
        headers={"User-Agent": "git/expressiveos-update"},
    )
    if token is not None:
        auth = base64.b64encode(f"x-access-token:{token}".encode("utf-8")).decode("ascii")
        req.add_header("Authorization", f"Basic {auth}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ctype = (resp.headers.get("Content-Type") or "").split(";", 1)[0].strip()
            return resp.status, ctype
    except urllib.error.HTTPError as err:
        ctype = (err.headers.get("Content-Type") or "").split(";", 1)[0].strip() if err.headers else ""
        return err.code, ctype
    except (urllib.error.URLError, OSError) as err:
        return None, str(err)


def cmd_token(args):
    eos_conf = load_eos_config(KIT)
    branch = args.branch or eos_conf.get("EOS_MANIFEST_BRANCH", DEFAULT_EOS_BRANCH)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL", f"https://github.com/{DEFAULT_EOS_ORG}")
    manifest_url = (args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)).rstrip("/")
    allow_local = os.environ.get("EOS_ALLOW_LOCAL_TOKEN_TEST") == "1"

    token = os.environ.get("EOS_PUSH_TOKEN", "")
    print("== Checking EOS_PUSH_TOKEN git-receive-pack access across ExpressiveOS 2.0 repos (nothing pushed)")
    if not token:
        raise UpdateError("EOS_PUSH_TOKEN is empty: the Actions secret EXPRESSIVEOS_PUSH_TOKEN isn't set in this repo")
    if token != token.strip() or any(c.isspace() for c in token):
        raise UpdateError("EOS_PUSH_TOKEN has spaces or line breaks in it: save the secret again with the token alone")

    if not is_github_https(manifest_url) and not (allow_local and manifest_url.startswith("http://127.0.0.1:")):
        raise UpdateError(f"EOS_MANIFEST_URL {manifest_url} isn't on GitHub (https://github.com/), the only place EOS_PUSH_TOKEN goes")

    if args.manifest:
        mf_path = Path(args.manifest)
    else:
        work = Path(args.work).resolve() / "token-check"
        if work.exists():
            shutil.rmtree(work)
        work.parent.mkdir(parents=True, exist_ok=True)
        git("clone", "--depth=1", "--branch", branch, "--single-branch", manifest_url, str(work), timeout=120)
        mf_path = work / "default.xml"

    mf = parse_manifest(mf_path)
    urls = sorted(
        {manifest_url}
        | {eos_repo_url(eos_org_base, p["name"]).rstrip("/") for p in mf["projects"].values() if p["remote"] == "expressiveos"}
    )
    off = [
        u for u in urls
        if not is_github_https(u) and not (allow_local and u.startswith("http://127.0.0.1:"))
    ]
    if off:
        raise UpdateError(f"not on GitHub (https://github.com/), the only place EOS_PUSH_TOKEN goes: {', '.join(off)}")

    code, _ = receive_pack_check(manifest_url, None)
    if code != 401:
        raise UpdateError(
            f"{manifest_url} answered {code} to an unauthenticated git-receive-pack request (401 expected)"
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        answers = dict(zip(urls, ex.map(lambda u: receive_pack_check(u, token), urls)))

    meaning = {
        401: "token refused (wrong, expired or revoked)",
        403: "no push access (check repository access, Contents write permission, or org approval)",
        404: "not found (or not visible to the token)",
    }
    bad = 0
    for u in urls:
        rc_code, ctype = answers[u]
        if rc_code == 200 and ctype == "application/x-git-receive-pack-advertisement":
            continue
        bad += 1
        msg = ctype if rc_code is None else meaning.get(rc_code, f"answered {rc_code} {ctype}".strip())
        print(f"  {u}: {msg}", file=sys.stderr)
    print(f"-- {len(urls) - bad} of {len(urls)} repos accept git-receive-pack")
    print("TOKEN_CHECK=OK" if bad == 0 else "TOKEN_CHECK=FAIL")
    return 0 if bad == 0 else 1


def cmd_push(args):
    upd_id = args.id
    if not UPDATE_ID_RE.fullmatch(upd_id):
        raise UpdateError(f"invalid update id '{upd_id}'")
    work = Path(args.work).resolve() / upd_id
    plan_path = work / "plan.json"
    if not plan_path.is_file():
        raise UpdateError(f"no plan.json at {plan_path}")
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    if plan.get("conflicts"):
        raise UpdateError(f"refusing to push plan with {len(plan['conflicts'])} unresolved conflict(s)")

    eos_conf = load_eos_config(KIT)
    ident_name, ident_email = parse_ident(eos_conf.get("EOS_UPDATE_IDENT", "Daryl Denson <9751141+denson9874@users.noreply.github.com>"))
    branch = plan.get("branch", DEFAULT_EOS_BRANCH)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL", f"https://github.com/{plan.get('eos_org', DEFAULT_EOS_ORG)}")
    manifest_url = args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)

    all_urls = [eos_repo_url(eos_org_base, upd["eos_repo"]) for _, upd in sorted(plan["updates"].items())] + [manifest_url]
    validate_push_urls_and_token(all_urls)

    pushed = 0
    for path, upd in sorted(plan["updates"].items()):
        scratch = Path(upd["scratch_dir"])
        remote_url = eos_repo_url(eos_org_base, upd["eos_repo"])
        head = upd["new_head"]
        # Check current remote branch ref to guarantee fast-forward (or unborn branch for new fork)
        ls = git("ls-remote", "--heads", remote_url, branch, cwd=scratch, timeout=60).stdout.strip()
        if ls:
            remote_sha = ls.split()[0]
            if remote_sha == head:
                print(f"  already pushed: {upd['eos_repo']} @ {head[:12]}")
                continue
            git("fetch", remote_url, f"refs/heads/{branch}:refs/eos/remote_tip", cwd=scratch, timeout=120)
            anc = git("merge-base", "--is-ancestor", "refs/eos/remote_tip", head, cwd=scratch, ok=(0, 1), timeout=15)
            if anc.returncode != 0:
                raise UpdateError(f"refusing non-fast-forward push on {upd['eos_repo']} ({remote_sha[:12]} not ancestor of {head[:12]})")
        git(*git_push_cfg(remote_url), "push", "--no-verify", remote_url, f"{head}:refs/heads/{branch}", cwd=scratch, timeout=180)
        print(f"  pushed: {upd['eos_repo']} -> {branch} @ {head[:12]}")
        pushed += 1

    # Commit and push manifest PR branch update/<id> (idempotent if already pushed with identical tree)
    mf_scratch = work / "manifest-push"
    if mf_scratch.exists():
        shutil.rmtree(mf_scratch)
    git("clone", "--branch", branch, "--single-branch", manifest_url, str(mf_scratch), timeout=120)
    pr_branch = f"update/{upd_id}"
    ls_pr = git("ls-remote", "--heads", manifest_url, pr_branch, cwd=mf_scratch, timeout=60).stdout.strip()
    if ls_pr:
        git("fetch", manifest_url, f"refs/heads/{pr_branch}:refs/eos/existing_pr", cwd=mf_scratch, timeout=120)
        git("checkout", "-B", pr_branch, "refs/eos/existing_pr", cwd=mf_scratch, timeout=30)
    else:
        git("checkout", "-b", pr_branch, cwd=mf_scratch, timeout=30)
    shutil.copyfile(plan["manifest_out"], mf_scratch / "default.xml")
    shutil.copyfile(plan["last_update_out"], mf_scratch / "last-update.conf")
    git("add", "default.xml", "last-update.conf", cwd=mf_scratch, timeout=30)
    if git("diff", "--cached", "--quiet", cwd=mf_scratch, ok=(0, 1), timeout=15).returncode == 1:
        git(
            "commit", "-m", f"manifest: AOSP security update {upd_id} ({plan['to_sec_tag']}, SPL {plan['target_spl']})",
            cwd=mf_scratch,
            env={
                "GIT_AUTHOR_NAME": ident_name,
                "GIT_AUTHOR_EMAIL": ident_email,
                "GIT_COMMITTER_NAME": ident_name,
                "GIT_COMMITTER_EMAIL": ident_email,
            },
            timeout=30,
        )
    elif ls_pr:
        print(f"  already pushed: manifest @ {pr_branch}")
        print(f"UPDATE_PUSH=OK (forks_pushed={pushed}, manifest_branch={pr_branch})")
        return 0
    git(*git_push_cfg(manifest_url), "push", "--no-verify", manifest_url, f"HEAD:refs/heads/{pr_branch}", cwd=mf_scratch, timeout=120)
    print(f"UPDATE_PUSH=OK (forks_pushed={pushed}, manifest_branch={pr_branch})")
    return 0


def cmd_verify(args):
    upd_id = args.id
    if not UPDATE_ID_RE.fullmatch(upd_id):
        raise UpdateError(f"invalid update id '{upd_id}'")
    work = Path(args.work).resolve() / upd_id
    plan_path = work / "plan.json"
    if not plan_path.is_file():
        raise UpdateError(f"no plan.json at {plan_path}")
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    eos_conf = load_eos_config(KIT)
    branch = plan.get("branch", DEFAULT_EOS_BRANCH)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL", f"https://github.com/{plan.get('eos_org', DEFAULT_EOS_ORG)}")
    manifest_url = args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)

    ver_dir = work / "manifest-verify"
    if ver_dir.exists():
        shutil.rmtree(ver_dir)
    git("clone", "--depth=1", "--branch", branch, "--single-branch", manifest_url, str(ver_dir), timeout=120)

    problems = []
    mf = parse_manifest(ver_dir / "default.xml")
    problems.extend(lint_manifest_data(ver_dir / "default.xml"))

    lu = parse_kv_file(ver_dir / "last-update.conf")
    if lu.get("UPDATE") != upd_id:
        problems.append(f"last-update.conf UPDATE is {lu.get('UPDATE')!r}, want {upd_id!r}")
    if lu.get("SPL") != plan["target_spl"]:
        problems.append(f"last-update.conf SPL is {lu.get('SPL')!r}, want {plan['target_spl']!r}")

    for path, upd in sorted(plan["updates"].items()):
        proj = mf["projects"].get(path)
        if proj is None:
            problems.append(f"{path} missing from live manifest")
            continue
        if proj["revision"] != upd["new_head"]:
            problems.append(f"{path} manifest rev {proj['revision'][:12]} != planned {upd['new_head'][:12]}")
        if proj["remote"] != "expressiveos":
            problems.append(f"{path} remote is {proj['remote']!r}, expected 'expressiveos'")
        remote_url = eos_repo_url(eos_org_base, upd["eos_repo"])
        ls = git("ls-remote", "--heads", remote_url, branch, timeout=60).stdout.strip()
        if not ls:
            problems.append(f"{upd['eos_repo']} has no branch {branch}")
        elif ls.split()[0] != upd["new_head"]:
            problems.append(f"{upd['eos_repo']} remote {branch} {ls.split()[0][:12]} != planned {upd['new_head'][:12]}")

    if problems:
        for p in problems:
            print(f"  DIFF: {p}", file=sys.stderr)
        print(f"UPDATE_VERIFY=DIFFERS (problems={len(problems)})")
        return 1
    print(f"UPDATE_VERIFY=OK (verified={len(plan['updates'])}, spl={plan['target_spl']})")
    return 0


def cmd_lint(args):
    manifest_path = Path(args.manifest) if args.manifest else find_manifest_path(args)
    spl_file = args.spl_file
    if not spl_file and args.top:
        cand = Path(args.top) / "vendor" / "expressiveos" / SPL_REL_PATH
        if cand.is_file():
            spl_file = str(cand)
    errs = lint_manifest_data(manifest_path, spl_file=spl_file)
    if errs:
        for e in errs:
            print(f"  LINT_ERR: {e}", file=sys.stderr)
        print(f"MANIFEST_LINT=FAIL (errors={len(errs)})")
        return 1
    print("MANIFEST_LINT=OK")
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description="ExpressiveOS 2.0 pure-AOSP monthly ASB updater")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_common(p):
        p.add_argument("--work", required=True, help="scratch working directory")
        p.add_argument("--top", help="optional local EOS tree for git object reuse")
        p.add_argument("--manifest", help="path to current default.xml")
        p.add_argument("--aosp-manifest-url", help="override AOSP platform/manifest URL")
        p.add_argument("--aosp-base-url", help="override AOSP git base URL")
        p.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")

    p_chk = sub.add_parser("check", help="dry-run AOSP ASB check")
    add_common(p_chk)
    p_chk.add_argument("--from-sec-tag", help="base android-security tag")
    p_chk.add_argument("--to-sec-tag", help="target android-security tag")

    p_plan = sub.add_parser("plan", help="stage monthly ASB update <id>")
    p_plan.add_argument("id", help="update id (YYYY-MM)")
    add_common(p_plan)
    p_plan.add_argument("--from-sec-tag", help="base android-security tag")
    p_plan.add_argument("--to-sec-tag", help="target android-security tag")
    p_plan.add_argument("--target-spl", help="target security patch YYYY-MM-DD")
    p_plan.add_argument("--updates-dir", help="override sources/updates directory")
    p_plan.add_argument("--branch", help="override EOS branch (default expressiveos-2.0)")
    p_plan.add_argument("--org", help="override GitHub org (default ExpressiveOS)")

    p_cr = sub.add_parser("create-repos", help="Mac admin: create new ExpressiveOS ASB repos via gh api")
    p_cr.add_argument("id", help="update id (YYYY-MM)")
    p_cr.add_argument("--work", required=True, help="scratch working directory")
    p_cr.add_argument("--org", help="override GitHub org")
    p_cr.add_argument("--dry-run", action="store_true", help="print actions without calling POST")

    p_push = sub.add_parser("push", help="fast-forward push staged forks + manifest update/<id>")
    p_push.add_argument("id", help="update id (YYYY-MM)")
    p_push.add_argument("--work", required=True, help="scratch working directory")
    p_push.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")
    p_push.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_tok = sub.add_parser("token", help="verify EOS_PUSH_TOKEN git-receive-pack access")
    p_tok.add_argument("--work", required=True, help="scratch working directory")
    p_tok.add_argument("--manifest", help="optional local default.xml path")
    p_tok.add_argument("--branch", help="override EOS branch (default expressiveos-2.0)")
    p_tok.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")
    p_tok.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_ver = sub.add_parser("verify", help="verify merged manifest and pushed forks")
    p_ver.add_argument("id", help="update id (YYYY-MM)")
    p_ver.add_argument("--work", required=True, help="scratch working directory")
    p_ver.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")
    p_ver.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_lint = sub.add_parser("lint", help="strict EOS 2.0 manifest validator")
    p_lint.add_argument("manifest", nargs="?", help="path to default.xml")
    p_lint.add_argument("--top", help="optional EOS tree path")
    p_lint.add_argument("--spl-file", help="optional RELEASE_PLATFORM_SECURITY_PATCH.textproto path")

    return ap


def main(argv=None):
    global STOPPED
    args = build_parser().parse_args(argv)
    STOPPED = {
        "check": "UPDATE_CHECK=FAILED",
        "plan": "UPDATE_PLAN=NOT_READY",
        "create-repos": "CREATE_REPOS=FAIL",
        "push": "UPDATE_PUSH=FAILED",
        "token": "TOKEN_CHECK=FAIL",
        "verify": "UPDATE_VERIFY=FAILED",
        "lint": "MANIFEST_LINT=FAIL",
    }.get(args.cmd)

    handlers = {
        "check": cmd_check,
        "plan": cmd_plan,
        "create-repos": cmd_create_repos,
        "push": cmd_push,
        "token": cmd_token,
        "verify": cmd_verify,
        "lint": cmd_lint,
    }
    try:
        rc = handlers[args.cmd](args)
        sys.exit(rc)
    except UpdateError as exc:
        die(exc)


if __name__ == "__main__":
    main()
