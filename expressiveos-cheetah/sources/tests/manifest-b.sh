#!/usr/bin/env bash
# Regression test (manifest-b): how update.py's plan and dry run read LineageOS's manifest changes.
#
#   bash manifest-b.sh <kit src>        (the folder with sources/update.py)
#
# Fixed behaviour checked:
#  a. LineageOS switches a project whose line has no path= (name == path) to another repo: the plan
#     puts path= in before changing name, so the project stays at its path; READY, and push pushes
#     a manifest with it there
#  b. a repo LineageOS moves to another path: a non-fork's old line is removed ("removed <old>:
#     LineageOS moved <name> to <new>") and the new one added ("..., moved from <old>"); a fork's
#     move is a problem ("move the fork's line by hand"); a project LineageOS drops that's on an
#     AOSP tag is a "Needs a look" note, not "kept"
#  c. the kernel pins proposal: a project LineageOS's kernel manifest moves to another tag or
#     branch gets the new revision and upstream/dest-branch = the new ref; a repo or linkfile
#     change is a note "change the pins by hand" (no proposal); the plan says to commit it after
#     the manifest's pull request is merged, on its own, and build with kernel-sync
#  d. the dry run (update-check.sh) says "ExpressiveOS's manifest has it already" only when every
#     changed attribute (groups, depth, linkfiles...) matches
#  e. plan's fetch of a LineageOS project that moves sends a "have" (refs/eos/<path>/ours set to
#     the pin first) when the tree is laid out as repo does (objects a symlink into a ref-less
#     .repo/project-objects repo), so only the new commits are downloaded
#
# Worlds: harness.sh (next to this script), one at a time, in manifest-b under
# $EOS_TEST_WORK (default $TMPDIR/eos-update-tests); removed at the end. Only file:// repos (GIT_ALLOW_PROTOCOL=file): nothing leaves the machine.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
H=$HERE/harness.sh
TRES=$HERE/t-resolve.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/manifest-b
LB=lineage-24.0
rm -rf "$WD"
mkdir -p "$WD/aux"
trap 'rm -rf "$WD"' EXIT
export GIT_ALLOW_PROTOCOL=file

pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { [[ -n ${1:-} ]] && printf '%s\n' "$1" | tail -"${2:-20}" | sed 's/^/    | /'; return 0; }
# A case is a list of checks; WHY collects what's wrong (empty: pass)
WHY=
want() {   # want <reason> <bash test, eval'd>: notes reason when the test fails
    eval "$2" || WHY+="${WHY:+; }$1"
}
verdict() {   # verdict <case name> [output to show on failure]
    if [[ -z $WHY ]]; then ok "$1"; else bad "$1: $WHY"; show "${2:-}" 25; fi
    WHY=
}

# A manifest, queried: q <file|-> <op> args (count-path, count-name, paths-of-name, attr, kids, url)
cat > "$WD/aux/q.py" <<'EOF'
import sys, urllib.parse, xml.etree.ElementTree as ET
f, op, args = sys.argv[1], sys.argv[2], sys.argv[3:]
r = ET.fromstring(sys.stdin.read() if f == "-" else open(f).read())
projs = list(r.iter("project"))
def at(path):
    return [p for p in projs if (p.get("path") or p.get("name")) == path]
if op == "count-path":
    print(len(at(args[0])))
elif op == "count-name":
    print(sum(1 for p in projs if p.get("name") == args[0]))
elif op == "paths-of-name":
    print(" ".join(sorted((p.get("path") or p.get("name")) for p in projs if p.get("name") == args[0])))
elif op == "attr":       # attr <path> <key>: its value, <none>, or <count N> when not exactly one project
    ps = at(args[0])
    print(ps[0].get(args[1], "<none>") if len(ps) == 1 else f"<count {len(ps)}>")
elif op == "kids":
    ps = at(args[0])
    print(" ".join(f"{k.tag}:{k.get('src')}:{k.get('dest')}" for k in ps[0]) if len(ps) == 1 else f"<count {len(ps)}>")
elif op == "url":        # url <path> <the manifest's own url>: the project's repo, as repo resolves it
    rem = {e.get("name"): e.get("fetch") for e in r.iter("remote")}
    d = r.find("default")
    ps = at(args[0])
    if len(ps) != 1:
        print(f"<count {len(ps)}>")
    else:
        p = ps[0]
        print(urllib.parse.urljoin(args[1].rstrip("/"), rem[p.get("remote") or d.get("remote")].rstrip("/")).rstrip("/")
              + "/" + p.get("name"))
