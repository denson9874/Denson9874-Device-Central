#!/usr/bin/env bash
# update.py's tests (the monthly update's dry run, plan, push and resolution): each script builds
# throwaway worlds of file:// repos standing in for LineageOS, AOSP and ExpressiveOS's GitHub
# (harness.sh), a tree and a copy of this kit, and runs update.sh and update.py on them. Nothing
# leaves the machine and nothing outside $EOS_TEST_WORK (default $TMPDIR/eos-update-tests) is
# touched. Needs git 2.38 or newer and python3. About 10 minutes, the scripts run in parallel.
#
#   run.sh [script...]      # default: all; a script by its name without .sh (round2)
#
# Prints each script's failures and counts, and the log folder; exits 1 if any failed.
set -uo pipefail
here=$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
kit=$(cd "$here/../.." && pwd)
work=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}
case $work/ in
    "$kit"/*) echo "FAIL: EOS_TEST_WORK ($work) is in the kit: the worlds copy the kit" >&2; exit 2 ;;
esac
export EOS_TEST_WORK=$work
logs=$work/logs
mkdir -p "$logs"
names=("$@")
if [[ ${#names[@]} = 0 ]]; then
    for s in "$here"/*.sh; do
        n=$(basename "$s" .sh)
        [[ $n = run || $n = harness || $n = t-resolve ]] || names+=("$n")
    done
fi
for n in "${names[@]}"; do
    [[ -f $here/$n.sh ]] || { echo "FAIL: no $here/$n.sh" >&2; exit 2; }
    ( bash "$here/$n.sh" "$kit" > "$logs/$n.log" 2>&1; echo "rc=$?" >> "$logs/$n.log" ) &
done
wait
bad=0
for n in "${names[@]}"; do
    grep -q '^rc=0$' "$logs/$n.log" || bad=1
    echo "== $n: $(grep -E '^== [0-9]+ passed' "$logs/$n.log" | tail -1 | sed 's/^== //')"
    grep -E '^FAIL' "$logs/$n.log" | sed 's/^/   /'
done
echo "logs: $logs"
exit $bad
