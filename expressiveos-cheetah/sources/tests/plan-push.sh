#!/usr/bin/env bash
# update.py plan/push tests on a throwaway world (harness.sh) in plan-push under $EOS_TEST_WORK
# (default $TMPDIR/eos-update-tests). Usage: plan-push.sh <kit src>
set -uo pipefail
P=$(cd "$(dirname "$0")" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/plan-push
trap 'rm -rf "$WD"' EXIT
KSRC=$1
pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
expect() {   # expect <name> <want rc: 0|1> <grep -E pattern> -- cmd...
    local name=$1 want=$2 pat=$3 out rc
    shift 4
    out=$("$@" 2>&1); rc=$?
    if [[ ( $want = 0 && $rc = 0 ) || ( $want != 0 && $rc != 0 ) ]] && grep -qE -- "$pat" <<<"$out"; then
        ok "$name"
    else
        bad "$name (rc $rc, want $want, pattern '$pat')"; echo "$out" | tail -25 | sed 's/^/    | /'
    fi
}
fresh() {   # a new world, kit from KSRC, frameworks/base resolved
    bash "$P/harness.sh" "$KSRC" "$WD" >/dev/null 2>&1 || { echo "harness failed"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/2026-11
}
resolve() { bash "$P/t-resolve.sh" "$WD" "${1:-true}" >/dev/null 2>&1; }
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "${1:-2026-11}" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "${1:-2026-11}" "$top"); }
check() { (cd "$T" && bash "$kit/sources/update-check.sh" "$top"); }
tipof() { git --git-dir="$T/gh/$1.git" rev-parse -q --verify "refs/heads/${2:-expressiveos}" 2>/dev/null; }
merge_manifest_pr() {   # Daryl merges update/<id> (fast-forward), and setup brings the tree onto it
    git --git-dir="$T/gh/ExpressiveOS/manifest.git" update-ref refs/heads/expressiveos "refs/heads/update/$1"
    git -C "$top/.repo/manifests" fetch -q origin
    git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
    # the tree syncs the new commits (objects only: what scratch() borrows)
    python3 - "$top/.repo/manifests/default.xml" "$T" <<'EOF' | while read -r path url rev; do git --git-dir="$top/.repo/projects/$path.git" fetch -q "$url" "+refs/heads/*:refs/remotes/x/*" "+refs/tags/*:refs/tags/*" 2>/dev/null || git clone -q --bare "$url" "$top/.repo/projects/$path.git"; done
import sys, urllib.parse, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
rem = {e.get("name"): e.get("fetch") for e in r.iter("remote")}
d = r.find("default")
base = "file://" + sys.argv[2] + "/gh/ExpressiveOS/manifest"
for p in r.iter("project"):
    f = urllib.parse.urljoin(base, rem[p.get("remote") or d.get("remote")]).rstrip("/")
    print(p.get("path") or p.get("name"), f + "/" + p.get("name"), p.get("revision"))
EOF
}

# --- 1. no resolution: conflicts shown, nothing planned
fresh
expect "unresolved conflict: CONFLICTS, zdiff3 lines shown" 1 'UPDATE_PLAN=CONFLICTS' -- plan
[[ ! -e $W/updates/2026-11/plan.json ]] && ok "no plan.json after CONFLICTS" || bad "plan.json left after CONFLICTS"
grep -q '||||||| ' "$W"/reports/update-plan-2026-11-*.txt && ok "report has the merge base's lines" || bad "no zdiff3 base lines in report"
expect "push without a plan refused" 1 'no ready plan' -- push

# --- 2. resolved: READY, push, push again
resolve
expect "resolved: READY" 0 'UPDATE_PLAN=READY \(2 forks merged' -- plan
before_fb=$(tipof ExpressiveOS/frameworks_base)
expect "push: 2 forks + manifest branch" 0 'UPDATE_PUSH=OK \(2 forks pushed now' -- push
m=$(tipof ExpressiveOS/frameworks_base)
[[ $(git --git-dir="$T/gh/ExpressiveOS/frameworks_base.git" rev-parse "$m^1") = "$before_fb" ]] && ok "fork's push is a fast-forward merge on its old tip" || bad "fork merge parent"
git --git-dir="$T/gh/ExpressiveOS/frameworks_base.git" show "$m:core/Power.java" | grep -q 'ExpressiveOS took it' && ok "resolution in the pushed merge" || bad "resolution missing"
[[ -n $(tipof ExpressiveOS/manifest update/2026-11) ]] && ok "manifest branch update/2026-11 pushed" || bad "no manifest branch"
[[ $(tipof ExpressiveOS/manifest expressiveos) = $(git -C "$top/.repo/manifests" rev-parse HEAD) ]] && ok "manifest's expressiveos untouched by push" || bad "push moved expressiveos"
expect "second push: nothing to do" 0 'UPDATE_PUSH=OK \(0 forks pushed now, 2 before' -- push
expect "plan after push refused (branch exists)" 1 'has a branch update/2026-11 already' -- plan

