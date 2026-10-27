#!/bin/bash
# Weekly parity routine for one device (the Pixel 11 family, the Pixel 7 Pro from
# evolution-cheetah/ and the Pixel 8 Pro from evolution-husky/): keep its build in step
# with official Evolution X (cnb).
#
#   p11-routine.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--dry-run] [--force] [--no-upload] [--no-sync] [--mark-current]
#   p11-routine.sh <dev> --publish-staged
#
#   1. Takes the device's publish lock (~/.evolution-publish-<dev>.lock, held to the end, so a
#      device's routine never starts while its last one is still uploading), then the tree lock,
#      so the weekly routines (and anything else using the lock) build one at a time, and waits
#      for any build started by hand. Routines waiting for the tree together take it in the order
#      that rebuilds least in the shared out/: kodiak, grizzly and yogi carry HiLight's notification
#      flag and cubs, husky and cheetah don't, and every switch across that line rebuilds SystemUI
#      and Settings. So the devices on the same side as the last build (~/.evolution-last-build) go
#      first, each side in the order kodiak, grizzly, yogi, cubs, husky, cheetah.
#   2. Runs `repo sync` unless the tree was synced in the last 6 hours (the first
#      routine of the day syncs; the others build from the same sync), skipping
#      the cheetah and husky ports' projects, which only their own runs check out. Then (synced or
#      not) applies our build/make and frameworks/base patches (apply-patches.sh, idempotent).
#   3. Skips the build when nothing the device depends on changed since its last
#      published build. The state is the content (git tree hash) of every repo
#      project plus our device, vendor, images and signing-key trees, so
#      re-applying the same patch doesn't count as a change.
#   4. Builds (images plus the signed A/B OTA package), runs release-checks.sh (association
#      rules match stock, no stale apps left in out/), then runs the device's pack
#      script, which verifies the build and packs the fastboot zip; a release only
#      if every check passes.
#   5. Writes a changelog of upstream commits plus the device's community fixes from
#      ~/COMMUNITY_TRIAGE.md (community_release_notes.py), then p11-ota.sh verifies the OTA
#      package. A release is staged in ~/releases/<dev>/staged-<time>: the pack script's files,
#      the OTA package and the builds/<dev>.json, changelog and pinned manifest (manifests/<dev>.xml)
#      for denson9874/evolution_ota, all read from out/ and the tree under the lock.
#   6. Releases the tree lock, so the next device builds while this one uploads: the files go to
#      SourceForge (p11-upload.sh), the OTA package to SourceForge and the R2 mirror, and the
#      Updater JSON last (p11-ota.sh --publish). Only then is the published state recorded.
#   7. Deletes the device's zips (in ~/releases/<dev> and out/) that SourceForge has
#      (release-cleanup.sh). Zips that aren't there stay, and are listed.
#
#   --dry-run         report what would happen; no sync, build or upload
#   --force           build even if nothing changed
#   --no-upload       build and verify (fastboot zip and OTA), but don't upload or publish
#   --no-sync         build from the tree as it is (hotfix releases)
#   --mark-current    record the current tree as this device's published state
#   --publish-staged  upload and publish the newest release staged for the device, after a
#                     publish failed (the network); needs no tree lock. A routine whose tree
#                     is the one staged does the same instead of building it again.
#
# A staged release older than the build the Updater already has (one published by hand, say) is
# never published: it's dropped, with its zips that never reached SourceForge (SUPERSEDED).
#
# The last line is ROUTINE_RESULT=PUBLISHED|BUILT|NOCHANGE|DRYRUN|MARKED|SUPERSEDED|FAILED.
set -uo pipefail

dev=${1:-}; [ $# -gt 0 ] && shift
DRY=0; FORCE=0; UPLOAD=1; MARK=0; NOSYNC=0; REPUBLISH=0
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;; --force) FORCE=1 ;; --no-upload) UPLOAD=0 ;; --mark-current) MARK=1 ;; --no-sync) NOSYNC=1 ;;
        --publish-staged) REPUBLISH=1 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
