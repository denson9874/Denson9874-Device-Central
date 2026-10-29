#!/usr/bin/env bash
# Regression test (round2): the second review's fixes to the monthly update's plan, push and
# resolution.
#
#   bash round2.sh <kit src>
#
# Fixed behaviour checked:
#  1. The same merge on every machine: a fork's .gitattributes (merge=union), the resolution
#     maker's merge driver (merge=keep with merge.keep.driver) and renormalizing (core.autocrlf,
#     merge.renormalize) don't change update.py's merges. A resolution made as README step 4 says
#     (cd <clone>; resolution .) writes down what they did, the plan is READY, and its merge has
#     exactly the clone's tree. A shallow clone is refused.
#  2. File names: a conflict in a file whose name isn't UTF-8, or has newlines in it: the plan
#     ends UPDATE_PLAN=CONFLICTS (no traceback), the name prints git-quoted on one line, no line
#     of the output is a GitHub workflow command or a second UPDATE_PLAN, the report is written;
#     the dry run ends UPDATE_CHECK=OK.
#  3. A binary file the fork deleted and LineageOS changed: the hint names LineageOS's side as the
#     one the merge left.
#  4. A fork of an AOSP repo (a tag): a resolution made by merging FETCH_HEAD (the tag object)
#     names the tag's commit and the plan is READY; once update.conf moves to a newer tag, that
#     resolution is stale (the fork is never merged at the old tag).
#  5. After a push that stopped with the manifest refused (both forks pushed), LineageOS commits
#     to vendor_lineage: the re-plan keeps vendor/lineage at its pushed merge (no second merge),
#     the newer commit waits for the next update, push finishes.
#  6. Manifest: a project LineageOS puts back into the default sync is added.
#  7. A complete push, then plan again: refused, and the update's plan.json, default.xml and
#     kernel.xml are left; push again is OK; without plan.json push names update/<id>.
#
# Each case builds a fresh world with harness.sh (next to this script; EOS_TEST_AOSP_FORK=1 makes
# build/make a fork of AOSP's platform/build) in round2 under $EOS_TEST_WORK (default $TMPDIR/eos-update-tests), one
# at a time; it is removed at the end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=$HERE/harness.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/round2
LB=lineage-24.0
ID=2026-11
trap 'rm -rf "$WD"' EXIT

pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { [[ -n ${1:-} ]] && printf '%s\n' "$1" | tail -"${2:-25}" | sed 's/^/    | /'; return 0; }

# --- a case: checks in order; the first that fails is the case's reason --------------------------
CASE= CERR= OUT= RC=0 LOG=
begin() { CASE=$1; CERR=; LOG=; }
check() {   # check <reason> <bash test, eval'd>
    [[ -n $CERR ]] && return 1
    if eval "$2"; then return 0; fi
    CERR=$1
    LOG=$OUT
    return 1
}
finish() { if [[ -z $CERR ]]; then ok "$CASE"; else bad "$CASE: $CERR"; show "$LOG"; fi; }
run() { OUT=$("$@" 2>&1); RC=$?; }

