#!/usr/bin/env bash
# ExpressiveOS's monthly update, made (update.py; update-check.sh is its dry run, which changes
# nothing). Runs on the build server, from the runner's expressiveos-update action, which hands
# it the push token as EOS_PUSH_TOKEN (the Actions secret EXPRESSIVEOS_PUSH_TOKEN: a
# fine-grained token of ExpressiveOS's with Contents read and write). The token lives in the
# environment of this run only: never on the server's disk, in a command line or in a log.
#
#   update.sh token     # read-only: may the token push to every ExpressiveOS repo? Nothing pushed
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update), shared with update-check.sh
set -euo pipefail
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"

usage="usage: update.sh token"
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
    *)
        fail "$usage"
        ;;
esac
