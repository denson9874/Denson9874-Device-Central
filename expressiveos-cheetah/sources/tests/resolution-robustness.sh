#!/usr/bin/env bash
# Regression test: update.py's resolution and plan stay right whatever git config the machines
# have (colour, diff prefixes, an external diff, merge settings), with non-ASCII file names, refuse
# names a resolution can't hold, the plan's "to resolve it" recipe works as printed, and a
# resolution with colour codes is refused (but not one whose files hold an ESC byte themselves).
#   resolution-robustness.sh <kit src>
# Builds its worlds (harness.sh, one at a time) in resolution-robustness under $EOS_TEST_WORK
# (default $TMPDIR/eos-update-tests) and deletes them at the end.
set -uo pipefail
KSRC=$(cd "${1:?usage: resolution-robustness.sh <kit src>}" && pwd) || exit 2
R=$(cd "$(dirname "$0")" && pwd)
H=$R/harness.sh
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/resolution-robustness
trap 'rm -rf "$WD"' EXIT
pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
# check <name> <reason if not> <command...>: PASS when the command succeeds
check() { local name=$1 why=$2; shift 2; if "$@"; then ok "$name"; else bad "$name ($why)"; fi; }

world() {   # a fresh world (the old one deleted)
    bash "$H" "$KSRC" "$WD" >/dev/null 2>&1 || { bad "harness.sh failed to build a world"; echo "== $pass passed, $failn failed"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    export GIT_CEILING_DIRECTORIES=$T
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/2026-11
    FB=$T/gh/ExpressiveOS/frameworks_base.git
    LFB=$T/gh/LineageOS/android_frameworks_base.git
    O=$T/out
    mkdir -p "$O"
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "${1:-2026-11}" "$top"); }
resolution() { python3 -I "$kit/sources/update.py" resolution "$@"; }
tipof() { git --git-dir="$1" rev-parse "refs/heads/$2"; }

POWER_RES='class Power {\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}\n'
BOTH='one\ntwo both\nthree\n'

# A git config that colours everything, drops or renames diff prefixes and runs an external diff
# (with "merge": diff3 conflict markers, no rename detection; with "dirs": directory renames taken
# silently), in the world's HOME
hostile_on() {
    cp "$HOME/.gitconfig" "$HOME/.gitconfig.clean"
    cat > "$T/extdiff.sh" <<EOF
#!/bin/sh
echo "EXTERNAL DIFF OF \$1"
: > "$T/extdiff.ran"
EOF
    chmod +x "$T/extdiff.sh"
    rm -f "$T/extdiff.ran"
    git config --global color.ui always
    git config --global color.diff always
    git config --global diff.noprefix true
    git config --global diff.mnemonicPrefix true
    git config --global diff.external "$T/extdiff.sh"
    if [[ " $* " = *" merge "* ]]; then
        git config --global merge.conflictStyle diff3
        git config --global merge.renames false
    fi
    if [[ " $* " = *" dirs "* ]]; then
        git config --global merge.directoryRenames true
    fi
}
hostile_off() { mv -f "$HOME/.gitconfig.clean" "$HOME/.gitconfig"; }

handclone() {   # handclone <dir> [<fork> <LineageOS repo>]: the fork (frameworks_base) at its branch's
    # tip, LineageOS's branch merged --no-commit
    local d=$1 f=${2:-frameworks_base} l=${3:-android_frameworks_base}
    rm -rf "$d"
    git clone -q "$G/ExpressiveOS/$f" "$d" 2>/dev/null
    git -C "$d" checkout -q --detach "$(tipof "$T/gh/ExpressiveOS/$f.git" expressiveos)"
    git -C "$d" fetch -q "$G/LineageOS/$l" lineage-24.0
    git -C "$d" merge --no-commit -q FETCH_HEAD >/dev/null 2>&1 || true
}

commit_in() {   # commit_in <bare> <branch> <msg> <shell run in a clone>: one commit pushed
    local w
    w=$(mktemp -d "$T/w/c.XXXX")
    git clone -q -b "$2" "$1" "$w"
    (cd "$w" && eval "$4")
    git -C "$w" add -A && git -C "$w" commit -qm "$3" && git -C "$w" push -q origin "$2"
    rm -rf "$w"
}

