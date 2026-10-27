#!/bin/bash
# Release several devices at once with p11-routine.sh: every routine starts now, they take the tree
# lock in p11-routine.sh's order (the fewest SystemUI and Settings rebuilds in the shared out/), and
# each one uploads and publishes while the next one builds.
#
#   release-chain.sh [<kodiak|grizzly|cubs|yogi|cheetah|husky>...] [-- <p11-routine.sh options>]
#   e.g. release-chain.sh kodiak grizzly yogi cubs -- --no-sync
#
# No device: kodiak grizzly yogi cubs. The routines start in the order given, a few seconds apart:
# when the tree is free the first one builds first, and the rest follow in p11-routine.sh's order.
# Each routine writes its own log (~/routine-logs/<dev>-<time>.log); its output also goes to
# ~/routine-logs/chain-<time>-<dev>.out. The chain ends with one ROUTINE_RESULT line per device,
# then CHAIN_RESULT=OK (every routine exited 0) or CHAIN_RESULT=FAILED.
set -uo pipefail

devs=(); opts=()
while [ $# -gt 0 ]; do
    case $1 in
        --) shift; opts=("$@"); break ;;
        kodiak|grizzly|cubs|yogi|cheetah|husky)
            printf '%s\n' "${devs[@]}" | grep -qx "$1" || devs+=("$1") ;;
        *) echo "usage: release-chain.sh [<kodiak|grizzly|cubs|yogi|cheetah|husky>...] [-- <p11-routine.sh options>]" >&2; exit 2 ;;
    esac
    shift
done
[ ${#devs[@]} -gt 0 ] || devs=(kodiak grizzly yogi cubs)
for o in ${opts[@]+"${opts[@]}"}; do
    case $o in
        --dry-run|--force|--no-upload|--no-sync) ;;
        *) echo "release-chain.sh passes on only --dry-run, --force, --no-upload and --no-sync, not $o" >&2; exit 2 ;;
    esac
done

stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p ~/routine-logs
echo "== $(date '+%F %T %Z') release chain: ${devs[*]}${opts[*]+ (${opts[*]})}"
pids=()
for d in "${devs[@]}"; do
    out=~/routine-logs/chain-$stamp-$d.out
    ~/p11-routine.sh "$d" ${opts[@]+"${opts[@]}"} > "$out" 2>&1 &
    pids+=($!)
    echo "   $d: started (pid $!, output $out)"
    sleep 5
done

rc=0
for i in "${!devs[@]}"; do
    d=${devs[$i]}
    wait "${pids[$i]}" || rc=1
    r=$(grep -a "^ROUTINE_RESULT=" ~/routine-logs/chain-$stamp-$d.out | tail -1)
    echo "${r:-ROUTINE_RESULT=FAILED device=$d (the routine printed no result; see ~/routine-logs/chain-$stamp-$d.out)}"
done
echo "== $(date '+%F %T %Z') release chain done"
[ $rc = 0 ] && echo "CHAIN_RESULT=OK" || echo "CHAIN_RESULT=FAILED"
exit $rc
