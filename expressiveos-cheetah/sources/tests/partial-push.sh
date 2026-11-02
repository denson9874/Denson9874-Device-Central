#!/usr/bin/env bash
# Regression test (partial-push): a push of the monthly update that stopped partway (some forks
# pushed, a later fork or the manifest refused), then push again or plan again.
#
#   bash partial-push.sh <kit src>
#
# Fixed behaviour checked: plan_fork finds this update's merge pushed already (its message names
# the update) and takes its resolution as spent: the fork is "merged by this update and pushed
# before", pinned at its branch's tip (plan.json "pins"), and push finishes from there. When
# LineageOS commits after that (conflicting or not), the fork stays at that merge and the newer
# commits wait for the next update (no second merge, no crash, no RESOLUTION UNUSED). The
# manifest commit (the pull request) counts the pushed merges.
# Outcomes are checked in the file:// repos standing in for GitHub (fork branches, merge
# parents, the manifest's update/<id> branch and the default.xml it pins) and in plan.json.
#
# Each case builds a fresh world with harness.sh (next to this script) in partial-push under
# $EOS_TEST_WORK (default $TMPDIR/eos-update-tests), one at a time; it is removed at the end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=$HERE/harness.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/partial-push
mkdir -p -- "$(dirname -- "$WD")"   # the harness log goes next to it
LB=lineage-24.0
ID=2026-11
trap 'rm -rf "$WD"' EXIT

pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { [[ -n ${1:-} ]] && printf '%s\n' "$1" | tail -"${2:-20}" | sed 's/^/    | /'; return 0; }

# --- a case: checks in order; the first that fails is the case's reason --------------------------
CASE= CERR= OUT= RC=0 LOG=
begin() { CASE=$1; CERR=; LOG=; }
check() {   # check <reason> <bash test, eval'd>: records reason if the test fails (first one only)
    [[ -n $CERR ]] && return 1
    if eval "$2"; then return 0; fi
    CERR=$1
    LOG=$OUT
    return 1
}
finish() {
    if [[ -z $CERR ]]; then ok "$CASE"; else bad "$CASE: $CERR"; show "$LOG"; fi
}
run() { OUT=$("$@" 2>&1); RC=$?; }   # run <cmd...>: OUT, RC

