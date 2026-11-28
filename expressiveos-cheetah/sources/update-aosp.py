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
DEFAULT_EOS_ASB_ORG = "ExpressiveOS-ASB"
DEFAULT_EOS_DEVICES_ORG = "ExpressiveOS-Devices"
DEFAULT_EOS_BRANCH = "expressiveos-2.0"
DEFAULT_EOS_MANIFEST_URL = "https://github.com/ExpressiveOS/manifest"
SPL_REL_PATH = "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"

EOS_REMOTES = {"expressiveos", "expressiveos-asb", "expressiveos-devices"}
DEFAULT_EOS_REMOTE_ORGS = {
    "expressiveos": DEFAULT_EOS_ORG,
    "expressiveos-asb": DEFAULT_EOS_ASB_ORG,
    "expressiveos-devices": DEFAULT_EOS_DEVICES_ORG,
}
REMOTE_TOKEN_ENV_VARS = {
    "expressiveos": "EOS_PUSH_TOKEN",
    "expressiveos-asb": "EOS_ASB_PUSH_TOKEN",
    "expressiveos-devices": "EOS_DEVICES_PUSH_TOKEN",
}

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
UPDATE_ID_RE = re.compile(r"^[0-9]{4}-(?:0[1-9]|1[0-2])(?:-[2-9])?$")
SPL_DATE_RE = re.compile(r"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])$")
SEC_TAG_RE = re.compile(r"^android-security-17\.0\.0_r([0-9]+)$")
REL_TAG_RE = re.compile(r"^android-17\.0\.0_r([0-9]+)$")
IDENT_RE = re.compile(r"^([^<>]+?)\s+<([^<>\s]+@[^<>\s]+)>$")

ALLOWED_MANIFEST_TAGS = {"remote", "default", "project", "notice", "contactinfo"}
ALLOWED_PROJECT_CHILDREN = {"linkfile", "copyfile", "annotation"}
ALLOWED_REMOTES = {"aosp"} | EOS_REMOTES
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

# git credential helpers reading push tokens from environment only, never written to disk or argv.
def _push_cred_helper_for_env(env_var):
    return (
        f'!f() {{ test "$1" = get || exit 0; echo username=x-access-token; '
        f'printf "password=%s\\n" "${{{env_var}:-$EOS_PUSH_TOKEN}}"; }}; f'
    )


PUSH_CRED_HELPER = _push_cred_helper_for_env("EOS_PUSH_TOKEN")

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


def infer_fn_topic_for_path(path):
    """Map an AOSP project path to its standardized fn-* GitHub topic."""
    p = path.strip("/")
    if p in ("art", "bionic", "bootable/recovery", "build/make", "build/soong", "trusty/user/base"):
        return "fn-core-build"
    if p.startswith("frameworks/"):
        return "fn-frameworks"
    if p.startswith("system/"):
        return "fn-system"
    if p.startswith("hardware/"):
        return "fn-hardware"
    if p.startswith("packages/apps/"):
        return "fn-apps"
    if p.startswith("packages/modules/"):
        return "fn-modules"
    if p.startswith("packages/services/"):
        return "fn-services"
    if p.startswith("packages/providers/"):
        return "fn-providers"
    if p.startswith("external/"):
        return "fn-external"
    if p.startswith("device/"):
        return "fn-devices"
    if p.startswith("vendor/"):
        return "fn-vendor"
    return "fn-core-build"


def is_eos_remote(remote_name):
    return remote_name in EOS_REMOTES


def remote_org_name(manifest_remotes, remote_name, override_org=None):
    if override_org and remote_name == "expressiveos":
        return override_org
    fetch = (manifest_remotes.get(remote_name) or {}).get("fetch", "").rstrip("/")
    if fetch.startswith("https://github.com/"):
        tail = fetch[len("https://github.com/"):].strip("/")
        if tail and "/" not in tail:
            return tail
    return DEFAULT_EOS_REMOTE_ORGS.get(remote_name, DEFAULT_EOS_ORG)