# --- 3. after Daryl merges: the dry run counts from last-update.conf; the same id is refused
merge_manifest_pr 2026-11
expect "dry run counts from the update's LineageOS manifest" 0 "commits since ${C1:0:12} \(update 2026-11\)" -- check
expect "same id again refused" 1 'has update 2026-11 already' -- plan
# a December update: LineageOS moves again; frameworks/base merges cleanly now
commit_los() { local w; w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b lineage-24.0 "$T/gh/LineageOS/$1.git" "$w"; printf '%s\n' "$3" > "$w/$2"; git -C "$w" add -A; git -C "$w" commit -qm "$4"; git -C "$w" push -q origin lineage-24.0; rm -rf "$w"; }
commit_los android_frameworks_base README "fb3" "README: even more"
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b lineage-24.0 "$T/gh/LineageOS/android.git" "$w"; echo "<!-- dec -->" >> "$w/default.xml"; git -C "$w" commit -qam dec; git -C "$w" push -q origin lineage-24.0; rm -rf "$w"
C2=$(tipof LineageOS/android lineage-24.0)
mkdir -p "$kit/sources/updates/2026-12"; echo "LINEAGE_MANIFEST=$C2" > "$kit/sources/updates/2026-12/update.conf"
expect "next update: base is last update's, clean merge" 0 "LineageOS's manifest ${C1:0:12} \(update 2026-11\).*" -- plan 2026-12
grep -q 'frameworks/base .*1 new commit.*merge' "$W"/reports/update-plan-2026-12-*.txt && ok "December merges frameworks/base cleanly" || bad "December frameworks/base"

# --- 4. stale, bad and unused resolutions
fresh; resolve
commit_los android_frameworks_base core/Other.java "x" "LineageOS: another"
expect "LineageOS moved on: the resolution's commit is taken" 0 "takes LineageOS's [0-9a-f]{12}, the commit its resolution is for: 1 new commit after it wait for the next update" -- plan
fresh; resolve
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/frameworks_base.git" "$w"; echo z > "$w/z"; git -C "$w" add -A; git -C "$w" commit -qm "fork: later"; git -C "$w" push -q origin expressiveos; rm -rf "$w"
expect "stale resolution (the fork moved)" 1 'STALE RESOLUTION: the resolution is for merging' -- plan
fresh
expect "resolution refuses markers left" 1 'still has conflict markers: core/Power.java' -- bash "$P/t-resolve.sh" "$WD" 'eval printf "<<<<<<< x\n" >> $R/core/Power.java'
fresh; resolve
sed -i 's#^+  int b = 200; // LineageOS, ExpressiveOS took it$#+<<<<<<< x#' "$U/resolutions/frameworks/base.patch"
expect "markers left (hand-edited resolution): bad resolution" 1 'BAD RESOLUTION: still has conflict markers after the resolution: core/Power.java' -- plan
fresh; resolve
sed -i 's#^resolved core/Power.java#resolved core/Power.java\nresolved core/Nope.java#' "$U/resolutions/frameworks/base.patch"
expect "resolution lists a file that doesn't conflict" 1 "BAD RESOLUTION: the resolution lists files the merge doesn't conflict in: core/Nope.java" -- plan
fresh; resolve
mkdir -p "$U/resolutions/vendor"; sed "s#^merge .*#merge $(printf '%040d' 0) $(printf '%040d' 0)#" "$U/resolutions/frameworks/base.patch" > "$U/resolutions/vendor/lineage.patch"
expect "resolution for a clean merge: unused" 1 'RESOLUTION UNUSED' -- plan
fresh; resolve
mkdir -p "$U/resolutions/development"; cp "$U/resolutions/frameworks/base.patch" "$U/resolutions/development.patch"
expect "resolution for a non-fork" 1 "development isn't one of ExpressiveOS's forks" -- plan
fresh; resolve
echo junk > "$U/notes.txt"
expect "stray file in the update refused" 1 'holds update.conf and resolutions' -- plan
fresh; resolve 'eval printf "extra\n" > $R/core/Extra.java'
expect "resolution may change another file" 0 'resolution also changes core/Extra.java' -- plan

