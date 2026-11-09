#!/usr/bin/env bash
# Release several phones in one go, each in turn, every step right after the one before:
#   1. eos-pack.sh --upload: check/'s tested candidate released, its target-files to R2
#   2. eos-ota.sh --upload: its full OTA package and the incremental to R2, with the feed files
#      kept in its ota/feed/ (they go to the feed's pull request, as before)
#   3. the web installer: flasher_publish.py, the release's fastboot zip to R2 and the manifest
#      listing it alone (--keep 1: R2 keeps the current release only, Daryl 2026-11-08)
# It stops at the first step that fails: the phones after it aren't touched. Every gate stays
# where it was: eos-pack.sh refuses a candidate without its device-ok or with unpinned keys,
# eos-ota.sh a release older than the feed's build, flasher_publish.py a zip that isn't
# released. The runner's expressiveos-pack release devices=<phone>,... runs it in the one
# eos-pack session, in place of a dispatch per step and phone: on 1.1.2's release
# (2026-11-09) the server sat idle about 45 minutes of the chain's 2 h 23 min between those
# dispatches.
#
#   eos-release.sh <flasher_publish.py> <phone>...
#
# Each phone gets "== <phone> (<n> of <total>): <script>, <time> UTC" lines before its steps
# (for expressiveos-progress) and one DEVICE line: "DEVICE <phone>: RELEASE=OK" or
# "DEVICE <phone>: RELEASE=FAIL at <pack|ota|web> (exit <n>)[; not released: <phones>]".
# Each phone's eos-ota.sh output also goes to ~/expressiveos-jobs/ota-<phone>.log (any older
# one of the phones named goes first), whose feed files expressiveos-progress with query feed
# prints. The OTA and web installer steps' times go to ~/expressiveos-build-times.txt as TIME
# lines (kind=publish), beside the pack's own. The last line is RELEASE=OK or RELEASE=FAIL.
set -uo pipefail
umask 022
export LC_ALL=C
kit=$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
jobs=$HOME/expressiveos-jobs times=$HOME/expressiveos-build-times.txt
done=0
t=$(mktemp) || { echo "can't make a temporary file"; echo "RELEASE=FAIL"; exit 1; }
trap 'rm -f -- "$t"; [[ $done = 1 ]] || echo "RELEASE=FAIL"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

[[ $# -ge 2 ]] || fail "usage: eos-release.sh <flasher_publish.py> <phone>..."
flasher=$1
shift
[[ -f $flasher ]] || fail "no $flasher (the web installer's publish script)"
seen=" "
for d in "$@"; do
    [[ $d =~ ^[a-z0-9]+$ && -f $kit/devices/$d.conf ]] || fail "'$d' isn't one of the kit's phones (devices/*.conf)"
    [[ $seen != *" $d "* ]] || fail "$d is named twice"
    seen+="$d "
done
mkdir -p -- "$jobs" || fail "can't make $jobs"
for d in "$@"; do rm -f -- "$jobs/ota-$d.log" || fail "can't remove $jobs/ota-$d.log"; done

all=("$@")
n=0
stop() {   # stop <phone> <step> <exit>: its DEVICE line, then the end
    local rest=${all[*]:n}
    echo "DEVICE $1: RELEASE=FAIL at $2 (exit $3)${rest:+; not released: $rest}"
    exit 1
}
header() { echo "== $1 ($n of ${#all[@]}): $2, $(date -u '+%F %T') UTC"; }
timed() {   # timed <step> <phone> <since>: its TIME line, as lib.sh's eos_step writes them
    local now
    now=$(date -u +%s)
    echo "TIME $1 device=$2 kind=publish fresh=- at=$(date -ud "@$now" +%FT%TZ) secs=$((now - $3))" >> "$times" 2>/dev/null || true
}

for d in "${all[@]}"; do
    n=$((n + 1))
    header "$d" eos-pack.sh
    env EOS_DEVICE="$d" bash "$kit/tools/eos-pack.sh" --upload 2>&1 | tee -- "$t"
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && [[ "$(tail -n 1 -- "$t")" = PACK=OK ]] || stop "$d" pack "$rc"

    header "$d" eos-ota.sh
    s=$(date -u +%s)
    env EOS_DEVICE="$d" bash "$kit/tools/eos-ota.sh" --upload 2>&1 | tee -- "$jobs/ota-$d.log"
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && [[ "$(tail -n 1 -- "$jobs/ota-$d.log")" = OTA=OK ]] || stop "$d" ota "$rc"
    timed ota "$d" "$s"

    header "$d" flasher_publish.py
    s=$(date -u +%s)
    # The release eos-pack.sh just made, found as the runner's expressiveos-flasher-release finds it
    r=$HOME/releases/expressiveos-$d
    l=$(cat -- "$r/target-files/LATEST" 2>/dev/null) || { echo "FAIL: no $r/target-files/LATEST"; stop "$d" web 1; }
    [[ $l == *-target_files.zip && $l != */* ]] || { echo "FAIL: $r/target-files/LATEST names $l"; stop "$d" web 1; }
    z=$r/${l%-target_files.zip}-fastboot.zip
    [[ -f $z && -f $z.sha256 ]] || { echo "FAIL: no $z with its .sha256"; stop "$d" web 1; }
    [[ -f $z.uploaded ]] || { echo "FAIL: $z isn't released yet (eos-pack.sh --upload)"; stop "$d" web 1; }
    echo "release: $z"
    python3 -I "$flasher" "$d" "$z" --keep 1 2>&1 | tee -- "$t"
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && [[ "$(tail -n 1 -- "$t")" = FLASHER_PUBLISH=OK ]] || stop "$d" web "$rc"
    timed web "$d" "$s"

    echo "DEVICE $d: RELEASE=OK (released, OTA packages on R2, on the web installer)"
done
echo "OK: released: ${all[*]}"
echo "next: the feed's pull request (expressiveos-progress, query feed, prints each phone's feed files)"
done=1
echo "RELEASE=OK"