# --- the world ------------------------------------------------------------------------------------
fresh() {   # fresh [1: build/make a fork of AOSP's]: a new world; sets T kit top G FB VL MAN LFB LVL W U PF RES R
    rm -rf "$WD"
    EOS_TEST_AOSP_FORK=${1:-} bash "$HARNESS" "$KSRC" "$WD" >/dev/null 2>&1 || { echo "FAIL: the harness couldn't build the world"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    export GIT_CEILING_DIRECTORIES=$T
    FB=$T/gh/ExpressiveOS/frameworks_base.git
    VL=$T/gh/ExpressiveOS/vendor_lineage.git
    MAN=$T/gh/ExpressiveOS/manifest.git
    LFB=$T/gh/LineageOS/android_frameworks_base.git
    LVL=$T/gh/LineageOS/android_vendor_lineage.git
    LOSM=$T/gh/LineageOS/android.git
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/$ID
    PF=$W/updates/$ID/plan.json
    RES=$U/resolutions/frameworks/base.patch
    R=$T/w/clone
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "$ID" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "$ID" "$top"); }
drycheck() { (cd "$T" && bash "$kit/sources/update-check.sh" "$top"); }
tipof() { git --git-dir="$1" rev-parse -q --verify "refs/heads/${2:-expressiveos}" 2>/dev/null; }
parents() { git --git-dir="$1" rev-list --parents -n 1 "$2" 2>/dev/null | cut -d' ' -f2-; }
hook_on() { printf '#!/bin/sh\necho "remote: simulated refusal" >&2\nexit 1\n' > "$1/hooks/pre-receive"; chmod +x "$1/hooks/pre-receive"; }
hook_off() { rm -f "$1/hooks/pre-receive"; }
pj() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$PF" "$1" 2>/dev/null; }
fork_merge() { pj "[f['merge'] for f in d['forks'] if f['path'] == '$1'][0]"; }
fork_gd() { pj "[f['gd'] for f in d['forks'] if f['path'] == '$1'][0]"; }
pj_forks() { pj "' '.join(f['path'] for f in d['forks'])"; }
pj_pins() { pj "' '.join(sorted(f['path'] + '=' + f['tip'] for f in d.get('pins', [])))"; }
change() {   # change <bare> <branch> <msg> <bash run in a clone of it>: one commit pushed there
    local w
    w=$(mktemp -d "$T/w/e.XXXX")
    git clone -q -b "$2" "$1" "$w" 2>/dev/null || return 1
    (cd "$w" && eval "$4") || return 1
    git -C "$w" add -A && git -C "$w" commit -qm "$3" && git -C "$w" push -q origin "$2" || return 1
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
onbase() {   # onbase <msg> <bash>: a commit on frameworks_base's root, merged into LineageOS's branch and the fork's
    local w
    w=$(mktemp -d "$T/w/b.XXXX")
    git clone -q -b $LB "$LFB" "$w" 2>/dev/null || return 1
    git -C "$w" checkout -q -b side "$(git -C "$w" rev-list --max-parents=0 HEAD)"
    (cd "$w" && eval "$2") || return 1
    git -C "$w" add -A && git -C "$w" commit -qm "$1" || return 1
    git -C "$w" checkout -q $LB && git -C "$w" merge -q --no-ff -m "m $1" side && git -C "$w" push -q origin $LB || return 1
    git -C "$w" fetch -q "$FB" expressiveos && git -C "$w" checkout -q -B eos FETCH_HEAD \
        && git -C "$w" merge -q --no-ff -m "m $1" side && git -C "$w" push -q "$FB" eos:expressiveos || return 1
    rm -rf "$w"
}
clonemerge() {   # README step 4 in $R: the fork's tip, LineageOS's tip merged (--no-commit); sets F L
    F=$(tipof "$FB") L=$(tipof "$LFB" $LB)
    rm -rf "$R"
    git clone -q "$G/ExpressiveOS/frameworks_base" "$R" 2>/dev/null || return 1
    git -C "$R" checkout -q --detach "$F"
    git -C "$R" fetch -q "$G/LineageOS/android_frameworks_base" $LB
    git -C "$R" merge -q --no-commit "$L" >/dev/null 2>&1
    return 0
}
fixpower() {
    printf 'class Power {\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}\n' > "$R/core/Power.java"
    git -C "$R" add -- core/Power.java
}
mkres() { mkdir -p "$(dirname "$RES")"; (cd "$R" && python3 -I "$kit/sources/update.py" resolution . --out "$RES"); }
resolve_fb() {   # frameworks/base's merge of LineageOS's tip into the fork's tip, by hand -> $RES
    clonemerge && fixpower && git -C "$R" add -A && mkres >/dev/null 2>&1
}
plan_tree() {   # the plan's merge's tree for <path>
    local m gd
    m=$(fork_merge "$1") gd=$(fork_gd "$1")
    [[ -n $m ]] && git --git-dir="$gd" rev-parse "$m^{tree}" 2>/dev/null
}
one_line_out() {   # nothing in OUT reads as a GitHub workflow command or a second UPDATE_PLAN line
    ! grep -qE '^[[:space:]]*::' <<<"$OUT" && [[ $(grep -c '^UPDATE_PLAN=' <<<"$OUT") = 1 ]]
}

# --- 1a. a fork's .gitattributes: merge=union ------------------------------------------------------
begin "1a. fork's .gitattributes merge=union: the resolution (made in the clone) writes it down, READY, the clone's tree"
fresh
onbase "attrs" "printf 'notes.txt merge=union\n' > .gitattributes; printf 'n1\nn2\n' > notes.txt" >/dev/null
change "$FB" expressiveos "fork notes" "printf 'n3 eos\n' >> notes.txt" >/dev/null
change "$LFB" $LB "los notes" "printf 'n3 los\n' >> notes.txt" >/dev/null
clonemerge; fixpower
check "the clone's merge didn't merge notes.txt by itself (the union driver)" '[[ -z $(git -C "$R" ls-files -u -- notes.txt) ]]'
itree=$(git -C "$R" write-tree)
run mkres
check "resolution refused (rc $RC)" '[[ $RC = 0 && -f $RES ]]'
check "the resolution doesn't list notes.txt (the merge without attributes conflicts there)" 'grep -qx "resolved notes.txt" "$RES"'
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "the plan's merge isn't the clone's tree ($itree)" '[[ $(plan_tree frameworks/base) = "$itree" ]]'
finish

# --- 1b. the resolution maker's merge driver (merge=keep, merge.keep.driver=true) ----------------
begin "1b. merge=keep with the maker's merge.keep.driver: READY, the plan's merge is the clone's tree"
fresh
onbase "brand" "printf 'brand.txt merge=keep\n' > .gitattributes; printf 'b1\nb2\nb3\nb4\nb5\nb6\nb7\n' > brand.txt" >/dev/null
change "$FB" expressiveos "fork brand" "printf 'b1\nb2\nb3\nb4\nb5\nb6\nb7 EOS\n' > brand.txt" >/dev/null
change "$LFB" $LB "los brand" "printf 'b1 LOS\nb2\nb3\nb4\nb5\nb6\nb7\n' > brand.txt" >/dev/null
cp "$HOME/.gitconfig" "$T/gitconfig.clean"
git config --global merge.keep.driver true
clonemerge; fixpower
itree=$(git -C "$R" write-tree)
run mkres
cp "$T/gitconfig.clean" "$HOME/.gitconfig"
check "resolution refused (rc $RC)" '[[ $RC = 0 && -f $RES ]]'
check "the clone's brand.txt isn't the fork's (the keep driver)" '[[ $(git -C "$R" show :brand.txt | head -1) = b1 ]]'
check "the resolution doesn't write down brand.txt as changed" 'grep -qx "changed brand.txt" "$RES"'
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "the plan's merge isn't the clone's tree ($itree)" '[[ $(plan_tree frameworks/base) = "$itree" ]]'
finish

# --- 1c. the maker's core.autocrlf and merge.renormalize ------------------------------------------
begin "1c. the maker's core.autocrlf=true and merge.renormalize=true: READY, the plan's merge is the clone's tree"
fresh
onbase "crlf" "printf 'l1\r\nl2\r\nl3\r\nl4\r\nl5\r\n' > win.txt" >/dev/null
change "$FB" expressiveos "fork: win l2" "printf 'l1\r\nl2 eos\r\nl3\r\nl4\r\nl5\r\n' > win.txt" >/dev/null
change "$LFB" $LB "los: win to LF" "printf 'l1\nl2\nl3\nl4\nl5\n' > win.txt" >/dev/null
cp "$HOME/.gitconfig" "$T/gitconfig.clean"
git config --global core.autocrlf true
git config --global merge.renormalize true
clonemerge; fixpower; git -C "$R" add -A
itree=$(git -C "$R" write-tree)
run mkres
cp "$T/gitconfig.clean" "$HOME/.gitconfig"
check "resolution refused (rc $RC)" '[[ $RC = 0 && -f $RES ]]'
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "the plan's merge isn't the clone's tree ($itree)" '[[ $(plan_tree frameworks/base) = "$itree" ]]'
finish

# --- 1d. a shallow clone --------------------------------------------------------------------------
begin "1d. resolution refuses a shallow clone, saying so; nothing written"
fresh
F=$(tipof "$FB") L=$(tipof "$LFB" $LB)
rm -rf "$R"
git clone -q --depth 1 -b expressiveos "$G/ExpressiveOS/frameworks_base" "$R" 2>/dev/null
git -C "$R" fetch -q --depth 2 "$G/LineageOS/android_frameworks_base" $LB
git -C "$R" merge -q --no-commit --allow-unrelated-histories "$L" >/dev/null 2>&1
fixpower; git -C "$R" add -A
run mkres
check "resolution didn't refuse the shallow clone (rc $RC)" '[[ $RC != 0 ]] && grep -q "is a shallow clone" <<<"$OUT" && [[ ! -e $RES ]]'
finish

# --- 2a. a conflict in a file whose name isn't UTF-8 ----------------------------------------------
begin "2a. a conflict in core/caf\\xe9.txt: CONFLICTS (no traceback), name quoted, report written; dry run OK"
fresh
onbase "latin1" "printf 'one\ntwo\nthree\n' > \$'core/caf\\xe9.txt'" >/dev/null
change "$FB" expressiveos "fork cafe" "printf 'one\ntwo eos\nthree\n' > \$'core/caf\\xe9.txt'" >/dev/null
change "$LFB" $LB "los cafe" "printf 'one\ntwo los\nthree\n' > \$'core/caf\\xe9.txt'" >/dev/null
for loc in C.UTF-8 C unset; do
    rm -rf "$W/reports"
    if [[ $loc = unset ]]; then OUT=$(env -u LC_ALL -u LANG bash -c "cd '$T' && bash '$kit/sources/update.sh' plan $ID '$top'" 2>&1); RC=$?
    else OUT=$(cd "$T" && LC_ALL=$loc bash "$kit/sources/update.sh" plan $ID "$top" 2>&1); RC=$?; fi
    check "plan ($loc) not CONFLICTS, or a traceback (rc $RC)" \
        '[[ $RC != 0 ]] && grep -q "^UPDATE_PLAN=CONFLICTS " <<<"$OUT" && ! grep -q Traceback <<<"$OUT"'
    check "plan ($loc) doesn't show the name git-quoted" 'grep -qF "== \"frameworks/base/core/caf\\351.txt\": both changed it" <<<"$OUT"'
    check "plan ($loc) wrote no report with the UPDATE_PLAN line" 'grep -q "^UPDATE_PLAN=CONFLICTS " "$W"/reports/update-plan-*.txt'
done
run drycheck
check "dry run not OK, or a traceback (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_CHECK=OK" <<<"$OUT" && ! grep -q Traceback <<<"$OUT"'
check "dry run doesn't show the name git-quoted" 'grep -qF "\"core/caf\\351.txt\"" <<<"$OUT"'
finish

# --- 2b + 3. a name with newlines; a binary file the fork deleted and LineageOS changed ------------
begin "2b/3. a name with newlines prints as one quoted line (no workflow command, one UPDATE_PLAN); the binary hint names LineageOS's"
fresh
N=$'core/x\n::error::injected\nUPDATE_PLAN=READY (fake)'
export N
onbase "base" "printf 'one\ntwo\nthree\n' > \"\$N\"; printf 'PNG\000base\001\n' > logo.bin" >/dev/null
change "$FB" expressiveos "fork" "printf 'one\ntwo eos\nthree\n' > \"\$N\"; git rm -q logo.bin" >/dev/null
change "$LFB" $LB "los" "printf 'one\ntwo los\nthree\n' > \"\$N\"; printf 'PNG\000los new\002\n' > logo.bin" >/dev/null
run plan
check "plan not CONFLICTS (rc $RC)" '[[ $RC != 0 ]] && grep -q "^UPDATE_PLAN=CONFLICTS " <<<"$OUT" && ! grep -q Traceback <<<"$OUT"'
check "a line reads as a workflow command, or there's more than one UPDATE_PLAN line" 'one_line_out'
check "the name isn't shown quoted on one line" \
    'grep -qF "== \"frameworks/base/core/x\\n::error::injected\\nUPDATE_PLAN=READY (fake)\": both changed it" <<<"$OUT"'
check "the binary hint doesn't say the merge left LineageOS's" \
    'grep -qF "binary (fork none, LineageOS 13 bytes): resolve by taking one side (the merge left LineageOS'"'"'s)" <<<"$OUT"'
run drycheck
check "dry run not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_CHECK=OK" <<<"$OUT" && ! grep -qE "^[[:space:]]*::" <<<"$OUT"'
finish

# --- 4a. a fork of an AOSP repo: a resolution made by merging FETCH_HEAD (a tag object) ------------
begin "4a. build/make (a fork of AOSP's platform/build): a resolution made from FETCH_HEAD (the tag) names the commit, READY"
fresh 1
resolve_fb
PB=$T/gh/ExpressiveOS/platform_build.git AB=$T/aosp/platform/build.git
PF0=$(tipof "$PB") R2=$(git --git-dir="$AB" rev-parse 'android-17.0.0_r2^{commit}')
RB=$T/w/resbm
rm -rf "$RB"
git clone -q "$PB" "$RB" && git -C "$RB" checkout -q "$PF0"
git -C "$RB" fetch -q "file://$AB" refs/tags/android-17.0.0_r2
git -C "$RB" merge --no-commit -q FETCH_HEAD >/dev/null 2>&1
check "MERGE_HEAD isn't the tag object (the case this tests)" '[[ $(git -C "$RB" cat-file -t "$(cat "$RB/.git/MERGE_HEAD")") = tag ]]'
echo "eos on r2" > "$RB/core/main.mk"; git -C "$RB" add -A
mkdir -p "$U/resolutions/build"
run python3 -I "$kit/sources/update.py" resolution "$RB" --out "$U/resolutions/build/make.patch"
check "resolution refused (rc $RC)" '[[ $RC = 0 ]]'
check "its first line isn't 'merge <fork> <r2 commit>'" '[[ $(head -1 "$U/resolutions/build/make.patch") = "merge $PF0 $R2" ]]'
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "build/make's merge isn't [fork, r2]" '[[ $(parents "$(fork_gd build/make)" "$(fork_merge build/make)") = "$PF0 $R2" ]]'
finish
C4ERR=$CERR

# --- 4b. (4a continued) update.conf moves to a newer tag: the resolution is stale -------------------
begin "4b. update.conf moves to a LineageOS manifest naming r3: build/make's resolution (for r2) is stale, not merged at r2"
if [[ -z $C4ERR ]]; then
    R3=$(change "$AB" main "r3: security fix" "echo fixed > core/fix.mk")
    git --git-dir="$AB" tag -a -m r3 android-17.0.0_r3 "$R3"
    C2=$(change "$LOSM" $LB "manifest: r3" "sed -i 's#refs/tags/android-17.0.0_r2#refs/tags/android-17.0.0_r3#' default.xml")
    echo "LINEAGE_MANIFEST=$C2" > "$U/update.conf"
    run plan
    check "plan not CONFLICTS (rc $RC)" '[[ $RC != 0 ]] && grep -q "^UPDATE_PLAN=CONFLICTS " <<<"$OUT"'
    check "build/make isn't a STALE RESOLUTION for r2 into the fork" \
        'grep -qE "^build/make <- .*STALE RESOLUTION: the resolution is for merging ${R2:0:12} into ${PF0:0:12}; the merge now is ${R3:0:12} into ${PF0:0:12}" <<<"$OUT"'
    check "a plan.json was left" '[[ ! -e $PF ]]'
else
    CERR="case 4a failed"
fi
finish

# --- 5. both forks pushed, the manifest refused; LineageOS commits to vendor_lineage; plan again ---
begin "5. manifest refused after both forks pushed; LineageOS commits to vendor_lineage: no second merge, it waits; push OK"
fresh
resolve_fb
VL0=$(tipof "$VL") LVL1=$(tipof "$LVL" $LB)
run plan
check "first plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY (2 forks merged" <<<"$OUT"'
P1_VLM=$(fork_merge vendor/lineage) P1_FBM=$(fork_merge frameworks/base)
hook_on "$MAN"; run push; hook_off "$MAN"
check "the push with the manifest refusing didn't stop after both forks" \
    '[[ $RC != 0 && $(tipof "$VL") = "$P1_VLM" && $(tipof "$FB") = "$P1_FBM" && -z $(tipof "$MAN" "update/$ID") ]]'
LVL2=$(change "$LVL" $LB "config: more" "echo y > config/y.mk")
run plan
check "re-plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY (0 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
check "vendor/lineage isn't pushed before, LineageOS's new commit waiting" \
    'grep -qE "^vendor/lineage <- .*: merged by this update and pushed before \[.*this update.s merge of LineageOS.s ${LVL1:0:12} is in the fork already, pushed before: 1 new commit after it wait for the next update\]" <<<"$OUT"'
check "the count line doesn't say 2 merged and pushed before" 'grep -qE "^-- 0 merged \(0 with conflicts resolved\), 2 merged and pushed before, " <<<"$OUT"'
check "plan.json has forks to merge, or doesn't pin both at their pushed merges" \
    '[[ -z $(pj_forks) && $(pj_pins) = "frameworks/base=$P1_FBM vendor/lineage=$P1_VLM" ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (0 forks pushed now" <<<"$OUT"'
check "vendor_lineage moved off its pushed merge" '[[ $(tipof "$VL") = "$P1_VLM" ]]'
check "update/$ID's message doesn't count 2 merges, 1 resolved, both pushed before" \
    'git --git-dir="$MAN" log -1 --format=%B "update/$ID" | grep -qF "2 of ExpressiveOS'"'"'s forks merge LineageOS'"'"'s commits (1 with conflicts resolved; 2 of them pushed before)"'
finish

# --- 6. a project LineageOS puts back into the default sync -------------------------------------
begin "6. LineageOS drops notdefault from a project ExpressiveOS's manifest left out: added, READY"
fresh
resolve_fb
git init -q --bare "$T/gh/LineageOS/android_external_tool.git"
w=$(mktemp -d "$T/w/d.XXXX"); git -C "$w" init -q -b $LB; echo tool > "$w/tool.c"; git -C "$w" add -A; git -C "$w" commit -qm tool
git -C "$w" push -q "$T/gh/LineageOS/android_external_tool.git" $LB; rm -rf "$w"
TOOL=$(tipof "$T/gh/LineageOS/android_external_tool.git" $LB)
C2=$(change "$LOSM" $LB "add tool, notdefault" "sed -i 's#</manifest>#  <project name=\"LineageOS/android_external_tool\" path=\"external/tool\" groups=\"notdefault,tools\" />\n</manifest>#' snippets/lineage.xml")
# ExpressiveOS's manifest: the last update took C2 (and left external/tool out, as the plan does)
change "$MAN" expressiveos "last update C2" "printf 'UPDATE=2026-10\nLINEAGE_MANIFEST=%s\n' $C2 > last-update.conf" >/dev/null
git -C "$top/.repo/manifests" fetch -q origin && git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
C3=$(change "$LOSM" $LB "tool: default sync" "sed -i 's#groups=\"notdefault,tools\"#groups=\"tools\"#' snippets/lineage.xml")
echo "LINEAGE_MANIFEST=$C3" > "$U/update.conf"
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "no 'added external/tool ..., which LineageOS puts into the default sync now' line" \
    'grep -qF "added external/tool (LineageOS/android_external_tool $LB, ${TOOL:0:12}), which LineageOS puts into the default sync now (groups tools)" <<<"$OUT"'
check "the new manifest doesn't have external/tool at its commit, groups tools" \
    'grep -qE "<project name=\"LineageOS/android_external_tool\" path=\"external/tool\" (remote=\"[a-z]+\" )?revision=\"$TOOL\" upstream=\"refs/heads/$LB\" dest-branch=\"refs/heads/$LB\" groups=\"tools\" />" "$W/updates/$ID/default.xml"'
finish

# --- 7. a complete push, then plan again ----------------------------------------------------------
begin "7. after a complete push, plan again refuses and leaves plan.json, default.xml, kernel.xml; push again OK"
fresh
resolve_fb
run plan
check "plan not READY (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"'
check "the plan made no kernel.xml (the harness moves the kernel)" '[[ -f $W/updates/$ID/kernel.xml ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK" <<<"$OUT"'
k1=$(sha1sum "$W/updates/$ID/kernel.xml" "$W/updates/$ID/default.xml" 2>/dev/null)
run plan
check "plan again didn't refuse (rc $RC)" '[[ $RC != 0 ]] && grep -q "has a branch update/$ID already" <<<"$OUT"'
check "plan again removed the update's files" \
    '[[ -f $PF && $(sha1sum "$W/updates/$ID/kernel.xml" "$W/updates/$ID/default.xml" 2>/dev/null) = "$k1" ]]'
run push
check "push again not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "UPDATE_PUSH=OK (0 forks pushed now, 2 before" <<<"$OUT"'
rm -f "$PF"
run push
check "push without plan.json doesn't name the pushed update's branch" \
    '[[ $RC != 0 ]] && grep -q "no ready plan of update $ID" <<<"$OUT" && grep -q "has a branch update/$ID: then this update was pushed" <<<"$OUT"'
finish

rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
