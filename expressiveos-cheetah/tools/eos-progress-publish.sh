#!/usr/bin/env bash
# The live build page (Daryl, 2026-11-11: "view build progress so I don't have to continue to
# prompt threads"): while a runner session (eos-build, eos-pack) runs, this sends what
# eos-progress.py prints to R2 once a minute, where tools/progress-page/index.html, served by
# the OTA mirror Worker (tools/ota_mirror/), reads it. It ends with the session, after one last
# send that holds the session's result, so nothing of it stays running on the server.
#
#   eos-progress-publish.sh <pid of the session's job script> [<seconds between sends: 60>]
#   eos-progress-publish.sh --where      # the page's address, for Daryl only (see below)
#
# The runner's launch() copies this, eos-progress.py and the page to ~/expressiveos-jobs/progress/
# and starts it from the job script, so it is no script of the kit's folder (the kit can't be
# replaced while one runs). It must never stop or slow a build: every failure here is silent,
# and each send has a time limit.
#
# Where: <EOS_R2_REMOTE>/expressiveos/progress/<key>/{index.html,status.txt}. The mirror is
# public and lists nothing, so the page's only lock is <key>: 32 hex digits made here on the
# first run, kept in ~/.expressiveos-progress-key (mode 600). The key and the page's address
# are never printed by the loop, and --where must not be run in a runner job: the repo's
# Actions logs are public. status.txt holds eos-progress.py's output as it is, so the session
# log's last 40 lines too (file paths and compiler output; the kit prints no key material).
set -u
RC=~/bin/rclone
KEYFILE=~/.expressiveos-progress-key
here=$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)

remote=$(bash --noprofile --norc -c '. "$1" > /dev/null 2>&1; printf %s "${EOS_R2_REMOTE:-}"' _ ~/expressiveos-cheetah/eos.conf 2> /dev/null)
[[ $remote =~ ^[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*$ ]] || remote=

key() {   # print the key, making it on the first run
    local k
    if [[ ! -s $KEYFILE ]]; then
        k=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        ( umask 077; printf '%s\n' "$k" > "$KEYFILE.$$" ) && mv -f -- "$KEYFILE.$$" "$KEYFILE" || return 1
    fi
    k=$(head -n 1 -- "$KEYFILE")
    [[ $k =~ ^[0-9a-f]{32}$ ]] || return 1
    printf %s "$k"
}

if [[ ${1:-} = --where ]]; then
    k=$(key) || { echo "FAIL: can't read or make $KEYFILE" >&2; exit 1; }
    mirror=$(bash --noprofile --norc -c '. "$1" > /dev/null 2>&1; printf %s "${EOS_OTA_MIRROR:-}"' _ ~/expressiveos-cheetah/eos.conf 2> /dev/null)
    [[ -n $mirror ]] || { echo "FAIL: eos.conf has no EOS_OTA_MIRROR" >&2; exit 1; }
    echo "${mirror%/}/expressiveos/progress/$k/index.html"
    exit 0
fi

pid=${1:-} every=${2:-60}
[[ $pid =~ ^[0-9]+$ && $every =~ ^[0-9]+$ && $every -ge 1 ]] || { echo "usage: ${0##*/} <pid> [<seconds>] | --where" >&2; exit 2; }
# The session's terminal goes away when the session ends: the last send comes after that
trap '' HUP
[[ -x $RC && -n $remote ]] || exit 0
k=$(key) || exit 0
dest=$remote/expressiveos/progress/$k
T=$(mktemp -d "${TMPDIR:-/tmp}/eos-progress-publish.XXXXXX") || exit 0
trap 'rm -rf -- "$T"' EXIT

put() {   # put <file> <name> <content type> <cache control>
    timeout 45 "$RC" copyto --s3-no-check-bucket --header-upload "Content-Type: $3" \
        --header-upload "Cache-Control: $4" "$1" "$dest/$2" > /dev/null 2>&1 || true
}
send() {
    {
        echo "PUBLISHED at=$(date -u +%FT%TZ) every=$every"
        timeout 30 python3 -I "$here/eos-progress.py" 2>&1 || echo "PUBLISH_ERROR eos-progress.py ended $?"
    } > "$T/status.txt"
    put "$T/status.txt" status.txt 'text/plain; charset=utf-8' no-store
}

[[ ! -f $here/index.html ]] || put "$here/index.html" index.html 'text/html; charset=utf-8' no-cache
end=$(( $(date +%s) + 86400 ))   # no session runs a day: never outlive one by more
while kill -0 "$pid" 2> /dev/null && (( $(date +%s) < end )); do
    send
    # In 2 s steps, so this ends within seconds of the session
    for (( i = 0; i < every; i += 2 )); do
        kill -0 "$pid" 2> /dev/null || break
        sleep 2
    done
done
sleep 2
send