[ $REPUBLISH = 0 ] || [ $# = 1 ] || { echo "--publish-staged takes no other option" >&2; exit 2; }
case $dev in
    kodiak)  BUILD=~/kodiak-release-images.sh; BLOG=~/kodiak-release-build.log; PACK=~/kodiak-release-pack.sh ;;
    grizzly) BUILD=~/grizzly-images.sh;        BLOG=~/grizzly-build.log;        PACK=~/grizzly-pack.sh ;;
    cubs)    BUILD=~/cubs-images.sh;           BLOG=~/cubs-build.log;           PACK=~/cubs-pack.sh ;;
    yogi)    BUILD=~/yogi-images.sh;           BLOG=~/yogi-build.log;           PACK=~/yogi-pack.sh ;;
    cheetah) BUILD=~/cheetah-images.sh;        BLOG=~/cheetah-build.log;        PACK=~/cheetah-pack.sh ;;
    husky)   BUILD=~/husky-images.sh;          BLOG=~/husky-build.log;          PACK=~/husky-release-pack.sh ;;
    *) echo "usage: p11-routine.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--dry-run] [--force] [--no-upload] [--no-sync] [--mark-current] | --publish-staged" >&2; exit 2 ;;
esac

TOP=~/evolution
STATE=~/releases/$dev; mkdir -p "$STATE" ~/routine-logs
LOG=~/routine-logs/$dev-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
finish() { echo "ROUTINE_RESULT=$1 device=$dev log=$LOG"; exit "${2:-0}"; }
fail() { echo "FAIL: $*"; finish FAILED 1; }
trees=; snap=; staging=; me=
cleanup() { rm -f "$trees" "$snap" "$me"; [ -z "$staging" ] || rm -rf "$staging"; }
trap cleanup EXIT
# Scripts too old for staged publishing (an install from an older ref) would fail only after the build
if [ $UPLOAD = 1 ] && [ $MARK = 0 ]; then
    for need in "$PACK:--stage" ~/p11-ota.sh:--check-newer ~/p11-upload.sh:UPLOAD_DONE; do
        grep -q -- "${need##*:}" "${need%:*}" 2>/dev/null \
            || fail "${need%:*} is missing or predates staged publishing: install the routine scripts again (runner action routine-install)"
    done
fi
# Projects outside this device's build: the husky and cheetah ports' local manifests
# (evolution-<dev>/local_manifests/<dev>.xml), whose projects only that device's runs check
# out (they carry its locally committed patches, and for cheetah its firmware).
HUSKY='device/google/(husky|shusky|shusky-kernels|zuma)|vendor/google/husky'
CHEETAH='device/google/(pantah|gs201|pantah-kernels)|vendor/google/cheetah'
HUSKY_PROJECTS='device/google/husky device/google/shusky device/google/shusky-kernels device/google/zuma vendor/google/husky'
CHEETAH_PROJECTS='device/google/pantah device/google/gs201 device/google/pantah-kernels vendor/google/cheetah'
case $dev in
    cheetah) SKIP="^($HUSKY)( |\$)" ;;
    husky)   SKIP="^($CHEETAH)( |\$)" ;;
    *)       SKIP="^($HUSKY|$CHEETAH)( |\$)" ;;
esac

