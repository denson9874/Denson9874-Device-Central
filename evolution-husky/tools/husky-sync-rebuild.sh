#!/bin/bash
# Sync the shared Evolution X tree to upstream cnb the way p11-routine.sh does,
# move the clean husky device trees (shusky, zuma) to upstream too, re-apply
# every patch queue, then run ~/husky-build.sh.
#
#   husky-sync-rebuild.sh
set -uo pipefail

TOP=~/evolution
cd "$TOP"
fail() { echo "FAIL: $*"; exit 1; }

exec 9>~/.evolution-tree.lock
echo "== waiting for the tree lock..."
flock -w 28800 9 || fail "waited 8 hours for the tree lock"
while pgrep -x soong_ui >/dev/null || pgrep -x ninja >/dev/null; do sleep 30; done

# Same projects as p11-routine.sh leaves alone; the husky ones are handled below.
SKIP='^(device/google/(husky|shusky|shusky-kernels|zuma|pantah|pantah-kernels|gs201)|vendor/google/(husky|cheetah))( |$)'

echo "== repo sync: fetch"
repo sync -c -n -j8 --no-tags --no-clone-bundle --optimized-fetch 9>&- \
    || repo sync -c -n -j4 --no-tags --no-clone-bundle 9>&- \
    || fail "repo sync (fetch) failed"
mapfile -t projects < <(repo list -p 2>/dev/null | grep -Ev "$SKIP")
[ ${#projects[@]} -gt 1000 ] || fail "repo list returned only ${#projects[@]} projects"
echo "== repo sync: check out ${#projects[@]} projects"
repo sync -c -l -j8 --fail-fast "${projects[@]}" 9>&- || fail "repo sync (checkout) failed"
date +%s > ~/.evolution-last-sync

# shusky and zuma only carry our committed patches: move them to the manifest
# revision and let apply.sh put the patches back on top.
for p in device/google/shusky device/google/zuma; do
    [ -z "$(git -C $p status --porcelain)" ] || fail "$p has uncommitted changes"
    rev=$(git -C $p rev-parse --verify -q m/cnb) || fail "$p: no m/cnb"
    echo "== $p -> $(git -C $p log -1 --format='%h %s' $rev)"
    git -C $p checkout -q --detach "$rev" || fail "checkout $p"
done

echo "== re-applying patch queues"
device/google/kodiak/apply-patches.sh "$TOP" 9>&- || fail "kodiak apply-patches.sh: upstream conflicts with the shared patches"
~/evolution-husky/apply.sh "$TOP" 9>&- || fail "husky apply.sh: upstream conflicts with the husky patches"

exec 9>&-   # husky-build.sh takes the lock itself
mv -f ~/husky-build-20261020.out ~/husky-build-20261020-presync.out 2>/dev/null
# Keep the pre-sync test build: the rebuild may get the same file name.
for z in ~/releases/husky/EvolutionX-17.0-2026102[01]-husky-*-Unofficial.zip; do
    [ -f "$z" ] && mv -f "$z" "${z%.zip}-presync.zip" && mv -f "$z.sha256sum" "${z%.zip}-presync.zip.sha256sum" 2>/dev/null
done
~/husky-build.sh > ~/husky-build-20261020.out 2>&1
echo "SYNC_REBUILD_EXIT=$?"