both_change() {   # both_change <file>...: frameworks/base gets the files on a side commit off LineageOS's
    # first commit, merged into LineageOS's branch and into the fork's; then each side changes them
    local w=$T/w/bc f i
    rm -rf "$w"
    git clone -q -b lineage-24.0 "$LFB" "$w"
    i=$(git -C "$w" rev-list --max-parents=0 HEAD)
    git -C "$w" checkout -q -b side "$i"
    for f in "$@"; do mkdir -p "$w/$(dirname "$f")"; printf 'one\ntwo\nthree\n' > "$w/$f"; done
    git -C "$w" add -A && git -C "$w" commit -qm "add files"
    git -C "$w" checkout -q lineage-24.0
    git -C "$w" merge -q --no-edit side
    for f in "$@"; do printf 'one\ntwo LineageOS\nthree\n' > "$w/$f"; done
    git -C "$w" commit -qam "LineageOS: change them" && git -C "$w" push -q origin lineage-24.0
    git -C "$w" fetch -q "$FB" expressiveos
    git -C "$w" checkout -q -b eos FETCH_HEAD
    git -C "$w" merge -q --no-edit side
    for f in "$@"; do printf 'one\ntwo ExpressiveOS\nthree\n' > "$w/$f"; done
    git -C "$w" commit -qam "ExpressiveOS: change them" && git -C "$w" push -q "$FB" eos:expressiveos
    rm -rf "$w"
}

fork_of_plan() {   # fork_of_plan <path>: sets gd tip up m from plan.json's fork (x when none)
    local l
    l=$(python3 -I - "$W/updates/2026-11/plan.json" "$1" 2>/dev/null <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
f = [f for f in d["forks"] if f["path"] == sys.argv[2]][0]
print(f["gd"], f["tip"], f["up"], f["merge"])
EOF
)
    read -r gd tip up m <<<"${l:-x x x x}"
}
# blob_is <rev> <file> <printf format>: file in rev of the plan's scratch repo ($gd) is exactly that
blob_is() {
    git --git-dir="$gd" cat-file blob "$1:$2" > "$O/got" 2>/dev/null || return 1
    printf "$3" > "$O/want"
    cmp -s "$O/got" "$O/want"
}
has_file() { git --git-dir="$gd" ls-tree -r -z --name-only "$1" 2>/dev/null | grep -qzxF -- "$2"; }
parents_are() { [[ "$(git --git-dir="$gd" rev-parse "$1^1" "$1^2" 2>/dev/null | tr '\n' ' ')" = "$2 $3 " ]]; }
no_esc() { ! grep -q $'\x1b' "$@"; }
lines() { grep -aE "$1" "$2" 2>/dev/null | head -"${3:-6}" | tr '\n' '|'; }

# --- 1. the resolution's machine colours diffs, drops/renames prefixes and has an external diff
world
F=$(tipof "$FB" expressiveos); L=$(tipof "$LFB" lineage-24.0)
hostile_on
handclone "$T/w/r1"
printf "$POWER_RES" > "$T/w/r1/core/Power.java"
git -C "$T/w/r1" add core/Power.java
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r1" --out "$out" > "$O/res1" 2>&1; rc=$?
resolution "$T/w/r1" > "$O/res1.stdout" 2> "$O/res1.stderr"; rc2=$?
ext_ran=no; [[ -e $T/extdiff.ran ]] && ext_ran=yes
hostile_off
check "1: resolution under a colouring/noprefix/external-diff git config succeeds" "rc $rc: $(tail -3 "$O/res1" | tr '\n' ' ')" \
    test "$rc" = 0 -a -f "$out"