# --- the world ------------------------------------------------------------------------------------
fresh() {   # a new world with frameworks/base's conflict resolved; sets T kit top G FB VL MAN LFB LVL W U PF RES
    bash "$HARNESS" "$KSRC" "$WD" >"$WD.harness.log" 2>&1 || { tail -n 20 "$WD.harness.log" >&2; echo "FAIL: harness.sh couldn't build the world"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    FB=$T/gh/ExpressiveOS/frameworks_base.git
    VL=$T/gh/ExpressiveOS/vendor_lineage.git
    ST=$T/gh/ExpressiveOS/packages_apps_Settings.git
    MAN=$T/gh/ExpressiveOS/manifest.git
    LFB=$T/gh/LineageOS/android_frameworks_base.git
    LVL=$T/gh/LineageOS/android_vendor_lineage.git
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/$ID
    PF=$W/updates/$ID/plan.json
    RES=$U/resolutions/frameworks/base.patch
    resolve_fb "$(tipof "$FB")" "$(tipof "$LFB" $LB)" 'int b = 200; // LineageOS, ExpressiveOS took it' >/dev/null 2>&1 \
        || { echo "FAIL: couldn't make frameworks/base's resolution"; exit 1; }
}
resolve_fb() {   # resolve_fb <fork commit> <LineageOS commit> <line b>: frameworks/base's merge by hand -> $RES
    local R=$T/w/resolve-fb
    rm -rf "$R"
    git clone -q "$FB" "$R" && git -C "$R" checkout -q "$1" || return 1
    git -C "$R" fetch -q "$LFB" "$2" || return 1
    git -C "$R" merge --no-commit -q "$2" >/dev/null 2>&1
    printf 'class Power {\n  int a = 1;\n  %s\n  int c = 3;\n}\n' "$3" > "$R/core/Power.java"
    git -C "$R" add -A || return 1
    python3 -I "$kit/sources/update.py" resolution "$R" --out "$RES" || return 1
    rm -rf "$R"
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "$ID" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "$ID" "$top"); }
tipof() { git --git-dir="$1" rev-parse -q --verify "refs/heads/${2:-expressiveos}" 2>/dev/null; }
upd_branch() { tipof "$MAN" "update/$ID"; }
parents() { git --git-dir="$1" rev-list --parents -n 1 "$2" 2>/dev/null | cut -d' ' -f2-; }
hook_on() { printf '#!/bin/sh\necho "remote: simulated refusal" >&2\nexit 1\n' > "$1/hooks/pre-receive"; chmod +x "$1/hooks/pre-receive"; }
hook_off() { rm -f "$1/hooks/pre-receive"; }
pj() {   # pj <python expression over d, plan.json>: prints it
    python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$PF" "$1" 2>/dev/null
}
pj_forks() { pj "' '.join(f['path'] + '=' + f['tip'] + '>' + f['merge'] for f in d['forks'])"; }
pj_pins() { pj "' '.join(sorted(f['path'] + '=' + f['tip'] for f in d.get('pins', [])))"; }
mrev() {   # mrev <git dir> <manifest commit-ish> <project name>: its revision in that commit's default.xml
    git --git-dir="$1" show "$2:default.xml" 2>/dev/null | python3 -I -c '
import sys, xml.etree.ElementTree as ET
t = sys.stdin.read()
r = ET.fromstring(t) if t.strip() else None
print("" if r is None else next((p.get("revision") for p in r.iter("project") if p.get("name") == sys.argv[1]), ""))' "$3"
}
commit_on() {   # commit_on <bare> <branch> <msg> <file> <content>: one commit pushed there; prints it
    local w
    w=$(mktemp -d "$T/w/c.XXXX")
    git clone -q -b "$2" "$1" "$w" 2>/dev/null || return 1
    mkdir -p "$w/$(dirname "$4")" && printf '%s\n' "$5" > "$w/$4"
    git -C "$w" add -A && git -C "$w" commit -qm "$3" && git -C "$w" push -q origin "$2" || return 1
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
power_l2() {   # LineageOS changes Power.java's line b again: conflicts with the fork's (resolved) line
    commit_on "$LFB" $LB "Power: LineageOS's b again" core/Power.java \
        "$(printf 'class Power {\n  int a = 1;\n  int b = 300; // LineageOS again\n  int c = 3;\n}')"
}
no_bad_output() {   # what a re-plan after a partial push must never say
    ! grep -qE 'RESOLUTION UNUSED|Traceback|stale resolution|STALE RESOLUTION' <<<"$OUT"
}
manifest_pins() {   # manifest_pins <git dir> <commit-ish> <frameworks_base rev> <vendor_lineage rev>: true when
                    # that manifest commit pins those (and Settings where it was) and is update <id>'s
    [[ $(mrev "$1" "$2" frameworks_base) = "$3" && $(mrev "$1" "$2" vendor_lineage) = "$4" \
        && $(mrev "$1" "$2" packages_apps_Settings) = "$ST0" ]] \
        && git --git-dir="$1" show "$2:last-update.conf" 2>/dev/null | grep -qx "UPDATE=$ID"
}

# The first plan and a push that stops partway: sets P1_* (the first plan) and FB0 VL0 ST0 LFB1 LVL1.
# hook <bare> refuses pushes there (vendor_lineage: after frameworks_base's merge was pushed;
# the manifest: after both forks were pushed)
partial() {
    FB0=$(tipof "$FB") VL0=$(tipof "$VL") ST0=$(tipof "$ST") LFB1=$(tipof "$LFB" $LB) LVL1=$(tipof "$LVL" $LB)
    run plan
    check "first plan isn't READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (2 forks merged" <<<"$OUT"' || return 1
    P1_FBM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'frameworks/base'][0]")
    P1_VLM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'vendor/lineage'][0]")
    P1_MC=$(pj "d['manifest_commit']")
    check "first plan.json: forks not frameworks/base then vendor/lineage, or pins not empty" \
        '[[ $(pj_forks) = "frameworks/base=$FB0>$P1_FBM vendor/lineage=$VL0>$P1_VLM" && -z $(pj_pins) ]]' || return 1
    hook_on "$1"
    run push
    hook_off "$1"
    check "push with $(basename "$1") refusing didn't fail (rc $RC)" '[[ $RC != 0 ]] && ! grep -q UPDATE_PUSH=OK <<<"$OUT"' || return 1
    check "after the refused push, frameworks_base isn't at the first plan's merge" '[[ $(tipof "$FB") = "$P1_FBM" ]]' || return 1
    check "after the refused push, a manifest branch update/$ID is there" '[[ -z $(upd_branch) ]]' || return 1
    if [[ $1 = "$VL" ]]; then
        check "after vendor_lineage refused, vendor_lineage moved" '[[ $(tipof "$VL") = "$VL0" ]]' || return 1
    else
        check "after the manifest refused, vendor_lineage isn't at the first plan's merge" '[[ $(tipof "$VL") = "$P1_VLM" ]]' || return 1
    fi
}