def remote_base_url(manifest_remotes, remote_name, eos_org_base=None, eos_asb_base=None, eos_devices_base=None):
    """Resolve fetch/push base URL for an ExpressiveOS remote."""
    if remote_name == "expressiveos" and eos_org_base:
        return eos_org_base.rstrip("/")
    if remote_name == "expressiveos-asb" and eos_asb_base:
        return eos_asb_base.rstrip("/")
    if remote_name == "expressiveos-devices" and eos_devices_base:
        return eos_devices_base.rstrip("/")
    fetch = (manifest_remotes.get(remote_name) or {}).get("fetch", "").rstrip("/")
    if fetch:
        return fetch
    org = DEFAULT_EOS_REMOTE_ORGS.get(remote_name, DEFAULT_EOS_ORG)
    return f"https://github.com/{org}"


def token_env_var_for_url(url, remote_name=None):
    """Pick the environment variable holding the push token for a GitHub URL or remote."""
    if remote_name in REMOTE_TOKEN_ENV_VARS:
        return REMOTE_TOKEN_ENV_VARS[remote_name]
    u = (url or "").rstrip("/")
    if u.startswith("https://github.com/"):
        owner = u[len("https://github.com/"):].split("/", 1)[0]
        for rname, org in DEFAULT_EOS_REMOTE_ORGS.items():
            if owner.lower() == org.lower():
                return REMOTE_TOKEN_ENV_VARS[rname]
    return "EOS_PUSH_TOKEN"


def resolve_token_for_url(url, remote_name=None):
    """Return (env_var_used, token_value) for url, falling back to EOS_PUSH_TOKEN."""
    pref = token_env_var_for_url(url, remote_name=remote_name)
    val = os.environ.get(pref, "")
    if val:
        return pref, val
    fallback = os.environ.get("EOS_PUSH_TOKEN", "")
    return (pref if not fallback else "EOS_PUSH_TOKEN"), fallback


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
        elif rem not in remotes:
            errors.append(f"project '{path}' references undeclared remote '{rem}'")
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


