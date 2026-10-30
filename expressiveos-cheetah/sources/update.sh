#!/usr/bin/env bash
# ExpressiveOS's monthly update, made (update.py; update-check.sh is its dry run, which changes
# nothing). Runs on the build server, from the runner's expressiveos-update action, which hands
# it the push token as EOS_PUSH_TOKEN (the Actions secret EXPRESSIVEOS_PUSH_TOKEN: a
# fine-grained token of ExpressiveOS's with Contents read and write). The token lives in the
# environment of this run only: never on the server's disk, in a command line or in a log.
#
#   update.sh token               # read-only: may the token push to every ExpressiveOS repo? Nothing pushed
#   update.sh plan <id> [top]     # make update <id> (this kit's sources/updates/<id>): merges, the new
#                                 # manifest, the kernel pins to take; nothing pushed. Ends UPDATE_PLAN=READY
#                                 # or with the conflicts to resolve
#   update.sh push <id> [top]     # push what the last plan of <id> made: the forks' merges, then the
#                                 # manifest's commit as branch update/<id>. Only when Daryl says so
#   update.sh verify <id> [top]   # read-only, after update <id>'s pull request is merged: is everything
#                                 # the plan made in the manifest's branch? Ends UPDATE_VERIFY=OK|DIFFERS
#   update.sh lint [ref]          # read-only: a change of ExpressiveOS's manifest (a branch of its repo,
#                                 # pull/<n>, or a commit; default its branch), read as the update reads
#                                 # it, before it's merged. Ends MANIFEST_LINT=OK|PROBLEMS. No tree needed
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update), shared with update-check.sh;
#                           plan and push keep update <id> in updates/<id> there
set -euo pipefail
# A stop before update.py runs still ends with the command's status line (update.py prints its own)
case ${1:-} in
    token) st=TOKEN_CHECK=FAIL ;;
    lint) st=MANIFEST_LINT=FAILED ;;
    plan) st=UPDATE_PLAN=NOT_READY ;;
    push) st=UPDATE_PUSH=FAILED ;;
    verify) st=UPDATE_VERIFY=FAILED ;;
    *) st= ;;
esac
why=
trap 'e=$?; [[ $e -eq 0 || -z $st ]] || echo "$st (stopped: ${why:-see the FAIL line})"' EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
fail() { why=$*; why=${why//$'\n'/ }; why=${why:0:300}; echo "FAIL: $*" >&2; exit 1; }   # lib.sh's, keeping the reason for the status line
# shellcheck source=lock-holder.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lock-holder.sh"

usage="usage: update.sh token | update.sh lint [ref] | update.sh plan|push|verify <id> [top]"
[[ $# -ge 1 ]] || fail "$usage"
work=${EOS_UPDATE_WORK:-$HOME/expressiveos-update}
not_other "$work"
r=$(realpath -m -- "$work") || fail "can't resolve $work"
case $1 in
    token)
        [[ $# -eq 1 ]] || fail "$usage"
        mkdir -p -- "$r"
        exec python3 -I "$kit/sources/update.py" token --work "$r"
        ;;
    lint)
        [[ $# -le 2 ]] || fail "$usage"
        mkdir -p -- "$r"
        exec python3 -I "$kit/sources/update.py" lint --work "$r" ${2:+-- "$2"}
        ;;
    plan|push|verify)
        [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
        mode=$1 id=$2
        eos_top "${3:-}"
        [[ "$r" != "$top" && "$r" != "$top"/* && "$top" != "$r"/* ]] || fail "the work folder $work is in the tree $top, or holds it"
        # Not while setup or a build runs: the scratch repos borrow the tree's git objects
        exec 8>"$HOME/.expressiveos.lock"
        if ! flock -n 8; then
            h=$(lock_holder) st=
            echo "UPDATE_${mode^^}=NOT_RUN (an ExpressiveOS build or setup holds ~/.expressiveos.lock${h:+: $h})"
            fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock); run this when it's done"
        fi
        mkdir -p -- "$r"
        if [[ $mode = plan ]]; then
            mf=$(tree_manifest) || exit 1
            st=
            python3 -I "$kit/sources/update.py" plan "$id" --top "$top" --manifest "$mf" --work "$r"
        else
            st=
            python3 -I "$kit/sources/update.py" "$mode" "$id" --work "$r"
        fi
        ;;
    *)
        fail "$usage"
        ;;
esac
