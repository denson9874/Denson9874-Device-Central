#!/usr/bin/env bash
# Stage one or more phones' verified candidates locally up to the pre-upload gate:
#   1. Verify no unmerged try= commits are present in check/ or out/eos*.
#   2. Record check/<candidate>.device-ok ("sha256 <sha256>") if not already written for that zip.
#   3. Run eos-pack.sh --release: packs into ~/releases/expressiveos-<phone>/ (target-files/,
#      target-files/LATEST, ota/<release>.zip, changelog/announcement) WITHOUT uploading to R2.
#   4. Run eos-ota.sh (preview, no --upload): builds and verifies the full OTA and the
#      incremental OTA from the live Updater feed's base build, writes ota/feed/builds/<phone>.json
#      and ota/feed/changelogs/<phone>.txt locally, logs to ~/expressiveos-jobs/ota-<phone>.log,
#      and uploads NOTHING to R2.
#
# When Daryl later approves publishing, running `eos-release.sh` (`expressiveos-pack release
# devices=...`) reuses the exact staged release name and pre-computed incremental OTA package.
#
#   eos-stage.sh <phone>...
set -uo pipefail
umask 022
export LC_ALL=C
kit=$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
jobs=$HOME/expressiveos-jobs times=$HOME/expressiveos-build-times.txt
done=0
t=$(mktemp) || { echo "can't make a temporary file"; echo "STAGE=FAIL"; exit 1; }
trap 'rm -f -- "$t"; [[ $done = 1 ]] || echo "STAGE=FAIL"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

[[ $# -ge 1 ]] || fail "usage: eos-stage.sh <phone>..."
seen=" "
for d in "$@"; do
    [[ $d =~ ^[a-z0-9]+$ && -f $kit/devices/$d.conf ]] || fail "'$d' isn't one of the kit's phones (devices/*.conf)"
    [[ $seen != *" $d "* ]] || fail "$d is named twice"
    seen+="$d "
done
for d in "$@"; do
    st=$HOME/expressiveos/out/eos-$d
    [[ $d != cheetah ]] || st=$HOME/expressiveos/out/eos
    ck=$HOME/releases/expressiveos-$d/check
    if [[ -f $ck/try.txt || -f $st/try.txt ]]; then
        fail "not staging a build with unmerged try= commits ($d)"
    fi
done

mkdir -p -- "$jobs" || fail "can't make $jobs"
for d in "$@"; do rm -f -- "$jobs/ota-$d.log" || fail "can't remove $jobs/ota-$d.log"; done

all=("$@")
n=0
stop() {
    local rest=${all[*]:n}
    echo "DEVICE $1: STAGE=FAIL at $2 (exit $3)${rest:+; not staged: $rest}"
    exit 1
}
header() { echo "== $1 ($n of ${#all[@]}): $2, $(date -u '+%F %T') UTC"; }
timed() {
    local now
    now=$(date -u +%s)
    echo "TIME $1 device=$2 kind=stage fresh=- at=$(date -ud "@$now" +%FT%TZ) secs=$((now - $3))" >> "$times" 2>/dev/null || true
}

for d in "${all[@]}"; do
    n=$((n + 1))
    ck=$HOME/releases/expressiveos-$d/check
    zips=()
    for f in "$ck"/*-fastboot.zip; do if [[ -f $f ]]; then zips+=("$f"); fi; done
    (( ${#zips[@]} == 1 )) || { echo "FAIL: $ck holds ${#zips[@]} fastboot zips, expected 1 candidate"; stop "$d" check 1; }
    cand=${zips[0]}
    zsha=$(sha256sum -- "$cand" | cut -d' ' -f1) || stop "$d" check 1
    dok=$cand.device-ok
    if [[ ! -f $dok ]] || ! grep -qF -- "$zsha" "$dok"; then
        printf 'sha256 %s\nstaged pre-upload gate %s UTC\n' "$zsha" "$(date -u '+%F %T')" > "$dok.part" \
            && mv -f -- "$dok.part" "$dok" || { echo "FAIL: can't write $dok"; stop "$d" check 1; }
    fi

    header "$d" eos-pack.sh
    env EOS_DEVICE="$d" bash "$kit/tools/eos-pack.sh" --release 2>&1 | tee -- "$t"
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && [[ "$(tail -n 1 -- "$t")" = PACK=OK ]] || stop "$d" pack "$rc"

    header "$d" eos-ota.sh
    s=$(date -u +%s)
    env EOS_DEVICE="$d" bash "$kit/tools/eos-ota.sh" 2>&1 | tee -- "$jobs/ota-$d.log"
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && [[ "$(tail -n 1 -- "$jobs/ota-$d.log")" = OTA=OK ]] || stop "$d" ota "$rc"
    timed ota "$d" "$s"

    echo "DEVICE $d: STAGE=OK (packed locally and OTA preview generated; nothing uploaded to R2)"
done
echo "OK: staged locally (nothing uploaded): ${all[*]}"
echo "next: review OTA_PREVIEW feed files (expressiveos-progress, query feed) and approve before R2 upload"
done=1
echo "STAGE=OK"
