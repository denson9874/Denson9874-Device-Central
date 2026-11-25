#!/usr/bin/env bash
# ExpressiveOS 2.0's monthly pure-AOSP ASB update (update-aosp.py; update-check.sh is its
# dry run, which changes nothing).
#
#   update.sh plan <id> [top]          # stage update <id> (sources/updates/<id>): ASB cherry-picks,
#                                      # SPL bump, new manifest; nothing pushed. Ends UPDATE_PLAN=READY|CONFLICTS
#   update.sh create-repos <id>        # Mac admin: create new ExpressiveOS ASB fork repos via gh api
#   update.sh push <id> [top]          # fast-forward push staged forks + manifest update/<id> branch
#   update.sh token                    # read-only: check EOS_PUSH_TOKEN push access across EOS 2.0 repos
#   update.sh verify <id> [top]        # read-only, after manifest PR merge: verify live manifest & forks
#   update.sh lint [manifest]          # strict EOS 2.0 manifest validator (40-hex SHAs, zero LineageOS)
#
#   EOS_UPDATE_WORK=<dir>   the work folder (default ~/expressiveos-update), shared with update-check.sh
set -euo pipefail
case ${1:-} in
    lint) st=MANIFEST_LINT=FAIL ;;
    token) st=TOKEN_CHECK=FAIL ;;
    plan) st=UPDATE_PLAN=NOT_READY ;;
    create-repos) st=CREATE_REPOS=FAIL ;;
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

usage="usage: update.sh token | update.sh lint [manifest] | update.sh create-repos <id> | update.sh plan|push|verify <id> [top]"
[[ $# -ge 1 ]] || fail "$usage"
work=${EOS_UPDATE_WORK:-$HOME/expressiveos-update}
r=$(realpath -m -- "$work" 2>/dev/null || python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$work") || fail "can't resolve $work"
case $1 in
    token)
        [[ $# -eq 1 ]] || fail "$usage"
        mkdir -p -- "$r"
        st=
        exec python3 -I "$kit/sources/update-aosp.py" token --work "$r"
        ;;
    lint)
        [[ $# -le 2 ]] || fail "$usage"
        mkdir -p -- "$r"
        st=
        exec python3 -I "$kit/sources/update-aosp.py" lint --work "$r" ${2:+"$2"}
        ;;
    create-repos)
        [[ $# -eq 2 ]] || fail "$usage"
        st=
        exec python3 -I "$kit/sources/update-aosp.py" create-repos "$2" --work "$r"
        ;;
    plan|push|verify)
        [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
        mode=$1 id=$2
        eos_top "${3:-}"
        [[ "$r" != "$top" && "$r" != "$top"/* && "$top" != "$r"/* ]] || fail "the work folder $work is in the tree $top, or holds it"
        # Not while setup or a build runs: the scratch repos borrow the tree's git objects
        exec 8>"$EOS_LOCK"
        if ! flock -n 8; then
            h=$(lock_holder) st=
            echo "UPDATE_${mode^^}=NOT_RUN (an ExpressiveOS build or setup holds ${EOS_LOCK/#"$HOME"/\~}${h:+: $h})"
            fail "an ExpressiveOS build or setup is running (${EOS_LOCK/#"$HOME"/\~}); run this when it's done"
        fi
        mkdir -p -- "$r"
        if [[ $mode = plan ]]; then
            mf=$(tree_manifest) || exit 1
            st=
            python3 -I "$kit/sources/update-aosp.py" plan "$id" --top "$top" --manifest "$mf" --work "$r"
        else
            st=
            python3 -I "$kit/sources/update-aosp.py" "$mode" "$id" --work "$r"
        fi
        ;;
    *)
        fail "$usage"
        ;;
esac