# --- 1. push stops at vendor_lineage; push again with nothing moved: the rest, and the manifest ----
fresh
begin "1. push refused at vendor_lineage after frameworks_base's merge; push again: OK, rest + manifest branch"
if partial "$VL"; then
    run push
    check "second push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (1 forks pushed now, 1 before" <<<"$OUT"'
    check "frameworks_base moved off the first push's merge" '[[ $(tipof "$FB") = "$P1_FBM" ]]'
    check "vendor_lineage isn't at the plan's merge" '[[ $(tipof "$VL") = "$P1_VLM" ]]'
    check "vendor_lineage's merge parents aren't [fork tip, LineageOS tip]" '[[ $(parents "$VL" "$P1_VLM") = "$VL0 $LVL1" ]]'
    check "manifest branch update/$ID isn't the plan's commit" '[[ $(upd_branch) = "$P1_MC" ]]'
    check "manifest branch doesn't pin both forks' merges" 'manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P1_VLM"'
    check "GitHub's manifest expressiveos moved" '[[ $(parents "$MAN" "$P1_MC") = "$(tipof "$MAN")" ]]'
    check "plan.json not marked pushed" '[[ -n $(pj "d.get(\"pushed\", \"\")") ]]'
fi
finish

# --- 2. same stop; plan again with nothing moved: READY, the note, push OK ------------------------
fresh
begin "2. push refused at vendor_lineage; plan again: READY (spent note, frameworks/base pinned), push OK"
if partial "$VL"; then
    run plan
    check "re-plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (1 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
    check "re-plan says RESOLUTION UNUSED / stale / crashed" 'no_bad_output'
    check "frameworks/base isn't 'merged by this update and pushed before', with the note" \
        'grep -qE "^frameworks/base <- .*: merged by this update and pushed before \[.*this update.s merge is in the fork already, pushed before\]" <<<"$OUT"'
    check "the count line doesn't say 1 merged and pushed before" \
        'grep -qE "^-- 1 merged \(0 with conflicts resolved\), 1 merged and pushed before, " <<<"$OUT"'
    check "no plan.json after the re-plan" '[[ -f $PF ]]'
    P2_VLM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'vendor/lineage'][0]")
    P2_MC=$(pj "d['manifest_commit']")
    P2_MGD=$(pj "d['manifest_gd']")
    check "plan.json forks aren't just vendor/lineage from its unpushed tip" '[[ $(pj_forks) = "vendor/lineage=$VL0>$P2_VLM" ]]'
    check "plan.json pins aren't frameworks/base at the first push's merge" '[[ $(pj_pins) = "frameworks/base=$P1_FBM" ]]'
    check "planned manifest commit doesn't pin frameworks/base at the first push's merge" \
        'manifest_pins "$P2_MGD" "$P2_MC" "$P1_FBM" "$P2_VLM"'
    run push
    check "push after the re-plan not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (1 forks pushed now, 0 before" <<<"$OUT"'
    check "frameworks_base isn't at the first push's merge (unchanged)" '[[ $(tipof "$FB") = "$P1_FBM" ]]'
    check "frameworks_base's merge parents aren't [fork tip, LineageOS tip]" '[[ $(parents "$FB" "$P1_FBM") = "$FB0 $LFB1" ]]'
    check "vendor_lineage isn't at the re-plan's merge" '[[ $(tipof "$VL") = "$P2_VLM" ]]'
    check "vendor_lineage's merge parents aren't [fork tip, LineageOS tip]" '[[ $(parents "$VL" "$P2_VLM") = "$VL0 $LVL1" ]]'
    check "manifest branch update/$ID isn't the re-plan's commit" '[[ $(upd_branch) = "$P2_MC" ]]'
    check "manifest branch update/$ID doesn't pin frameworks_base at the first merge, vendor_lineage at the new one" \
        'manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P2_VLM"'
fi
finish

