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
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update), shared with update-check.sh;
#                           plan and push keep update <id> in updates/<id> there
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"

usage="usage: update.sh token | update.sh plan|push <id> [top]"
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
    plan|push)
        [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
        mode=$1 id=$2
        eos_top "${3:-}"
        [[ "$r" != "$top" && "$r" != "$top"/* && "$top" != "$r"/* ]] || fail "the work folder $work is in the tree $top, or holds it"
        # Not while setup or a build runs: the scratch repos borrow the tree's git objects
        exec 8>"$HOME/.expressiveos.lock"
        flock -n 8 || fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock); run this when it's done"
        mkdir -p -- "$r"
        if [[ $mode = plan ]]; then
            mf=$(tree_manifest) || exit 1
            python3 -I "$kit/sources/update.py" plan "$id" --top "$top" --manifest "$mf" --work "$r"
        else
            python3 -I "$kit/sources/update.py" push "$id" --work "$r"
        fi
        ;;
    *)
        fail "$usage"
        ;;
esac