# --- 5. push refusals: nothing pushed when anything moved since the plan
fresh; resolve
plan >/dev/null 2>&1
echo "# changed" >> "$U/resolutions/frameworks/base.patch"
expect "kit changed since the plan" 1 "isn't what the plan was made from" -- push
fresh; resolve
plan >/dev/null 2>&1
vl=$(tipof ExpressiveOS/vendor_lineage)
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/frameworks_base.git" "$w"; echo y > "$w/y"; git -C "$w" add -A; git -C "$w" commit -qm y; git -C "$w" push -q origin expressiveos; rm -rf "$w"
expect "fork moved since the plan" 1 'frameworks/base: .* the plan merged into' -- push
[[ $(tipof ExpressiveOS/vendor_lineage) = "$vl" ]] && ok "nothing pushed when one fork moved" || bad "vendor/lineage pushed although frameworks/base moved"
[[ -z $(tipof ExpressiveOS/manifest update/2026-11) ]] && ok "no manifest branch when refused" || bad "manifest branch pushed"
fresh; resolve
plan >/dev/null 2>&1
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/manifest.git" "$w"; echo z > "$w/z"; git -C "$w" add -A; git -C "$w" commit -qm z; git -C "$w" push -q origin expressiveos; rm -rf "$w"
expect "GitHub's manifest moved since the plan" 1 "GitHub's manifest expressiveos is at .* plan again" -- push
expect "tree behind GitHub's manifest: plan refused" 1 "run expressiveos-setup" -- plan

# --- 6. the fork's branch ahead of the pin is taken; a 3-way manifest conflict stops it
fresh; resolve
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/vendor_lineage.git" "$w"; echo y > "$w/y"; git -C "$w" add -A; git -C "$w" commit -qm "vendor: a later fix"; git -C "$w" push -q origin expressiveos; rm -rf "$w"
expect "fork ahead of its pin: taken, noted" 0 "vendor/lineage .*1 commits the manifest doesn't pin yet" -- plan
fresh; resolve
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/manifest.git" "$w"; sed -i 's#path="external/foo" \(.*\) groups="pdk"#path="external/foo" \1 groups="pdk,eos"#' "$w/default.xml"; git -C "$w" commit -qam "foo groups"; git -C "$w" push -q origin expressiveos; rm -rf "$w"
git -C "$top/.repo/manifests" fetch -q origin; git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
expect "ours and LineageOS both changed external/foo's groups: both kept" 0 "changed external/foo: groups" -- plan
grep -q 'path="external/foo" .*groups="pdk,eos,pdk-fs"' "$W/updates/2026-11/default.xml" && ok "external/foo groups pdk,eos,pdk-fs" || bad "external/foo groups: $(grep 'external/foo"' "$W/updates/2026-11/default.xml")"

# --- 7. guards
fresh; resolve
expect "update.conf with another key" 1 'must hold LINEAGE_MANIFEST' -- bash -c "echo X=1 >> '$U/update.conf'; cd '$T' && bash '$kit/sources/update.sh' plan 2026-11 '$top'"
fresh; resolve
echo "LINEAGE_MANIFEST=$(printf '%040d' 1)" > "$U/update.conf"
expect "LINEAGE_MANIFEST not on LineageOS's branch" 1 "isn't on LineageOS's manifest's lineage-24.0" -- plan
fresh; resolve
expect "bad id" 1 'usage|an update.s id' -- bash -c "cd '$T' && bash '$kit/sources/update.sh' plan 2026-13 '$top'"
expect "missing update dir" 1 'has no sources/updates/2026-10/update.conf' -- plan 2026-10
expect "lock held" 1 'is running' -- bash -c "exec 9>'$HOME/.expressiveos.lock'; flock 9; cd '$T' && bash '$kit/sources/update.sh' plan 2026-11 '$top'"
expect "work folder in the tree" 1 'is in the tree' -- bash -c "cd '$T' && EOS_UPDATE_WORK='$top/w' bash '$kit/sources/update.sh' plan 2026-11 '$top'"
expect "token mode refuses an empty token" 1 'EOS_PUSH_TOKEN is empty' -- bash -c "cd '$T' && EOS_PUSH_TOKEN= bash '$kit/sources/update.sh' token"

echo "== $pass passed, $failn failed"