# A staged release (step 5) is a folder ~/releases/<dev>/staged-<time>: files (the pack script's
# STAGED list), ota/ (p11-ota.sh --stage: publish.env names the OTA package in ~/releases/<dev>) and
# state/ (what a publish records). release-cleanup.sh keeps every file one names.
newest_staged() { ls -d "$STATE"/staged-* 2>/dev/null | sort | tail -1; }
staged_files() {    # staged_files <dir>: every file the release uploads, one per line
    tr ' ' '\n' < "$1/files" 2>/dev/null | sed '/^$/d'
    sed -n "s|^P_NAME=|$STATE/|p" "$1/ota/publish.env" 2>/dev/null
}
staged_complete() {   # staged_complete <dir>: all its parts and files are still there
    local f
    [ -s "$1/files" ] && [ -f "$1/ota/publish.env" ] && [ -f "$1/ota/builds/$dev.json" ] && [ -f "$1/state/LAST_STATE" ] || return 1
    for f in $(staged_files "$1"); do [ -f "$f" ] || { echo "   $f is gone"; return 1; }; done
}
# drop_staged <dir> <why>: forget a staged release, and delete its zips that never reached SourceForge
# (their .sha256 stay, so the names stay taken), unless another staged release names them too
drop_staged() {
    local S=$1 f o others=
    for o in "$STATE"/staged-*; do [ -d "$o" ] && [ "$o" != "$S" ] && others+=$'\n'$(staged_files "$o"); done
    for f in $(staged_files "$S"); do
        [[ $f == *.zip ]] && [ -f "$f" ] && [ ! -f "$f.uploaded" ] || continue
        grep -qxF "$f" <<<"$others" || { rm -f "$f" && echo "   deleted $f (never uploaded)"; }
    done
    rm -rf "$S"
    echo "== dropped $(basename "$S"): $2"
}
# Exit status of p11-ota.sh --check-newer for the staged release: 0 newer than the Updater's build,
# 3 not (superseded), else the check failed
check_newer() { ~/p11-ota.sh "$dev" --check-newer "$1/ota" 2>&1 8>&- 9>&-; }

# Upload and publish a release staged in $1 (step 6); the tree lock isn't needed. Records the
# published state, then drops the staged releases this one supersedes. Ends the routine
# (SUPERSEDED) when the Updater already has a newer build.
publish_staged() {
    local S=$1 files=() z up=1 o rc
    read -r -a files < "$S/files" || true
    staged_complete "$S" || fail "$S isn't a complete staged release (above)"
    echo "== publish $(basename "$S")"
    check_newer "$S"; rc=$?
    if [ $rc = 3 ]; then drop_staged "$S" "the Updater already has a newer build"; finish SUPERSEDED; fi
    [ $rc = 0 ] || fail "couldn't compare $(basename "$S") with the Updater's build; the release stays staged (retry: p11-routine.sh $dev --publish-staged)"
    # p11-upload.sh marks the zips once every file is up, so a retry after a failed OTA publish skips it
    for z in "${files[@]}"; do [[ $z != *.zip ]] || [ -f "$z.uploaded" ] || up=0; done
    if [ $up = 1 ]; then
        echo "== the files are already on SourceForge (marked .uploaded)"
    else
        ~/p11-upload.sh "$dev" "${files[@]}" 2>&1 8>&- | tee "$S/upload.log"
        [ "${PIPESTATUS[0]}" = 0 ] && grep -q "^UPLOAD_DONE" "$S/upload.log" \
            || fail "the upload failed; the release stays staged in $S (retry: p11-routine.sh $dev --publish-staged)"
    fi
    ~/p11-ota.sh "$dev" --publish "$S/ota" 2>&1 8>&- | tee "$S/publish.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 3 ]; then drop_staged "$S" "the Updater got a newer build meanwhile"; finish SUPERSEDED; fi
    [ "$rc" = 0 ] && grep -q "^OTA_PUBLISHED" "$S/publish.log" \
        || fail "the OTA wasn't published; the release stays staged in $S (retry: p11-routine.sh $dev --publish-staged)"
    # Only a published build moves the baseline
    cp "$S/state/LAST_STATE" "$S/state/LAST_TREES" "$STATE/"
    [ ! -f "$S/state/LAST_MANIFEST.xml" ] || cp "$S/state/LAST_MANIFEST.xml" "$STATE/"
    rm -rf "$S"
    for o in "$STATE"/staged-*; do
        [ -d "$o" ] && [[ ! $o > $S ]] || continue
        drop_staged "$o" "an older release, staged and never published"
    done
}

echo "== $(date '+%F %T %Z') $dev routine (dry-run=$DRY force=$FORCE upload=$UPLOAD mark=$MARK no-sync=$NOSYNC publish-staged=$REPUBLISH)"

# 1. One routine per device at a time, to the end of its publish. 8>&- and 9>&- below: children must
# not inherit the locks, or a straggler (Bazel's server, say) would keep holding them.
exec 8>~/.evolution-publish-$dev.lock
if [ $DRY = 1 ]; then
    # Only looks: the device's real routine mustn't wait for a dry run
    if flock -n 8; then flock -u 8; else echo "note: a $dev publish is still running; the state below is compared with the build before it"; fi
    exec 8>&-
