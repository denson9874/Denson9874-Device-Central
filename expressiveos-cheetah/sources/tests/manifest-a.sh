#!/usr/bin/env bash
# Regression test (manifest-a): plan's "ExpressiveOS's manifest" section, for LineageOS's
# manifest changes to groups (notdefault), linkfiles/copyfiles and clone-depth, on forks and on
# LineageOS's own projects.
#
#   bash manifest-a.sh <kit src>
#
# Fixed behaviour checked:
#  a. notdefault: a project LineageOS adds outside repo's default sync is left out; one LineageOS
#     takes out of the default sync is removed (a non-fork) or stays in it (a fork: the rest of
#     LineageOS's groups change taken, and a note); the new manifest's check (manifest_problems)
#     refuses any notdefault project.
#  b. forks: LineageOS's groups and linkfile/copyfile changes since the base go into the fork's
#     line, clone-depth doesn't; a fork LineageOS dropped gets a note in "Needs a look".
#  c. groups and linkfiles/copyfiles merge element by element (ExpressiveOS's own entries kept,
#     LineageOS's additions and removals taken); two kids making the same dest are a problem.
# Outcomes are checked in the repos: the plan's manifest commit (refs/eos/update/<id> in the work
# folder's eos.git), updates/<id>/default.xml and plan.json, and, after push, the update/<id>
# branch of the file:// repo standing in for GitHub's manifest (and the forks' branches).
#
# Each case builds a fresh world with harness.sh (next to this script) in manifest-a under
# $EOS_TEST_WORK (default $TMPDIR/eos-update-tests), one at a time; it is removed at the end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS=$HERE/harness.sh
RESOLVE=$HERE/t-resolve.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/manifest-a
mkdir -p -- "$(dirname -- "$WD")"   # the harness log goes next to it
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
check() {   # check <reason> <bash test, eval'd>: records reason if the test fails (first one only;
            # MA_ALL=1 in the environment runs the later checks too and prints theirs)
    if [[ -n $CERR ]]; then
        [[ -n ${MA_ALL:-} ]] && ! eval "$2" && echo "    (also) $1"
        return 1
    fi
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
fresh() {   # a new world with frameworks/base's conflict resolved; sets T kit top G C0 C1 LOSM MAN FB VL MGD W U PF NEW GHX
    bash "$HARNESS" "$KSRC" "$WD" >"$WD.harness.log" 2>&1 || { tail -n 20 "$WD.harness.log" >&2; echo "FAIL: harness.sh couldn't build the world"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/env.sh"
    bash "$RESOLVE" "$WD" >/dev/null 2>&1 || { echo "FAIL: couldn't make frameworks/base's resolution"; exit 1; }
    LOSM=$T/gh/LineageOS/android.git
    MAN=$T/gh/ExpressiveOS/manifest.git
    FB=$T/gh/ExpressiveOS/frameworks_base.git
    VL=$T/gh/ExpressiveOS/vendor_lineage.git
    W=$HOME/expressiveos-update
    MGD=$W/manifests/eos.git
    U=$kit/sources/updates/$ID
    PF=$W/updates/$ID/plan.json
    NEW=$T/w/new.xml      # the plan's manifest commit's default.xml
    GHX=$T/w/gh.xml       # GitHub's update/<id> default.xml, after push
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "$ID" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "$ID" "$top"); }
tipof() { git --git-dir="$1" rev-parse -q --verify "refs/heads/${2:-expressiveos}" 2>/dev/null; }
take() { echo "LINEAGE_MANIFEST=$1" > "$U/update.conf"; }   # take <LineageOS manifest commit>: this update's

edit_repo() {   # edit_repo <bare> <branch> <msg> <file> <python over t, with rep(a, b)> [<extra file>=<content>]: one commit; prints it
    local bare=$1 br=$2 msg=$3 file=$4 code=$5 w fc
    w=$(mktemp -d "$T/w/e.XXXX")
    git clone -q -b "$br" "$bare" "$w" || return 1
    python3 -I - "$w/$file" "$code" <<'PY' || return 1
import sys
f, code = sys.argv[1], sys.argv[2]
t = open(f).read()
def rep(a, b):
    global t
    if t.count(a) != 1:
        raise SystemExit(f"edit: {a!r} is in {f} {t.count(a)} times")
    t = t.replace(a, b)
exec(code)
open(f, "w").write(t)
PY
    shift 5
    for fc in "$@"; do printf '%s\n' "${fc#*=}" > "$w/${fc%%=*}"; done
    git -C "$w" add -A && git -C "$w" commit -qm "$msg" && git -C "$w" push -q origin "$br" || return 1
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
los_edit() { edit_repo "$LOSM" $LB "$@"; }   # los_edit <msg> <file> <python>: LineageOS's manifest
eos_edit() {   # eos_edit <msg> <python over default.xml> [<file>=<content>]: GitHub's ExpressiveOS manifest, and the tree onto it
    edit_repo "$MAN" expressiveos "$1" default.xml "$2" "${@:3}" >/dev/null || return 1
    tree_sync_manifest
}
tree_sync_manifest() {   # the tree's manifest checkout onto GitHub's, and objects for every project
    git -C "$top/.repo/manifests" fetch -q origin
    git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
    python3 -I - "$top/.repo/manifests/default.xml" "$T" <<'PY' | while read -r path url; do [[ -d $top/.repo/projects/$path.git ]] || git clone -q --bare "$url" "$top/.repo/projects/$path.git"; done
import sys, urllib.parse, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
rem = {e.get("name"): e.get("fetch") for e in r.iter("remote")}
d = r.find("default")
base = "file://" + sys.argv[2] + "/gh/ExpressiveOS/manifest"
for p in r.iter("project"):
    f = urllib.parse.urljoin(base, rem[p.get("remote") or d.get("remote")]).rstrip("/")
    print(p.get("path") or p.get("name"), f + "/" + p.get("name"))
PY
}

# --- what the plan made ---------------------------------------------------------------------------
pj_commit() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["manifest_commit"])' "$PF" 2>/dev/null; }
new_manifest() {   # the plan's manifest commit's default.xml -> $NEW; true when that commit is there, on GitHub's
                   # expressiveos, is plan.json's, and its default.xml is updates/<id>/default.xml
    local c
    c=$(git --git-dir="$MGD" rev-parse -q --verify "refs/eos/update/$ID^{commit}" 2>/dev/null) || return 1
    [[ $(git --git-dir="$MGD" rev-parse -q --verify "$c^" 2>/dev/null) = "$(tipof "$MAN")" && $(pj_commit) = "$c" ]] || return 1
    git --git-dir="$MGD" show "$c:default.xml" > "$NEW" 2>/dev/null && cmp -s "$NEW" "$W/updates/$ID/default.xml"
}
no_manifest() {   # nothing made: no plan.json, no updates/<id>/default.xml, no refs/eos/update/<id>
    [[ ! -e $PF && ! -e $W/updates/$ID/default.xml ]] && ! git --git-dir="$MGD" rev-parse -q --verify "refs/eos/update/$ID" >/dev/null 2>&1
}
gh_manifest() {   # after push: GitHub's update/<id> default.xml -> $GHX; true when the branch is the plan's commit
    [[ -n $(pj_commit) && $(tipof "$MAN" "update/$ID") = "$(pj_commit)" ]] || return 1
    git --git-dir="$MAN" show "update/$ID:default.xml" > "$GHX" 2>/dev/null && cmp -s "$GHX" "$NEW"
}
mq() {   # mq <manifest file> <path> <what>: has (0/1) | groups | depth | kids | line | rev | paths (any path)
    python3 -I - "$@" <<'PY'
import sys, xml.etree.ElementTree as ET
f, path, what = sys.argv[1:4]
t = open(f).read()
r = ET.fromstring(t)
ps = [p for p in r.iter("project") if (p.get("path") or p.get("name")) == path]
if what == "paths":
    print(" ".join(sorted(p.get("path") or p.get("name") for p in r.iter("project"))))
elif what == "has":
    print(len(ps))
elif len(ps) != 1:
    print(f"<{path}: {len(ps)} times>")
elif what == "groups":
    print(ps[0].get("groups", "-"))
elif what == "depth":
    print(ps[0].get("clone-depth", "-"))
elif what == "rev":
    print(ps[0].get("revision", "-"))
elif what == "kids":
    print(" ".join(f"{k.tag}:{k.get('src')}>{k.get('dest')}" for k in ps[0]))
elif what == "line":
    # the project's text: its line, and its kids' lines up to </project>
    lines = t.split("\n")
    i = next(n for n, l in enumerate(lines) if l.startswith("  <project ") and (f' path="{path}"' in l or f' name="{path}"' in l and ' path="' not in l))
    j = i if lines[i].endswith("/>") else lines.index("  </project>", i)
    print("\n".join(lines[i:j + 1]))
PY
}
needs_a_look() {   # the plan output's "Needs a look" section
    sed -n '/^== Needs a look/,/^\(== \|report: \)/p' <<<"$OUT" | grep -v '^== \|^report: '
}
ready() { [[ $RC = 0 ]] && grep -q "^UPDATE_PLAN=READY " <<<"$OUT"; }
not_ready() { [[ $RC != 0 ]] && grep -q "^UPDATE_PLAN=NOT_READY " <<<"$OUT"; }

# --- 1. LineageOS adds a notdefault project: left out ----------------------------------------------
begin "1. LineageOS adds prebuilts/go/darwin-x86 with groups notdefault,platform-darwin: left out, READY, not in default.xml"
fresh
git init -q --bare "$T/aosp/platform/prebuilts/go/darwin-x86.git"
w=$(mktemp -d "$T/w/d.XXXX"); git -C "$w" init -q -b main; echo go > "$w/go"; git -C "$w" add -A; git -C "$w" commit -qm go
git -C "$w" push -q "$T/aosp/platform/prebuilts/go/darwin-x86.git" main; rm -rf "$w"
git --git-dir="$T/aosp/platform/prebuilts/go/darwin-x86.git" tag -a -m r2 android-17.0.0_r2 main
C2=$(los_edit "add darwin go" default.xml 'rep("</manifest>", "  <project path=\"prebuilts/go/darwin-x86\" name=\"platform/prebuilts/go/darwin-x86\" groups=\"notdefault,platform-darwin,darwin,pdk\" clone-depth=\"1\" remote=\"aosp\" />\n</manifest>")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
run plan
check "plan not READY (rc $RC)" 'ready'
check "no 'left out' line for prebuilts/go/darwin-x86" \
    "grep -qE \"^LineageOS added prebuilts/go/darwin-x86 \\(platform/prebuilts/go/darwin-x86\\) outside repo's default sync .*: left out\" <<<\"\$OUT\""
check "plan says it added prebuilts/go/darwin-x86" '! grep -q "^added prebuilts/go/darwin-x86" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "the new default.xml has prebuilts/go/darwin-x86" '[[ $(mq "$NEW" prebuilts/go/darwin-x86 has) = 0 ]]'
check "the new default.xml has a notdefault group" '! grep -q notdefault "$NEW"'
check "the new default.xml lacks external/new (LineageOS's other addition, default sync)" '[[ $(mq "$NEW" external/new has) = 1 ]]'
check "no plan.json" '[[ -s $PF ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
check "GitHub's update/$ID has prebuilts/go/darwin-x86" '[[ $(mq "$GHX" prebuilts/go/darwin-x86 has) = 0 ]]'
finish

# --- 2. LineageOS adds notdefault to a non-fork's groups: removed ----------------------------------
begin "2. LineageOS adds notdefault to external/foo's groups: removed from the new default.xml, READY, verified"
fresh
C2=$(los_edit "foo: notdefault" snippets/lineage.xml 'rep("path=\"external/foo\" groups=\"pdk,pdk-fs\"", "path=\"external/foo\" groups=\"pdk,pdk-fs,notdefault\"")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
OURS_PATHS=$(mq "$top/.repo/manifests/default.xml" - paths)
run plan
check "plan not READY (rc $RC)" 'ready'
check "no 'removed external/foo: LineageOS takes it out of the default sync' line" \
    'grep -qE "^removed external/foo: LineageOS takes it out of the default sync \(groups notdefault,pdk,pdk-fs\)" <<<"$OUT"'
check "the new manifest's check failed" '! grep -q "the new manifest:" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "the new default.xml has external/foo" '[[ $(mq "$NEW" external/foo has) = 0 ]]'
check "the new default.xml's projects aren't ours less external/foo plus external/new" \
    '[[ $(mq "$NEW" - paths) = $(tr " " "\n" <<<"$OURS_PATHS external/new" | grep -vx external/foo | LC_ALL=C sort | tr "\n" " " | sed "s/ $//") ]]'
check "the new default.xml has a notdefault group" '! grep -q notdefault "$NEW"'
check "no plan.json" '[[ -s $PF ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
check "GitHub's update/$ID has external/foo" '[[ $(mq "$GHX" external/foo has) = 0 ]]'
finish

# --- 3. LineageOS adds notdefault to a fork's groups: the fork stays in the default sync ---------
begin "3. LineageOS adds notdefault to frameworks/base's groups (a fork): READY, the fork stays in the default sync, a note"
fresh
C2=$(los_edit "fb: notdefault" snippets/lineage.xml 'rep("path=\"frameworks/base\" groups=\"pdk\"", "path=\"frameworks/base\" groups=\"pdk,notdefault\"")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
run plan
check "plan not READY (rc $RC)" 'ready'
check "no note 'LineageOS takes frameworks/base out of the default sync ...: ExpressiveOS's fork frameworks_base stays in it'" \
    "needs_a_look | grep -qF \"LineageOS takes frameworks/base out of the default sync (groups notdefault,pdk): ExpressiveOS's fork frameworks_base stays in it\""
check "the manifest section says it changed frameworks/base" '! grep -q "^changed frameworks/base" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "frameworks/base's groups aren't pdk (kept in the default sync)" '[[ $(mq "$NEW" frameworks/base groups) = pdk ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q UPDATE_PUSH=OK <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's, or frameworks/base isn't on pdk there" \
    'gh_manifest && [[ $(mq "$GHX" frameworks/base groups) = pdk ]]'
finish

# --- 3b. ... with another groups change: that's taken, notdefault isn't -------------------------
begin "3b. LineageOS changes frameworks/base's groups pdk -> pdk-fs,notdefault: READY, groups pdk-fs, a note"
fresh
C2=$(los_edit "fb: pdk-fs, notdefault" snippets/lineage.xml 'rep("path=\"frameworks/base\" groups=\"pdk\"", "path=\"frameworks/base\" groups=\"pdk-fs,notdefault\"")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
run plan
check "plan not READY (rc $RC)" 'ready'
check "no note that the fork stays in the default sync" \
    "needs_a_look | grep -qF \"LineageOS takes frameworks/base out of the default sync (groups notdefault,pdk-fs): ExpressiveOS's fork frameworks_base stays in it\""
check "no 'changed frameworks/base: groups' line" 'grep -qx "changed frameworks/base: groups" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "frameworks/base's groups aren't pdk-fs" '[[ $(mq "$NEW" frameworks/base groups) = pdk-fs ]]'
finish

# --- 4. LineageOS adds a linkfile and a group to a fork and changes its clone-depth ----------------
begin "4. LineageOS adds a linkfile and a group to frameworks/base (a fork), changes its clone-depth: line has groups+linkfile, no clone-depth"
fresh
C2=$(los_edit "fb: linkfile, group, clone-depth" snippets/lineage.xml 'rep("<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk\" />", "<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk,sysui-studio\" clone-depth=\"1\">\n    <linkfile src=\"README\" dest=\"FB_README\" />\n  </project>")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
run plan
check "plan not READY (rc $RC)" 'ready'
check "no 'changed frameworks/base: groups; linkfiles/copyfiles' line" 'grep -qx "changed frameworks/base: groups; linkfiles/copyfiles" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
FBM=$(python3 -I -c 'import json, sys; print([f["merge"] for f in json.load(open(sys.argv[1]))["forks"] if f["path"] == "frameworks/base"][0])' "$PF" 2>/dev/null)
check "frameworks_base's groups aren't pdk,sysui-studio (got $(mq "$NEW" frameworks/base groups))" '[[ $(mq "$NEW" frameworks/base groups) = pdk,sysui-studio ]]'
check "frameworks_base's kids aren't the linkfile README>FB_README (got $(mq "$NEW" frameworks/base kids))" '[[ $(mq "$NEW" frameworks/base kids) = "linkfile:README>FB_README" ]]'
check "frameworks_base has a clone-depth ($(mq "$NEW" frameworks/base depth))" '[[ $(mq "$NEW" frameworks/base depth) = - ]]'
check "frameworks_base's line isn't own-manifest.py's layout with the merge pinned" \
    '[[ $(mq "$NEW" frameworks/base line) = "  <project name=\"frameworks_base\" path=\"frameworks/base\" remote=\"expressiveos\" revision=\"$FBM\" upstream=\"refs/heads/expressiveos\" dest-branch=\"refs/heads/expressiveos\" groups=\"pdk,sysui-studio\">
    <linkfile src=\"README\" dest=\"FB_README\" />
  </project>" ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
check "frameworks_base's expressiveos isn't at the merge the manifest pins" '[[ -n $FBM && $(tipof "$FB") = "$FBM" && $(mq "$GHX" frameworks/base rev) = "$FBM" ]]'
finish

# --- 5. LineageOS drops a fork (and adds a copyfile and a group to another) ------------------------
begin "5. LineageOS drops vendor/lineage (a fork): 'Needs a look' note, READY, vendor_lineage kept as it was"
fresh
C2=$(los_edit "fb: copyfile, groups; drop vendor/lineage" snippets/lineage.xml '
rep("<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk\" />", "<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk,pdk-cw-fs\">\n    <copyfile src=\"README\" dest=\"FB_README\" />\n  </project>")
rep("  <project name=\"LineageOS/android_vendor_lineage\" path=\"vendor/lineage\" />\n", "")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
VL0=$(tipof "$VL")
VLLINE=$(mq "$top/.repo/manifests/default.xml" vendor/lineage line)
run plan
check "plan not READY (rc $RC)" 'ready'
check "no 'Needs a look' note that LineageOS dropped vendor/lineage" \
    "needs_a_look | grep -qx \"LineageOS dropped vendor/lineage from its manifest: ExpressiveOS's fork vendor_lineage doesn't follow LineageOS any more (it stays, as ExpressiveOS's own)\""
check "vendor/lineage isn't left out of the forks merged" 'grep -q "(1 forks merged, 0 need a resolution, 0 problems)" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "vendor_lineage's line isn't as it was (pin $VL0)" '[[ $(mq "$NEW" vendor/lineage line) = "$VLLINE" && $(mq "$NEW" vendor/lineage rev) = "$VL0" ]]'
check "plan.json has vendor/lineage among forks or pins" \
    '[[ $(python3 -I -c "import json, sys; d = json.load(open(sys.argv[1])); print(\" \".join(sorted(f[\"path\"] for f in d[\"forks\"] + d.get(\"pins\", []))))" "$PF") = frameworks/base ]]'
check "frameworks_base's groups aren't pdk,pdk-cw-fs (got $(mq "$NEW" frameworks/base groups))" '[[ $(mq "$NEW" frameworks/base groups) = pdk,pdk-cw-fs ]]'
check "frameworks_base's kids aren't the copyfile README>FB_README (got $(mq "$NEW" frameworks/base kids))" '[[ $(mq "$NEW" frameworks/base kids) = "copyfile:README>FB_README" ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK (1 forks pushed now" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
check "vendor_lineage's expressiveos moved, or GitHub's update/$ID doesn't pin it there" '[[ $(tipof "$VL") = "$VL0" && $(mq "$GHX" vendor/lineage rev) = "$VL0" ]]'
finish

# --- 6. linkfiles element by element: ours A+E, base A, LineageOS A+N -------------------------------
# (ours lists E before A, so "ours' order, then LineageOS's new N" isn't also the sorted order)
begin "6. base linkfile A, ours A+E, LineageOS A+N: READY, development's linkfiles ours' E, A then N; again with ours E, A, N: READY, the same"
fresh
C2=$(los_edit "dev: linkfile A" snippets/lineage.xml 'rep("<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\" />", "<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\">\n    <linkfile src=\"a\" dest=\"A\" />\n  </project>")')
C3=$(los_edit "dev: linkfile N" snippets/lineage.xml 'rep("<linkfile src=\"a\" dest=\"A\" />", "<linkfile src=\"a\" dest=\"A\" />\n    <linkfile src=\"n\" dest=\"N\" />")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 && -n $C3 ]]'
eos_edit "dev: linkfiles A and E; last update" '
import re
t, k = re.subn("(  <project name=\"LineageOS/android_development\" [^\n]*?) />", "\\1>\n    <linkfile src=\"e\" dest=\"E\" />\n    <linkfile src=\"a\" dest=\"A\" />\n  </project>", t)
assert k == 1' "last-update.conf=$(printf 'UPDATE=2026-10\nLINEAGE_MANIFEST=%s' "$C2")"
check "couldn't change ExpressiveOS's manifest" '[[ $(mq "$top/.repo/manifests/default.xml" development kids) = "linkfile:e>E linkfile:a>A" ]]'
take "$C3"
run plan
check "plan 1 not READY (rc $RC)" 'ready'
check "plan 1: no 'changed development: linkfiles/copyfiles' line" 'grep -qx "changed development: linkfiles/copyfiles" <<<"$OUT"'
check "plan 1: no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "plan 1: development's kids aren't E, A, N in that order (got $(mq "$NEW" development kids))" \
    '[[ $(mq "$NEW" development kids) = "linkfile:e>E linkfile:a>A linkfile:n>N" ]]'
check "plan 1: development's line isn't in own-manifest.py's layout" \
    '[[ $(mq "$NEW" development line | tail -4) = "    <linkfile src=\"e\" dest=\"E\" />
    <linkfile src=\"a\" dest=\"A\" />
    <linkfile src=\"n\" dest=\"N\" />
  </project>" ]]'
# Daryl takes LineageOS's N into ExpressiveOS's manifest by hand, keeping E; plan again
eos_edit "dev: take LineageOS's N" 'rep("    <linkfile src=\"a\" dest=\"A\" />\n  </project>", "    <linkfile src=\"a\" dest=\"A\" />\n    <linkfile src=\"n\" dest=\"N\" />\n  </project>")'
check "couldn't change ExpressiveOS's manifest again" '[[ $(mq "$top/.repo/manifests/default.xml" development kids) = "linkfile:e>E linkfile:a>A linkfile:n>N" ]]'
run plan
check "plan 2 (ours E, A, N) not READY (rc $RC)" 'ready'
check "plan 2 changes development's linkfiles" '! grep -q "^changed development:.*linkfiles" <<<"$OUT"'
check "plan 2: no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "plan 2: development's kids aren't E, A, N (got $(mq "$NEW" development kids))" \
    '[[ $(mq "$NEW" development kids) = "linkfile:e>E linkfile:a>A linkfile:n>N" ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
check "GitHub's update/$ID: development's kids aren't E, A, N" '[[ $(mq "$GHX" development kids) = "linkfile:e>E linkfile:a>A linkfile:n>N" ]]'
check "GitHub's update/$ID: last-update.conf isn't this update's" \
    '[[ $(git --git-dir="$MAN" show "update/$ID:last-update.conf" 2>/dev/null | grep -E "^(UPDATE|LINEAGE_MANIFEST)=" | tr "\n" " ") = "UPDATE=$ID LINEAGE_MANIFEST=$C3 " ]]'
finish

# --- 7. two linkfiles to the same dest after the merge: a problem ----------------------------------
begin "7. ours and LineageOS each change linkfile A's src (development, and frameworks/base's FB_README): NOT_READY, same file"
fresh
C2=$(los_edit "dev, fb: linkfiles" snippets/lineage.xml '
rep("<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\" />", "<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\">\n    <linkfile src=\"a\" dest=\"A\" />\n  </project>")
rep("<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk\" />", "<project name=\"LineageOS/android_frameworks_base\" path=\"frameworks/base\" groups=\"pdk\">\n    <linkfile src=\"README\" dest=\"FB_README\" />\n  </project>")')
C3=$(los_edit "dev, fb: other srcs" snippets/lineage.xml '
rep("<linkfile src=\"a\" dest=\"A\" />", "<linkfile src=\"a-los\" dest=\"A\" />")
rep("<linkfile src=\"README\" dest=\"FB_README\" />", "<linkfile src=\"core/Power.java\" dest=\"FB_README\" />")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 && -n $C3 ]]'
eos_edit "dev, fb: our own srcs; last update" '
import re
t, k = re.subn("(  <project name=\"LineageOS/android_development\" [^\n]*?) />", "\\1>\n    <linkfile src=\"a-eos\" dest=\"A\" />\n  </project>", t)
t, j = re.subn("(  <project name=\"frameworks_base\" [^\n]*?) />", "\\1>\n    <linkfile src=\"core\" dest=\"FB_README\" />\n  </project>", t)
assert k == j == 1' "last-update.conf=$(printf 'UPDATE=2026-10\nLINEAGE_MANIFEST=%s' "$C2")"
check "couldn't change ExpressiveOS's manifest" \
    '[[ $(mq "$top/.repo/manifests/default.xml" development kids) = "linkfile:a-eos>A" && $(mq "$top/.repo/manifests/default.xml" frameworks/base kids) = "linkfile:core>FB_README" ]]'
take "$C3"
run plan
check "plan not NOT_READY (rc $RC)" 'not_ready'
check "no problem for development: two linkfiles would make the same file" \
    "sed -n '/^== Not ready/,\$p' <<<\"\$OUT\" | grep -qE \"^development: its linkfiles/copyfiles: .*two would make the same file\""
check "no problem for frameworks/base (a fork): two linkfiles would make the same file" \
    "sed -n '/^== Not ready/,\$p' <<<\"\$OUT\" | grep -qE \"^manifest, frameworks/base: its linkfiles/copyfiles: .*two would make the same file\""
check "a manifest commit, plan.json or updates/$ID/default.xml was made" 'no_manifest'
finish

# --- 8. groups element by element, with ExpressiveOS's own groups, on a fork and a non-fork ---------
begin "8. groups element by element: ours pdk,eos / developers,eos-dev; LineageOS pdk->sysui-studio, developers->pdk: eos,sysui-studio / eos-dev,pdk"
fresh
eos_edit "fb, dev: our own groups" '
rep("dest-branch=\"refs/heads/expressiveos\" groups=\"pdk\" />", "dest-branch=\"refs/heads/expressiveos\" groups=\"pdk,eos\" />")
rep("dest-branch=\"refs/heads/lineage-24.0\" groups=\"developers\" />", "dest-branch=\"refs/heads/lineage-24.0\" groups=\"developers,eos-dev\" />")'
check "couldn't change ExpressiveOS's manifest" \
    '[[ $(mq "$top/.repo/manifests/default.xml" frameworks/base groups) = pdk,eos && $(mq "$top/.repo/manifests/default.xml" development groups) = developers,eos-dev ]]'
C2=$(los_edit "fb, dev: groups" snippets/lineage.xml '
rep("path=\"frameworks/base\" groups=\"pdk\"", "path=\"frameworks/base\" groups=\"sysui-studio\"")
rep("path=\"development\" groups=\"developers\"", "path=\"development\" groups=\"pdk\"")')
check "couldn't change LineageOS's manifest" '[[ -n $C2 ]]' && take "$C2"
run plan
check "plan not READY (rc $RC)" 'ready'
check "no 'changed frameworks/base: groups' and 'changed development: groups' lines" \
    'grep -qx "changed frameworks/base: groups" <<<"$OUT" && grep -qx "changed development: groups" <<<"$OUT"'
check "no manifest commit refs/eos/update/$ID on GitHub's expressiveos that is plan.json's and updates/$ID/default.xml" 'new_manifest'
check "frameworks_base's groups aren't eos,sysui-studio (got $(mq "$NEW" frameworks/base groups))" '[[ $(mq "$NEW" frameworks/base groups) = eos,sysui-studio ]]'
check "development's groups aren't eos-dev,pdk (got $(mq "$NEW" development groups))" '[[ $(mq "$NEW" development groups) = eos-dev,pdk ]]'
run push
check "push not OK (rc $RC)" '[[ $RC = 0 ]] && grep -q "^UPDATE_PUSH=OK" <<<"$OUT"'
check "GitHub's update/$ID isn't the plan's manifest" 'gh_manifest'
finish

# --- 9. the new manifest's check refuses a notdefault project ---------------------------------------
begin "9. a notdefault project in ExpressiveOS's manifest (packages/apps/Evolver): NOT_READY, the new manifest refused"
fresh
eos_edit "Evolver: notdefault" 'rep("<project name=\"packages_apps_Evolver\" path=\"packages/apps/Evolver\" remote=\"expressiveos\"", "<project name=\"packages_apps_Evolver\" path=\"packages/apps/Evolver\" remote=\"expressiveos\" groups=\"notdefault\"")'
check "couldn't change ExpressiveOS's manifest" '[[ $(mq "$top/.repo/manifests/default.xml" packages/apps/Evolver groups) = notdefault ]]'
run plan
check "plan not NOT_READY (rc $RC)" 'not_ready'
check "no problem 'the new manifest: packages/apps/Evolver is outside repo's default sync (notdefault)'" \
    "sed -n '/^== Not ready/,\$p' <<<\"\$OUT\" | grep -qE \"^the new manifest: .*packages/apps/Evolver is outside repo's default sync \\(notdefault\\)\""
check "a manifest commit, plan.json or updates/$ID/default.xml was made" 'no_manifest'
finish

rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
