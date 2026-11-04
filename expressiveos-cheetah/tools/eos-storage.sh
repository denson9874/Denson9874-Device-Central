#!/usr/bin/env bash
# Where ExpressiveOS releases live off the server (Daryl, 2026-11-03): R2 holds each phone's
# current release only, Google Drive the last two as a backup.
#
#   eos-storage.sh list                          read-only: R2's bucket, Drive's backup folder
#                                                (EOS_DRIVE_BACKUP) and each phone's newest
#                                                release here, with the feed's names
#   eos-storage.sh drive <phone>|all [--dry-run] the phone's newest release (eos-pack.sh
#                                                --upload) to <EOS_DRIVE_BACKUP>/<phone>/<release>/,
#                                                then only the newest two release folders stay
#                                                there (older ones go to Drive's trash)
#   eos-storage.sh prune [<phone>] [--dry-run]   R2 keeps each phone's current release only
#
# What prune keeps in R2's expressiveos/<phone>/ (it never touches anything else in the bucket):
#   ota/           the packages the live feed names and the newest release's (its full package,
#                  and the incremental its feed pull request names), each with its .sha256.
#                  ota/test/ (phone-test incrementals) is emptied when the phone is named
#                  (prune <phone>); a run over every phone leaves it, as another phone's test
#                  may be under way
#   target-files/  the newest release's, and the full release each feed names (the live one and
#                  the last OTA upload's): the next incremental's base
#   flasher/       what flasher.json lists (the web installer: flasher_publish.py --keep 1 lists
#                  each channel's newest only), in flasher/ and flasher/testers/. With no
#                  flasher.json, flasher/ is left as is
#   the top level  flasher.json, and the newest release's own ExpressiveOS-* files (an older
#                  release's loose files there go)
# So between an OTA upload and its feed pull request's merge, both releases stay; the next
# prune, once the feed is merged, leaves the new one only. A phone with no release here, or whose
# live feed or flasher.json can't be read, is skipped. R2 deletes can't be undone: --dry-run says
# what would go.
# Drive's copy holds the fastboot zip, the full OTA package, the feed's incremental, the
# target-files (each with its .sha256) and the changelog, each checked against its .sha256
# before the upload. Names and sizes are printed, never a file's contents.
# The last line is STORAGE=OK, or STORAGE=FAIL (exit 1) when anything went wrong: a phone
# skipped, a listing or a removal that failed (each is a "note:" line).
set -uo pipefail
T='' done=0
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "STORAGE=FAIL"
    exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
bad=0
# problem <text>: a note; the run then ends with STORAGE=FAIL
problem() { echo "  note: $*"; bad=$((bad + 1)); }
finish() {
    (( bad == 0 )) || { echo "FAIL: $bad problem(s), see the notes above" >&2; exit 1; }
    done=1; echo "STORAGE=OK"; exit 0
}
kit="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
PHONES="cheetah husky kodiak grizzly cubs yogi"
usage="usage: eos-storage.sh list | drive <phone>|all [--dry-run] | prune [<phone>] [--dry-run]"
mode=${1:-list}; [[ $# -gt 0 ]] && shift
dry=0 which='' named=0
for a in "$@"; do
    case $a in
        --dry-run) dry=1 ;;
        all) which=$PHONES ;;
        *) [[ " $PHONES " == *" $a "* && -z $which ]] || fail "$usage"; which=$a named=1 ;;
    esac
done
case $mode in
    list) [[ -z $which && $dry = 0 ]] || fail "$usage" ;;
    drive) [[ -n $which ]] || fail "$usage" ;;
    prune) which=${which:-$PHONES} ;;
    *) fail "$usage" ;;
esac
RC=~/bin/rclone
[[ -x $RC ]] || fail "no ~/bin/rclone (tools/ota_mirror/README.md)"
rc() { timeout 3600 "$RC" "$@"; }
T=$(mktemp -d) || fail "can't make a temp folder"
# has_remote <name>: rclone has that remote, from its config or from RCLONE_CONFIG_<NAME>_TYPE
has_remote() {
    local v="RCLONE_CONFIG_${1^^}_TYPE"
    [[ -n ${!v:-} ]] || rc listremotes 2> /dev/null | grep -qx -- "$1:"
}
# lsd <remote folder> <out>: its files as <bytes>|<name>; a folder that isn't there (rclone's
# exit 3) has none. Any other failure returns 1
lsd() {
    rc lsf --files-only --format sp --separator '|' "$1" > "$2" 2> "$T/rclone.log" && return 0
    local e=$?
    : > "$2"; (( e == 3 )) && return 0
    tail -2 "$T/rclone.log" >&2; return 1
}
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0} bytes"; }

