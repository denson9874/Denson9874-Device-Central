#!/usr/bin/env bash
# Set up the ExpressiveOS cheetah tree, or bring it up to date: Evolution X's cnb
# manifest with full git history and Git LFS, plus this kit's local manifest
# (local_manifests/cheetah.xml: cheetah's device trees and blobs), then repo sync.
# The tree is its own: nothing in it may be a symlink, hardlink or git alternate into
# ~/evolution or ~/derpfest, so nothing this kit does can reach their builds.
# A sync drops the kit's local commits; eos-images.sh puts them back (prepare.sh).
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
url=$(git -C "$m" config --get remote.origin.url || true)
[[ "${url%.git}" = "$EOS_MANIFEST_URL" ]] || fail "$top's manifest is ${url:-unknown}, not $EOS_MANIFEST_URL"
# Full history: git am --3way can then merge a kit patch around a later Evolution X
# change to the same file; in a shallow tree that patch just fails (~50 GB saved)
depth=$(git -C "$m" config --get repo.depth || true)
[[ -z "$depth" ]] || fail "$top was initialized with --depth=$depth; the kit's patches need full history to apply across Evolution X's changes. Set up a fresh folder, or unshallow it: git -C $m config --unset repo.depth, then git -C $top/frameworks/base fetch --unshallow"
[[ "$(git -C "$m" config --get --bool repo.git-lfs || true)" = true ]] \
    || fail "$top wasn't initialized with --git-lfs (radio images would be 130-byte pointers): run (cd $top && repo init --git-lfs), then setup.sh again"

lm="$top/.repo/local_manifests"
mkdir -p -- "$lm"
for f in "$lm"/*.xml; do
    [[ -e "$f" && "${f##*/}" != cheetah.xml ]] && echo "WARNING: $f is another local manifest; check it belongs in the ExpressiveOS tree"
done
if cmp -s -- "$kit/local_manifests/cheetah.xml" "$lm/cheetah.xml"; then
    echo "unchanged: .repo/local_manifests/cheetah.xml"
else
    { cp -- "$kit/local_manifests/cheetah.xml" "$lm/.cheetah.xml.tmp" && mv -f -- "$lm/.cheetah.xml.tmp" "$lm/cheetah.xml"; } \
        || fail "can't install $lm/cheetah.xml"
    echo "installed: .repo/local_manifests/cheetah.xml"
fi

echo "== repo sync (-j${EOS_SYNC_JOBS:-4}; the first one downloads a few hundred GB)"
(cd "$top" && repo sync -c -j"${EOS_SYNC_JOBS:-4}" --no-tags --no-clone-bundle --optimized-fetch) || fail "repo sync failed (its errors are above); run setup.sh again to resume"

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
echo "SETUP_OK $top ($(df -h --output=avail -- "$top" | tail -1 | tr -d ' ') free)"
