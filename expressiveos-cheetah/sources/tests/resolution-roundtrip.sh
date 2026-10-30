#!/usr/bin/env bash
# Regression test (resolution-roundtrip): a resolution made by `update.py resolution` from a
# correct hand merge, put into the same merge by plan, gives exactly the hand-resolved tree.
#
#   bash resolution-roundtrip.sh <kit src>
#
# Each case: a fresh test world (harness.sh, next to this script), commits on ExpressiveOS's
# frameworks_base fork and/or LineageOS's android_frameworks_base that make the case, the merge
# done by hand in a clone (git merge --no-commit, fixed, git added), the resolution written with
# update.py resolution --out, then plan (must be READY; refs/eos/frameworks/base/merge in the
# scratch repo must have the hand-resolved tree and the right parents) and push (the fork's
# expressiveos must be that merge). Worlds live in resolution-roundtrip under
# $EOS_TEST_WORK (default $TMPDIR/eos-update-tests), one at a time, and are removed at the end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=$HERE/harness.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/resolution-roundtrip
mkdir -p -- "$(dirname -- "$WD")"   # the harness log goes next to it
LB=lineage-24.0
trap 'rm -rf "$WD"' EXIT

pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { [[ -n ${1:-} ]] && printf '%s\n' "$1" | tail -"${2:-15}" | sed 's/^/    | /'; return 0; }

fresh() {   # a new world (harness.sh rm -rf's it first); sets T kit top G FB LFB U SGD W R
    bash "$HARNESS" "$KSRC" "$WD" >"$WD.harness.log" 2>&1 || { tail -n 20 "$WD.harness.log" >&2; echo "FAIL: harness.sh couldn't build the world"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    FB=$T/gh/ExpressiveOS/frameworks_base.git
    LFB=$T/gh/LineageOS/android_frameworks_base.git
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/2026-11
    SGD=$W/git/frameworks_base.git
    R=$T/w/hand
    RES=$U/resolutions/frameworks/base.patch
}
edit() {    # edit <bare> <branch> <msg> <shell run in a clone>: one commit pushed to branch
    local w
    w=$(mktemp -d "$T/w/e.XXXX")
    git clone -q -b "$2" "$1" "$w" 2>/dev/null
    (cd "$w" && eval "$4") || return 1
    git -C "$w" add -A && git -C "$w" commit -qm "$3" && git -C "$w" push -q origin "$2" || return 1
    rm -rf "$w"
}
base_add() {   # base_add <msg> <shell>: a commit on the merge base (off LineageOS's first commit),
               # merged into LineageOS's branch and into the fork's: the merge base then has it
    local w
    w=$(mktemp -d "$T/w/b.XXXX")
    git clone -q -b $LB "$LFB" "$w" 2>/dev/null
    git -C "$w" checkout -q -b side "$(git -C "$w" rev-list --max-parents=0 HEAD)"
    (cd "$w" && eval "$2") || return 1
    git -C "$w" add -A && git -C "$w" commit -qm "$1" || return 1
    git -C "$w" checkout -q $LB && git -C "$w" merge -q --no-ff -m "Merge $1" side && git -C "$w" push -q origin $LB || return 1
    git -C "$w" fetch -q "$FB" expressiveos && git -C "$w" checkout -q -B eos FETCH_HEAD \
        && git -C "$w" merge -q --no-ff -m "Merge $1" side && git -C "$w" push -q "$FB" eos:expressiveos || return 1
    rm -rf "$w"
}
power() {   # power <file>: the both-changed Power.java conflict fixed by hand, git added
    printf 'class Power {\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}\n' > "$R/$1"
    git -C "$R" add -- "$1"
}
blob() { printf "$1" | git hash-object --stdin; }   # blob <printf format>: its blob id

tree_check() {   # tree_check <git dir> <tree-ish> <spec>...: prints the first spec that fails
    # p=text: file p, that text; p#id: file p, that blob; !p: no p; p/: p a folder
    local gd=$1 t=$2 s p got
    shift 2
    for s in "$@"; do
        case $s in
            !*) p=${s#!}; git --git-dir="$gd" cat-file -e "$t:$p" 2>/dev/null && { echo "$p is there"; return 1; } ;;
            */) p=${s%/}; [[ $(git --git-dir="$gd" cat-file -t "$t:$p" 2>/dev/null) = tree ]] || { echo "$p isn't a folder"; return 1; } ;;
            *#*) p=${s%%#*}; got=$(git --git-dir="$gd" rev-parse -q --verify "$t:$p" 2>/dev/null)
                 [[ $got = "${s#*#}" && $(git --git-dir="$gd" cat-file -t "$t:$p") = blob ]] || { echo "$p is ${got:-none}, not ${s#*#}"; return 1; } ;;
            *=*) p=${s%%=*}; [[ $(git --git-dir="$gd" cat-file -t "$t:$p" 2>/dev/null) = blob ]] || { echo "$p isn't a file"; return 1; }
                 got=$(git --git-dir="$gd" cat-file blob "$t:$p")
                 [[ $got = "${s#*=}" ]] || { echo "$p has '$got', not '${s#*=}'"; return 1; } ;;
        esac
    done
    # never a leftover of git's file/folder conflicts (name~side), nor a conflict marker
    if git --git-dir="$gd" ls-tree -r --name-only "$t" | grep -q '~'; then
        echo "a name~side leftover: $(git --git-dir="$gd" ls-tree -r --name-only "$t" | grep '~' | head -3 | tr '\n' ' ')"; return 1
    fi
    if git --git-dir="$gd" grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$t" -- 2>/dev/null; then
        echo "conflict markers left"; return 1
    fi
    return 0
}