# phone_conf <phone>: DEST (its release folder), R2 (its part of the bucket), FEED (its live
# feed file) and DRIVE (the backup folder) from eos.conf and devices/<phone>.conf, as lib.sh reads them
phone_conf() {
    local -a v
    mapfile -t v < <(EOS_DEVICE=$1 bash -c 'source "$1/lib.sh" > /dev/null || exit 1
        printf "%s\n" "$EOS_RELEASES" "${EOS_R2_REMOTE:-}" "$EOS_R2_PREFIX" "$EOS_FEED_REPO" "$EOS_FEED_BRANCH" "${EOS_DRIVE_BACKUP:-}"' _ "$kit")
    [[ ${#v[@]} = 6 ]] || { echo "$1: can't read its configuration (lib.sh)"; return 1; }
    [[ ${v[0]} = "releases/expressiveos-$1" ]] || { echo "$1: EOS_RELEASES is '${v[0]}'"; return 1; }
    [[ ${v[1]} =~ ^[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*$ ]] || { echo "$1: EOS_R2_REMOTE is '${v[1]}'"; return 1; }
    [[ ${v[2]} = "expressiveos/$1/" ]] || { echo "$1: EOS_R2_PREFIX is '${v[2]}'"; return 1; }
    [[ ${v[3]} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${v[4]} =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "$1: EOS_FEED_REPO/BRANCH is '${v[3]}' '${v[4]}'"; return 1; }
    DEST=$HOME/${v[0]} BUCKET=${v[1]} R2=${v[1]}/${v[2]%/}
    FEED=https://raw.githubusercontent.com/${v[3]}/${v[4]}/builds/$1.json DRIVE=${v[5]}
    PENDING=$DEST/ota/feed/builds/$1.json
}

# newest: the newest release here (eos-pack.sh writes target-files/LATEST): RTF, BASE, REL
newest() {
    local l
    l=$(cat -- "$DEST/target-files/LATEST" 2> /dev/null) || return 1
    [[ $l =~ ^ExpressiveOS-[A-Za-z0-9._-]+-target_files\.zip$ ]] || return 1
    RTF=$l BASE=${l%-target_files.zip}; REL=$BASE-fastboot.zip
}

# json_names <builds JSON>: the package names it lists, one a line
json_names() {
    python3 -I -c '
import json, re, sys
for e in json.load(open(sys.argv[1])).get("response") or []:
    n = e.get("filename", "")
    if not re.fullmatch(r"ExpressiveOS-[A-Za-z0-9._-]+\.zip", n):
        sys.exit("a package name that is not an ExpressiveOS zip: %r" % n)
    print(n)' "$1"
}
# live_names <out>: the names the live feed lists (none when the phone has no feed file yet)
live_names() {
    local code
    code=$(curl -sS -L --max-time 60 -o "$T/live.json" -w '%{http_code}' -- "$FEED") || return 1
    case $code in
        200) json_names "$T/live.json" > "$1" ;;
        404) : > "$1" ;;
        *) return 1 ;;
    esac
}
# flasher_names <out>: "<channel folder>/<file>" for each file flasher.json lists. FL_NONE=1:
# the phone has no flasher.json (a listing of its folder that worked doesn't name it). A manifest
# that is there but can't be read, or a listing that fails, returns 1
flasher_names() {
    FL_NONE=0
    if ! rc cat "$R2/flasher.json" > "$T/flasher.json" 2> "$T/rclone.log"; then
        lsd "$R2/" "$T/fltop" || return 1
        grep -q '|flasher\.json$' "$T/fltop" && return 1
        FL_NONE=1; : > "$1"; return 0
    fi
    python3 -I -c '
import json, re, sys
dirs = {"release": "flasher", "testers": "flasher/testers"}
for e in json.load(open(sys.argv[1])).get("releases") or []:
    d = dirs[e["channel"]]
    for f in (e.get("zip"), e.get("initBootStock")):
        if f:
            if not re.fullmatch(r"[A-Za-z0-9._-]+", f["file"]):
                sys.exit("flasher.json lists %r" % f["file"])
            print(d + "/" + f["file"])' "$T/flasher.json" > "$1"
}

if [[ $mode = list ]]; then
    echo "== rclone's remotes (names only): $(rc listremotes 2> /dev/null | tr '\n' ' ')"
    phone_conf cheetah || fail "cheetah's configuration"
    echo "== R2, $BUCKET: the top level"
    rc lsf "$BUCKET" > "$T/top" 2> "$T/rclone.log" || { tail -3 "$T/rclone.log" >&2; fail "can't list $BUCKET"; }
    while IFS= read -r e; do
        s=$(rc size --json "$BUCKET/$e" 2> /dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["bytes"])' 2> /dev/null) || s="? 0"
        echo "  $e: ${s% *} files, $(human "${s#* }")"
    done < "$T/top"
    echo "== R2, $BUCKET/expressiveos/: every file (bytes, time, name)"
    rc lsf -R --files-only --format stp --separator '  ' "$BUCKET/expressiveos/" 2> "$T/rclone.log" | sort -k4 \
        || { tail -3 "$T/rclone.log" >&2; echo "note: can't list $BUCKET/expressiveos/"; }
    echo "== Google Drive"
    if [[ -z $DRIVE ]]; then
        echo "note: eos.conf sets no EOS_DRIVE_BACKUP"
    elif ! has_remote "${DRIVE%%:*}"; then
        echo "note: rclone has no ${DRIVE%%:*}: remote (the runner makes it from the RCLONE_DRIVE_TOKEN secret)"
    else
        rc about "${DRIVE%%:*}:" 2>&1 | grep -E '^(Total|Used|Free|Trashed|Other):' || echo "note: rclone about ${DRIVE%%:*}: failed (signed out?)"
        echo "-- $DRIVE (bytes, time, name)"
        rc lsf -R --files-only --format stp --separator '  ' "$DRIVE/" 2>&1 | sort -k4 | head -100
    fi
    for p in $PHONES; do
        echo "== $p"
        phone_conf "$p" || continue
        if newest; then
            echo "newest release: $BASE ($([[ -f $DEST/$REL.uploaded ]] && echo released || echo 'not marked .uploaded'))"
            for f in "$DEST/$REL" "$DEST/ota/$BASE.zip" "$DEST/target-files/$RTF"; do
                [[ -f $f ]] && echo "  ${f#"$DEST"/}: $(human "$(stat -c %s -- "$f")")" || echo "  ${f#"$DEST"/}: not here"
            done
        else
            echo "no release here ($DEST/target-files/LATEST)"
        fi
        if live_names "$T/live"; then echo "live feed: $(tr '\n' ' ' < "$T/live")"; else echo "live feed: can't read $FEED"; fi
        [[ -f $PENDING ]] && echo "feed files of the last OTA upload: $(json_names "$PENDING" | tr '\n' ' ')"
    done
    finish
fi

if [[ $mode = drive ]]; then
    for p in $which; do
        echo "== $p: the newest release to Google Drive"
        phone_conf "$p" || fail "$p's configuration"
        [[ -n $DRIVE ]] || fail "eos.conf sets no EOS_DRIVE_BACKUP"
        [[ $DRIVE =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9\ _./-]+$ && $DRIVE != *..* ]] || fail "EOS_DRIVE_BACKUP ($DRIVE) isn't <rclone remote>:<folder>"
        has_remote "${DRIVE%%:*}" || fail "rclone has no ${DRIVE%%:*}: remote (the runner makes it from the RCLONE_DRIVE_TOKEN secret)"
        newest || fail "$p has no release here ($DEST/target-files/LATEST)"
        [[ -f $DEST/$REL.uploaded ]] || fail "$REL isn't released (eos-pack.sh --upload)"
        files=("$DEST/$REL" "$DEST/ota/$BASE.zip" "$DEST/target-files/$RTF")
        if [[ -f $PENDING ]]; then
            while IFS= read -r n; do
                [[ $n = "$BASE-incremental-from-"* ]] && files+=("$DEST/ota/$n")
            done < <(json_names "$PENDING")
        fi
        bytes=0
        for f in "${files[@]}"; do
            [[ -f $f && -f $f.sha256 ]] || fail "no $f with its .sha256"
            (cd -- "${f%/*}" && sha256sum --quiet -c -- "${f##*/}.sha256") || fail "${f##*/} isn't what its .sha256 says"
            bytes=$((bytes + $(stat -c %s -- "$f")))
        done
        list=()
        for f in "${files[@]}"; do list+=("$f" "$f.sha256"); done
        [[ -f $DEST/$BASE-changelog.txt ]] && list+=("$DEST/$BASE-changelog.txt")
        to="$DRIVE/$p/$BASE"
        echo "${#list[@]} files, $(human "$bytes"), to $to/:"
        for f in "${list[@]}"; do echo "  ${f##*/} ($(human "$(stat -c %s -- "$f")"))"; done
        if [[ $dry = 0 ]]; then
            for f in "${list[@]}"; do
                # Up to 2 hours a file: Drive slows uploads down when it's busy (rateLimitExceeded)
                timeout 7200 "$RC" copyto --drive-chunk-size 64M "$f" "$to/${f##*/}" > "$T/rclone.log" 2>&1 || {
                    grep -E 'ERROR|NOTICE|rateLimit' "$T/rclone.log" | tail -3 | cut -c1-300 >&2
                    fail "the copy of ${f##*/} to $to failed (a re-run copies only what isn't there yet)"; }
            done
            # All of each: Drive has its size (rclone checked its MD5 on the upload)
            rc lsf --files-only --format sp --separator '|' "$to/" > "$T/drive.ls" 2> "$T/rclone.log" || { tail -3 "$T/rclone.log" >&2; fail "can't list $to"; }
            for f in "${list[@]}"; do
                grep -qxF -- "$(stat -c %s -- "$f")|${f##*/}" "$T/drive.ls" || fail "$to/${f##*/} isn't there with $(stat -c %s -- "$f") bytes"
            done
            echo "OK: $to holds all ${#list[@]} files"
        fi
        # The newest two releases stay: by build date, then by when the fastboot zip was made
        # (rclone keeps a file's own time on Drive), then -r<n>. A dry run counts this one in.
        # With no listing, nothing goes to the trash
        if ! rc lsf -R --files-only --format tp --separator '|' "$DRIVE/$p/" > "$T/drive.all" 2> "$T/rclone.log"; then
            [[ $dry = 1 ]] || { tail -3 "$T/rclone.log" >&2; problem "can't list $DRIVE/$p/"; }
            : > "$T/drive.all"
        fi
        python3 -I -c '
import re, sys
ls, p, base, base_t = sys.argv[1:]
pat = re.compile(r"ExpressiveOS-[0-9.]+-([0-9]{8})-%s-[A-Za-z0-9.-]+" % p)
made = {base: base_t}
for l in open(ls):
    t, _, f = l.rstrip("\n").partition("|")
    d, _, n = f.partition("/")
    if n and pat.fullmatch(d) and d != base:
        made.setdefault(d, "")
        if n == d + "-fastboot.zip":
            made[d] = t
def key(d):
    r = re.search(r"-r([0-9]+)$", d)
    return pat.fullmatch(d).group(1), made[d], int(r.group(1)) if r else 1
print("\n".join(sorted(made, key=key)))' "$T/drive.all" "$p" "$BASE" "$(date -r "$DEST/$REL" '+%Y-%m-%d %H:%M:%S')" > "$T/rels" \
            || fail "can't order $DRIVE/$p/'s releases"
        n=$(wc -l < "$T/rels")
        if (( n > 2 )); then
            tail -n 2 "$T/rels" | grep -qxF -- "$BASE" || fail "$BASE wouldn't be one of the newest two on Drive: $(tr '\n' ' ' < "$T/rels")"
            while IFS= read -r old; do
                if [[ $dry = 1 ]]; then echo "would move $DRIVE/$p/$old to Drive's trash"
                elif rc purge --drive-use-trash=true "$DRIVE/$p/$old" > "$T/rclone.log" 2>&1; then echo "moved $DRIVE/$p/$old to Drive's trash"
                else tail -3 "$T/rclone.log" >&2; problem "couldn't move $DRIVE/$p/$old to Drive's trash"; fi
            done < <(head -n $((n - 2)) "$T/rels")
        fi
        if [[ $dry = 1 ]]; then echo "on Drive after this: $(tail -n 2 "$T/rels" | tr '\n' ' ')"
        else echo "on Drive now: $(rc lsf --dirs-only "$DRIVE/$p/" 2> /dev/null | sed 's#/$##' | tr '\n' ' ')"; fi
        echo "DRIVE_BACKUP $p $BASE$([[ $dry = 1 ]] && echo ' (dry run)')"
    done
    finish
fi

freed=0
# prune
for p in $which; do
    echo "== $p: R2 keeps the current release only$([[ $dry = 1 ]] && echo ' (dry run: nothing is removed)')"
    phone_conf "$p" || { problem "skipped $p"; continue; }
    newest || { problem "skipped $p: no release here ($DEST/target-files/LATEST)"; continue; }
    live_names "$T/live" || { problem "skipped $p: can't read its live feed $FEED"; continue; }
    : > "$T/pend"; [[ ! -f $PENDING ]] || json_names "$PENDING" > "$T/pend" || { problem "skipped $p: can't read $PENDING"; continue; }
    flasher_names "$T/fl" || { problem "skipped $p: can't read $R2/flasher.json"; continue; }
    echo "newest release: $BASE; live feed: $(tr '\n' ' ' < "$T/live")"
    keep_ota=" $BASE.zip $BASE.zip.sha256 "
    while IFS= read -r n; do keep_ota+="$n $n.sha256 "; done < <(cat "$T/live" "$T/pend")
    keep_tf=" $RTF $RTF.sha256 "
    while IFS= read -r n; do
        [[ $n = *-incremental-from-* ]] || keep_tf+="${n%.zip}-target_files.zip ${n%.zip}-target_files.zip.sha256 "
    done < <(cat "$T/live" "$T/pend")
    keep_fl=" "
    while IFS= read -r n; do keep_fl+="$n $n.sha256 "; done < "$T/fl"
    for d in ota ota/test target-files flasher flasher/testers; do
        case $d in
            ota) keep=$keep_ota ;;
            ota/test) [[ $named = 1 ]] || { echo "  left as is: ota/test/ (prune $p empties it)"; continue; }; keep=' ' ;;
            target-files) keep=$keep_tf ;;
            flasher*) [[ $FL_NONE = 0 ]] || { echo "  left as is: $d/ (there's no flasher.json)"; continue; }; keep=$keep_fl ;;
        esac
        lsd "$R2/$d/" "$T/ls" || { problem "can't list $d/"; continue; }
        while IFS='|' read -r size f; do
            [[ -n $f ]] || continue
            k=$f; [[ $d = flasher* ]] && k=$d/$f
            if [[ $keep == *" $k "* ]]; then echo "  keeps $d/$f ($(human "$size"))"; continue; fi
            if [[ $dry = 1 ]]; then echo "  would remove $d/$f ($(human "$size"))"; freed=$((freed + size))
            elif rc deletefile "$R2/$d/$f" > "$T/rclone.log" 2>&1; then echo "  removed $d/$f ($(human "$size"))"; freed=$((freed + size))
            else tail -2 "$T/rclone.log" >&2; problem "couldn't remove $d/$f"; fi
        done < "$T/ls"
    done
    # An older release's loose files in the phone's folder go too; anything else is left as it is
    lsd "$R2/" "$T/ls" || problem "can't list the phone's folder"
    while IFS='|' read -r size f; do
        [[ -n $f && $f != flasher.json ]] || continue
        if [[ $f != ExpressiveOS-*-"$p"-* || $f = "$BASE"[-.]* ]]; then echo "  left as is: $f"; continue; fi
        if [[ $dry = 1 ]]; then echo "  would remove $f ($(human "$size"))"; freed=$((freed + size))
        elif rc deletefile "$R2/$f" > "$T/rclone.log" 2>&1; then echo "  removed $f ($(human "$size"))"; freed=$((freed + size))
        else tail -2 "$T/rclone.log" >&2; problem "couldn't remove $f"; fi
    done < "$T/ls"
done
echo "R2_PRUNE $([[ $dry = 1 ]] && echo 'would free' || echo freed) $(human "$freed")"
finish