else
    flock -n 8 || { echo "== waiting for the $dev routine that is still running (publish lock)"; flock -w 28800 8; } \
        || fail "waited 8 h for the other $dev routine"
fi
if [ $REPUBLISH = 1 ]; then
    S=$(newest_staged)
    [ -n "$S" ] || fail "no release staged in $STATE"
    if ! staged_complete "$S"; then
        drop_staged "$S" "files it needs are gone, so it can't be published; the next routine builds again"
        finish FAILED 1
    fi
    publish_staged "$S"
    ~/release-cleanup.sh "$dev" 8>&- || echo "== cleanup kept zips it couldn't verify (above); retry: ~/release-cleanup.sh $dev"
    finish PUBLISHED
fi

# The tree, in turn. Waiting routines each leave a marker in ~/.evolution-queue; one that gets the
# lock while a routine ranked before it waits hands it on (flock alone wakes waiters in no order).
ORDER="kodiak grizzly yogi cubs husky cheetah"
hilight() { [[ $1 =~ ^(kodiak|grizzly|yogi)$ ]] && echo 1 || echo 0; }
rank() {    # rank <dev>: lower goes first
    local last d i=0
    last=$(cat ~/.evolution-last-build 2>/dev/null || true)
    for d in $ORDER; do [ "$d" = "$1" ] && break; i=$((i + 1)); done
    if [[ $last =~ ^(kodiak|grizzly|cubs|yogi|cheetah|husky)$ ]] && [ "$(hilight "$1")" != "$(hilight "$last")" ]; then i=$((i + 10)); fi
    echo $i
}
exec 9>~/.evolution-tree.lock
echo "== waiting for the tree lock"
if [ $DRY = 1 ] || [ $MARK = 1 ]; then
    # A dry run or a mark reads for a minute or two: it doesn't queue (a mark records the tree as it
    # is now, before a routine it would let go first syncs it)
    flock -w 28800 9 || fail "waited 8 h for the tree lock"
