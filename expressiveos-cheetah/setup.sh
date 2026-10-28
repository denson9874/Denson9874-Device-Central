#!/usr/bin/env bash
# Set up the ExpressiveOS cheetah tree, or sync it again: ExpressiveOS's own manifest
# (EOS_MANIFEST_URL, branch EOS_MANIFEST_BRANCH: every project at a commit, never a branch
# head, cheetah's device trees and blobs included) with full git history and Git LFS, then
# repo sync. Only a new commit of that manifest brings newer sources.
# A tree still on Evolution X's manifest and the 1.0 pins (EOS_OLD_MANIFEST_URL, the kit's
# expressiveos-pins.xml and local_manifests/cheetah.xml) moves to ExpressiveOS's manifest
# here: same paths, the forks' commits instead of Evolution X's, so the sync fetches only the
# kit's commits. A project whose repo is now another (BtHelper) is checked out again.
# The tree is its own: nothing in it may be a symlink, hardlink or git alternate into
# ~/evolution or ~/derpfest, so nothing this kit does can reach their builds.
# A sync drops local commits; eos-images.sh puts the kit's own back (prepare.sh).
#
#   setup.sh [top]          # default ~/expressiveos
#
#   EOS_SYNC_JOBS=<n>       repo sync jobs (default 4; GitHub refuses many more)
#   EOS_MIN_FREE_GB=<n>     free disk a new tree needs first (default 450: source with
#                           history, out/ and out-kernel/ for one device; DerpFest's
#                           tree, the same kind with two devices built, used 386 GB)
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "SETUP=FAIL"' EXIT
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"

