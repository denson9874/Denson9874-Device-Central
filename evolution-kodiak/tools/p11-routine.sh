#!/bin/bash
# Weekly parity routine for one device (the Pixel 11 family, the Pixel 7 Pro from
# evolution-cheetah/ and the Pixel 8 Pro from evolution-husky/): keep its build in step
# with official Evolution X (cnb).
#
#   p11-routine.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--dry-run] [--force] [--no-upload] [--mark-current]
#
#   1. Takes the tree lock, so the three weekly routines (and anything else using
#      the lock) run one at a time, and waits for any build started by hand.
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
#      script, which verifies the build and uploads the fastboot zip to SourceForge
#      only if every check passes.
#   5. Writes a changelog of upstream commits plus the device's community fixes from
#      ~/COMMUNITY_TRIAGE.md (community_release_notes.py), then p11-ota.sh verifies the OTA
#      package, uploads it and publishes builds/<dev>.json in denson9874/evolution_ota
#      for the Updater (last), with the build's pinned manifest as manifests/<dev>.xml.
#      Only then is the published state recorded.
#   6. Copies this run's zips, their .sha256 and the changelog to Google Drive,
#      gdrive:EvolutionX/<dev> (evox-to-drive.sh, as derp-build.sh does for DerpFest),
#      with or without --no-upload. A failed copy is reported but doesn't fail the routine.
#
#   --dry-run       report what would happen; no sync, build or upload
#   --force         build even if nothing changed
#   --no-upload     build and verify (fastboot zip and OTA), but don't upload or publish
#   --no-sync       build from the tree as it is (hotfix releases)
#   --mark-current  record the current tree as this device's published state
#
# The last line is ROUTINE_RESULT=PUBLISHED|BUILT|NOCHANGE|DRYRUN|MARKED|FAILED.
set -uo pipefail

dev=${1:-}; [ $# -gt 0 ] && shift
DRY=0; FORCE=0; UPLOAD=1; MARK=0; NOSYNC=0
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;; --force) FORCE=1 ;; --no-upload) UPLOAD=0 ;; --mark-current) MARK=1 ;; --no-sync) NOSYNC=1 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
case $dev in
    kodiak)  BUILD=~/kodiak-release-images.sh; BLOG=~/kodiak-release-build.log; PACK=~/kodiak-release-pack.sh ;;
    grizzly) BUILD=~/grizzly-images.sh;        BLOG=~/grizzly-build.log;        PACK=~/grizzly-pack.sh ;;
    cubs)    BUILD=~/cubs-images.sh;           BLOG=~/cubs-build.log;           PACK=~/cubs-pack.sh ;;
    yogi)    BUILD=~/yogi-images.sh;           BLOG=~/yogi-build.log;           PACK=~/yogi-pack.sh ;;
    cheetah) BUILD=~/cheetah-images.sh;        BLOG=~/cheetah-build.log;        PACK=~/cheetah-pack.sh ;;
    husky)   BUILD=~/husky-images.sh;          BLOG=~/husky-build.log;          PACK=~/husky-release-pack.sh ;;
    *) echo "usage: p11-routine.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--dry-run] [--force] [--no-upload] [--mark-current]" >&2; exit 2 ;;
esac

TOP=~/evolution
STATE=~/releases/$dev; mkdir -p "$STATE" ~/routine-logs
LOG=~/routine-logs/$dev-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
finish() { echo "ROUTINE_RESULT=$1 device=$dev log=$LOG"; exit "${2:-0}"; }
fail() { echo "FAIL: $*"; finish FAILED 1; }
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

echo "== $(date '+%F %T %Z') $dev routine (dry-run=$DRY force=$FORCE upload=$UPLOAD mark=$MARK no-sync=$NOSYNC)"