check "1: the resolution has no colour codes" "ESC bytes in it" no_esc "$out"
c1_head() { [[ "$(head -2 "$out" | tr '\n' '|')" = "merge $F $L|resolved core/Power.java|" ]]; }
check "1: the resolution starts with the merge and its conflicting file" "$(head -3 "$out" 2>/dev/null | tr '\n' '|')" c1_head
c1_diff() {
    grep -qxF 'diff --git a/core/Power.java b/core/Power.java' "$out" \
        && grep -qxF '+  int b = 200; // LineageOS, ExpressiveOS took it' "$out" && ! grep -q 'EXTERNAL DIFF' "$out"
}
check "1: the resolution's diff is git's own (a/ b/ prefixes) with the fixed line" "$(lines '^(diff|EXTERNAL|[-+]  int b)' "$out")" c1_diff
check "1: the external diff never ran" "diff.external's script ran during resolution" test "$ext_ran" = no
check "1: the printed resolution is --out's" "rc $rc2, or it differs" bash -c "test $rc2 = 0 && cmp -s '$out' '$O/res1.stdout'"
plan > "$O/plan1" 2>&1; rc=$?
check "1: plan with that resolution: READY" "rc $rc: $(lines 'UPDATE_PLAN|BAD|STALE|^frameworks' "$O/plan1")" \
    grep -q '^UPDATE_PLAN=READY (2 forks merged' "$O/plan1"
fork_of_plan frameworks/base
check "1: the plan's merge of frameworks/base is on the fork's tip and LineageOS's" "merge $m" parents_are "$m" "$F" "$L"
check "1: the plan's merge has the hand-resolved core/Power.java (not the fork's)" \
    "has: $(git --git-dir="$gd" cat-file blob "$m:core/Power.java" 2>/dev/null | grep 'int b')" \
    blob_is "$m" core/Power.java "$POWER_RES"