arg=${1:-$HOME/expressiveos}
[[ $# -le 1 ]] || fail "usage: setup.sh [top]"
not_other "$arg"
PATH=$HOME/bin:$PATH
command -v repo >/dev/null || fail "repo isn't installed"
git lfs version >/dev/null 2>&1 || fail "git-lfs isn't installed (vendor/google/cheetah and vendor/gms need it)"
# Not during an ExpressiveOS build (eos-images.sh holds this lock for its whole run).
# EOS_HOLDS_LOCK=1: run under eos_lock, which holds it already (checked, not taken on trust)
if [[ "${EOS_HOLDS_LOCK:-}" = 1 ]]; then
    locks_held
else
    exec 8>"$HOME/.expressiveos.lock"
    flock -n 8 || fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock)"
fi

if [[ ! -e "$arg/.repo" ]]; then
    [[ ! -e "$arg" || -z "$(ls -A -- "$arg")" ]] || fail "$arg exists and isn't a repo checkout; move it away or name another folder"
    mkdir -p -- "$arg"
    top=$(cd "$arg" && pwd -P)
    not_other "$top"
    free=$(df -BG --output=avail -- "$top" | tail -1 | tr -dc 0-9)
    min=${EOS_MIN_FREE_GB:-450}
    (( free >= min )) || fail "$top has $free GB free; a new ExpressiveOS tree needs about $min GB (EOS_MIN_FREE_GB)"
    echo "== repo init $EOS_MANIFEST_URL -b $EOS_MANIFEST_BRANCH in $top (full history, Git LFS)"
    (cd "$top" && repo init -u "$EOS_MANIFEST_URL" -b "$EOS_MANIFEST_BRANCH" --git-lfs)
else
    top=$(cd "$arg" && pwd -P)
    not_other "$top"
fi
for p in .repo .repo/manifests .repo/projects .repo/project-objects .repo/local_manifests; do in_top "$top/$p"; done
# Not under a build someone started by hand in this tree: the sync would change its sources
b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"
m="$top/.repo/manifests"
lm="$top/.repo/local_manifests"
url=$(git -C "$m" config --get remote.origin.url || true)
# Full history: git am --3way can then merge a kit patch around a later change to the same
# file, and a merge of LineageOS's changes needs it too; in a shallow tree they just fail
depth=$(git -C "$m" config --get repo.depth || true)
[[ -z "$depth" ]] || fail "$top was initialized with --depth=$depth; the kit needs full history. Set up a fresh folder, or unshallow it: git -C $m config --unset repo.depth, then git -C $top/frameworks/base fetch --unshallow"
[[ "$(git -C "$m" config --get --bool repo.git-lfs || true)" = true ]] \
    || fail "$top wasn't initialized with --git-lfs (radio images would be 130-byte pointers): run (cd $top && repo init --git-lfs), then setup.sh again"

if [[ "${url%.git}" = "$EOS_OLD_MANIFEST_URL" ]]; then
    # The 1.0 tree: Evolution X's manifest with the kit's pins and local manifest
    echo "== moving $top from $url to ExpressiveOS's manifest $EOS_MANIFEST_URL ($EOS_MANIFEST_BRANCH)"
    for p in "$lm/cheetah.xml" "$lm/cheetah.xml.eos-1.0" "$m/expressiveos-pins.xml"; do in_top "$p"; done
    # Its projects are in ExpressiveOS's manifest: as a local manifest too, repo would refuse
    # them twice. Kept beside it (not *.xml, so repo reads it no more)
    if [[ -e "$lm/cheetah.xml" ]]; then
        mv -f -- "$lm/cheetah.xml" "$lm/cheetah.xml.eos-1.0" || fail "can't move $lm/cheetah.xml aside"
    fi
    # No terminal on stdin: repo init then asks nothing
    (cd "$top" && repo init -u "$EOS_MANIFEST_URL" -b "$EOS_MANIFEST_BRANCH" -m default.xml </dev/null) \
        || fail "repo init -u $EOS_MANIFEST_URL -b $EOS_MANIFEST_BRANCH failed (the tree is unchanged but for $lm/cheetah.xml.eos-1.0; run setup.sh again)"
    rm -f -- "$m/expressiveos-pins.xml"
    url=$(git -C "$m" config --get remote.origin.url || true)
fi
[[ "${url%.git}" = "$EOS_MANIFEST_URL" ]] || fail "$top's manifest is ${url:-unknown}, not $EOS_MANIFEST_URL"
# On ExpressiveOS's default.xml, its branch, nothing local (a tree set up by hand, or moved
# back): repo init again puts that right
if ! grep -qF '<include name="default.xml" />' "$top/.repo/manifest.xml" 2>/dev/null \
    || [[ "$(git -C "$m" config --get branch.default.merge || true)" != "refs/heads/$EOS_MANIFEST_BRANCH" ]]; then
    (cd "$top" && repo init -u "$EOS_MANIFEST_URL" -b "$EOS_MANIFEST_BRANCH" -m default.xml </dev/null) \
        || fail "repo init -m default.xml failed in $top"
fi
for f in "$lm"/*.xml; do
    [[ ! -e "$f" ]] || fail "$f is a local manifest: ExpressiveOS's tree is its manifest alone (cheetah's projects are in it); move it out of .repo/local_manifests"
done

# repo keeps a project's git objects under its repo's name: a path with another repo behind it
# now (BtHelper: TheParasiteProject's, then ExpressiveOS's) is checked out again only when
# repo is told to (--force-sync), and nothing else in the sync goes on until it is
moved=$(python3 -I - "$top" "$m/default.xml" <<'EOF'
import os, sys, xml.etree.ElementTree as ET
top, f = sys.argv[1:]
out = []
for p in ET.parse(f).getroot().iter("project"):
    path = p.get("path") or p.get("name")
    have = os.path.join(top, ".repo", "projects", path + ".git", "objects")
    want = os.path.join(top, ".repo", "project-objects", p.get("name") + ".git", "objects")
    if os.path.lexists(have) and os.path.realpath(have) != os.path.realpath(want):
        out.append(path)
print(" ".join(out))
EOF
) || fail "can't read $m/default.xml"
if [[ -n "$moved" ]]; then
    echo "== checking out again what's another repo now: $moved"
    # shellcheck disable=SC2086   # paths, no spaces
    (cd "$top" && repo sync -c --force-sync --no-tags --no-clone-bundle $moved) || fail "repo sync --force-sync $moved failed (above); run setup.sh again"
fi

echo "== repo sync (-j${EOS_SYNC_JOBS:-4}; the first one downloads a few hundred GB)"
(cd "$top" && repo sync -c -j"${EOS_SYNC_JOBS:-4}" --no-tags --no-clone-bundle --optimized-fetch) || fail "repo sync failed (its errors are above); run setup.sh again to resume"
mf=$(tree_manifest) || exit 1
pins_check "$top" "$EOS_MANIFEST_BRANCH" "$mf" || fail "the tree isn't on its manifest's commits after the sync (above)"

# Nothing borrowed from another tree: git alternates (repo --reference) or a hardlinked copy
while IFS= read -r -d '' a; do
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        # Relative entries are relative to the objects folder
        r=$(cd "${a%/info/alternates}" && realpath -m -- "$line")
        for o in "$evo" "$derp"; do
            [[ -z "$o" || ( "$r" != "$o" && "$r" != "$o"/* ) ]] || fail "${a#"$top"/} borrows git objects from $o; set the tree up again without --reference"
        done
    done < "$a"
done < <(find "$top/.repo" -path '*/objects/info/alternates' -print0 2>/dev/null)
for f in build/make/core/Makefile vendor/lineage/config/common.mk device/google/pantah/device-cheetah.mk; do
    [[ -f "$top/$f" ]] || fail "$f is missing after the sync"
    [[ "$(stat -c %h -- "$top/$f")" = 1 ]] || fail "$f has other hard links: is $top a hardlinked copy of another tree? Set it up again from scratch"
done
done=1
echo "SETUP_OK $top, ExpressiveOS's manifest at $(git -C "$m" rev-parse --short HEAD) ($(df -h --output=avail -- "$top" | tail -1 | tr -d ' ') free)"