def resolve_local_or_remote_url(aosp_base, eos_base, proj_info, top_dir=None, manifest_remotes=None,
                                eos_asb_base=None, eos_devices_base=None):
    """Return fetch URL (and optional local reference dir) for a project."""
    rem = proj_info["remote"]
    if is_eos_remote(rem):
        base = remote_base_url(
            manifest_remotes or {},
            rem,
            eos_org_base=eos_base if rem == "expressiveos" else None,
            eos_asb_base=eos_asb_base,
            eos_devices_base=eos_devices_base,
        )
        url = eos_repo_url(base, proj_info["name"])
    else:
        url = aosp_repo_url(aosp_base, proj_info["name"])
    local_dir = None
    if top_dir:
        cand = Path(top_dir) / proj_info["path"]
        if (cand / ".git").exists():
            # Never borrow from a shallow local checkout (clone-depth in default.xml): git fetch
            # copies the shallow tip as a dangling commit without .git/shallow or its parents,
            # which passes cat-file -e and cherry-pick but fails git push with an unpacker error.
            sh = git("rev-parse", "--is-shallow-repository", cwd=cand, ok=(0, 128), timeout=15)
            if sh.returncode == 0 and sh.stdout.strip() != "true":
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
        cdate = git("show", "-s", "--format=%cI", sha, cwd=scratch_dir, timeout=15).stdout.strip()
        cp_env = dict(env, GIT_COMMITTER_DATE=cdate) if cdate else env
        res = git("cherry-pick", "--allow-empty", sha, cwd=scratch_dir, env=cp_env, ok=(0, 1), pure=True, timeout=timeout)
        if res.returncode == 0:
            applied.append(sha)
            continue
        # Conflict! Abort and try resolution patch (generated from base_rev..resolved) if supplied
        git("cherry-pick", "--abort", cwd=scratch_dir, ok=(0, 1, 128), timeout=30)
        if resolution_patch and Path(resolution_patch).is_file():
            git("reset", "--hard", orig_head, cwd=scratch_dir, timeout=30)
            am_res = git("am", "--3way", "--committer-date-is-author-date", str(resolution_patch), cwd=scratch_dir, env=env, ok=(0, 1, 128), pure=True, timeout=timeout)
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
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL") or None
    eos_asb_base = getattr(args, "eos_asb_org_base", None) or os.environ.get("EOS_ASB_ORG_BASE_URL") or None
    eos_devices_base = getattr(args, "eos_devices_org_base", None) or os.environ.get("EOS_DEVICES_ORG_BASE_URL") or None

    last_conf = parse_kv_file(manifest_path.parent / "last-update.conf")
    sec_tags, rel_tags = list_remote_tags(aosp_manifest_url)
    print(f"AOSP android-17.0.0_r* tags: {len(rel_tags)} (latest: {rel_tags[-1] if rel_tags else 'none'})")
    print(f"AOSP android-security-17.0.0_r* tags: {len(sec_tags)} (latest: {sec_tags[-1] if sec_tags else 'none'})")
    base_tag = last_conf.get("AOSP_BASE_TAG")
    if base_tag and rel_tags and rel_tags[-1] != base_tag:
        m_cur = REL_TAG_RE.fullmatch(base_tag)
        newer_rels = [
            t for t in rel_tags
            if not m_cur or int(REL_TAG_RE.fullmatch(t).group(1)) > int(m_cur.group(1))
        ]
        if newer_rels:
            print(
                f"NOTE: new AOSP release tag(s) beyond AOSP_BASE_TAG ({base_tag}): "
                f"{', '.join(newer_rels)} (full QPR rebase requires manual review; "
                f"update-aosp.py cherry-picks android-security-17.0.0_r* ASB commits only)"
            )

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
        base_url, local_dir = resolve_local_or_remote_url(
            aosp_base_url, eos_org_base, proj, args.top,
            manifest_remotes=eos_manifest["remotes"],
            eos_asb_base=eos_asb_base,
            eos_devices_base=eos_devices_base,
        )
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
            is_existing_fork = is_eos_remote(proj["remote"])
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
    """Rewrite default.xml pinning updated revisions and converting new forks to their target EOS remote."""
    tree = ET.parse(str(manifest_path))
    root = tree.getroot()
    for proj in root.findall("project"):
        name = proj.get("name")
        path = proj.get("path") or name
        if path in repo_updates:
            upd = repo_updates[path]
            proj.attrib.pop("clone-depth", None)
            proj.set("remote", upd.get("remote", "expressiveos"))
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

    manifest_path = find_manifest_path(args)
    existing_last = parse_kv_file(manifest_path.parent / "last-update.conf")
    upd_dir = Path(args.updates_dir) / upd_id if args.updates_dir else (HERE / "updates" / upd_id)
    uconf = parse_kv_file(upd_dir / "update.conf")
    from_tag = args.from_sec_tag or uconf.get("AOSP_SEC_TAG") or existing_last.get("AOSP_SEC_TAG")
    to_tag = args.to_sec_tag or uconf.get("TARGET_SEC_TAG")
    target_spl = args.target_spl or uconf.get("TARGET_SPL")
    if not from_tag or not to_tag or not target_spl:
        raise UpdateError(f"need AOSP_SEC_TAG (or last-update.conf), TARGET_SEC_TAG, and TARGET_SPL (in {upd_dir / 'update.conf'} or CLI flags)")
    if not SPL_DATE_RE.fullmatch(target_spl):
        raise UpdateError(f"invalid TARGET_SPL '{target_spl}' (expected YYYY-MM-DD)")

    eos_manifest = parse_manifest(manifest_path)

    aosp_manifest_url = args.aosp_manifest_url or os.environ.get("EOS_AOSP_MANIFEST_URL", DEFAULT_AOSP_MANIFEST_URL)
    aosp_base_url = args.aosp_base_url or os.environ.get("EOS_AOSP_BASE_URL", DEFAULT_AOSP_BASE_URL)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL") or None
    eos_asb_base = getattr(args, "eos_asb_org_base", None) or os.environ.get("EOS_ASB_ORG_BASE_URL") or None
    eos_devices_base = getattr(args, "eos_devices_org_base", None) or os.environ.get("EOS_DEVICES_ORG_BASE_URL") or None

    from_xml = fetch_manifest_at_tag(aosp_manifest_url, from_tag, work)
    to_xml = fetch_manifest_at_tag(aosp_manifest_url, to_tag, work)
    changed = diff_security_manifests(from_xml, to_xml)

    resolutions_dir = upd_dir / "resolutions"
    repo_updates = {}
    new_repos = []
    new_repo_targets = {}
    conflicts = []

    new_fork_remote = "expressiveos-asb" if "expressiveos-asb" in eos_manifest["remotes"] else "expressiveos"

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
        base_url, local_dir = resolve_local_or_remote_url(
            aosp_base_url, eos_org_base, proj, args.top,
            manifest_remotes=eos_manifest["remotes"],
            eos_asb_base=eos_asb_base,
            eos_devices_base=eos_devices_base,
        )
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
        is_existing = is_eos_remote(proj["remote"])
        target_remote = proj["remote"] if is_existing else new_fork_remote
        eos_repo = proj["name"] if is_existing else safe
        if res["status"] == "CONFLICTS":
            conflicts.append({"path": path, "eos_repo": eos_repo, "commit": res["conflict_commit"], "error": res["error"]})
            print(f"  [CONFLICTS] {path} at {res['conflict_commit']}: {res['error']}")
            continue

        is_new = not is_existing
        target_org = remote_org_name(eos_manifest["remotes"], target_remote, override_org=args.org)
        target_base = remote_base_url(
            eos_manifest["remotes"],
            target_remote,
            eos_org_base=eos_org_base,
            eos_asb_base=eos_asb_base,
            eos_devices_base=eos_devices_base,
        )
        if is_new:
            new_repos.append(eos_repo)
            new_repo_targets[eos_repo] = {"org": target_org, "remote": target_remote, "path": path}
        repo_updates[path] = {
            "path": path,
            "eos_repo": eos_repo,
            "remote": target_remote,
            "org": target_org,
            "remote_base": target_base,
            "old_rev": proj["revision"],
            "new_head": res["head"],
            "is_new_fork": is_new,
            "status": res["status"],
            "scratch_dir": str(scratch),
            "asb_commits": commits,
        }
        print(f"  [{res['status']}{' NEW_FORK' if is_new else ''}] {path} ({target_remote}) -> {res['head'][:12]}")

    # Stage SPL bump in vendor/expressiveos
    ve_proj = eos_manifest["projects"].get("vendor/expressiveos")
    if ve_proj is None:
        raise UpdateError("manifest lacks vendor/expressiveos project")
    ve_url, ve_local = resolve_local_or_remote_url(
        aosp_base_url, eos_org_base, ve_proj, args.top,
        manifest_remotes=eos_manifest["remotes"],
        eos_asb_base=eos_asb_base,
        eos_devices_base=eos_devices_base,
    )
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
        spl_iso = f"{target_spl}T00:00:00Z"
        git(
            "commit", "-m", f"release: Bump Security String to {target_spl} ({upd_id})",
            cwd=ve_scratch,
            env={
                "GIT_AUTHOR_NAME": ident_name,
                "GIT_AUTHOR_EMAIL": ident_email,
                "GIT_AUTHOR_DATE": spl_iso,
                "GIT_COMMITTER_NAME": ident_name,
                "GIT_COMMITTER_EMAIL": ident_email,
                "GIT_COMMITTER_DATE": spl_iso,
            },
            timeout=30,
        )
    ve_head = git("rev-parse", "HEAD", cwd=ve_scratch, timeout=15).stdout.strip()
    ve_remote = ve_proj["remote"]
    ve_org = remote_org_name(eos_manifest["remotes"], ve_remote, override_org=args.org)
    ve_base = remote_base_url(
        eos_manifest["remotes"],
        ve_remote,
        eos_org_base=eos_org_base,
        eos_asb_base=eos_asb_base,
        eos_devices_base=eos_devices_base,
    )
    repo_updates["vendor/expressiveos"] = {
        "path": "vendor/expressiveos",
        "eos_repo": ve_proj["name"],
        "remote": ve_remote,
        "org": ve_org,
        "remote_base": ve_base,
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

    base_tag = uconf.get("AOSP_BASE_TAG") or existing_last.get("AOSP_BASE_TAG")
    base_tag_line = f"AOSP_BASE_TAG={base_tag}\n" if base_tag else ""
    last_update_path = work / "last-update.conf"
    last_update_path.write_text(
        f"UPDATE={upd_id}\n"
        f"{base_tag_line}"
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
        "asb_org": remote_org_name(eos_manifest["remotes"], new_fork_remote, override_org=args.org),
        "new_fork_remote": new_fork_remote,
        "manifest_out": str(out_xml),
        "last_update_out": str(last_update_path),
        "new_repos": sorted(set(new_repos)),
        "new_repo_targets": new_repo_targets,
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
    default_org = args.org or plan.get("asb_org") or plan.get("eos_org") or DEFAULT_EOS_ORG
    repo_targets = plan.get("new_repo_targets") or {}
    branch = plan.get("branch", DEFAULT_EOS_BRANCH)
    gh_bin = os.environ.get("EOS_GH_BIN", "gh")

    created = 0
    existing = 0
    for repo in plan.get("new_repos", []):
        target_info = repo_targets.get(repo) or {}
        org = args.org or target_info.get("org") or default_org
        repo_path = target_info.get("path") or repo.replace("_", "/")
        check = run_cmd([gh_bin, "api", "-X", "GET", f"repos/{org}/{repo}"], ok=(0, 1), timeout=30)
        if check.returncode == 0:
            print(f"  exists: {org}/{repo}")
            existing += 1
            continue
        if args.dry_run:
            print(f"  would create: {org}/{repo} (public, target branch {branch})")
            created += 1
            continue
        desc = f"AOSP {repo_path} carrying monthly Android Security Bulletin (ASB) patches for ExpressiveOS 2.0"
        run_cmd(
            [
                gh_bin, "api", "-X", "POST", f"orgs/{org}/repos",
                "-f", f"name={repo}",
                "-f", f"description={desc}",
                "-F", "private=false",
                "-F", "auto_init=false",
            ],
            timeout=60,
        )
        # Auto-apply Option A standardized topics (best-effort; never blocks creation)
        topics_payload = json.dumps({
            "names": ["expressiveos", "eos-2-0", infer_fn_topic_for_path(repo_path), "eos-asb-patch"]
        })
        topic_res = run_cmd(
            [gh_bin, "api", "-X", "PUT", f"repos/{org}/{repo}/topics", "--input", "-"],
            input_data=topics_payload,
            ok=(0, 1),
            timeout=30,
        )
        if topic_res.returncode != 0:
            print(f"  note: created {org}/{repo} but skipped topic tagging", file=sys.stderr)
        print(f"  created: {org}/{repo}")
        created += 1

    print(f"CREATE_REPOS=OK (created={created}, existing={existing}, dry_run={args.dry_run})")
    return 0


def is_github_https(url):
    return (url or "").startswith("https://github.com/")


def validate_push_urls_and_token(url_entries):
    entries = [(u, None) if isinstance(u, str) else u for u in url_entries]
    off = [u for u, _ in entries if not is_github_https(u) and not u.startswith("file://")]
    if off:
        raise UpdateError(
            f"not on GitHub (https://github.com/), the only place EOS_PUSH_TOKEN goes: {', '.join(off)}"
        )
    checked = {}
    for u, rem in entries:
        if not is_github_https(u):
            continue
        env_var, token = resolve_token_for_url(u, remote_name=rem)
        if not token:
            raise UpdateError(
                f"{env_var} is empty: set the Actions secret for {u} (or EXPRESSIVEOS_PUSH_TOKEN)"
            )
        if token != token.strip() or any(c.isspace() for c in token):
            raise UpdateError(
                f"{env_var} has spaces or line breaks in it: save the secret again with the token alone"
            )
        checked[env_var] = token
    return checked.get("EOS_PUSH_TOKEN", "")


def git_push_cfg(url, remote_name=None):
    cfg = ["-c", "credential.helper=", "-c", f"core.hooksPath={os.devnull}"]
    if is_github_https(url):
        env_var = token_env_var_for_url(url, remote_name=remote_name)
        cfg += ["-c", f"credential.https://github.com.helper={_push_cred_helper_for_env(env_var)}"]
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


def _resolve_plan_update_url(upd, args, plan):
    rem = upd.get("remote", "expressiveos")
    if rem == "expressiveos" and getattr(args, "eos_org_base", None):
        base = args.eos_org_base
    elif rem == "expressiveos-asb" and getattr(args, "eos_asb_org_base", None):
        base = args.eos_asb_org_base
    elif rem == "expressiveos-devices" and getattr(args, "eos_devices_org_base", None):
        base = args.eos_devices_org_base
    elif rem == "expressiveos" and os.environ.get("EOS_ORG_BASE_URL"):
        base = os.environ["EOS_ORG_BASE_URL"]
    elif rem == "expressiveos-asb" and os.environ.get("EOS_ASB_ORG_BASE_URL"):
        base = os.environ["EOS_ASB_ORG_BASE_URL"]
    elif rem == "expressiveos-devices" and os.environ.get("EOS_DEVICES_ORG_BASE_URL"):
        base = os.environ["EOS_DEVICES_ORG_BASE_URL"]
    elif upd.get("remote_base"):
        base = upd["remote_base"]
    else:
        org = upd.get("org") or plan.get("eos_org") or DEFAULT_EOS_REMOTE_ORGS.get(rem, DEFAULT_EOS_ORG)
        base = f"https://github.com/{org}"
    return eos_repo_url(base, upd["eos_repo"]), rem


def cmd_token(args):
    eos_conf = load_eos_config(KIT)
    branch = args.branch or eos_conf.get("EOS_MANIFEST_BRANCH", DEFAULT_EOS_BRANCH)
    eos_org_base = args.eos_org_base or os.environ.get("EOS_ORG_BASE_URL") or None
    eos_asb_base = getattr(args, "eos_asb_org_base", None) or os.environ.get("EOS_ASB_ORG_BASE_URL") or None
    eos_devices_base = getattr(args, "eos_devices_org_base", None) or os.environ.get("EOS_DEVICES_ORG_BASE_URL") or None
    manifest_url = (args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)).rstrip("/")
    allow_local = os.environ.get("EOS_ALLOW_LOCAL_TOKEN_TEST") == "1"

    token = os.environ.get("EOS_PUSH_TOKEN", "")
    print("== Checking EOS push token git-receive-pack access across ExpressiveOS 2.0 repos (nothing pushed)")
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
    url_to_remote = {manifest_url: "expressiveos"}
    for p in mf["projects"].values():
        if not is_eos_remote(p["remote"]):
            continue
        base = remote_base_url(
            mf["remotes"],
            p["remote"],
            eos_org_base=eos_org_base,
            eos_asb_base=eos_asb_base,
            eos_devices_base=eos_devices_base,
        )
        url_to_remote[eos_repo_url(base, p["name"]).rstrip("/")] = p["remote"]

    urls = sorted(url_to_remote.keys())
    off = [
        u for u in urls
        if not is_github_https(u) and not (allow_local and u.startswith("http://127.0.0.1:"))
    ]
    if off:
        raise UpdateError(f"not on GitHub (https://github.com/), the only place EOS_PUSH_TOKEN goes: {', '.join(off)}")

    url_tokens = {}
    for u in urls:
        env_var, tok = resolve_token_for_url(u, remote_name=url_to_remote[u])
        if not tok:
            raise UpdateError(f"{env_var} is empty for {u}")
        if tok != tok.strip() or any(c.isspace() for c in tok):
            raise UpdateError(f"{env_var} has spaces or line breaks in it: save the secret again with the token alone")
        url_tokens[u] = tok

    code, _ = receive_pack_check(manifest_url, None)
    if code != 401:
        raise UpdateError(
            f"{manifest_url} answered {code} to an unauthenticated git-receive-pack request (401 expected)"
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        answers = dict(zip(urls, ex.map(lambda u: receive_pack_check(u, url_tokens[u]), urls)))

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
    manifest_url = args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)

    resolved = {}
    all_url_entries = []
    for path, upd in sorted(plan["updates"].items()):
        rurl, rname = _resolve_plan_update_url(upd, args, plan)
        resolved[path] = (rurl, rname)
        all_url_entries.append((rurl, rname))
    all_url_entries.append((manifest_url, "expressiveos"))
    validate_push_urls_and_token(all_url_entries)

    pushed = 0
    for path, upd in sorted(plan["updates"].items()):
        scratch = Path(upd["scratch_dir"])
        remote_url, rname = resolved[path]
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
        git(*git_push_cfg(remote_url, remote_name=rname), "push", "--no-verify", remote_url, f"{head}:refs/heads/{branch}", cwd=scratch, timeout=180)
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
    git(*git_push_cfg(manifest_url, remote_name="expressiveos"), "push", "--no-verify", manifest_url, f"HEAD:refs/heads/{pr_branch}", cwd=mf_scratch, timeout=120)
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
        expected_rem = upd.get("remote", "expressiveos")
        if proj["revision"] != upd["new_head"]:
            problems.append(f"{path} manifest rev {proj['revision'][:12]} != planned {upd['new_head'][:12]}")
        if proj["remote"] != expected_rem:
            problems.append(f"{path} remote is {proj['remote']!r}, expected {expected_rem!r}")
        remote_url, _ = _resolve_plan_update_url(upd, args, plan)
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


def fetch_eos_manifest_ref(manifest_url, ref, work_dir, timeout=90):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", ref) or ".." in ref:
        raise UpdateError(f"invalid manifest ref '{ref}'")
    fetch_spec = f"refs/{ref}/head" if re.fullmatch(r"pull/[0-9]+", ref) else ref
    repo_dir = Path(work_dir) / "lint-manifest.git"
    if not repo_dir.exists():
        repo_dir.mkdir(parents=True, exist_ok=True)
        git("init", "--bare", str(repo_dir), timeout=30)
    git("fetch", "--depth=1", manifest_url, fetch_spec, git_dir=repo_dir, timeout=timeout)
    blob = git("show", "FETCH_HEAD:default.xml", git_dir=repo_dir, timeout=30).stdout
    out_xml = Path(work_dir) / "lint-default.xml"
    out_xml.write_text(blob, encoding="utf-8")
    return out_xml


def cmd_lint(args):
    tmp_ctx = None
    try:
        if args.manifest and (Path(args.manifest).is_file() or args.manifest.endswith(".xml")):
            manifest_path = Path(args.manifest)
        elif not args.manifest and args.top:
            manifest_path = find_manifest_path(args)
        else:
            eos_conf = load_eos_config(KIT)
            manifest_url = (args.manifest_url or eos_conf.get("EOS_MANIFEST_URL", DEFAULT_EOS_MANIFEST_URL)).rstrip("/")
            ref = args.manifest or eos_conf.get("EOS_MANIFEST_BRANCH", DEFAULT_EOS_BRANCH)
            if args.work:
                work_dir = Path(args.work).resolve() / "lint"
                work_dir.mkdir(parents=True, exist_ok=True)
            else:
                tmp_ctx = tempfile.TemporaryDirectory(prefix="eos-lint-")
                work_dir = Path(tmp_ctx.name)
            manifest_path = fetch_eos_manifest_ref(manifest_url, ref, work_dir)

        spl_file = args.spl_file
        if not spl_file and args.top:
            cand = Path(args.top) / "vendor" / "expressiveos" / SPL_REL_PATH
            if cand.is_file():
                spl_file = str(cand)
        errs = lint_manifest_data(manifest_path, spl_file=spl_file)
    finally:
        if tmp_ctx is not None:
            tmp_ctx.cleanup()
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
        p.add_argument("--eos-asb-org-base", help="override ExpressiveOS-ASB org base URL")
        p.add_argument("--eos-devices-org-base", help="override ExpressiveOS-Devices org base URL")

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
    p_push.add_argument("--eos-asb-org-base", help="override ExpressiveOS-ASB org base URL")
    p_push.add_argument("--eos-devices-org-base", help="override ExpressiveOS-Devices org base URL")
    p_push.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_tok = sub.add_parser("token", help="verify EOS push token git-receive-pack access")
    p_tok.add_argument("--work", required=True, help="scratch working directory")
    p_tok.add_argument("--manifest", help="optional local default.xml path")
    p_tok.add_argument("--branch", help="override EOS branch (default expressiveos-2.0)")
    p_tok.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")
    p_tok.add_argument("--eos-asb-org-base", help="override ExpressiveOS-ASB org base URL")
    p_tok.add_argument("--eos-devices-org-base", help="override ExpressiveOS-Devices org base URL")
    p_tok.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_ver = sub.add_parser("verify", help="verify merged manifest and pushed forks")
    p_ver.add_argument("id", help="update id (YYYY-MM)")
    p_ver.add_argument("--work", required=True, help="scratch working directory")
    p_ver.add_argument("--eos-org-base", help="override ExpressiveOS org base URL")
    p_ver.add_argument("--eos-asb-org-base", help="override ExpressiveOS-ASB org base URL")
    p_ver.add_argument("--eos-devices-org-base", help="override ExpressiveOS-Devices org base URL")
    p_ver.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

    p_lint = sub.add_parser("lint", help="strict EOS 2.0 manifest validator")
    p_lint.add_argument("manifest", nargs="?", help="path to default.xml or remote ref (e.g. pull/50, update/2026-12)")
    p_lint.add_argument("--top", help="optional EOS tree path")
    p_lint.add_argument("--spl-file", help="optional RELEASE_PLATFORM_SECURITY_PATCH.textproto path")
    p_lint.add_argument("--work", help="optional scratch working directory for remote ref fetches")
    p_lint.add_argument("--manifest-url", help="override ExpressiveOS/manifest URL")

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