exec 9>~/.evolution-tree.lock
echo "== waiting for the tree lock"
flock -w 28800 9 || fail "waited 8 h for the tree lock"
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
    # 9>&-: children must not inherit the lock, or a straggler would keep holding it.
    # Fetch everything (and the manifest) first; it touches no working tree.
    echo "== repo sync: fetch"
    repo sync -c -n -j8 --no-tags --no-clone-bundle --optimized-fetch 9>&- \
        || { echo "== fetch failed; retrying with -j4"; repo sync -c -n -j4 --no-tags --no-clone-bundle 9>&-; } \
        || fail "repo sync (fetch) failed"
    # Then check out every project except the other ports' (theirs carry local commits
    # that only their own runs drop and re-apply).
    mapfile -t projects < <(repo list -p 2>/dev/null | grep -Ev "$SKIP")
    [ ${#projects[@]} -gt 1000 ] || fail "repo list returned only ${#projects[@]} projects"
    echo "== repo sync: check out ${#projects[@]} projects"
    repo sync -c -l -j8 --fail-fast "${projects[@]}" 9>&- || fail "repo sync (checkout) failed"
    date +%s > ~/.evolution-last-sync
fi
# The other runs don't check out cheetah's or husky's projects: do it here, from the last
# fetch, whether or not this run fetched. That also drops the previous run's local commits.
if [[ $dev =~ ^(cheetah|husky)$ ]] && [ $DRY = 0 ] && [ $MARK = 0 ] && [ $NOSYNC = 0 ]; then
    [ $dev = cheetah ] && P=$CHEETAH_PROJECTS || P=$HUSKY_PROJECTS
    echo "== repo sync: check out the $dev projects"
    repo sync -c -l -j4 $P 9>&- || fail "repo sync ($dev checkout) failed"
fi
# Our patches (build/make, frameworks/base) go into every build, whether or not this
# run synced. A sync drops them; apply-patches.sh skips the ones already applied.
if [ $DRY = 0 ] && [ $MARK = 0 ]; then
    device/google/kodiak/apply-patches.sh "$TOP" 9>&- || fail "apply-patches.sh failed: upstream may conflict with device/google/kodiak/patches"
    if [ "$dev" = cheetah ]; then
        # Our pantah patches and the newest cached Google firmware (local commits)
        ~/evolution-cheetah/prepare.sh "$TOP" 9>&- || fail "evolution-cheetah/prepare.sh failed"
    elif [ "$dev" = husky ]; then
        # Our shusky/zuma/vendor patches (local commits); TheMuppets' blobs carry the firmware
        ~/evolution-husky/apply.sh "$TOP" 9>&- || fail "evolution-husky/apply.sh failed"
    fi
fi

# 3. State: content of every project that goes into the build, plus our trees
echo "== computing the source state"
trees=$(mktemp); trap 'rm -f "$trees"' EXIT
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
    finish MARKED
fi

if [ "$cur" = "$prev" ] && [ $FORCE = 0 ]; then
    echo "== nothing changed since the last published $dev build"
    finish NOCHANGE
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

# Everything the pack script and p11-ota.sh write to $STATE from here on is this run's (step 6)
started=$(mktemp); trap 'rm -f "$trees" "$started"' EXIT
echo "== build ($BUILD, log $BLOG)"
$BUILD > "$BLOG" 2>&1 9>&-
if ! grep -q "BUILD_EXIT=0" "$BLOG"; then
    grep -E "FAILED:|error:|ninja: build stopped" "$BLOG" | head -30
    fail "the build failed, see $BLOG"
fi
echo "== release checks (association rules vs stock, stale apps in out/, release properties)"
~/release-checks.sh "$dev" 9>&- || fail "release-checks.sh found a problem (above); nothing was packed or uploaded"
echo "== verify and pack ($PACK)"
if [ $UPLOAD = 1 ]; then out=$($PACK --upload 2>&1 9>&-); else out=$($PACK 2>&1 9>&-); fi
rc=$?
echo "$out" | grep -v "^sftp> \|^Uploading "
[ $rc = 0 ] || fail "$PACK refused or failed (exit $rc)"
[ $UPLOAD = 0 ] || grep -q "UPLOAD_DONE" <<<"$out" || fail "the upload didn't finish"

# 5. Record the state and a changelog of upstream commits
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

# The OTA package for the Updater: verified always, uploaded and announced with an upload
echo "== OTA package (p11-ota.sh)"
if [ $UPLOAD = 1 ]; then out=$(~/p11-ota.sh "$dev" --upload --changes "$changes" --manifest "$snap" 2>&1 9>&-); else out=$(~/p11-ota.sh "$dev" 2>&1 9>&-); fi
rc=$?
echo "$out"
[ $rc = 0 ] || { rm -f "$snap"; fail "p11-ota.sh refused or failed (exit $rc)"; }
[ $UPLOAD = 0 ] || grep -q "^OTA_PUBLISHED" <<<"$out" || { rm -f "$snap"; fail "the OTA wasn't published"; }
# Only a published build moves the baseline
if [ $UPLOAD = 1 ]; then
    echo "$cur" > "$STATE/LAST_STATE"; cp "$trees" "$STATE/LAST_TREES"; cp "$snap" "$STATE/LAST_MANIFEST.xml"
fi
rm -f "$snap"
# 6. A copy on Google Drive
if [ -x ~/evox-to-drive.sh ]; then
    ~/evox-to-drive.sh "$dev" --newer "$started" 9>&- \
        || echo "== the Google Drive copy failed; the build is unaffected (retry: ~/evox-to-drive.sh $dev)"
fi
# Keep the newest two builds' zips (fastboot and OTA) on the server (the uploads stay on SourceForge)
ls -t "$STATE"/EvolutionX-*.zip 2>/dev/null | tail -n +5 | while read -r z; do rm -f "$z" "$z.sha256"; done
[ $UPLOAD = 1 ] && finish PUBLISHED || finish BUILT