# --- 2. the same config, plus diff3 markers and no rename detection, on the server (the plan's HOME)
world
# The fork renamed frameworks/base's README and vendor/lineage's config/x.mk; LineageOS changed
# both. Merged with rename detection: clean, LineageOS's change in the renamed file
commit_in "$FB" expressiveos "fork: rename README" 'git mv README README.eos'
commit_in "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos "fork: rename x.mk" 'git mv config/x.mk config/xx.mk'
commit_in "$T/gh/LineageOS/android_vendor_lineage.git" lineage-24.0 "LineageOS: x.mk" 'echo "x los" > config/x.mk'
F=$(tipof "$FB" expressiveos); L=$(tipof "$LFB" lineage-24.0)
VF=$(tipof "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos); VL=$(tipof "$T/gh/LineageOS/android_vendor_lineage.git" lineage-24.0)
hostile_on merge
plan > "$O/plan2a" 2>&1; rc=$?
hostile_off
c2_conflicts() {
    grep -q '^UPDATE_PLAN=CONFLICTS (1 forks merged, 1 need a resolution' "$O/plan2a" \
        && grep -q '^frameworks/base <- .*UNRESOLVED (conflicts in 1 file)' "$O/plan2a" \
        && grep -qxF '== frameworks/base/core/Power.java: both changed it' "$O/plan2a" \
        && grep -q '^vendor/lineage <- .*2 new commits.*merge [0-9a-f]' "$O/plan2a"
}
check "2: server config, no resolution yet: CONFLICTS, in frameworks/base's core/Power.java only" \
    "rc $rc: $(lines '^(frameworks/base|vendor/lineage) <-|^== frameworks|^UPDATE_PLAN' "$O/plan2a")" c2_conflicts
c2_shown() { no_esc "$O/plan2a" && grep -q '^ *[0-9]* ||||||| ' "$O/plan2a"; }
check "2: server config: the conflict is shown without colour codes, with zdiff3's base lines" "$(lines '\|\|\|\|\|\|\||<<<<<<<' "$O/plan2a")" c2_shown
handclone "$T/w/r2"
printf "$POWER_RES" > "$T/w/r2/core/Power.java"
git -C "$T/w/r2" add core/Power.java
resolution "$T/w/r2" --out "$U/resolutions/frameworks/base.patch" > "$O/res2" 2>&1 || echo "    (resolution failed: $(tail -1 "$O/res2"))"
hostile_on merge
plan > "$O/plan2" 2>&1; rc=$?
hostile_off
check "2: server config: plan READY" "rc $rc: $(lines 'UPDATE_PLAN|BAD|STALE|UNRESOLVED|^frameworks|^vendor' "$O/plan2")" \
    grep -q '^UPDATE_PLAN=READY (2 forks merged' "$O/plan2"
check "2: server config: plan's output has no colour codes" "ESC bytes in it" no_esc "$O/plan2"
fork_of_plan frameworks/base
check "2: frameworks/base's merge is on the fork's tip and LineageOS's" "merge $m" parents_are "$m" "$F" "$L"
check "2: frameworks/base's merge has the hand-resolved core/Power.java" "merge $m" blob_is "$m" core/Power.java "$POWER_RES"
c2_readme() { blob_is "$m" README.eos 'fb2\n' && ! has_file "$m" README; }
check "2: frameworks/base's merge: LineageOS's README change in the fork's renamed README.eos" \
    "README.eos: $(git --git-dir="$gd" cat-file blob "$m:README.eos" 2>/dev/null); README there: $(has_file "$m" README && echo yes || echo no)" c2_readme
fork_of_plan vendor/lineage
c2_vendor() { parents_are "$m" "$VF" "$VL" && blob_is "$m" config/xx.mk 'x los\n' && ! has_file "$m" config/x.mk; }
check "2: vendor/lineage's clean merge: LineageOS's x.mk change in the fork's renamed config/xx.mk" "merge $m" c2_vendor

# --- 2b. the server takes directory renames silently (merge.directoryRenames=true): the plan still
# merges as git's default does, as the resolution's machine did (a conflict where LineageOS added a
# file in a folder the fork renamed)
world
LS=$T/gh/LineageOS/android_packages_apps_Settings.git FS=$T/gh/ExpressiveOS/packages_apps_Settings.git
w=$T/w/s
git clone -q -b lineage-24.0 "$LS" "$w"
git -C "$w" checkout -q -b side "$(git -C "$w" rev-list --max-parents=0 HEAD)"
mkdir "$w/res" && printf 'a1\na2\na3\n' > "$w/res/a.xml" && printf 'b1\nb2\nb3\n' > "$w/res/b.xml"
git -C "$w" add -A && git -C "$w" commit -qm "res"
git -C "$w" checkout -q lineage-24.0 && git -C "$w" merge -q --no-edit side
printf 'c1\nc2\n' > "$w/res/c.xml"
git -C "$w" add -A && git -C "$w" commit -qm "LineageOS: res/c.xml" && git -C "$w" push -q origin lineage-24.0
git -C "$w" fetch -q "$FS" expressiveos && git -C "$w" checkout -q -b eos FETCH_HEAD && git -C "$w" merge -q --no-edit side
git -C "$w" mv res res_eos && git -C "$w" commit -qm "fork: res -> res_eos" && git -C "$w" push -q "$FS" eos:expressiveos
SF=$(tipof "$FS" expressiveos); SL=$(tipof "$LS" lineage-24.0)
hostile_on merge dirs
plan > "$O/plan2ba" 2>&1; rc=$?
hostile_off
c2b_conflict() {
    grep -q '^packages/apps/Settings <- .*UNRESOLVED (conflicts in 1 file)' "$O/plan2ba" \
        && grep -q '^== packages/apps/Settings/res_eos/c.xml: ' "$O/plan2ba"
}
check "2b: server takes directory renames: packages/apps/Settings still conflicts in res_eos/c.xml, as git's default" \
    "rc $rc: $(lines '^packages/apps/Settings <-|^== packages|^UPDATE_PLAN' "$O/plan2ba")" c2b_conflict
handclone "$T/w/r2bf"
printf "$POWER_RES" > "$T/w/r2bf/core/Power.java"
git -C "$T/w/r2bf" add core/Power.java
resolution "$T/w/r2bf" --out "$U/resolutions/frameworks/base.patch" > "$O/res2bf" 2>&1 || echo "    (frameworks/base's resolution failed: $(tail -1 "$O/res2bf"))"
handclone "$T/w/r2b" packages_apps_Settings android_packages_apps_Settings
git -C "$T/w/r2b" add -A
resolution "$T/w/r2b" --out "$U/resolutions/packages/apps/Settings.patch" > "$O/res2b" 2>&1; rc=$?
check "2b: resolution of that merge (res_eos/c.xml kept where the merge put it)" "rc $rc: $(tail -2 "$O/res2b" | tr '\n' ' ')" \
    grep -qx 'resolved res_eos/c.xml' "$U/resolutions/packages/apps/Settings.patch"
hostile_on merge dirs
plan > "$O/plan2b" 2>&1; rc=$?
hostile_off
check "2b: server takes directory renames: plan with the resolutions READY" \
    "rc $rc: $(lines 'UPDATE_PLAN|BAD|STALE|UNUSED|^packages|^frameworks' "$O/plan2b")" \
    grep -q '^UPDATE_PLAN=READY (3 forks merged' "$O/plan2b"
fork_of_plan packages/apps/Settings
c2b_tree() { parents_are "$m" "$SF" "$SL" && blob_is "$m" res_eos/c.xml 'c1\nc2\n' && ! has_file "$m" res/c.xml; }
check "2b: Settings' merge has LineageOS's res/c.xml at res_eos/c.xml" "merge $m" c2b_tree

# --- 3. a conflict in a non-ASCII file name
world
both_change "core/Größe.txt"
plan > "$O/plan3a" 2>&1; rc=$?
c3_shown() {
    grep -q '^UPDATE_PLAN=CONFLICTS' "$O/plan3a" && grep -qxF '== frameworks/base/core/Größe.txt: both changed it' "$O/plan3a" \
        && grep -q '^frameworks/base <- .*UNRESOLVED (conflicts in 2 files)' "$O/plan3a" \
        && ! grep -qF -e '\303' -e '"core/Gr' "$O/plan3a" && ! grep -q Traceback "$O/plan3a"
}
check "3: plan shows core/Größe.txt's conflict, its name unquoted" \
    "rc $rc: $(lines '^== frameworks/base/|^frameworks/base <-|Traceback|^UPDATE_PLAN|303' "$O/plan3a")" c3_shown
handclone "$T/w/r3"
printf "$POWER_RES" > "$T/w/r3/core/Power.java"
printf "$BOTH" > "$T/w/r3/core/Größe.txt"
git -C "$T/w/r3" add -A
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r3" --out "$out" > "$O/res3" 2>&1; rc=$?
check "3: resolution of a merge conflicting in core/Größe.txt works" "rc $rc: $(tail -3 "$O/res3" | tr '\n' ' ')" test "$rc" = 0 -a -f "$out"
c3_names() { grep -qxF 'resolved core/Größe.txt' "$out" && grep -qxF 'diff --git a/core/Größe.txt b/core/Größe.txt' "$out"; }
check "3: the resolution names core/Größe.txt as it is" "$(lines '^(resolved|diff --git)' "$out")" c3_names
plan > "$O/plan3" 2>&1; rc=$?
check "3: plan with that resolution: READY" "rc $rc: $(lines 'UPDATE_PLAN|BAD|STALE|^frameworks' "$O/plan3")" \
    grep -q '^UPDATE_PLAN=READY (2 forks merged' "$O/plan3"
fork_of_plan frameworks/base
c3_tree() { has_file "$m" 'core/Größe.txt' && blob_is "$m" 'core/Größe.txt' "$BOTH" && blob_is "$m" core/Power.java "$POWER_RES"; }
check "3: the merged tree has core/Größe.txt with the resolved content (and Power.java's)" \
    "merge $m: $(git --git-dir="$gd" ls-tree -r --name-only "$m" core 2>/dev/null | tr '\n' ' ')" c3_tree

# --- 4. a conflict in a file whose name has a double quote: resolution refuses, clearly
world
both_change 'core/say"hi".txt'
plan > "$O/plan4" 2>&1; rc=$?
c4_plan() { grep -q '^UPDATE_PLAN=CONFLICTS' "$O/plan4" && ! grep -q Traceback "$O/plan4"; }
check "4: plan shows the conflicts (no traceback)" "rc $rc: $(lines 'Traceback|^UPDATE_PLAN' "$O/plan4")" c4_plan
handclone "$T/w/r4"
printf "$POWER_RES" > "$T/w/r4/core/Power.java"
printf "$BOTH" > "$T/w/r4/core/say\"hi\".txt"
git -C "$T/w/r4" add -A
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r4" --out "$out" > "$O/res4" 2>&1; rc=$?
c4_refused() {
    [[ $rc != 0 ]] && grep -q "^FAIL: file names a resolution can't hold" "$O/res4" && grep -qF '"core/say\"hi\".txt"' "$O/res4" \
        && ! grep -q Traceback "$O/res4" && [[ ! -e $out ]]
}
check "4: resolution refuses a name with a double quote, saying which; no traceback, nothing written" \
    "rc $rc: $(head -c 600 "$O/res4" | tr '\n' ' ')" c4_refused

# --- 4b. the same for names with a backslash and a tab
world
both_change 'core/back\slash.txt' $'core/tab\tname.txt'
handclone "$T/w/r4b"
printf "$POWER_RES" > "$T/w/r4b/core/Power.java"
printf "$BOTH" > "$T/w/r4b/core/back\\slash.txt"
printf "$BOTH" > "$T/w/r4b/core/tab"$'\t'"name.txt"
git -C "$T/w/r4b" add -A
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r4b" --out "$out" > "$O/res4b" 2>&1; rc=$?
c4b_refused() {
    [[ $rc != 0 ]] && grep -q "^FAIL: file names a resolution can't hold" "$O/res4b" && grep -qF 'back\\slash' "$O/res4b" \
        && grep -qF 'tab\tname' "$O/res4b" && ! grep -q Traceback "$O/res4b" && [[ ! -e $out ]]
}
check "4b: resolution refuses names with a backslash and a tab, naming both; no traceback, nothing written" \
    "rc $rc: $(head -c 600 "$O/res4b" | tr '\n' ' ')" c4b_refused

# --- 5. the plan's "to resolve it" lines (README step 4), run as printed, no mkdir first
world
F=$(tipof "$FB" expressiveos); L=$(tipof "$LFB" lineage-24.0)
plan > "$O/plan5a" 2>&1
awk '/^    to resolve it, in a clone/ {n = 6; next} n > 0 {print substr($0, 7); n--}' "$O/plan5a" > "$O/recipe"
c5_readme() {
    python3 -I - "$kit/README.md" "$O/recipe" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
step = text.split("### 4. Resolving a conflict", 1)[1]
block = step.split("```bash\n", 1)[1].split("```", 1)[0].strip("\n").split("\n")
got = open(sys.argv[2], encoding="utf-8").read().strip("\n").split("\n")
def rx(line):
    line = line.replace("https://github.com/", "<host>/")
    return "".join(".+" if re.fullmatch(r"<[^>]+>", p) else re.escape(p) for p in re.split(r"(<[^>]+>)", line))
ok = len(block) == len(got) == 6 and all(re.fullmatch(rx(b), g) for b, g in zip(block, got))
ok = ok and got[5].endswith(" --out <kit>/sources/updates/2026-11/resolutions/frameworks/base.patch")
sys.exit(0 if ok else 1)
EOF
}
check "5: the plan prints README step 4's recipe, filled in" "$(tr '\n' '|' < "$O/recipe")" c5_readme
had=no; [[ -e $U/resolutions ]] && had=yes
{
    sed -n '1,4p' "$O/recipe"
    echo "printf '$POWER_RES' > core/Power.java"
    echo "git add core/Power.java"
    sed -n '6p' "$O/recipe" | sed "s#<kit>#$kit#g"
} > "$O/recipe.sh"
mkdir -p "$T/w/r5"
(cd "$T/w/r5" && bash "$O/recipe.sh") > "$O/run5" 2>&1; rc=$?
out=$U/resolutions/frameworks/base.patch
c5_written() { [[ $rc = 0 && $had = no && -f $out ]] && grep -qx 'resolved core/Power.java' "$out"; }
check "5: the recipe, run as printed, writes the resolution (its folders made)" \
    "rc $rc, resolutions/ there before: $had: $(tail -3 "$O/run5" | tr '\n' ' ')" c5_written
c5_clone() { [[ "$(git -C "$T/w/r5/frameworks_base" rev-parse HEAD MERGE_HEAD 2>/dev/null | tr '\n' ' ')" = "$F $L " ]]; }
check "5: the recipe's clone is the fork's commit with LineageOS's merging" "HEAD/MERGE_HEAD not the plan's" c5_clone
plan > "$O/plan5" 2>&1; rc=$?
check "5: next plan READY" "rc $rc: $(lines 'UPDATE_PLAN|BAD|STALE|^frameworks' "$O/plan5")" \
    grep -q '^UPDATE_PLAN=READY (2 forks merged' "$O/plan5"
fork_of_plan frameworks/base
c5_merge() { parents_are "$m" "$F" "$L" && blob_is "$m" core/Power.java "$POWER_RES"; }
check "5: the plan's merge has the hand-resolved core/Power.java" "merge $m" c5_merge

# --- 6. a resolution with terminal colour codes (its diff made by git diff with colour on) is refused
world
F=$(tipof "$FB" expressiveos)
handclone "$T/w/r6"
printf "$POWER_RES" > "$T/w/r6/core/Power.java"
git -C "$T/w/r6" add core/Power.java
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r6" --out "$out" > "$O/res6" 2>&1
{ sed '/^$/q' "$out"; git -C "$T/w/r6" diff --cached --color=always --binary "$F" -- core/Power.java; } > "$O/coloured"
cp "$O/coloured" "$out"
plan > "$O/plan6" 2>&1; rc=$?
c6_refused() {
    [[ $rc != 0 ]] && grep -q $'\x1b' "$out" && grep -q 'resolutions/frameworks/base.patch: has terminal colour codes' "$O/plan6" \
        && ! grep -q Traceback "$O/plan6" && [[ ! -e $W/updates/2026-11/plan.json ]]
}
check "6: plan refuses a resolution with colour codes, saying so; no traceback, no plan" \
    "rc $rc: $(lines 'colour|Traceback|UPDATE_PLAN|^FAIL' "$O/plan6")" c6_refused

# --- 6b. ... but a resolution of a text file that holds an ESC byte itself (a string constant) is made and taken
world
commit_in "$FB" expressiveos "fork: red" \
    "printf 'class Power {\n  String red = \"\\033[31m\";\n  int a = 1;\n  int b = 20; // ExpressiveOS\n  int c = 3;\n}\n' > core/Power.java"
F=$(tipof "$FB" expressiveos); L=$(tipof "$LFB" lineage-24.0)
RED_RES='class Power {\n  String red = "\033[31m";\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}\n'
handclone "$T/w/r6b"
printf "$RED_RES" > "$T/w/r6b/core/Power.java"
git -C "$T/w/r6b" add core/Power.java
out=$U/resolutions/frameworks/base.patch
resolution "$T/w/r6b" --out "$out" > "$O/res6b" 2>&1; rc=$?
check "6b: resolution of a conflict in a file holding a raw ESC byte (unchanged, near the fix) is made" \
    "rc $rc: $(tail -2 "$O/res6b" | tr '\n' ' ')" test "$rc" = 0 -a -f "$out"
plan > "$O/plan6b" 2>&1; rc=$?
fork_of_plan frameworks/base
c6b_taken() { grep -q '^UPDATE_PLAN=READY' "$O/plan6b" && parents_are "$m" "$F" "$L" && blob_is "$m" core/Power.java "$RED_RES"; }
check "6b: ... and the plan takes it: READY, the merge has the resolved file, ESC byte and all" \
    "rc $rc: $(lines 'colour|UPDATE_PLAN|^FAIL' "$O/plan6b")" c6b_taken

rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