# roundtrip <name> <setup fn> <fix fn> <resolution lines it must have, then --, then tree specs>
roundtrip() {
    local name=$1 setup=$2 fix=$3 lines=() specs=() out rc itree ftip ltip m why l
    shift 3
    while [[ $# -gt 0 && $1 != -- ]]; do lines+=("$1"); shift; done
    [[ ${1:-} = -- ]] && shift
    specs=("$@")
    fresh
    out=$($setup 2>&1) || { bad "$name: test setup failed"; show "$out"; return; }
    ftip=$(git --git-dir="$FB" rev-parse expressiveos)
    ltip=$(git --git-dir="$LFB" rev-parse $LB)
    # the hand merge, as plan's report says to make it
    git clone -q "$G/ExpressiveOS/frameworks_base" "$R" 2>/dev/null
    git -C "$R" checkout -q --detach "$ftip"
    git -C "$R" fetch -q "$G/LineageOS/android_frameworks_base" $LB
    if git -C "$R" merge -q --no-commit "$ltip" >/dev/null 2>&1; then bad "$name: test setup: the merge doesn't conflict"; return; fi
    out=$( (cd "$R" && $fix) 2>&1) || { bad "$name: test's hand fix failed"; show "$out"; return; }
    [[ -z $(git -C "$R" ls-files -u) ]] || { bad "$name: test's hand fix left unmerged files"; show "$(git -C "$R" ls-files -u)"; return; }
    itree=$(git -C "$R" write-tree)
    why=$(tree_check "$R/.git" "$itree" "${specs[@]}") || { bad "$name: test's hand fix isn't the case's: $why"; return; }

    # the resolution
    out=$(python3 -I "$kit/sources/update.py" resolution "$R" --out "$RES" 2>&1); rc=$?
    if [[ $rc -ne 0 || ! -s $RES ]]; then bad "$name: update.py resolution refused a correct hand merge (rc $rc)"; show "$out"; return; fi
    head -1 "$RES" | grep -qx "merge $ftip $ltip" || { bad "$name: resolution's first line isn't 'merge $ftip $ltip': $(head -1 "$RES")"; return; }
    for l in "${lines[@]}"; do
        grep -qxF -- "$l" "$RES" || { bad "$name: the resolution has no line '$l'"; show "$(sed -n '1,/^diff --git/p' "$RES")"; return; }
    done

    # plan: READY, its merge commit exactly the hand-resolved tree
    out=$( (cd "$T" && bash "$kit/sources/update.sh" plan 2026-11 "$top") 2>&1); rc=$?
    if [[ $rc -ne 0 ]] || ! grep -q '^UPDATE_PLAN=READY' <<<"$out"; then
        bad "$name: plan isn't READY (rc $rc)"; show "$(grep -E 'frameworks/base|UPDATE_PLAN|BAD|RESOLUTION' <<<"$out")"; return
    fi
    m=$(git --git-dir="$SGD" rev-parse -q --verify refs/eos/frameworks/base/merge 2>/dev/null)
    [[ -n $m ]] || { bad "$name: no refs/eos/frameworks/base/merge in the scratch repo"; return; }
    [[ $(git --git-dir="$SGD" rev-parse "$m^{tree}") = "$itree" ]] || {
        bad "$name: the plan's merge ${m:0:12} isn't the hand-resolved tree"
        show "$(git --git-dir="$SGD" diff-tree -r --no-renames --stat "$m^{tree}" "$itree" 2>&1)"; return; }
    [[ $(git --git-dir="$SGD" rev-parse "$m^1" "$m^2" 2>/dev/null | tr '\n' ' ') = "$ftip $ltip " ]] || {
        bad "$name: the plan's merge's parents aren't the fork's ${ftip:0:12} and LineageOS's ${ltip:0:12}"; return; }
    [[ $(python3 -I -c 'import json,sys; print(*[f["merge"] for f in json.load(open(sys.argv[1]))["forks"] if f["path"] == "frameworks/base"])' \
         "$W/updates/2026-11/plan.json" 2>/dev/null) = "$m" ]] || { bad "$name: plan.json's frameworks/base merge isn't ${m:0:12}"; return; }

    # push: the fork's expressiveos is that merge
    out=$( (cd "$T" && bash "$kit/sources/update.sh" push 2026-11 "$top") 2>&1); rc=$?
    if [[ $rc -ne 0 ]] || ! grep -q '^UPDATE_PUSH=OK' <<<"$out"; then bad "$name: push failed (rc $rc)"; show "$out"; return; fi
    [[ $(git --git-dir="$FB" rev-parse expressiveos) = "$m" ]] || { bad "$name: the fork's expressiveos isn't the plan's merge after push"; return; }
    why=$(tree_check "$FB" expressiveos "${specs[@]}") || { bad "$name: the pushed fork: $why"; return; }
    git --git-dir="$FB" cat-file blob "expressiveos:$(git --git-dir="$FB" ls-tree -r --name-only expressiveos | grep 'Power.java$' | head -1)" 2>/dev/null \
        | grep -q 'ExpressiveOS took it' || { bad "$name: the pushed fork hasn't the Power.java fix"; return; }
    ok "$name"
}

# --- 1. a clean LineageOS change to another file (README fb -> fb2) put back to the fork's by hand
setup1() { :; }
fix1() { power core/Power.java && git checkout -q HEAD -- README; }
roundtrip "1. clean LineageOS change to README reverted to the fork's by hand" setup1 fix1 \
    "resolved core/Power.java" "changed README" -- "README=fb" "core/Power.java=$(printf 'class Power {\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}')"

# --- 2. a file LineageOS added, deleted by hand
setup2() { edit "$LFB" $LB "LineageOS: New.java" 'printf "class New {}\n" > core/New.java'; }
fix2() { power core/Power.java && git rm -qf core/New.java; }
roundtrip "2. file LineageOS added (core/New.java) deleted by hand" setup2 fix2 \
    "resolved core/Power.java" "changed core/New.java" -- "!core/New.java" "README=fb2"

# --- 3. LineageOS turns README into README/index.md, the fork edited README: keep the fork's
setup3() {
    edit "$FB" expressiveos "fork: README" 'printf "fb eos\n" > README' &&
    edit "$LFB" $LB "LineageOS: README folder" 'git rm -q README && mkdir README && printf "index\n" > README/index.md'
}
fix3() { power core/Power.java && git rm -qrf README && git rm -qrf --ignore-unmatch -- ':(glob)README~*' && git checkout -q HEAD -- README; }
roundtrip "3. README -> README/index.md in LineageOS, fork edited README: fork's README kept" setup3 fix3 \
    "resolved core/Power.java" "changed README" "changed README/index.md" -- "README=fb eos" "!README/index.md"

# --- 4. same, LineageOS's folder kept
fix4() { power core/Power.java && git rm -qrf --ignore-unmatch -- ':(glob)README~*'; }
roundtrip "4. README -> README/index.md in LineageOS, fork edited README: LineageOS's folder kept" setup3 fix4 \
    "resolved core/Power.java" -- "README/" "README/index.md=index"

# --- 5. LineageOS turns folder cfg/ into a file cfg, the fork edited cfg/a: LineageOS's file taken
setup5() {
    base_add "cfg folder" 'mkdir cfg && printf "a\n" > cfg/a && printf "b\n" > cfg/b' &&
    edit "$FB" expressiveos "fork: cfg/a" 'printf "a eos\n" > cfg/a' &&
    edit "$LFB" $LB "LineageOS: cfg a file" 'git rm -rq cfg && printf "cfg file\n" > cfg'
}
fix5() { power core/Power.java && git rm -qrf -- cfg && git rm -qrf --ignore-unmatch -- ':(glob)cfg~*' && git checkout -q MERGE_HEAD -- cfg; }
roundtrip "5. folder cfg/ -> file cfg in LineageOS, fork edited cfg/a: LineageOS's file taken" setup5 fix5 \
    "resolved core/Power.java" "resolved cfg/a" "changed cfg" -- "cfg=cfg file" "!cfg/a" "!cfg/b"

# --- 6. binary conflict: both changed data.bin
setup6() {
    base_add "data.bin" 'printf "BIN\000base\001\n" > data.bin' &&
    edit "$FB" expressiveos "fork: data.bin" 'printf "BIN\000eos\003\n" > data.bin' &&
    edit "$LFB" $LB "LineageOS: data.bin" 'printf "BIN\000los\004\n" > data.bin'
}
fix6a() { power core/Power.java && git checkout -q --ours data.bin && git add data.bin; }
fix6b() { power core/Power.java && git checkout -q --theirs data.bin && git add data.bin; }
roundtrip "6a. binary conflict (data.bin): the fork's side kept" setup6 fix6a \
    "resolved core/Power.java" "resolved data.bin" -- "data.bin#$(blob 'BIN\000eos\003\n')"
roundtrip "6b. binary conflict (data.bin): LineageOS's side taken" setup6 fix6b \
    "resolved core/Power.java" "resolved data.bin" -- "data.bin#$(blob 'BIN\000los\004\n')"

# --- 7. modify/delete: the fork changed README, LineageOS deleted it: the fork's kept
setup7() {
    edit "$FB" expressiveos "fork: README" 'printf "fb eos\n" > README' &&
    edit "$LFB" $LB "LineageOS: no README" 'git rm -q README'
}
fix7() { power core/Power.java && git add README; }
roundtrip "7. modify/delete (fork changed README, LineageOS deleted it): the fork's kept" setup7 fix7 \
    "resolved core/Power.java" "resolved README" -- "README=fb eos"

# --- 8. directory rename: LineageOS renamed core/ to java/, the fork added core/Extra.java
setup8() {
    edit "$FB" expressiveos "fork: Extra.java" 'printf "class Extra {}\n" > core/Extra.java' &&
    edit "$LFB" $LB "LineageOS: core -> java" 'git mv core java'
}
fix8() { power java/Power.java && git add java/Extra.java; }
roundtrip "8. directory rename core/ -> java/ in LineageOS, fork added core/Extra.java: java/Extra.java taken" setup8 fix8 \
    "resolved java/Power.java" "resolved java/Extra.java" -- "java/Extra.java=class Extra {}" "!core" "README=fb2"

# --- 9. the "unresolved" test: unmerged index entries refuse, and nothing is written
fresh
if ! setup6 >/dev/null 2>&1; then
    bad "9. resolution refuses unmerged files: test setup failed"
else
    git clone -q "$G/ExpressiveOS/frameworks_base" "$R" 2>/dev/null
    git -C "$R" checkout -q --detach "$(git --git-dir="$FB" rev-parse expressiveos)"
    git -C "$R" fetch -q "$G/LineageOS/android_frameworks_base" $LB
    git -C "$R" merge -q --no-commit "$(git --git-dir="$LFB" rev-parse $LB)" >/dev/null 2>&1
    power core/Power.java   # data.bin left unmerged (the merge left the fork's bytes in the work tree)
    out=$(python3 -I "$kit/sources/update.py" resolution "$R" --out "$RES" 2>&1); rc=$?
    if [[ $rc -ne 0 && ! -e $RES ]] && grep -q 'still conflicting.*data\.bin' <<<"$out"; then
        ok "9. resolution refuses a clone with data.bin still unmerged, writes nothing"
    else
        bad "9. resolution with data.bin unmerged: rc $rc, file $([[ -e $RES ]] && echo written || echo 'not written')"; show "$out"
    fi
    # --- 10. conflict markers left in a conflicted file, git added: refused, nothing written
    git -C "$R" checkout -q --ours data.bin && git -C "$R" add data.bin
    printf '<<<<<<< HEAD\n  int d = 4;\n=======\n  int d = 40;\n>>>>>>> lineage\n' >> "$R/core/Power.java"
    git -C "$R" add core/Power.java
    rm -f "$RES"
    out=$(python3 -I "$kit/sources/update.py" resolution "$R" --out "$RES" 2>&1); rc=$?
    if [[ $rc -ne 0 && ! -e $RES ]] && grep -q 'still has conflict markers: core/Power.java' <<<"$out"; then
        ok "10. resolution refuses conflict markers left in conflicted core/Power.java, writes nothing"
    else
        bad "10. resolution with markers left in core/Power.java: rc $rc, file $([[ -e $RES ]] && echo written || echo 'not written')"; show "$out"
    fi
fi

rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn -eq 0 ]]