EOF
q() { python3 -I "$WD/aux/q.py" "$@"; }

world() {   # a fresh world in $WD/w, sourced; frameworks/base's conflict resolved
    bash "$H" "$KSRC" "$WD/w" >"$WD.harness.log" 2>&1 || { tail -n 20 "$WD.harness.log" >&2; echo "FAIL: harness.sh couldn't build a world"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/w/env.sh"
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/2026-11
    bash "$TRES" "$WD/w" >/dev/null 2>&1 || { echo "FAIL: t-resolve.sh failed"; exit 1; }
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "${1:-2026-11}" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "${1:-2026-11}" "$top"); }
check() { (cd "$T" && bash "$kit/sources/update-check.sh" "$top"); }
tipof() { git --git-dir="$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null; }
newman() { git --git-dir="$W/manifests/eos.git" show refs/eos/update/2026-11:default.xml 2>/dev/null; }
newcommit() {   # newcommit <bare> <branch> <msg> <cmd run in a clone>: prints the new commit
    local bare=$1 br=$2 msg=$3 w
    shift 3
    w=$(mktemp -d "$T/w/n.XXXX")
    git clone -q -b "$br" "$bare" "$w"
    (cd "$w" && eval "$@")
    git -C "$w" add -A && git -C "$w" commit -qm "$msg" && git -C "$w" push -q origin "$br"
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
los() {   # los <msg> <cmd in a clone of LineageOS's manifest>: a new commit, which update.conf takes
    local c
    c=$(newcommit "$T/gh/LineageOS/android.git" $LB "$1" "$2")
    echo "LINEAGE_MANIFEST=$c" > "$U/update.conf"
}
eos_edit() {   # eos_edit <msg> <cmd in a clone of ExpressiveOS's manifest>; the tree follows
    newcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos "$1" "$2" >/dev/null
    git -C "$top/.repo/manifests" fetch -q origin
    git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
}
tree_sync() {   # the tree's projects: a bare clone for each project of its manifest it lacks
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
section() {   # section <title start> <text>: the lines of a "== <title>" section
    awk -v t="== $1" 'index($0, t) == 1 {on = 1; next} on && (/^== / || /^report: / || /^UPDATE_PLAN=/) {on = 0} on' <<<"$2"
}
has() { grep -qF -- "$2" <<<"$1"; }        # has <text> <fixed string>
hasline() { grep -qxF -- "$2" <<<"$1"; }   # hasline <text> <whole line>

# ================================================================================================
# a. LineageOS switches device/common (name == path, no path= on ExpressiveOS's line) from AOSP's
#    repo to its own fork: the plan keeps the path (review/manifest/repro/r1-nopath.sh)
world
git init -q --bare "$T/aosp/device/common.git"
w=$(mktemp -d "$T/w/d.XXXX"); git -C "$w" init -q -b main; echo dc > "$w/dc.mk"; git -C "$w" add -A
git -C "$w" commit -qm dc; git -C "$w" push -q "$T/aosp/device/common.git" main; rm -rf "$w"
git --git-dir="$T/aosp/device/common.git" tag -a -m r2 android-17.0.0_r2 main
DC=$(tipof "$T/aosp/device/common.git" android-17.0.0_r2)
git clone -q --bare "$T/aosp/device/common.git" "$T/gh/LineageOS/android_device_common.git"
git --git-dir="$T/gh/LineageOS/android_device_common.git" branch -q $LB main
DCL=$(newcommit "$T/gh/LineageOS/android_device_common.git" $LB "lineage: dc" 'echo lineage >> dc.mk')
C2=$(newcommit "$T/gh/LineageOS/android.git" $LB "add device/common" \
  "sed -i 's#^</manifest>#  <project path=\"device/common\" name=\"device/common\" remote=\"aosp\" groups=\"pdk\" />\n</manifest>#' default.xml")
los "device/common: LineageOS's fork" \
  "sed -i 's#<project path=\"device/common\" name=\"device/common\" remote=\"aosp\" groups=\"pdk\" />#<project path=\"device/common\" name=\"LineageOS/android_device_common\" groups=\"pdk\" />#' default.xml"
eos_edit "device/common; last update" \
  "sed -i 's#^</manifest>#  <project name=\"device/common\" remote=\"aosp\" revision=\"$DC\" upstream=\"refs/tags/android-17.0.0_r2\" dest-branch=\"refs/tags/android-17.0.0_r2\" groups=\"pdk\" />\n</manifest>#' default.xml; printf 'UPDATE=2026-10\nLINEAGE_MANIFEST=$C2\n' > last-update.conf"
tree_sync
want "the setup isn't as meant (ExpressiveOS's line has a path=)" \
    '[[ $(q "$top/.repo/manifests/default.xml" attr device/common path) = "<none>" ]]'
out=$(plan 2>&1); rc=$?
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no 'changed device/common: repo device/common -> LineageOS/android_device_common'" \
    'has "$out" "changed device/common: repo device/common -> LineageOS/android_device_common"'
verdict "a. name==path project switched to LineageOS's fork: plan READY" "$out"
nm=$(newman)
want "the plan made no manifest commit" '[[ -n $nm ]]'
want "device/common isn't one project in the new manifest ($(q - count-path device/common <<<"$nm"))" \
    '[[ $(q - count-path device/common <<<"$nm") = 1 ]]'
want "a project sits at path LineageOS/android_device_common" \
    '[[ $(q - count-path LineageOS/android_device_common <<<"$nm") = 0 ]]'
want "its name is $(q - attr device/common name <<<"$nm")" \
    '[[ $(q - attr device/common name <<<"$nm") = LineageOS/android_device_common ]]'
want "its path= is $(q - attr device/common path <<<"$nm")" \
    '[[ $(q - attr device/common path <<<"$nm") = device/common ]]'
want "it resolves to $(q - url device/common "$G/ExpressiveOS/manifest" <<<"$nm")" \
    '[[ $(q - url device/common "$G/ExpressiveOS/manifest" <<<"$nm") = "$G/LineageOS/android_device_common" ]]'
want "its revision is $(q - attr device/common revision <<<"$nm"), not LineageOS's fork's tip ${DCL:0:12}" \
    '[[ $(q - attr device/common revision <<<"$nm") = "$DCL" ]]'
want "its upstream/dest-branch aren't refs/heads/$LB" \
    '[[ $(q - attr device/common upstream <<<"$nm") = refs/heads/$LB && $(q - attr device/common dest-branch <<<"$nm") = refs/heads/$LB ]]'
want "the plan's default.xml isn't the manifest commit's" '[[ "$(cat "$W/updates/2026-11/default.xml" 2>/dev/null)" = "$nm" ]]'
verdict "a. the new manifest keeps device/common at its path, name LineageOS/android_device_common at LineageOS's tip" "$(grep -n 'device/common' <<<"$nm")"
pout=$(push 2>&1); prc=$?
gm=$(git --git-dir="$T/gh/ExpressiveOS/manifest.git" show refs/heads/update/2026-11:default.xml 2>/dev/null)
want "push rc $prc" '[[ $prc = 0 ]] && has "$pout" "UPDATE_PUSH=OK"'
want "GitHub's update/2026-11 doesn't have device/common at its path from LineageOS's fork" \
    '[[ $(q - url device/common "$G/ExpressiveOS/manifest" <<<"$gm") = "$G/LineageOS/android_device_common" && $(q - attr device/common revision <<<"$gm") = "$DCL" ]]'
verdict "a. pushed: GitHub's manifest branch update/2026-11 has device/common at its path" "$pout"

# ================================================================================================
# b1. LineageOS moves external/foo (a non-fork) to external/foo-legacy (repro/r6-move.sh)
world
los "move external/foo" "sed -i 's#path=\"external/foo\"#path=\"external/foo-legacy\"#' snippets/lineage.xml"
FOO=$(tipof "$T/gh/LineageOS/android_external_foo.git" refs/heads/$LB)
out=$(plan 2>&1); rc=$?
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no 'added external/foo-legacy (...), moved from external/foo'" \
    'hasline "$out" "added external/foo-legacy (LineageOS/android_external_foo $LB, ${FOO:0:12}), moved from external/foo"'
want "no 'removed external/foo: LineageOS moved LineageOS/android_external_foo to external/foo-legacy'" \
    'hasline "$out" "removed external/foo: LineageOS moved LineageOS/android_external_foo to external/foo-legacy"'
want "says external/foo is kept" '! has "$out" "LineageOS dropped external/foo"'
verdict "b. non-fork moved to another path: plan READY, 'removed' and 'added ..., moved from' lines" "$out"
nm=$(newman)
want "the plan made no manifest commit" '[[ -n $nm ]]'
want "external/foo still in the new manifest" '[[ $(q - count-path external/foo <<<"$nm") = 0 ]]'
want "LineageOS/android_external_foo is at '$(q - paths-of-name LineageOS/android_external_foo <<<"$nm")'" \
    '[[ $(q - paths-of-name LineageOS/android_external_foo <<<"$nm") = external/foo-legacy ]]'
want "external/foo-legacy at $(q - attr external/foo-legacy revision <<<"$nm"), not ${FOO:0:12}" \
    '[[ $(q - attr external/foo-legacy revision <<<"$nm") = "$FOO" ]]'
want "external/foo-legacy's groups are $(q - attr external/foo-legacy groups <<<"$nm")" \
    '[[ $(q - attr external/foo-legacy groups <<<"$nm") = pdk,pdk-fs ]]'
want "external/foo-legacy's upstream isn't refs/heads/$LB" \
    '[[ $(q - attr external/foo-legacy upstream <<<"$nm") = refs/heads/$LB ]]'
verdict "b. the new manifest has LineageOS/android_external_foo once, at external/foo-legacy" "$(grep -n 'external_foo' <<<"$nm")"

# b2. LineageOS moves packages/apps/Settings, which is ExpressiveOS's fork, to another path
world
los "move Settings" "sed -i 's#path=\"packages/apps/Settings\"#path=\"packages/apps/Settings2\"#' snippets/lineage.xml"
out=$(plan 2>&1); rc=$?
nr=$(section "Not ready" "$out")
want "plan rc $rc (0)" '[[ $rc != 0 ]]'
want "not UPDATE_PLAN=NOT_READY" 'has "$out" "UPDATE_PLAN=NOT_READY"'
want "no 'move the fork's line by hand' problem" \
    'has "$nr" "manifest: LineageOS moved LineageOS/android_packages_apps_Settings from packages/apps/Settings to packages/apps/Settings2, where ExpressiveOS has its fork packages_apps_Settings: move the fork'"'"'s line by hand"'
want "adds packages/apps/Settings2" '! has "$out" "added packages/apps/Settings2"'
want "a plan.json" '[[ ! -e $W/updates/2026-11/plan.json ]]'
want "a manifest commit (refs/eos/update/2026-11)" '[[ -z $(newman) ]]'
verdict "b. a fork LineageOS moved to another path: NOT_READY, 'move the fork's line by hand', no plan" "$out"

# b3. LineageOS drops build/make (on AOSP's tag): a "Needs a look" note; hardware/old (on a branch) kept
world
los "drop platform/build" "sed -i '/name=\"platform\\/build\"/d' default.xml"
R1=$(tipof "$T/aosp/platform/build.git" refs/tags/android-17.0.0_r1)
OLD=$(q "$top/.repo/manifests/default.xml" attr hardware/old revision)
out=$(plan 2>&1); rc=$?
nl=$(section "Needs a look" "$out")
nm=$(newman)
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no 'Needs a look' note for build/make" \
    'hasline "$nl" "LineageOS dropped build/make (platform/build): kept on AOSP'"'"'s android-17.0.0_r1, which doesn'"'"'t move; take it out of the manifest by hand if nothing builds from it"'
want "build/make still 'kept, following its own upstream'" '! has "$out" "LineageOS dropped build/make: kept"'
want "hardware/old isn't 'kept, following its own upstream' any more" \
    'hasline "$out" "LineageOS dropped hardware/old: kept, following its own upstream"'
want "build/make isn't kept at android-17.0.0_r1's ${R1:0:12} ($(q - attr build/make revision <<<"$nm"))" \
    '[[ $(q - attr build/make revision <<<"$nm") = "$R1" && $(q - attr build/make upstream <<<"$nm") = refs/tags/android-17.0.0_r1 ]]'
want "hardware/old isn't kept at its pin" '[[ $(q - attr hardware/old revision <<<"$nm") = "$OLD" ]]'
verdict "b. dropped project on an AOSP tag: 'Needs a look' note, kept; one on a branch: 'kept'" "$out"

# ================================================================================================
# c1. The kernel manifest moves private/devices to the next GKI tag; aosp moves on its branch
#     (repro/r5-kerneltag.sh)
world
KR="$T/gh/LineageOS/android_kernel_google_gs-6.1_devices.git"
KA="$T/gh/LineageOS/android_kernel_google_gs-6.1.git"
git --git-dir="$KR" tag -a -m k1 gki-2026-03_r1 $LB
KD1=$(tipof "$KR" refs/tags/gki-2026-03_r1)
newcommit "$KR" $LB "next gki" 'echo d2 > dev' >/dev/null
git --git-dir="$KR" tag -a -m k2 gki-2026-05_r1 $LB
KD2=$(tipof "$KR" refs/tags/gki-2026-05_r1)
KA2=$(tipof "$KA" refs/heads/$LB)
newcommit "$T/gh/LineageOS/android_kernel_google_gs-6.1_manifest.git" $LB "devices: gki-2026-05_r1" \
  "sed -i 's#path=\"private/devices\" />#path=\"private/devices\" revision=\"refs/tags/gki-2026-05_r1\" />#' default.xml" >/dev/null
sed -i "s#path=\"private/devices\" revision=\"[0-9a-f]*\" upstream=\"refs/heads/$LB\"#path=\"private/devices\" revision=\"$KD1\" upstream=\"refs/tags/gki-2026-03_r1\" dest-branch=\"refs/tags/gki-2026-03_r1\"#" "$kit/pins/kernel.xml"
KA1=$(q "$kit/pins/kernel.xml" attr aosp revision)
pins_before=$(cat "$kit/pins/kernel.xml")
out=$(plan 2>&1); rc=$?
kx=$W/updates/2026-11/kernel.xml
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no kernel.xml proposed" '[[ -f $kx ]]'
want "private/devices' revision $(q "$kx" attr private/devices revision), not gki-2026-05_r1's ${KD2:0:12}" \
    '[[ $(q "$kx" attr private/devices revision) = "$KD2" ]]'
want "private/devices' upstream $(q "$kx" attr private/devices upstream)" \
    '[[ $(q "$kx" attr private/devices upstream) = refs/tags/gki-2026-05_r1 ]]'
want "private/devices' dest-branch $(q "$kx" attr private/devices dest-branch)" \
    '[[ $(q "$kx" attr private/devices dest-branch) = refs/tags/gki-2026-05_r1 ]]'
want "aosp's revision $(q "$kx" attr aosp revision), not $LB's ${KA2:0:12}" '[[ $(q "$kx" attr aosp revision) = "$KA2" ]]'
want "aosp's upstream/dest-branch changed (it stays on $LB)" \
    '[[ $(q "$kx" attr aosp upstream) = refs/heads/$LB && $(q "$kx" attr aosp dest-branch) = "<none>" ]]'
want "lines other than the two projects' changed" \
    '[[ $(diff <(printf "%s\n" "$pins_before") "$kx" | grep -c "^>") = 2 ]]'
want "the kit's pins/kernel.xml was changed by plan" '[[ "$(cat "$kit/pins/kernel.xml")" = "$pins_before" ]]'
verdict "c. kernel project to a new GKI tag: proposal has its commit and upstream/dest-branch = the tag" "$(cat "$kx" 2>/dev/null; section Kernel "$out")"
want "no 'private/devices: <old> -> <new> (gki-2026-05_r1)'" \
    'hasline "$out" "private/devices: ${KD1:0:12} -> ${KD2:0:12} (gki-2026-05_r1)"'
want "no 'aosp: <old> -> <new>' (without a ref)" 'hasline "$out" "aosp: ${KA1:0:12} -> ${KA2:0:12}"'
want "the plan doesn't say to commit it after the manifest's pull request is merged, on its own, and build with kernel-sync" \
    'hasline "$out" "pins/kernel.xml to take: $kx. After the manifest'"'"'s pull request is merged, commit it as the kit'"'"'s pins/kernel.xml, on its own, and build with kernel-sync"'
verdict "c. the plan's kernel lines, and when to commit the pins (after the manifest's pull request, on its own, kernel-sync)" "$(section Kernel "$out")"

# c2. The kernel manifest moves aosp to another branch, and private/devices to a tag of the commit
#     it's pinned at (the ref moves, the commit doesn't)
world
KR="$T/gh/LineageOS/android_kernel_google_gs-6.1_devices.git"
KA="$T/gh/LineageOS/android_kernel_google_gs-6.1.git"
KD=$(q "$kit/pins/kernel.xml" attr private/devices revision)
git --git-dir="$KR" tag -a -m k1 gki-2026-03_r1 "$KD"
git --git-dir="$KA" branch -q android14-6.1-2026-05 $LB
KB=$(newcommit "$KA" android14-6.1-2026-05 "next branch" 'echo k3 > Makefile')
newcommit "$T/gh/LineageOS/android_kernel_google_gs-6.1_manifest.git" $LB "aosp: next branch; devices: a tag" \
  "sed -i 's#path=\"aosp\" />#path=\"aosp\" revision=\"android14-6.1-2026-05\" />#; s#path=\"private/devices\" />#path=\"private/devices\" revision=\"refs/tags/gki-2026-03_r1\" />#' default.xml" >/dev/null
sed -i "s#upstream=\"refs/heads/$LB\" />#upstream=\"refs/heads/$LB\" dest-branch=\"refs/heads/$LB\" />#" "$kit/pins/kernel.xml"
KA1=$(q "$kit/pins/kernel.xml" attr aosp revision)
out=$(plan 2>&1); rc=$?
kx=$W/updates/2026-11/kernel.xml
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no kernel.xml proposed" '[[ -f $kx ]]'
want "aosp's revision $(q "$kx" attr aosp revision), not the new branch's ${KB:0:12}" '[[ $(q "$kx" attr aosp revision) = "$KB" ]]'
want "aosp's upstream $(q "$kx" attr aosp upstream) / dest-branch $(q "$kx" attr aosp dest-branch)" \
    '[[ $(q "$kx" attr aosp upstream) = refs/heads/android14-6.1-2026-05 && $(q "$kx" attr aosp dest-branch) = refs/heads/android14-6.1-2026-05 ]]'
want "private/devices' revision $(q "$kx" attr private/devices revision), not its pin ${KD:0:12}" \
    '[[ $(q "$kx" attr private/devices revision) = "$KD" ]]'
want "private/devices' upstream $(q "$kx" attr private/devices upstream) / dest-branch $(q "$kx" attr private/devices dest-branch)" \
    '[[ $(q "$kx" attr private/devices upstream) = refs/tags/gki-2026-03_r1 && $(q "$kx" attr private/devices dest-branch) = refs/tags/gki-2026-03_r1 ]]'
want "no 'aosp: <old> -> <new> (android14-6.1-2026-05)'" 'hasline "$out" "aosp: ${KA1:0:12} -> ${KB:0:12} (android14-6.1-2026-05)"'
want "no 'private/devices: <pin> -> <pin> (gki-2026-03_r1)'" 'hasline "$out" "private/devices: ${KD:0:12} -> ${KD:0:12} (gki-2026-03_r1)"'
verdict "c. kernel project to another branch, and one to a tag of its pinned commit: upstream/dest-branch move" "$(cat "$kx" 2>/dev/null; section Kernel "$out")"

# c3. The kernel manifest takes private/devices from another repo: a note, no proposal
world
KR="$T/gh/LineageOS/android_kernel_google_gs-6.1_devices.git"
git clone -q --bare "$KR" "$T/gh/LineageOS/android_kernel_google_gs-6.1_devices_new.git"
newcommit "$T/gh/LineageOS/android_kernel_google_gs-6.1_devices_new.git" $LB "new repo's" 'echo dn > dev' >/dev/null
newcommit "$T/gh/LineageOS/android_kernel_google_gs-6.1_manifest.git" $LB "devices: another repo" \
  "sed -i 's#name=\"LineageOS/android_kernel_google_gs-6.1_devices\"#name=\"LineageOS/android_kernel_google_gs-6.1_devices_new\"#' default.xml" >/dev/null
out=$(plan 2>&1); rc=$?
nl=$(section "Needs a look" "$out")
kx=$W/updates/2026-11/kernel.xml
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no 'change the pins by hand' note for private/devices" \
    'hasline "$nl" "kernel: private/devices: LineageOS'"'"'s kernel manifest has it from another repo, or with other linkfiles/copyfiles, now: change the pins by hand"'
want "a kernel.xml proposed anyway" '[[ ! -e $kx ]] && ! has "$out" "pins/kernel.xml to take"'
verdict "c. kernel project from another repo: a 'change the pins by hand' note, no kernel.xml" "$out"

# c4. (same world) the repo back, and a linkfile added to aosp: the same note
newcommit "$T/gh/LineageOS/android_kernel_google_gs-6.1_manifest.git" $LB "aosp: a linkfile" \
  "sed -i 's#_devices_new\"#_devices\"#; s#<project name=\"LineageOS/android_kernel_google_gs-6.1\" path=\"aosp\" />#<project name=\"LineageOS/android_kernel_google_gs-6.1\" path=\"aosp\">\n    <linkfile src=\"Makefile\" dest=\"Makefile.top\" />\n  </project>#' default.xml" >/dev/null
out=$(plan 2>&1); rc=$?
nl=$(section "Needs a look" "$out")
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no 'change the pins by hand' note for aosp" \
    'hasline "$nl" "kernel: aosp: LineageOS'"'"'s kernel manifest has it from another repo, or with other linkfiles/copyfiles, now: change the pins by hand"'
want "a kernel.xml proposed anyway" '[[ ! -e $kx ]] && ! has "$out" "pins/kernel.xml to take"'
verdict "c. kernel project with a new linkfile: a 'change the pins by hand' note, no kernel.xml" "$out"

# ================================================================================================
# d. The dry run: "has it already" only when every changed attribute matches. LineageOS changes
#    external/foo's groups (the harness's), and development's clone-depth and linkfiles
world
for r in KernelSU-Next:v3.4.2 NeoZygisk:v2.4; do   # ksu.conf's repos, here (the dry run reads their tags)
    w=$(mktemp -d "$T/w/k.XXXX"); git -C "$w" init -q -b main; echo x > "$w/x"; git -C "$w" add -A
    git -C "$w" commit -qm x; git init -q --bare "$T/ksu/${r%%:*}.git"; git -C "$w" push -q "$T/ksu/${r%%:*}.git" main
    git --git-dir="$T/ksu/${r%%:*}.git" tag "${r#*:}" main; rm -rf "$w"
done
sed -i "s#^src_url=.*#src_url=file://$T/ksu/KernelSU-Next.git#; s#^zygisk_src_url=.*#zygisk_src_url=file://$T/ksu/NeoZygisk.git#" "$kit/ksu/ksu.conf"
newcommit "$T/gh/LineageOS/android.git" $LB "development: depth, a linkfile" \
  "sed -i 's#<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\" />#<project name=\"LineageOS/android_development\" path=\"development\" groups=\"developers\" clone-depth=\"1\">\n    <linkfile src=\"dev.txt\" dest=\"DEV\" />\n  </project>#' snippets/lineage.xml" >/dev/null
out=$(check 2>&1); rc=$?
lm=$(section "LineageOS's manifest since" "$out")
want "check rc $rc / didn't finish" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK="'
want "external/foo isn't 'changed external/foo: groups' alone" 'hasline "$lm" "changed external/foo: groups"'
want "development isn't 'changed development: depth; kids' alone" 'hasline "$lm" "changed development: depth; kids"'
want "says 'has it already'" '! has "$lm" "has it already"'
verdict "d. dry run: LineageOS's groups/depth/linkfile changes ExpressiveOS's manifest lacks aren't 'has it already'" "$out"
# ExpressiveOS takes the groups and the depth, not the linkfile
eos_edit "foo's groups, development's depth" \
  "sed -i 's#path=\"external/foo\" \\(.*\\) groups=\"pdk\" />#path=\"external/foo\" \\1 groups=\"pdk,pdk-fs\" />#; s#\\(path=\"development\" .*\\) groups=\"developers\" />#\\1 groups=\"developers\" clone-depth=\"1\" />#' default.xml"
want "the setup isn't as meant" \
    '[[ $(q "$top/.repo/manifests/default.xml" attr external/foo groups) = pdk,pdk-fs && $(q "$top/.repo/manifests/default.xml" attr development clone-depth) = 1 ]]'
out=$(check 2>&1); rc=$?
lm=$(section "LineageOS's manifest since" "$out")
want "check rc $rc / didn't finish" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK="'
want "external/foo (groups as LineageOS's) not 'has it already'" \
    'hasline "$lm" "changed external/foo: groups; ExpressiveOS'"'"'s manifest has it already"'
want "development (depth matches, linkfile missing) said 'has it already' or not listed" \
    'hasline "$lm" "changed development: depth; kids"'
verdict "d. dry run: 'has it already' for a full match (groups), not for a partial one (depth without the linkfile)" "$out"
eos_edit "development's linkfile" \
  "sed -i 's#\\(<project [^>]*path=\"development\" [^>]*\\) />#\\1>\n    <linkfile src=\"dev.txt\" dest=\"DEV\" />\n  </project>#' default.xml"
want "the setup isn't as meant" '[[ $(q "$top/.repo/manifests/default.xml" kids development) = "linkfile:dev.txt:DEV" ]]'
out=$(check 2>&1); rc=$?
lm=$(section "LineageOS's manifest since" "$out")
want "check rc $rc / didn't finish" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK="'
want "development (depth and linkfile as LineageOS's) not 'has it already'" \
    'hasline "$lm" "changed development: depth; kids; ExpressiveOS'"'"'s manifest has it already"'
verdict "d. dry run: 'has it already' once depth and linkfiles both match" "$out"

# ================================================================================================
# e. plan's fetch of development (LineageOS's, 2 new commits) in a fresh work folder, the tree laid
#    out as repo does: .repo/projects/development.git/objects -> .repo/project-objects/<name>.git
#    (no refs there) (review/planflow/r4-haves.sh, r4b-layout.sh)
world
d=$top/.repo/projects/development.git
o=$top/.repo/project-objects/LineageOS/android_development.git
mkdir -p "$(dirname "$o")"; git init -q --bare "$o"; rm -rf "$o/objects"
mv "$d/objects" "$o/objects"; ln -s "$o/objects" "$d/objects"
PIN=$(q "$top/.repo/manifests/default.xml" attr development revision)
DEVTIP=$(tipof "$T/gh/LineageOS/android_development.git" refs/heads/$LB)
want "the setup isn't as meant (pin not readable through the symlink, or the tip is the pin)" \
    'git --git-dir="$d" cat-file -e "$PIN^{commit}" && [[ $DEVTIP != "$PIN" && -z $(git --git-dir="$o" for-each-ref) ]]'
rm -rf "$W"
# Every fetched pack kept as sent (a small one is otherwise exploded into loose objects, skipping
# those the alternates have), so the scratch repo shows what was downloaded. (HOME is the world's)
git config --global fetch.unpackLimit 1
trace=$WD/aux/trace-packet.txt
rm -f "$trace"
out=$(cd "$T" && GIT_TRACE_PACKET=$trace EOS_UPDATE_JOBS=1 bash "$kit/sources/update.sh" plan 2026-11 "$top" 2>&1); rc=$?
g=$W/git/LineageOS/android_development.git
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "development doesn't move to ${DEVTIP:0:12}" 'has "$out" "development <- LineageOS/android_development $LB: ${PIN:0:12} -> ${DEVTIP:0:12}, 2 new commits"'
verdict "e. repo's layout, fresh work folder: plan READY, development moves" "$out"
want "no trace written" '[[ -s $trace ]]'
want "the fetch of development sent no 'have ${PIN:0:12}' (pin)" 'grep -qE "fetch(-pack)?> have $PIN" "$trace"'
want "the scratch repo's refs/eos/development/ours isn't the pin" \
    '[[ $(git --git-dir="$g" rev-parse -q --verify refs/eos/development/ours) = "$PIN" ]]'
want "refs/eos/development/up isn't LineageOS's tip" '[[ $(git --git-dir="$g" rev-parse -q --verify refs/eos/development/up) = "$DEVTIP" ]]'
want "the scratch repo doesn't borrow the ref-less project-objects ($(cat "$g/objects/info/alternates" 2>/dev/null))" \
    'grep -qxF "$(realpath "$o/objects")" "$g/objects/info/alternates"'
verdict "e. plan's fetch of a moving LineageOS project negotiates a 'have' (the pin) through repo's layout" "$(grep -E ' have ' "$trace" | head -8)"
own=$( { find "$g/objects" -type f -path '*/objects/[0-9a-f][0-9a-f]/*' 2>/dev/null | sed -E 's#.*/([0-9a-f]{2})/([0-9a-f]{38})$#\1\2#'
         for i in "$g"/objects/pack/*.idx; do [[ -f $i ]] && git show-index < "$i" | awk '{print $2}'; done; } | sort -u)
want "the scratch repo holds no objects of its own" '[[ -n $own ]]'
want "the fetch wasn't kept as a pack" 'compgen -G "$g/objects/pack/*.idx" >/dev/null'
want "the pin ${PIN:0:12} was downloaded again (the tree has it)" '! grep -qx "$PIN" <<<"$own"'
want "LineageOS's new tip wasn't downloaded" 'grep -qx "$DEVTIP" <<<"$own"'
want "more than the 2 new commits' objects downloaded ($(grep -c . <<<"$own"))" '[[ $(grep -c . <<<"$own") -le 6 ]]'
verdict "e. only development's new commits were downloaded (not the pin the tree has)" "$own"

echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