# --- 3. same stop; vendor_lineage gets a commit; push says plan again; plan READY; push OK --------
fresh
begin "3. push refused at vendor_lineage; vendor_lineage gets a commit: push says plan again, plan READY, push OK"
if partial "$VL"; then
    VLX=$(commit_on "$VL" expressiveos "vendor: a fix" y "y")
    run push
    check "push after vendor_lineage moved didn't say plan again (rc $RC)" \
        '[[ $RC != 0 ]] && grep -qE "vendor/lineage: .* is at ${VLX:0:12}, the plan merged into ${VL0:0:12}: plan again" <<<"$OUT"'
    check "the refused push moved something" '[[ $(tipof "$VL") = "$VLX" && $(tipof "$FB") = "$P1_FBM" && -z $(upd_branch) ]]'
    run plan
    check "re-plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (1 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
    check "re-plan says RESOLUTION UNUSED / stale / crashed" 'no_bad_output'
    check "frameworks/base isn't 'merged by this update and pushed before', with the note" \
        'grep -qE "^frameworks/base <- .*: merged by this update and pushed before \[.*this update.s merge is in the fork already, pushed before\]" <<<"$OUT"'
    check "vendor/lineage's line doesn't say it takes the fork's new commit" \
        'grep -qE "^vendor/lineage <- .*merge [0-9a-f]{12}.*its expressiveos branch has 1 commits? the manifest doesn.t pin yet" <<<"$OUT"'
    P2_VLM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'vendor/lineage'][0]")
    P2_MC=$(pj "d['manifest_commit']")
    P2_MGD=$(pj "d['manifest_gd']")
    check "plan.json forks aren't vendor/lineage from its new commit" '[[ $(pj_forks) = "vendor/lineage=$VLX>$P2_VLM" ]]'
    check "plan.json pins aren't frameworks/base at the first push's merge" '[[ $(pj_pins) = "frameworks/base=$P1_FBM" ]]'
    run push
    check "push after the re-plan not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (1 forks pushed now, 0 before" <<<"$OUT"'
    check "frameworks_base isn't at the first push's merge (unchanged)" '[[ $(tipof "$FB") = "$P1_FBM" ]]'
    check "vendor_lineage isn't at the re-plan's merge" '[[ $(tipof "$VL") = "$P2_VLM" ]]'
    check "vendor_lineage's merge parents aren't [its new commit, LineageOS tip]" '[[ $(parents "$VL" "$P2_VLM") = "$VLX $LVL1" ]]'
    check "manifest branch update/$ID isn't the re-plan's commit" '[[ $(upd_branch) = "$P2_MC" ]]'
    check "manifest branch update/$ID doesn't pin frameworks_base at the first merge, vendor_lineage at the new one" \
        'manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P2_VLM"'
fi
finish

# --- 4. the manifest refuses after both forks were pushed; plan again: READY; push OK ------------
fresh
begin "4. manifest push refused after both forks pushed; plan again: READY (both pinned), push OK"
if partial "$MAN"; then
    run plan
    check "re-plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (0 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
    check "re-plan says RESOLUTION UNUSED / stale / crashed" 'no_bad_output'
    check "frameworks/base isn't 'merged by this update and pushed before', with the note" \
        'grep -qE "^frameworks/base <- .*: merged by this update and pushed before \[.*this update.s merge is in the fork already, pushed before\]" <<<"$OUT"'
    check "vendor/lineage isn't 'merged by this update and pushed before'" \
        'grep -qE "^vendor/lineage <- .*: merged by this update and pushed before \[.*this update.s merge is in the fork already, pushed before\]" <<<"$OUT"'
    check "the manifest commit's message doesn't count both merges, 1 resolved, both pushed before" \
        'git --git-dir="$(pj "d[\"manifest_gd\"]")" log -1 --format=%B "$(pj "d[\"manifest_commit\"]")" | grep -qF "2 of ExpressiveOS'"'"'s forks merge LineageOS'"'"'s commits (1 with conflicts resolved; 2 of them pushed before)"'
    check "no plan.json after the re-plan" '[[ -f $PF ]]'
    P2_MC=$(pj "d['manifest_commit']")
    P2_MGD=$(pj "d['manifest_gd']")
    check "plan.json forks not empty" '[[ -z $(pj_forks) ]]'
    check "plan.json pins aren't both forks at the first push's merges" \
        '[[ $(pj_pins) = "frameworks/base=$P1_FBM vendor/lineage=$P1_VLM" ]]'
    check "planned manifest commit doesn't pin both forks at the first push's merges" \
        'manifest_pins "$P2_MGD" "$P2_MC" "$P1_FBM" "$P1_VLM"'
    run push
    check "push after the re-plan not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (0 forks pushed now, 0 before" <<<"$OUT"'
    check "a fork moved" '[[ $(tipof "$FB") = "$P1_FBM" && $(tipof "$VL") = "$P1_VLM" ]]'
    check "manifest branch update/$ID isn't the re-plan's commit" '[[ $(upd_branch) = "$P2_MC" ]]'
    check "manifest branch update/$ID doesn't pin both forks at the first push's merges" \
        'manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P1_VLM"'