else
    Q=~/.evolution-queue; mkdir -p "$Q"; me=$Q/$dev.$$; : > "$me"
    deadline=$(( $(date +%s) + 28800 )); said=
    while :; do
        left=$(( deadline - $(date +%s) ))
        [ $left -gt 0 ] || fail "waited 8 h for the tree lock"
        # One long wait keeps this routine's place among the lock's waiters (Linux wakes them in turn)
        flock -w "$left" 9 || continue
        ahead=
        for w in "$Q"/*; do
            [ -f "$w" ] && [ "$w" != "$me" ] || continue
            pid=${w##*.}; d=$(basename "${w%.*}")
            # A marker whose routine is gone (killed while waiting) is stale, and so is one whose pid is
            # now another process's
            if ! [[ $pid =~ ^[0-9]+$ ]] || [ "$pid" = $$ ] || ! kill -0 "$pid" 2>/dev/null \
                || ! tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "p11-routine\.sh $d( |\$)"; then
                rm -f "$w"; continue
            fi
            [ "$(rank "$d")" -lt "$(rank "$dev")" ] && ahead+=" $d"
        done
        [ -z "$ahead" ] && break
        flock -u 9
        [ "$ahead" = "$said" ] || echo "== letting$ahead build first (order: least rebuilding after $(cat ~/.evolution-last-build 2>/dev/null || echo "no recorded build"))"
        said=$ahead
        sleep 20
    done
    rm -f "$me"; me=
fi
for i in $(seq 1 480); do
    pgrep -x soong_ui >/dev/null || pgrep -x ninja >/dev/null || break
    [ "$i" = 1 ] && echo "== waiting for a build that was started by hand"
    sleep 60
done
pgrep -x soong_ui >/dev/null && fail "another build is still running after 8 h"
cd "$TOP" || fail "no $TOP"

# 2. Sync
last=$(cat ~/.evolution-last-sync 2>/dev/null || echo 0)
age=$(( $(date +%s) - last ))
if [ $MARK = 1 ]; then
    :
elif [ $NOSYNC = 1 ]; then
    echo "== --no-sync: building the tree as it is"
elif [ $age -lt 21600 ]; then
    echo "== tree synced $((age / 60)) min ago; using that sync"
elif [ $DRY = 1 ]; then
    echo "== would repo sync (last sync $((age / 3600)) h ago)"
else
    # Fetch everything (and the manifest) first; it touches no working tree.
    echo "== repo sync: fetch"
    repo sync -c -n -j8 --no-tags --no-clone-bundle --optimized-fetch 8>&- 9>&- \
        || { echo "== fetch failed; retrying with -j4"; repo sync -c -n -j4 --no-tags --no-clone-bundle 8>&- 9>&-; } \
        || fail "repo sync (fetch) failed"
    # Then check out every project except the other ports' (theirs carry local commits
    # that only their own runs drop and re-apply).
    mapfile -t projects < <(repo list -p 2>/dev/null | grep -Ev "$SKIP")
    [ ${#projects[@]} -gt 1000 ] || fail "repo list returned only ${#projects[@]} projects"
    echo "== repo sync: check out ${#projects[@]} projects"
    repo sync -c -l -j8 --fail-fast "${projects[@]}" 8>&- 9>&- || fail "repo sync (checkout) failed"
    date +%s > ~/.evolution-last-sync
fi
# The other runs don't check out cheetah's or husky's projects: do it here, from the last
# fetch, whether or not this run fetched. That also drops the previous run's local commits.
if [[ $dev =~ ^(cheetah|husky)$ ]] && [ $DRY = 0 ] && [ $MARK = 0 ] && [ $NOSYNC = 0 ]; then
    [ $dev = cheetah ] && P=$CHEETAH_PROJECTS || P=$HUSKY_PROJECTS
    echo "== repo sync: check out the $dev projects"
    repo sync -c -l -j4 $P 8>&- 9>&- || fail "repo sync ($dev checkout) failed"
fi
# Our patches (build/make, frameworks/base) go into every build, whether or not this
# run synced. A sync drops them; apply-patches.sh skips the ones already applied.
if [ $DRY = 0 ] && [ $MARK = 0 ]; then
    device/google/kodiak/apply-patches.sh "$TOP" 8>&- 9>&- || fail "apply-patches.sh failed: upstream may conflict with device/google/kodiak/patches"
    if [ "$dev" = cheetah ]; then
        # Our pantah patches and the newest cached Google firmware (local commits)
        ~/evolution-cheetah/prepare.sh "$TOP" 8>&- 9>&- || fail "evolution-cheetah/prepare.sh failed"
    elif [ "$dev" = husky ]; then
        # Our shusky/zuma/vendor patches (local commits); TheMuppets' blobs carry the firmware
        ~/evolution-husky/apply.sh "$TOP" 8>&- 9>&- || fail "evolution-husky/apply.sh failed"
    fi
fi

# 3. State: content of every project that goes into the build, plus our trees
echo "== computing the source state"
trees=$(mktemp)
repo forall -c 'echo "$REPO_PATH $(git rev-parse HEAD^{tree})"' 2>/dev/null | grep -Ev "$SKIP" | sort > "$trees"
[ -s "$trees" ] || fail "repo forall listed no projects"
if [[ $dev =~ ^(cheetah|husky)$ ]]; then
    # The upstream device and vendor trees are repo projects (listed above); our part is the kit
    ours="vendor/evolution-priv/keys"
    echo "evolution-$dev $(cd ~/evolution-$dev && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)" >> "$trees"
else
    ours="device/google/$dev vendor/google/$dev vendor/google/$dev-images vendor/evolution-priv/keys"
fi
for p in $ours; do
    [ -d "$p/.git" ] || fail "$p is not a git tree"
    echo "$p $(git -C "$p" rev-parse 'HEAD^{tree}') dirty:$(git -C "$p" status --porcelain | sha256sum | cut -c1-12)" >> "$trees"
done
cur=$(sha256sum < "$trees" | cut -c1-16)
prev=$(cat "$STATE/LAST_STATE" 2>/dev/null || echo none)
echo "   state $cur (last published: $prev)"

if [ $MARK = 1 ]; then
    [ $DRY = 1 ] && { echo "== would record $cur as the published state"; finish DRYRUN; }
    echo "$cur" > "$STATE/LAST_STATE"; cp "$trees" "$STATE/LAST_TREES"
    repo manifest -r -o "$STATE/LAST_MANIFEST.xml" 2>/dev/null
    ls -d "$STATE"/staged-* 2>/dev/null | sed 's|^|note: still staged, not published: |'
    finish MARKED
fi

if [ "$cur" = "$prev" ] && [ $FORCE = 0 ]; then
    echo "== nothing changed since the last published $dev build"
    finish NOCHANGE
fi
# A release of this same tree staged by an earlier run whose publish failed: publish it rather than
# build it again, if it's all still there and newer than the Updater's build
S=$(newest_staged)
if [ -n "$S" ] && [ "$(cat "$S/state/LAST_STATE" 2>/dev/null)" = "$cur" ] && [ $FORCE = 0 ] && [ $UPLOAD = 1 ]; then
    echo "== $(basename "$S") holds a release of this same tree that wasn't published"
    use=1
    if ! staged_complete "$S"; then
        use=0; [ $DRY = 1 ] || drop_staged "$S" "files it needs are gone; building again"
    else
        check_newer "$S"; rc=$?
        [ $rc = 0 ] || use=0
        if [ $rc = 3 ] && [ $DRY = 0 ]; then drop_staged "$S" "the Updater already has a newer build; building again"; fi
        # Publishing a rebuild would need the same check, so a failed check (GitHub, ~/evolution_ota)
        # keeps the release staged rather than building the same tree again
        if [ $rc != 0 ] && [ $rc != 3 ]; then
            [ $DRY = 1 ] && { echo "== couldn't compare it with the Updater's build (above)"; finish DRYRUN; }
            fail "couldn't compare $(basename "$S") with the Updater's build (above); it stays staged (retry: p11-routine.sh $dev --publish-staged)"
        fi
    fi
    if [ $use = 1 ]; then
        [ $DRY = 1 ] && { echo "== would publish $(basename "$S") instead of building"; finish DRYRUN; }
        echo "== publishing it instead of building again"
        flock -u 9; exec 9>&-
        publish_staged "$S"
        ~/release-cleanup.sh "$dev" 8>&- || echo "== cleanup kept zips it couldn't verify (above); retry: ~/release-cleanup.sh $dev"
        finish PUBLISHED
    fi
fi
if [ -f "$STATE/LAST_TREES" ]; then
    echo "== projects changed since the last published build:"
    diff <(cut -d' ' -f1,2 "$STATE/LAST_TREES") <(cut -d' ' -f1,2 "$trees") | awk '/^[<>]/ {print $2}' | sort -u | sed 's/^/   /' | head -100
fi
[ $DRY = 1 ] && { echo "== would build $dev, verify, and $([ $UPLOAD = 1 ] && echo upload || echo "not upload")"; finish DRYRUN; }

# 4. Kernel and build
if [[ $dev =~ ^(kodiak|grizzly|cubs)$ ]] && [ -x ~/espada-fetch.sh ]; then
    echo "== espada kernel: fetch & verify"
    ~/espada-fetch.sh "$dev" || echo "== espada fetch failed or unavailable, falling back to stock kernel"
fi

echo "== build ($BUILD, log $BLOG)"
# What out/ is configured for now, for the order of the routines waiting (step 1)
echo "$dev" > ~/.evolution-last-build
$BUILD > "$BLOG" 2>&1 8>&- 9>&-
if ! grep -q "BUILD_EXIT=0" "$BLOG"; then
    grep -E "FAILED:|error:|ninja: build stopped" "$BLOG" | head -30
    fail "the build failed, see $BLOG"
fi
echo "== release checks (association rules vs stock, stale apps in out/, release properties)"
~/release-checks.sh "$dev" 8>&- 9>&- || fail "release-checks.sh found a problem (above); nothing was packed or uploaded"
echo "== verify and pack ($PACK)"
if [ $UPLOAD = 1 ]; then out=$($PACK --stage 2>&1 8>&- 9>&-); else out=$($PACK 2>&1 8>&- 9>&-); fi
rc=$?
echo "$out"
[ $rc = 0 ] || fail "$PACK refused or failed (exit $rc)"
if [ $UPLOAD = 1 ]; then
    staged=$(sed -n 's/^STAGED //p' <<<"$out" | tail -1)
    [ -n "$staged" ] || fail "$PACK listed nothing to upload (no STAGED line)"
    # Removed unless the whole release gets staged (cleanup)
    staging=$STATE/.staging-$(date +%Y%m%d-%H%M%S); mkdir -p "$staging/state"
    echo "$staged" > "$staging/files"
fi

# 5. The pinned manifest and a changelog of upstream commits
snap=$(mktemp); repo manifest -r -o "$snap" 2>/dev/null
changes=$STATE/CHANGES-$(date +%Y%m%d).txt
if [ -f "$STATE/LAST_MANIFEST.xml" ]; then
    python3 - "$STATE/LAST_MANIFEST.xml" "$snap" "$SKIP" > "$changes" <<'EOF'
import re, subprocess, sys, xml.etree.ElementTree as ET
def revs(f):
    return {p.get('path') or p.get('name'): p.get('revision') for p in ET.parse(f).getroot().iter('project')}
old, new, skip = revs(sys.argv[1]), revs(sys.argv[2]), re.compile(sys.argv[3])
for path in sorted(new):
    if skip.match(path) or old.get(path) == new[path] or path not in old:
        continue
    log = subprocess.run(['git', '-C', path, 'log', '--no-merges', '--format=%h %s', f'{old[path]}..{new[path]}'],
                         capture_output=True, text=True).stdout.splitlines()
    print(f'{path} ({len(log)} commits)')
    for l in log[:15]:
        print(f'    {l}')
    if len(log) > 15:
        print(f'    ... {len(log) - 15} more')
EOF
    echo "== changelog since the last published build: $changes ($(grep -c '^[^ ]' "$changes") projects)"
fi
# Community fixes for this device from ~/COMMUNITY_TRIAGE.md (a copy of the Mac repo's) go into the
# changelog. They're marked RELEASED in the repo on the Mac after the publish, not here (HANDOFF 2af).
if [ -f ~/community_release_notes.py ]; then
    python3 ~/community_release_notes.py "$dev" --triage ~/COMMUNITY_TRIAGE.md --changes-file "$changes" \
        || echo "== community release notes skipped; the build is unaffected"
fi

# The OTA package for the Updater: verified always; with an upload, staged (step 6 publishes it)
echo "== OTA package (p11-ota.sh)"
if [ $UPLOAD = 1 ]; then out=$(~/p11-ota.sh "$dev" --stage "$staging/ota" --changes "$changes" --manifest "$snap" 2>&1 8>&- 9>&-); else out=$(~/p11-ota.sh "$dev" 2>&1 8>&- 9>&-); fi
rc=$?
echo "$out"
[ $rc = 0 ] || fail "p11-ota.sh refused or failed (exit $rc)"
if [ $UPLOAD = 1 ]; then
    grep -q "^OTA_STAGED" <<<"$out" || fail "the OTA wasn't staged"
    # The state a successful publish records
    echo "$cur" > "$staging/state/LAST_STATE"; cp "$trees" "$staging/state/LAST_TREES"
    [ ! -s "$snap" ] || cp "$snap" "$staging/state/LAST_MANIFEST.xml"
    S=$STATE/staged-${staging##*/.staging-}
    mv "$staging" "$S" || fail "couldn't move $staging to $S"
    staging=
    echo "== staged: $S"
fi

# 6. Everything from here on reads only ~/releases/<dev> and ~/evolution_ota: the next device can build
flock -u 9; exec 9>&-
echo "== $(date '+%F %T %Z') released the tree lock"
[ $UPLOAD = 0 ] || publish_staged "$S"
# 7. The builds are hosted on SourceForge (the Updater's OTAs on the R2 mirror): delete this device's zips that SourceForge has
~/release-cleanup.sh "$dev" 8>&- || echo "== cleanup kept zips it couldn't verify (above); retry: ~/release-cleanup.sh $dev"
[ $UPLOAD = 1 ] && finish PUBLISHED || finish BUILT
