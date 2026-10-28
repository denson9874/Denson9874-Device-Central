#!/usr/bin/env python3
# ExpressiveOS's own manifest (default.xml on ExpressiveOS/manifest, branch expressiveos), made
# from the sources of the 1.0 builds (eos-1.0-base/manifest.xml and eos-1.0-base/cheetah.xml):
# every project Evolution X, Evolution-X-Devices or BtHelper's TheParasiteProject hosted comes
# from ExpressiveOS's fork instead (org-fork.sh made them), at the commit its expressiveos
# branch has now (the 1.0 pin plus the kit's commits), and everything else (LineageOS, AOSP)
# stays at its 1.0 pin. One flat file, every project at a commit, never a branch head; a fresh
# tree can sync it too, since each commit is on the branch named as its upstream.
# evolution/manifest stays at Evolution X's last manifest (its 1.0 pin): build_kernel reads
# the LineageOS version from it, and a manifest can't name its own next commit.
#
#   own-manifest.py [org url]     # default https://github.com/ExpressiveOS; prints default.xml
#
# Reads each fork's branch with git ls-remote; fails if a fork or its branch is missing.
import os, re, subprocess, sys
import xml.etree.ElementTree as ET

here = os.path.dirname(os.path.abspath(__file__))
base = [os.path.join(here, "eos-1.0-base", f) for f in ("manifest.xml", "cheetah.xml")]
org = (sys.argv[1] if len(sys.argv) > 1 else "https://github.com/ExpressiveOS").rstrip("/")
SELF = "evolution/manifest"

def fail(msg):
    sys.exit(f"FAIL: {msg}")

def tip(name, branch):
    try:
        out = subprocess.run(["git", "ls-remote", f"{org}/{name}", f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=120, check=True).stdout.split()
    except (subprocess.SubprocessError, OSError) as e:
        fail(f"git ls-remote {org}/{name} failed: {e}")
    if len(out) != 2 or not re.fullmatch(r"[0-9a-f]{40}", out[0]):
        fail(f"{org}/{name} has no branch {branch}")
    return out[0]

remotes, projects, seen = {}, [], {}
for f in base:
    r = ET.parse(f).getroot()
    fetch = {e.get("name"): (e.get("fetch") or "").rstrip("/") for e in r.iter("remote")}
    d = r.find("default")
    for p in r.iter("project"):
        rem = p.get("remote") or d.get("remote")
        rev = p.get("revision") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            fail(f"{p.get('path') or p.get('name')} isn't pinned to a commit in {f}")
        url = f"{fetch[rem]}/{p.get('name')}"
        m = re.fullmatch(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)", url)
        a = dict(p.attrib)
        if m and m.group(1) == "LineageOS" and rem not in ("github",):
            # cheetah.xml's own LineageOS remote: the same repo, under the
            # same name, so the tree keeps its git objects
            a["remote"] = "lineageos"
        elif m and m.group(1) != "LineageOS":
            # The fork, on the branch org-fork.sh made for this pin: expressiveos for a repo's
            # first pin, expressiveos-<suffix> for another (OTA-VANILLA: cnb-vanilla)
            name = m.group(2)
            up = re.sub(r"^refs/heads/", "", p.get("upstream") or "")
            first = seen.setdefault(name, up)
            branch = "expressiveos" if up == first else "expressiveos-" + (up[len(first) + 1:] if up.startswith(first + "-") else up)
            a.update(name=name, remote="expressiveos",
                     revision=rev if p.get("path") == SELF else tip(name, branch),
                     upstream=f"refs/heads/{branch}")
            a["dest-branch"] = f"refs/heads/{branch}"
        elif rem not in ("aosp", "github"):
            fail(f"{url}: a remote this manifest doesn't keep ({rem})")
        projects.append((a, list(p)))

out = ['<?xml version="1.0" encoding="UTF-8"?>',
       "<!-- ExpressiveOS's sources: every project at a commit, never a branch head. Projects from",
       "     github.com/ExpressiveOS are ExpressiveOS's own (forks of Evolution X's repos at the 1.0",
       "     builds' commits, plus ExpressiveOS's changes as commits on branch expressiveos); the rest",
       "     are LineageOS's and AOSP's, at the commits of the 1.0 builds until an update moves them.",
       "     Change a revision here only to a commit on the branch its upstream names. -->",
       "<manifest>",
       '  <remote name="aosp" fetch="https://android.googlesource.com" review="android-review.googlesource.com" revision="refs/tags/android-17.0.0_r1" />',
       f'  <remote name="expressiveos" fetch="{org}" />',
       '  <remote name="github" fetch=".." review="review.lineageos.org" />',
       '  <remote name="lineageos" fetch="https://github.com/LineageOS" />',
       "",
       # build_kernel greps this line for the LineageOS version (lineage-24.0)
       '  <default remote="github" revision="refs/heads/lineage-24.0" sync-j="4" sync-c="true" />',
       ""]
def esc(v):
    return v.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")
def tag(e, a):
    return f"<{e} " + " ".join(f'{k}="{esc(v)}"' for k, v in a.items())
paths = set()
for a, kids in projects:
    p = a.get("path") or a["name"]
    if p in paths:
        fail(f"two projects at {p}")
    paths.add(p)
    if kids:
        out.append(f"  {tag('project', a)}>")
        out += [f"    {tag(k.tag, dict(k.attrib))} />" for k in kids]
        out.append("  </project>")
    else:
        out.append(f"  {tag('project', a)} />")
out.append("</manifest>")
print("\n".join(out))
