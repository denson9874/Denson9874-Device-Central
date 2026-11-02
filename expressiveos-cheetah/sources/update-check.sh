#!/usr/bin/env bash
# ExpressiveOS's monthly update, checked (update.py check): what LineageOS has added since the
# sources ExpressiveOS's manifest pins (and through it Google's AOSP tags and the monthly
# security patches), and whether ExpressiveOS's forks of LineageOS's repos would take it
# cleanly. A dry run: it changes nothing in the tree, makes no commit and pushes nothing.
# update.py fetches and merges in scratch repos in the work folder, which borrow the tree's git
# objects (git alternates: read, never written), so only the new commits are downloaded.
# It holds ~/.expressiveos.lock while it runs: setup.sh can't sync under it, and a build waits.
#
#   update-check.sh [top]       # default ~/expressiveos
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update): the scratch repos and
#                           reports/update-check-<time>.txt. Shared with update.sh, whose plan and
#                           push keep an update there until its pull request is merged and its
#                           kernel.xml committed; safe to delete when no update is under way
#   EOS_UPDATE_JOBS=<n>     projects checked at once (default 6)
set -euo pipefail
# A stop before update.py runs still ends with UPDATE_CHECK=FAILED (update.py prints its own)
st=UPDATE_CHECK=FAILED why=
trap 'e=$?; [[ $e -eq 0 || -z $st ]] || echo "$st (stopped: ${why:-see the FAIL line})"' EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
fail() { why=$*; why=${why//$'\n'/ }; why=${why:0:300}; echo "FAIL: $*" >&2; exit 1; }   # lib.sh's, keeping the reason for the status line
# shellcheck source=lock-holder.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lock-holder.sh"

[[ $# -le 1 ]] || fail "usage: update-check.sh [top]"
eos_top "${1:-}"
work=${EOS_UPDATE_WORK:-$HOME/expressiveos-update}
not_other "$work"
r=$(realpath -m -- "$work") || fail "can't resolve $work"
[[ "$r" != "$top" && "$r" != "$top"/* && "$top" != "$r"/* ]] || fail "the work folder $work is in the tree $top, or holds it"
exec 8>"$HOME/.expressiveos.lock"
if ! flock -n 8; then
    h=$(lock_holder) st=
    echo "UPDATE_CHECK=NOT_RUN (an ExpressiveOS build or setup holds ~/.expressiveos.lock${h:+: $h})"
    fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock); check again when it's done"
fi
mf=$(tree_manifest) || exit 1
mkdir -p -- "$r"
st=
python3 -I "$kit/sources/update.py" check --top "$top" --manifest "$mf" --work "$r"
