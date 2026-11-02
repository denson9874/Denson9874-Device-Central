#!/usr/bin/env bash
# Regression test (devices): the update with more devices in ExpressiveOS's manifest, the manifest
# lint, verify, and a kit that lacks what the update reads.
#
#   bash devices.sh <kit src>        (the folder with sources/update.py)
#
# Fixed behaviour checked:
#  a. device projects as the six-device manifest has them: an own tree in the organization (kept), a
#     LineageOS -kernels prebuilt with an upstream (moves to its tip, listed under "Projects outside
#     LineageOS's manifest"), LineageOS's and TheMuppets' repos with no upstream (pinned: never
#     contacted, so the dry run and plan pass with those repos gone); plan READY, the commit message
#     counts the outside move; push, the pull request merged, verify OK; then verify DIFFERS when a
#     manifest commit takes a fork off its merge, notes a project added since, and accepts a fork
#     moved past its merge
#  b. the commits a fork's branch has past its pin are listed under its line (dry run and plan)
#  c. a kit missing what the update reads: no pins/kernel.xml, an <include> in it, other projects
#     in it, no ksu/ksu.conf: the dry run ends UPDATE_CHECK=INCOMPLETE naming it, no traceback; plan
#     READY with "kernel: no new pins proposed"; an eos.conf key missing or not a plain value: the
#     dry run and plan stop with UPDATE_CHECK=FAILED / UPDATE_PLAN=NOT_READY (stopped: ...)
#  d. a device's patches (devices/<dev>/patches) count as ExpressiveOS's own changes in a conflict
#  e. a manifest text plan refuses (a comment line): the dry run says so, for the tree's manifest and
#     for GitHub's newer one; plan ends UPDATE_PLAN=NOT_READY (stopped: ...)
#  f. lint: the branch itself OK; good device lines OK with each kind (pinned: on a branch; with
#     clone-depth, fetched by its id, or on a branch where the server won't hand it out by id); bad
#     lines each a problem (organization repo under another remote, and under the default one;
#     fork with clone-depth, pin missing, own upstream branch missing, own pin off its branch,
#     outside pin off its upstream, notdefault, a comment line, a pin the server hands out by id
#     that's on no branch, with and without clone-depth); pull/<n>; last-update.conf changed;
#     update.sh lint without a tree
#  g. a held ~/.expressiveos.lock: the dry run prints UPDATE_CHECK=NOT_RUN, plan UPDATE_PLAN=NOT_RUN
#  h. a stop before update.py runs (no tree) still ends with the status line
#
# Worlds: harness.sh (next to this script), one at a time, in devices under $EOS_TEST_WORK (default
# $TMPDIR/eos-update-tests); removed at the end. Only file:// repos (GIT_ALLOW_PROTOCOL=file).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
H=$HERE/harness.sh
TRES=$HERE/t-resolve.sh
if [[ $# -ne 1 || ! -f $1/sources/update.py ]]; then
    echo "usage: bash $0 <kit src> (the folder with sources/update.py)" >&2
    exit 2
fi
KSRC=$(cd "$1" && pwd)
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/devices
LB=lineage-24.0
rm -rf "$WD"
mkdir -p "$WD"
trap 'rm -rf "$WD"' EXIT
export GIT_ALLOW_PROTOCOL=file

pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { [[ -n ${1:-} ]] && printf '%s\n' "$1" | tail -"${2:-20}" | sed 's/^/    | /'; return 0; }
WHY=
want() {   # want <reason> <bash test, eval'd>: notes reason when the test fails
    eval "$2" || WHY+="${WHY:+; }$1"
}
verdict() {   # verdict <case name> [output to show on failure]
    if [[ -z $WHY ]]; then ok "$1"; else bad "$1: $WHY"; show "${2:-}" 30; fi
    WHY=
}
has() { grep -qF -- "$2" <<<"$1"; }
hasre() { grep -qE -- "$2" <<<"$1"; }
section() {   # section <title start> <text>: the lines of a "== <title>" section
    awk -v t="== $1" 'index($0, t) == 1 {on = 1; next} on && (/^== / || /^report: / || /^UPDATE_/ || /^MANIFEST_LINT=/) {on = 0} on' <<<"$2"
}
entry() {   # entry <path> <text>: lint's lines for project <path>, its head and the indented ones under it
    awk -v t="$1 (" 'index($0, t) == 1 {on = 1; print; next} on && /^    / {print; next} {on = 0}' <<<"$2"
}

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
verify() { (cd "$T" && bash "$kit/sources/update.sh" verify "${1:-2026-11}" "$top"); }
check() { (cd "$T" && bash "$kit/sources/update-check.sh" "$top"); }
lint() { (cd "$T" && bash "$kit/sources/update.sh" lint "$@"); }
tipof() { git --git-dir="$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null; }
newman() { git --git-dir="$W/manifests/eos.git" show refs/eos/update/2026-11:default.xml 2>/dev/null; }
mkrepo() {   # mkrepo <bare> <branch> <file=content>...: a repo with one commit; prints it
    local bare=$1 br=$2 w
    shift 2
    git init -q --bare "$bare"
    w=$(mktemp -d "$T/w/r.XXXX")
    git -C "$w" init -q -b "$br"
    for fc in "$@"; do printf '%s\n' "${fc#*=}" > "$w/${fc%%=*}"; done
    git -C "$w" add -A && git -C "$w" commit -qm "initial $(basename "$bare")" && git -C "$w" push -q "$bare" "$br"
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
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
branchcommit() {   # branchcommit <bare> <from branch> <new branch> <msg> <cmd run in a clone>: a commit on a new branch; prints it
    local bare=$1 from=$2 br=$3 msg=$4 w
    shift 4
    w=$(mktemp -d "$T/w/b.XXXX")
    git clone -q -b "$from" "$bare" "$w"
    git -C "$w" checkout -q -b "$br"
    (cd "$w" && eval "$@")
    git -C "$w" add -A && git -C "$w" commit -qm "$msg" && git -C "$w" push -q origin "$br"
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
tree_sync() {   # the tree follows GitHub's manifest: its checkout, and a bare clone of each project it lacks
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
eos_edit() {   # eos_edit <msg> <cmd in a clone of ExpressiveOS's manifest>: a new commit of it; the tree follows
    newcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos "$1" "$2" >/dev/null
    tree_sync
}
devlines() {   # the husky-like lines: an own tree, LineageOS's kernels prebuilt, LineageOS's zuma and TheMuppets' blobs pinned
    printf '%s\\n' \
        "  <project path=\"device/google/husky\" name=\"device_google_husky\" remote=\"expressiveos\" revision=\"$HUSKY\" upstream=\"refs/heads/expressiveos\" dest-branch=\"refs/heads/expressiveos\" />" \
        "  <project path=\"device/google/shusky-kernels\" name=\"android_device_google_shusky-kernels\" remote=\"lineageos\" revision=\"$SK\" upstream=\"$LB\" />" \
        "  <project path=\"device/google/zuma\" name=\"android_device_google_zuma\" remote=\"lineageos\" revision=\"$ZUMA\" />" \
        "  <project path=\"vendor/google/husky\" name=\"TheMuppets/proprietary_vendor_google_husky\" revision=\"$VH\" />"
}
devrepos() {   # the repos devlines names
    mkdir -p "$T/gh/TheMuppets"
    HUSKY=$(mkrepo "$T/gh/ExpressiveOS/device_google_husky.git" expressiveos "h.mk=husky")
    SK=$(mkrepo "$T/gh/LineageOS/android_device_google_shusky-kernels.git" $LB "k.img=k1")
    ZUMA=$(mkrepo "$T/gh/LineageOS/android_device_google_zuma.git" $LB "z.mk=z1")
    VH=$(mkrepo "$T/gh/TheMuppets/proprietary_vendor_google_husky.git" $LB "v.bin=v1")
    # VH isn't the branch's tip: a server that won't hand out a commit by its id (no
    # uploadpack.allowAnySHA1InWant) gives only its branches' tips
    newcommit "$T/gh/TheMuppets/proprietary_vendor_google_husky.git" $LB "v2" 'echo v2 > v.bin' >/dev/null
}
addlines() {   # addlines <file> <lines>: the lines put in before </manifest>
    python3 -I - "$1" "$2" <<'PY'
import sys
f, lines = sys.argv[1], sys.argv[2].replace("\\n", "\n")
t = open(f).read()
assert t.endswith("</manifest>\n")
open(f, "w").write(t[:-len("</manifest>\n")] + lines + "</manifest>\n")
PY
}

# ================================================================================================
# a. device projects: dry run, plan, push, merge, verify
world
devrepos
eos_edit "husky's projects" "addlines default.xml '$(devlines)'"
SK2=$(newcommit "$T/gh/LineageOS/android_device_google_shusky-kernels.git" $LB "k2" 'echo k2 > k.img')
newcommit "$T/gh/LineageOS/android_device_google_zuma.git" $LB "z2" 'echo z2 > z.mk' >/dev/null
# Pinned: never contacted, so their repos can go
mv "$T/gh/LineageOS/android_device_google_zuma.git" "$T/gh/LineageOS/zuma-gone.git"
mv "$T/gh/TheMuppets/proprietary_vendor_google_husky.git" "$T/gh/TheMuppets/vh-gone.git"
out=$(check 2>&1); rc=$?
outs=$(section "Projects outside LineageOS's manifest" "$out")
# (the test world can't reach KernelSU Next's and NeoZygisk's GitHub: their lines are its only problems)
only_ksu() { [[ -z $(section "Couldn't check" "$1" | grep -vE '^(KernelSU Next|NeoZygisk): |^$') ]]; }
want "check rc $rc, or problems besides KernelSU's" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=" && only_ksu "$out"'
want "no outside block with 2 pinned" 'has "$out" "== Projects outside LineageOS'"'"'s manifest (4): 2 pinned (no upstream: never move), 2 follow their own upstream, unreviewed (1 move)"'
want "no shusky-kernels move" 'has "$outs" "device/google/shusky-kernels <- android_device_google_shusky-kernels lineage-24.0: 1 new commit"'
want "no zuma pinned line" 'has "$outs" "device/google/zuma: pinned at ${ZUMA:0:12} (android_device_google_zuma)"'
want "no vendor/google/husky pinned line" 'has "$outs" "vendor/google/husky: pinned at ${VH:0:12} (TheMuppets/proprietary_vendor_google_husky)"'
want "husky's tree not ExpressiveOS's own" 'has "$out" "== ExpressiveOS'"'"'s own repos with nothing upstream (3)"'
want "shusky-kernels in LineageOS's block" '! has "$(section "LineageOS'"'"'s and AOSP'"'"'s projects" "$out")" "shusky-kernels"'
want "a traceback" '! has "$out" "Traceback"'
verdict "a1. dry run: device projects sorted by kind, pinned ones never contacted" "$out"

out=$(plan 2>&1); rc=$?
want "plan rc $rc, not READY" '[[ $rc = 0 ]] && has "$out" "UPDATE_PLAN=READY"'
want "no outside block" 'has "$out" "== Projects outside LineageOS'"'"'s manifest (4): 1 move to their own upstream'"'"'s tip, unreviewed"'
want "no shusky-kernels move in it" 'has "$(section "Projects outside" "$out")" "device/google/shusky-kernels <- android_device_google_shusky-kernels lineage-24.0: ${SK:0:12} -> ${SK2:0:12}, 1 new commit"'
nm=$(newman)
want "shusky-kernels not at its tip in the new manifest" 'has "$nm" "name=\"android_device_google_shusky-kernels\" remote=\"lineageos\" revision=\"$SK2\""'
want "zuma moved" 'has "$nm" "name=\"android_device_google_zuma\" remote=\"lineageos\" revision=\"$ZUMA\" />"'
want "vendor/google/husky moved" 'has "$nm" "revision=\"$VH\" />"'
want "husky's tree moved" 'has "$nm" "revision=\"$HUSKY\" upstream"'
msg=$(git --git-dir="$W/manifests/eos.git" log -1 --format=%B refs/eos/update/2026-11 2>/dev/null)
want "commit message doesn't count the outside move" 'has "$msg" ", 1 outside LineageOS'"'"'s manifest move to their own upstream;"'
verdict "a2. plan: outside moves listed on their own, pinned ones kept, READY" "$out"

out=$(EOS_PUSH_TOKEN=x push 2>&1); rc=$?
want "push rc $rc, not OK" '[[ $rc = 0 ]] && has "$out" "UPDATE_PUSH=OK"'
git --git-dir="$T/gh/ExpressiveOS/manifest.git" update-ref refs/heads/expressiveos refs/heads/update/2026-11
out2=$(verify 2>&1); rc2=$?
want "verify rc $rc2, not OK" '[[ $rc2 = 0 ]] && has "$out2" "UPDATE_VERIFY=OK (0 problems)"'
want "verify doesn't say merged" 'has "$out2" "is in expressiveos'"'"'s history (merged)"'
verdict "a3. push, merge, verify OK" "$out$out2"

# A later commit takes vendor/lineage back to its old pin, and adds a project: verify says so
VLOLD=$(git --git-dir="$T/gh/ExpressiveOS/manifest.git" show expressiveos~1:default.xml | grep -o 'name="vendor_lineage"[^>]*revision="[0-9a-f]*"' | grep -o '[0-9a-f]\{40\}')
VLNEW=$(tipof "$T/gh/ExpressiveOS/vendor_lineage.git" refs/heads/expressiveos)
EXTRA=$(mkrepo "$T/gh/ExpressiveOS/device_google_extra.git" expressiveos "e=1")
newcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos "vendor/lineage back; extra" \
    "sed -i 's/$VLNEW/$VLOLD/' default.xml; addlines default.xml '  <project path=\"device/google/extra\" name=\"device_google_extra\" remote=\"expressiveos\" revision=\"$EXTRA\" upstream=\"refs/heads/expressiveos\" dest-branch=\"refs/heads/expressiveos\" />\\n'" >/dev/null
out=$(verify 2>&1); rc=$?
want "verify rc $rc, not DIFFERS" '[[ $rc != 0 ]] && has "$out" "UPDATE_VERIFY=DIFFERS (1 problems)"'
want "vendor/lineage not named" 'has "$out" "vendor/lineage: the plan has vendor_lineage ${VLNEW:0:12}, expressiveos has vendor_lineage ${VLOLD:0:12}"'
want "the added project not noted" 'has "$out" "device/google/extra: in expressiveos, not in the plan (added since)"'
verdict "a4. verify DIFFERS: a fork off its merge; a project added since is a note" "$out"

# The fork moved past its merge, the manifest with it: fine
FB=$(newcommit "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos "vendor: after the update" 'echo after > after.mk')
newcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos "vendor/lineage past the update" "sed -i 's/$VLOLD/$FB/' default.xml" >/dev/null
out=$(verify 2>&1); rc=$?
want "verify rc $rc, not OK" '[[ $rc = 0 ]] && has "$out" "UPDATE_VERIFY=OK"'
want "no 'past the plan's' note" 'has "$out" "vendor/lineage: at ${FB:0:12}, past the plan'"'"'s"'
verdict "a5. verify OK with a fork past its merge" "$out"

# ================================================================================================
# b. the commits a fork's branch has past its pin, listed (dry run and plan)
world
VC=$(newcommit "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos "vendor: a device's tweak" 'echo tweak > tweak.mk')
out=$(check 2>&1); rc=$?
want "check rc $rc" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK="'
want "check doesn't list the commit" 'has "$out" "    + ${VC:0:7} t: vendor: a device'"'"'s tweak"'
want "check doesn't count it" 'has "$out" ": the update takes its 1 new commit"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2, not READY" '[[ $rc2 = 0 ]] && has "$out2" "UPDATE_PLAN=READY"'
want "plan doesn't list the commit" 'has "$out2" "    + ${VC:0:7} t: vendor: a device'"'"'s tweak"'
verdict "b. a fork's commits past its pin are listed" "$out$out2"

# ================================================================================================
# c. the kit lacks what the update reads
world
mv "$kit/pins/kernel.xml" "$WD/kernel.xml"
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "no 'kernel: can't read'" 'hasre "$out" "^kernel: can.t read .*pins/kernel.xml"'
want "a traceback" '! has "$out" "Traceback"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2, not READY with the kernel note" '[[ $rc2 = 0 ]] && has "$out2" "UPDATE_PLAN=READY (2 forks merged, 0 need a resolution, 0 problems) kernel: no new pins proposed (Needs a look)"'
want "plan's Needs a look lacks the kernel" 'hasre "$(section "Needs a look" "$out2")" "^kernel: can.t read"'
verdict "c1. no pins/kernel.xml: dry run INCOMPLETE, plan READY without new pins" "$out$out2"

sed 's#<manifest>#<manifest>\n  <include name="more.xml" />#' "$WD/kernel.xml" > "$kit/pins/kernel.xml"
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "no 'has an <include>'" 'has "$out" "kernel: pins/kernel.xml has an <include> of more.xml: it has to be one file"'
want "a traceback or recursion" '! hasre "$out" "Traceback|RecursionError"'
verdict "c2. an <include> in pins/kernel.xml: named, no recursion" "$out"

sed 's#</manifest>#  <project name="LineageOS/android_kernel_google_husky_extra" path="private/extra" revision="0000000000000000000000000000000000000001" />\n</manifest>#' "$WD/kernel.xml" > "$kit/pins/kernel.xml"
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "no 'plan won't propose new pins'" 'has "$out" "pins/kernel.xml has other projects than LineageOS'"'"'s kernel manifest (+[] -['"'"'private/extra'"'"']): plan won'"'"'t propose new pins"'
verdict "c3. a project LineageOS's kernel manifest lacks in the pins: the dry run says plan won't propose" "$out"
cp "$WD/kernel.xml" "$kit/pins/kernel.xml"

mv "$kit/ksu/ksu.conf" "$WD/ksu.conf"
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "no 'ksu/ksu.conf:' problem" 'hasre "$out" "^ksu/ksu.conf: .*No such file"'
want "a traceback" '! has "$out" "Traceback"'
verdict "c4. no ksu/ksu.conf: the dry run finishes, INCOMPLETE" "$out"
mv "$WD/ksu.conf" "$kit/ksu/ksu.conf"

cp "$kit/eos.conf" "$WD/eos.conf"
sed -i '/^EOS_KERNEL_MANIFEST_BRANCH=/d' "$kit/eos.conf"
out=$(check 2>&1); rc=$?
want "check rc $rc / not stopped FAILED" '[[ $rc != 0 ]] && has "$out" "UPDATE_CHECK=FAILED (stopped: eos.conf has no EOS_KERNEL_MANIFEST_BRANCH"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2 / not stopped NOT_READY" '[[ $rc2 != 0 ]] && has "$out2" "UPDATE_PLAN=NOT_READY (stopped: eos.conf has no EOS_KERNEL_MANIFEST_BRANCH"'
want "a traceback" '! has "$out$out2" "Traceback"'
verdict "c5. an eos.conf key missing: dry run and plan stop with their status line" "$out$out2"
cp "$WD/eos.conf" "$kit/eos.conf"
# shellcheck disable=SC2016
sed -i 's/^EOS_LUNCH=.*/EOS_LUNCH=${EOS_LUNCH_OVERRIDE:-lineage_cheetah-cp2a-user}/' "$kit/eos.conf"
out=$(check 2>&1); rc=$?
want "check rc $rc / not stopped on EOS_LUNCH" '[[ $rc != 0 ]] && has "$out" "UPDATE_CHECK=FAILED (stopped: eos.conf'"'"'s EOS_LUNCH is"'
want "not 'a plain value'" 'has "$out" "so it has to be a plain value"'
verdict "c6. a shell expression in eos.conf: stopped, named" "$out"
cp "$WD/eos.conf" "$kit/eos.conf"

# ================================================================================================
# d. a device's patches count as ExpressiveOS's own changes
out=$(check 2>&1)
fbl=$(grep '^frameworks/base <- ' <<<"$out")
want "frameworks/base's line names core/Power.java before any device patch" '! has "$fbl" "own changes touch"'
# (a device of its own: the kit's devices/ holds the real ones' files, which lib.sh reads)
mkdir -p "$kit/devices/eostest/patches/frameworks_base"
printf 'From 0 Mon Sep 17 00:00:00 2001\nSubject: [PATCH] eostest\n\ndiff --git a/core/Power.java b/core/Power.java\n' > "$kit/devices/eostest/patches/frameworks_base/0001-eostest.patch"
out2=$(check 2>&1)
fbl=$(grep '^frameworks/base <- ' <<<"$out2")
want "frameworks/base's conflict doesn't name the device patch's file" 'has "$fbl" "ExpressiveOS'"'"'s own changes touch core/Power.java"'
verdict "d. devices/<dev>/patches count in a fork's conflict" "$out$out2"
rm -rf "$kit/devices/eostest"

# ================================================================================================
# e. a manifest text plan refuses
GH_BAD=$(newcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos "a comment" "sed -i 's#^</manifest>#  <!-- a device -->\n</manifest>#' default.xml")
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "GitHub's newer manifest not named" 'has "$out" "GitHub'"'"'s manifest ${GH_BAD:0:12}: the manifest has something after its projects"'
want "the tree's named (it's fine)" '! has "$out" "the tree'"'"'s manifest: "'
verdict "e1. GitHub's newer manifest in a layout plan refuses: the dry run says so" "$out"
tree_sync
out=$(check 2>&1); rc=$?
want "check rc $rc, not INCOMPLETE" '[[ $rc = 0 ]] && has "$out" "UPDATE_CHECK=INCOMPLETE"'
want "the tree's manifest not named" 'has "$out" "the tree'"'"'s manifest: the manifest has something after its projects"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2 / not stopped NOT_READY" '[[ $rc2 != 0 ]] && has "$out2" "UPDATE_PLAN=NOT_READY (stopped: the manifest has something after its projects"'
verdict "e2. the tree's manifest in a layout plan refuses: dry run says so, plan stops NOT_READY" "$out$out2"

# ================================================================================================
# f. lint
world
devrepos
git --git-dir="$T/gh/LineageOS/android_device_google_zuma.git" config uploadpack.allowAnySHA1InWant true
# zuma's pin isn't its branch's tip either: fetched by its id only where the server allows it
newcommit "$T/gh/LineageOS/android_device_google_zuma.git" $LB "z2" 'echo z2 > z.mk' >/dev/null
out=$(lint 2>&1); rc=$?
want "lint of the branch rc $rc, not OK" '[[ $rc = 0 ]] && has "$out" "MANIFEST_LINT=OK (0 problems, 0 to look at)"'
want "added not 0" 'has "$out" "== Added (0)"'
verdict "f1. lint of the manifest's own branch: OK" "$out"

good=$(branchcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos devices "husky" "addlines default.xml '$(devlines)$(printf '%s\\n' \
    "  <project path=\"device/google/zuma-depth\" name=\"android_device_google_zuma\" remote=\"lineageos\" revision=\"$ZUMA\" clone-depth=\"1\" />" \
    "  <project path=\"vendor/google/husky-depth\" name=\"TheMuppets/proprietary_vendor_google_husky\" revision=\"$VH\" clone-depth=\"1\" />")'")
# Protocol v0, where a server hands out a commit by its id only when it allows that (protocol v2
# over file:// always does)
git config --global protocol.version 0
out=$(lint devices 2>&1); rc=$?
add=$(section "Added" "$out")
want "lint rc $rc, not OK" '[[ $rc = 0 ]] && has "$out" "MANIFEST_LINT=OK (0 problems, 0 to look at)"'
want "husky not own" 'has "$add" "device/google/husky (device_google_husky on expressiveos, ${HUSKY:0:12}, upstream refs/heads/expressiveos): own:"'
want "shusky-kernels not outside" 'has "$add" "device/google/shusky-kernels (android_device_google_shusky-kernels on lineageos, ${SK:0:12}, upstream lineage-24.0): outside:"'
want "zuma not pinned, on a branch" 'has "$add" "device/google/zuma (android_device_google_zuma on lineageos, ${ZUMA:0:12}, no upstream): pinned:" && has "$(entry device/google/zuma "$add")" "its commit is on a branch (repo sync fetches the branches)"'
want "zuma with clone-depth not fetched by id" 'has "$(entry device/google/zuma-depth "$add")" "its commit is there, by its id"'
want "TheMuppets' not found on a branch" 'has "$(entry vendor/google/husky "$add")" "its commit is on a branch (repo sync fetches the branches)"'
want "TheMuppets' with clone-depth not on a branch, by id refused" 'has "$(entry vendor/google/husky-depth "$add")" "its commit is on a branch (the server won'"'"'t hand it out by its id"'
want "kinds line" 'has "$out" "projects by kind: own 2 -> 3, fork 3, lineage 4, outside 1 -> 2, pinned 0 -> 4"'
verdict "f2. lint of good device lines: OK, each kind" "$out"

git --git-dir="$T/gh/ExpressiveOS/manifest.git" update-ref refs/pull/7/head "$good"
out=$(lint pull/7 2>&1); rc=$?
want "lint pull/7 rc $rc, not OK" '[[ $rc = 0 ]] && has "$out" "MANIFEST_LINT=OK" && has "$out" " pull/7 (${good:0:12})"'
out2=$(cd "$T" && bash "$kit/sources/update.sh" lint pull/7 2>&1 </dev/null); rc2=$?
mv "$top" "$T/tree-away"
out3=$(lint pull/7 2>&1); rc3=$?
mv "$T/tree-away" "$top"
want "update.sh lint without a tree rc $rc3" '[[ $rc3 = 0 ]] && has "$out3" "MANIFEST_LINT=OK"'
verdict "f3. lint pull/<n>, and without a tree" "$out$out3"

HSIDE=$(branchcommit "$T/gh/ExpressiveOS/device_google_husky.git" expressiveos side "side" 'echo side > s.mk')
# Commits on no branch, only on a change's ref (as LineageOS's Gerrit changes are): TheMuppets'
# (no fetch by id) one under the change's tip, and zuma's (fetch by id)
offbranch() {   # offbranch <bare> <file>: two commits on refs/changes/01/1/1 only; prints the first
    local c1
    c1=$(branchcommit "$1" $LB chg "change 1" "echo c1 > $2")
    newcommit "$1" chg "change 2" "echo c2 > $2" >/dev/null
    git --git-dir="$1" update-ref refs/changes/01/1/1 refs/heads/chg
    git --git-dir="$1" update-ref -d refs/heads/chg
    echo "$c1"
}
VX=$(offbranch "$T/gh/TheMuppets/proprietary_vendor_google_husky.git" v.bin)
ZX=$(offbranch "$T/gh/LineageOS/android_device_google_zuma.git" z.mk)
SKSIDE=$(newcommit "$T/gh/LineageOS/android_device_google_shusky-kernels.git" $LB "side" 'echo s > s.img')
git --git-dir="$T/gh/LineageOS/android_device_google_shusky-kernels.git" update-ref refs/heads/side "$SKSIDE"
git --git-dir="$T/gh/LineageOS/android_device_google_shusky-kernels.git" update-ref "refs/heads/$LB" "$SK"
bad=$(branchcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos bad "bad lines" "sed -i 's#^  <remote name=\"lineageos\"#  <remote name=\"eosorg\" fetch=\"$G/ExpressiveOS\" />\n  <remote name=\"lineageos\"#' default.xml; sed -i 's#name=\"frameworks_base\" path=\"frameworks/base\" remote=\"expressiveos\"#name=\"frameworks_base\" path=\"frameworks/base\" remote=\"expressiveos\" clone-depth=\"1\"#' default.xml; addlines default.xml '$(printf '%s\\n' \
    "  <project path=\"device/google/b1\" name=\"device_google_husky\" remote=\"eosorg\" revision=\"$HUSKY\" />" \
    "  <project path=\"device/google/b2\" name=\"android_device_google_zuma\" remote=\"lineageos\" revision=\"$(printf '%040d' 7)\" />" \
    "  <project path=\"device/google/b3\" name=\"device_google_husky\" remote=\"expressiveos\" revision=\"$HUSKY\" upstream=\"refs/heads/nope\" />" \
    "  <project path=\"device/google/b4\" name=\"device_google_husky\" remote=\"expressiveos\" revision=\"$HSIDE\" upstream=\"refs/heads/expressiveos\" />" \
    "  <project path=\"device/google/b5\" name=\"android_device_google_shusky-kernels\" remote=\"lineageos\" revision=\"$SKSIDE\" upstream=\"$LB\" />" \
    "  <project path=\"device/google/b6\" name=\"device_google_husky\" remote=\"expressiveos\" revision=\"$HUSKY\" groups=\"notdefault\" />" \
    "  <project path=\"device/google/b7\" name=\"TheMuppets/proprietary_vendor_google_husky\" revision=\"$VX\" clone-depth=\"1\" />" \
    "  <project path=\"device/google/b9\" name=\"android_device_google_zuma\" remote=\"lineageos\" revision=\"$ZX\" />" \
    "  <project path=\"device/google/b10\" name=\"ExpressiveOS/device_google_husky\" revision=\"$HUSKY\" />" \
    "  <!-- b8 -->")'")
out=$(lint bad 2>&1); rc=$?
pr=$(section "Problems" "$out")
want "lint rc $rc, not PROBLEMS" '[[ $rc != 0 ]] && has "$out" "MANIFEST_LINT=PROBLEMS"'
want "b1 (organization under another remote)" 'has "$pr" "device/google/b1: it'"'"'s a repo of ExpressiveOS'"'"'s organization on remote eosorg"'
want "b10 (organization under the default remote)" 'has "$pr" "device/google/b10: it'"'"'s a repo of ExpressiveOS'"'"'s organization on remote github"'
want "b2 (pin missing)" 'has "$pr" "device/google/b2: its commit 000000000000 isn'"'"'t on any branch of $G/LineageOS/android_device_google_zuma"'
want "b3 (own upstream branch missing)" 'has "$pr" "device/google/b3: $G/ExpressiveOS/device_google_husky has no branch nope"'
want "b4 (own pin off its branch)" 'has "$pr" "device/google/b4: its commit ${HSIDE:0:12} isn'"'"'t on its branch expressiveos"'
want "b5 (outside pin off its upstream)" 'has "$pr" "device/google/b5: its commit ${SKSIDE:0:12} isn'"'"'t in lineage-24.0'"'"'s history"'
want "b6 (notdefault)" 'has "$pr" "device/google/b6 is outside repo'"'"'s default sync (notdefault)"'
want "b7 (clone-depth, no fetch by id, on no branch)" 'has "$pr" "device/google/b7: $G/TheMuppets/proprietary_vendor_google_husky won'"'"'t hand out commit ${VX:0:12} by its id, and it isn'"'"'t on any branch"'
want "b9 (fetched by id, but on no branch and no clone-depth)" 'has "$pr" "device/google/b9: its commit ${ZX:0:12} isn'"'"'t on any branch"'
want "b8 (a comment line)" 'has "$pr" "plan would refuse the manifest: the manifest has something after its projects"'
want "fork with clone-depth" 'has "$pr" "frameworks/base: clone-depth 1 on a fork: its merge needs the whole history"'
want "frameworks/base not in Changed" 'has "$(section "Changed" "$out")" "frameworks/base (frameworks_base on expressiveos"'
want "a traceback" '! has "$out" "Traceback"'
verdict "f4. lint of bad lines: each a problem" "$out"

lu=$(branchcommit "$T/gh/ExpressiveOS/manifest.git" expressiveos lu "last update" "printf 'UPDATE=2026-10\nLINEAGE_MANIFEST=$C0\n' > last-update.conf")
out=$(lint lu 2>&1); rc=$?
want "lint rc $rc, not PROBLEMS" '[[ $rc != 0 ]] && has "$out" "it changes last-update.conf, which only an update'"'"'s own commit changes"'
out2=$(lint nope 2>&1); rc2=$?
want "lint of a missing branch rc $rc2 / no FAILED line" '[[ $rc2 != 0 ]] && has "$out2" "MANIFEST_LINT=FAILED (stopped: "'
verdict "f5. lint: last-update.conf changed is a problem; a missing branch stops FAILED" "$out$out2"

git config --global --unset protocol.version

# ================================================================================================
# g. a held ~/.expressiveos.lock
exec 9>"$HOME/.expressiveos.lock"
flock 9
out=$(check 2>&1); rc=$?
want "check rc $rc / no NOT_RUN" '[[ $rc != 0 ]] && has "$out" "UPDATE_CHECK=NOT_RUN (an ExpressiveOS build or setup holds ~/.expressiveos.lock"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2 / no NOT_RUN" '[[ $rc2 != 0 ]] && has "$out2" "UPDATE_PLAN=NOT_RUN (an ExpressiveOS build or setup holds ~/.expressiveos.lock"'
out3=$(lint 2>&1); rc3=$?
want "lint refused under the lock (rc $rc3)" '[[ $rc3 = 0 ]] && has "$out3" "MANIFEST_LINT=OK"'
exec 9>&-
verdict "g. under a held lock: NOT_RUN lines; lint needs no lock" "$out$out2$out3"

# ================================================================================================
# h. a stop before update.py runs
mv "$top" "$T/tree-away"
out=$(check 2>&1); rc=$?
want "check rc $rc / no FAILED line" '[[ $rc != 0 ]] && has "$out" "UPDATE_CHECK=FAILED (stopped: no tree at $top"'
out2=$(plan 2>&1); rc2=$?
want "plan rc $rc2 / no NOT_READY line" '[[ $rc2 != 0 ]] && has "$out2" "UPDATE_PLAN=NOT_READY (stopped: no tree at $top"'
out3=$(verify 2>&1); rc3=$?
want "verify rc $rc3 / no FAILED line" '[[ $rc3 != 0 ]] && has "$out3" "UPDATE_VERIFY=FAILED (stopped: no tree at $top"'
mv "$T/tree-away" "$top"
verdict "h. no tree: the status line still ends the run" "$out$out2$out3"

echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
