#!/usr/bin/env bash
# ExpressiveOS 2.0's monthly AOSP ASB update check (update-aosp.py check): dry-run check of
# new android-security-17.0.0_r* commits against EOS 2.0's pure-AOSP manifest. Changes nothing
# in the tree, makes no commit and pushes nothing.
# Holds ~/.expressiveos.lock while it runs: setup.sh can't sync under it, and a build waits.
#
#   update-check.sh [top]       # default ~/expressiveos
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update), shared with update.sh
set -euo pipefail
# A stop before update-aosp.py runs still ends with UPDATE_CHECK=FAILED (update-aosp.py prints its own)
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
python3 -I "$kit/sources/update-aosp.py" check --top "$top" --manifest "$mf" --work "$r"
