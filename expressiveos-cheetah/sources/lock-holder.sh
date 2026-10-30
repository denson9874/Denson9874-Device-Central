# Sourced by update-check.sh and update.sh (after lib.sh).
lock_holder() {   # lock_holder: what holds ~/.expressiveos.lock, as ps shows it, or nothing; never fails
    local l=$HOME/.expressiveos.lock f p n holders=() pid c
    # The processes with the lock file open whose descriptor holds the lock (its fdinfo has a
    # lock: line; one still waiting for it has none). /proc/locks names the pid that took the
    # lock, which may have exited since, handing it on (flock in a subshell)
    while read -r f; do
        p=${f#/proc/} n=${f##*/}
        p=${p%%/*}
        grep -q '^lock:' "/proc/$p/fdinfo/$n" 2>/dev/null && holders+=("$p")
    done < <(find /proc/[0-9]*/fd -lname "$l" 2>/dev/null || true)
    [[ ${#holders[@]} -gt 0 ]] || return 0
    # The first of them to start took it; the others inherited it
    pid=$(ps -o pid= --sort=start_time -p "$(IFS=,; echo "${holders[*]}")" 2>/dev/null | head -1 | tr -d ' ') || true
    [[ -n $pid ]] || return 0
    # Past eos_lock's flock and env to what they run (or the flock still waiting for the other lock)
    while [[ $(cat "/proc/$pid/comm" 2>/dev/null) =~ ^(flock|env)$ ]]; do
        c=$(pgrep -o -P "$pid" 2>/dev/null) || break
        pid=$c
    done
    ps -o args= -p "$pid" 2>/dev/null | cut -c1-200 || true
}