fi
finish

# --- 5. after the partial push, LineageOS adds a conflicting commit: the pushed merge stays --------
fresh
begin "5. partial push, then a conflicting LineageOS commit: frameworks/base stays at its pushed merge, READY, push OK"
if partial "$VL"; then
    LFB2=$(power_l2)
    run plan
    check "re-plan not READY (rc $RC)" \
        '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (1 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
    check "re-plan says RESOLUTION UNUSED / stale / crashed" 'no_bad_output'
    check "frameworks/base isn't pushed before, LineageOS's new commit waiting" \
        'grep -qE "^frameworks/base <- .*: merged by this update and pushed before \[.*this update.s merge of LineageOS.s ${LFB1:0:12} is in the fork already, pushed before: 1 new commit after it wait for the next update\]" <<<"$OUT"'
    check "the re-plan shows a conflict" '! grep -qE "UNRESOLVED|^== Conflicts" <<<"$OUT"'
    P2_VLM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'vendor/lineage'][0]")
    P2_MC=$(pj "d['manifest_commit']")
    P2_MGD=$(pj "d['manifest_gd']")
    check "plan.json forks aren't just vendor/lineage, or frameworks/base isn't pinned at the first merge" \
        '[[ $(pj_forks) = "vendor/lineage=$VL0>$P2_VLM" && $(pj_pins) = "frameworks/base=$P1_FBM" ]]'
    check "the manifest commit's message doesn't count frameworks/base's resolved merge, pushed before" \
        'git --git-dir="$P2_MGD" log -1 --format=%B "$P2_MC" | grep -qF "2 of ExpressiveOS'"'"'s forks merge LineageOS'"'"'s commits (1 with conflicts resolved; 1 of them pushed before)"'
    run push
    check "push after the re-plan not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (1 forks pushed now, 0 before" <<<"$OUT"'
    check "frameworks_base moved off the first push's merge" '[[ $(tipof "$FB") = "$P1_FBM" ]]'
    check "frameworks_base's merge parents aren't [fork tip, LineageOS's first commit]" '[[ $(parents "$FB" "$P1_FBM") = "$FB0 $LFB1" ]]'
    check "vendor_lineage isn't at the re-plan's merge" '[[ $(tipof "$VL") = "$P2_VLM" ]]'
    check "manifest branch update/$ID isn't the re-plan's commit pinning the first merge and vendor_lineage's" \
        '[[ $(upd_branch) = "$P2_MC" ]] && manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P2_VLM"'
fi
finish

# --- 7. after the partial push, LineageOS adds a commit that merges clean: READY, push OK ---------
fresh
begin "7. partial push, then a clean LineageOS commit on frameworks_base: no second merge, READY, push OK"
if partial "$VL"; then
    LFB2=$(commit_on "$LFB" $LB "README: again" README "fb3")
    run plan
    check "re-plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PLAN=READY (1 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
    check "re-plan says RESOLUTION UNUSED / stale / crashed" 'no_bad_output'
    check "frameworks/base isn't pushed before, LineageOS's new commit waiting (no second merge)" \
        'grep -qE "^frameworks/base <- .*: merged by this update and pushed before \[.*this update.s merge of LineageOS.s ${LFB1:0:12} is in the fork already, pushed before: 1 new commit after it wait for the next update\]" <<<"$OUT"'
    P2_VLM=$(pj "[f['merge'] for f in d['forks'] if f['path'] == 'vendor/lineage'][0]")
    P2_MC=$(pj "d['manifest_commit']")
    P2_MGD=$(pj "d['manifest_gd']")
    check "plan.json forks aren't just vendor/lineage, or frameworks/base isn't pinned at the first merge" \
        '[[ $(pj_forks) = "vendor/lineage=$VL0>$P2_VLM" && $(pj_pins) = "frameworks/base=$P1_FBM" ]]'
    run push
    check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (1 forks pushed now, 0 before" <<<"$OUT"'
    check "frameworks_base moved off the first push's merge" '[[ $(tipof "$FB") = "$P1_FBM" ]]'
    check "vendor_lineage isn't at its merge" '[[ $(tipof "$VL") = "$P2_VLM" ]]'
    check "manifest branch update/$ID isn't the plan's commit pinning the first merge and vendor_lineage's" \
        '[[ $(upd_branch) = "$P2_MC" ]] && manifest_pins "$MAN" "update/$ID" "$P1_FBM" "$P2_VLM"'
fi
finish

rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
