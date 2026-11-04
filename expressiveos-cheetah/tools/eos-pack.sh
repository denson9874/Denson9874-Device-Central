#!/usr/bin/env bash
# Pack an ExpressiveOS build of a phone (EOS_DEVICE, cheetah unless set; eos-images.sh) as a
# `fastboot update` zip, the only way to install it (a clean flash). It ships no root: the
# zip's init_boot is the build's stock one.
#
#   eos-pack.sh             # verify, then pack the candidate into ~/<EOS_RELEASES>/check
#                           # (replaced each time)
#   eos-pack.sh --release   # the tested candidate into ~/<EOS_RELEASES>
#   eos-pack.sh --upload    # --release, then upload its target-files to R2 (EOS_R2_REMOTE):
#                           # no SourceForge (Daryl, 2026-11-03); the zip goes to the web
#                           # installer (tools/expressiveos_flasher) and the OTA to the
#                           # Updater (tools/eos-ota.sh), both on R2
#   eos-pack.sh --testers   # check/'s candidate, not yet tested on a phone, to testers:
#                           # SourceForge's <EOS_SF_DIR>/testers and ~/<EOS_RELEASES>/testers
#
# After a quick build (EOS_QUICK=1 eos-images.sh: the images only, m droid, no OTA package or
# target-files; lib.sh), eos-pack.sh packs a quick candidate into check/ instead:
# <name>-quick-fastboot.zip, to flash
# and test a change on a phone. It needs EOS_STATE's quick.ok (only a complete quick
# eos-images.sh run writes it: the sha256 of every file the zip takes from out/, which must all
# still match; with EOS_SUPER_EMPTY=factory its super_empty.img is the newest factory zip's, as
# for a full build) and runs eos-verify.sh
# again as a quick build. Its .pack-ok says "build quick", and --release, --upload and --testers
# all refuse it: phones installed from it could take no incremental OTA, and a release must be
# the very zip that was tested, from a full build. It replaces check/'s candidate, as any
# candidate run does.
#
# Each candidate and release keeps the target-files zip its OTA package was made from
# (EOS_STATE's target-files.ok, out/eos/ for cheetah; patches/vendor_lineage/0003), the
# source of any incremental OTA from it later: check/<name>-target_files.zip, then
# target-files/ in the release folder, named after the release, with its .sha256.
# target-files/LATEST names the newest release's, which server-cleanup.sh never removes.
# A release also keeps out/'s OTA package (build.ok's, which eos-verify.sh checked), as
# ota/<release>.zip with its .sha256: tools/eos-ota.sh publishes it for the Updater, with an
# incremental from the release before it.
#
# The on-device gate, as on husky: after flashing and testing check/<zip>, write
# check/<zip>.device-ok with the line "sha256 <its sha256>". --release and --upload also
# need ExpressiveOS's keys pinned in eos.conf (KEYS_CHECK=OK, not UNPINNED), and pack the
# zip again from out/: it must come out byte for byte the zip that was tested.
# Every run but --testers (and a quick candidate's, above) needs EOS_STATE's build.ok naming
# out/'s OTA package (only a complete eos-images.sh run writes it) and runs eos-verify.sh
# again. A released name is never overwritten: a second release on the same day gets -r2, -r3...
# A candidate run also writes check/<zip>.pack-ok: the zip's sha256, whether the keys were
# pinned (keys OK or UNPINNED), whether its images are its target-files' (incremental-base
# OK or NO), the build (full or quick), the kit and the date. --testers works from check/
# alone (out/ may be gone since): it needs the candidate's zip to match its .sha256 and
# .pack-ok, a full build, and keys OK and incremental-base OK there, but no .device-ok; it uploads the zip and its .sha256
# to <EOS_SF_DIR>/testers, copied to ~/<EOS_RELEASES>/testers, never over
# another file of the same name (-r2, -r3...), and never touches the release folder's own
# files, the target-files or a feed. Only ever on that explicit flag.
# The zip holds what out/fastboot-info.txt flashes (ROM partitions, super_empty: out/'s, or
# with EOS_SUPER_EMPTY=factory the newest factory image zip's; vendor_kernel_boot too with
# EOS_FLASH_VKB=1), not the bootloader and radio: users flash the latest stock firmware
# first, and the OTA carries it. The OTA package itself is published for the Updater by
# tools/eos-ota.sh, not this one.
# The last line is PACK=OK or PACK=FAIL.
set -euo pipefail
# The same out/ packs into the same bytes whoever runs this: file modes, the order of the
# zip's entries and its (DOS, local-time) timestamps don't depend on the shell
umask 022
export LC_ALL=C TZ=UTC
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "PACK=FAIL"
    exit $rc
}
trap cleanup EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
mode=${1:-}
case "$mode" in ''|--release|--upload|--testers) ;; *) fail "usage: eos-pack.sh [--release | --upload | --testers]" ;; esac
[[ $# -le 1 ]] || fail "usage: eos-pack.sh [--release | --upload | --testers]"
eos_top ""
cd "$top"
O=$EOS_PRODUCT_OUT
# Not while an ExpressiveOS build or setup runs: out/ would change under the zip (--testers
# reads check/ only, which a candidate run, under this lock too, rewrites)
exec 8>"$HOME/.expressiveos.lock"
flock -n 8 || fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock)"
# A build started by hand changes out/ only, which --testers never reads
if [[ "$mode" != --testers ]]; then
    b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"
fi
# What the last eos-images.sh run built: a full build (build.ok) or a quick one (quick.ok,
# EOS_QUICK=1: the images only), whatever EOS_QUICK says here. The checks below (eos-verify.sh,
# eos-keys-check.sh out) are told which. --testers reads check/ alone
quick=0
if [[ "$mode" != --testers && -f $EOS_STATE/quick.ok && -f $EOS_STATE/build.ok ]]; then
    # This kit's eos-images.sh removes all three records before it builds, so both are there
    # only when a kit from before quick builds (which leaves quick.ok) made a full build since
    [[ $EOS_STATE/build.ok -nt $EOS_STATE/quick.ok ]] \
        || fail "$EOS_STATE holds both build.ok and quick.ok, quick.ok the newer: run eos-images.sh again"
    rm -f -- "$EOS_STATE/quick.ok" || fail "can't remove $EOS_STATE/quick.ok"
    echo "note: removed $EOS_STATE/quick.ok, older than build.ok: a kit from before quick builds made a full build since the quick one"
fi
if [[ "$mode" != --testers && -f $EOS_STATE/quick.ok ]]; then
    [[ -z "$mode" ]] || fail "the last build was a quick one ($EOS_STATE/quick.ok: the images only, no OTA package or target-files): $mode needs a full build (eos-images.sh without EOS_QUICK), packed with eos-pack.sh, flashed and tested"
    quick=1
fi
EOS_QUICK=$quick
export EOS_QUICK
# For the runner's expressiveos-progress (lib.sh's eos_step, which reads both): a candidate is
# of the build's kind
# shellcheck disable=SC2034
case $mode in
    '') EOS_RUN_KIND=full; [[ $quick = 0 ]] || EOS_RUN_KIND=quick ;;
    *) EOS_RUN_KIND=${mode#--} ;;
esac
# shellcheck disable=SC2034
EOS_RUN_FRESH=-
eos_step pack

# ExpressiveOS's own release folder, never Evolution X's: ~/releases/expressiveos-*/ and
# its check/, as named, with no symlink anywhere on the way. Checked before anything is made
[[ "$EOS_RELEASES" =~ ^releases/expressiveos-[a-z0-9-]+$ ]] || fail "devices/$EOS_DEVICE.conf's EOS_RELEASES ($EOS_RELEASES) isn't releases/expressiveos-<something>"
DEST=$HOME/$EOS_RELEASES; CHECK=$DEST/check
want=$(cd ~ && pwd -P)/$EOS_RELEASES
dirs=("$DEST" "$CHECK" "$DEST/target-files" "$DEST/ota")
[[ "$mode" != --testers ]] || dirs+=("$DEST/testers")
for f in "${dirs[@]}"; do
    d=$(realpath -m -- "$f") || fail "can't resolve $f"
    [[ "$d" = "$want${f#"$DEST"}" ]] || fail "$f leads to $d, not ExpressiveOS's own folder (a symlink?)"
done
mkdir -p -- "$CHECK"
# And its own SourceForge folder, never Evolution X's cheetah/17
[[ "$EOS_SF_DIR" == /home/frs/project/*/expressiveos/* ]] || fail "devices/$EOS_DEVICE.conf's EOS_SF_DIR ($EOS_SF_DIR) isn't an expressiveos/ folder"
# And its own R2 prefix for the target-files, never Evolution X's cheetah/17
R2TF=
if [[ -n "${EOS_R2_REMOTE:-}" ]]; then
    [[ "$EOS_R2_REMOTE" =~ ^[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*$ ]] || fail "eos.conf's EOS_R2_REMOTE ($EOS_R2_REMOTE) isn't <rclone remote>:<bucket>"
    [[ "$EOS_R2_PREFIX" =~ ^expressiveos/[a-z0-9-]+/$ ]] || fail "devices/$EOS_DEVICE.conf's EOS_R2_PREFIX ($EOS_R2_PREFIX) isn't expressiveos/<device>/"
    R2TF=$EOS_R2_REMOTE/${EOS_R2_PREFIX}target-files
fi

sf() { sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 daryldenson0405@frs.sourceforge.net; }
rc2() { ~/bin/rclone "$@"; }
r2_taken() {   # r2_taken <name> <file>: R2's target-files/<name> holds something other than <file>
    local rc=0
    rc2 lsf --files-only "$R2TF/" > "$T/r2.ls" 2> "$T/r2.log" || rc=$?
    # rclone exits 3 (directory not found) while nothing was ever uploaded there
    (( rc == 0 || rc == 3 )) || { tail -3 "$T/r2.log" >&2; fail "can't tell whether $R2TF/$1 exists"; }
    (( rc == 0 )) && grep -qxF -- "$1" "$T/r2.ls" || return 1
    rc2 cat "$R2TF/$1.sha256" > "$T/remote.sha256" 2> /dev/null || true
    [[ "$(cut -d' ' -f1 "$T/remote.sha256" 2>/dev/null)" != "$(sha256sum -- "$2" | cut -d' ' -f1)" ]]
}
taken() {   # taken <name> <file>: <name> already holds something other than <file>, here or (--upload, --testers) where it's uploaded
    if [[ -e $DEST/$1 ]] && ! cmp -s -- "$2" "$DEST/$1"; then return 0; fi
    [[ "$mode" = --upload || "$mode" = --testers ]] || return 1
    if [[ $1 = target-files/* && -n "$R2TF" ]]; then r2_taken "${1#target-files/}" "$2"; return; fi
    # --upload checks R2's target-files only: releases no longer go to SourceForge
    [[ "$mode" = --testers ]] || return 1
    # SourceForge too, even when the copy here matches: the copies here may have been
    # cleaned up since that upload and released again from another build. sftp -b ends
    # with 1 and "not found" on an ls of a file that isn't there; any other failure (no
    # connection: 255) says nothing about the name
    local rc=0
    printf 'ls %s/%s\nbye\n' "$EOS_SF_DIR" "$1" | sf > "$T/ls.log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        (( rc == 1 )) && grep -qF 'not found' "$T/ls.log" && return 1
        tail -3 "$T/ls.log" >&2; fail "can't tell whether $EOS_SF_DIR/$1 exists on SourceForge"
    fi
    rm -f -- "$T/remote.sha256"
    printf 'get %s/%s.sha256 %s/remote.sha256\nbye\n' "$EOS_SF_DIR" "$1" "$T" | sf > /dev/null 2>&1 || true
    [[ "$(cut -d' ' -f1 "$T/remote.sha256" 2>/dev/null)" != "$(sha256sum -- "$2" | cut -d' ' -f1)" ]]
}

generate_changelog() {   # generate_changelog <changelog.txt> <announcement.md> <build name> <fastboot zip>
    local out=$1 ann=$2 bname=$3 zip=$4 spl notes
    # The build's own security patch level, not the day it was packed (a release packs out/,
    # which it first checks is the tested candidate)
    spl=$(sed -n 's/^ro\.build\.version\.security_patch=//p' "$O/system/build.prop" 2> /dev/null | head -1 || true)
    [[ "$spl" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "no security patch level (ro.build.version.security_patch) in $O/system/build.prop"
    [[ -n "${EOS_MODEL:-}" ]] || fail "devices/$EOS_DEVICE.conf has no EOS_MODEL for the release notes"
    # This release's notes, written by hand in Expressive Launcher's announcement format (see
    # the file's own header): the same text goes to the phone, XDA and Telegram
    notes=$kit/release-notes/$EOS_VERSION.md
    [[ -f "$notes" ]] || fail "no release notes for ExpressiveOS $EOS_VERSION: write $notes (copy the last release's)"
    mkdir -p -- "$(dirname -- "$out")" "$(dirname -- "$ann")"
    # {{KIT_REV}}: the kit's commit; a copy the runner installed (rsync, no .git) names it in
    # INSTALLED_FROM as <ref>@<commit>
    python3 -I - "$notes" "$out" "$ann" "$EOS_DEVICE" "$EOS_VERSION" "$EOS_MODEL" "$bname" "$spl" \
        "$(sha256sum -- "$zip" | cut -d' ' -f1)" "$(git -C "$kit" rev-parse HEAD 2>/dev/null || sed -n '1s/^[^@]*@//p' "$kit/INSTALLED_FROM" 2>/dev/null | grep . || echo unknown)" \
        "https://expressiveos-flash.daryldenson-apps.workers.dev" <<'EOF' \
        || fail "can't write the release notes from $notes"
import re, sys
notes, out, ann, dev, version, model, build, spl, sha, kitrev, downloads = sys.argv[1:]
values = {'VERSION': version, 'MODEL': model, 'DEVICE': dev, 'BUILD': build, 'SPL': spl,
          'SHA256': sha, 'KIT_REV': kitrev, 'DOWNLOADS': downloads}
text = re.sub(r'<!--[\s\S]*?-->\n?', '', open(notes, encoding='utf-8').read()).strip() + '\n'
lines = []
for line in text.split('\n'):
    m = re.match(r'@([a-z0-9]+) (.*)$', line)
    if m:
        if m.group(1) == dev:
            lines.append(m.group(2))
        continue
    lines.append(line)
text = re.sub(r'\{\{([A-Z0-9_]+)\}\}', lambda m: values.get(m.group(1), m.group(0)), '\n'.join(lines))
left = sorted(set(re.findall(r'\{\{[^}]*\}\}', text)))
if left:
    sys.exit('unknown placeholders: ' + ' '.join(left))
open(ann, 'w', encoding='utf-8').write(text)

# The phone's copy: Studio's What's new shows plain text (a run of 20 "=" in its accent
# colour), the Updater renders Markdown, so plain lines that read well both ways
def answer(m):
    return 'Answer: ' + re.sub(r'</?b>', '', m.group(1)).strip()
plain = re.sub(r'<details>\s*<summary>[\s\S]*?</summary>([\s\S]*?)</details>', answer, text)
rule = '=' * 30
res = []
for line in plain.split('\n'):
    if re.match(r'#{1,3} ', line):
        line = line.split(' ', 1)[1] + '\n' + rule
    elif line.startswith('#### '):
        line = line[5:]
    elif line.strip() == '---':
        line = '─' * 23
    elif line.startswith('> '):
        line = line[2:].strip()
        if len(line) > 1 and line.startswith('*') and line.endswith('*'):
            line = line[1:-1]
    line = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', lambda m: m.group(2) if m.group(1) == m.group(2) else m.group(1) + ' (' + m.group(2) + ')', line)
    line = line.replace('**', '').replace('`', '')
    res.append(re.sub(r'\*([^*\n]+)\*', r'\1', line))
plain = re.sub(r'\n{3,}', '\n\n', '\n'.join(res)).strip() + '\n'
if plain.count('\n') > 200:
    sys.exit("the phone's copy is %d lines; the Updater shows 200" % plain.count('\n'))
open(out, 'w', encoding='utf-8').write(plain)
EOF
}

if [[ "$mode" = --testers ]]; then
    # Untested builds for testers, from check/ alone: out/ may be gone since the candidate
    # run, which recorded what this needs in <zip>.pack-ok. Nothing here reads out/,
    # build.ok or the target-files, or writes the release folder's own files or a feed
    echo "== the candidate: $CHECK"
    T=$(mktemp -d "${TMPDIR:-/tmp}/eos-pack.XXXXXX")
    zips=()
    for f in "$CHECK"/*-fastboot.zip; do if [[ -f $f ]]; then zips+=("$f"); fi; done
    (( ${#zips[@]} == 1 )) || fail "$CHECK holds ${#zips[@]} fastboot zips, not one candidate (run eos-pack.sh)"
    NAME=${zips[0]##*/}
    [[ $NAME = ExpressiveOS-*-"$EOS_DEVICE"-*-fastboot.zip ]] || fail "$CHECK/$NAME isn't an ExpressiveOS $EOS_DEVICE fastboot zip"
    base=${NAME%-fastboot.zip}
    zsha=$(sha256sum -- "$CHECK/$NAME" | cut -d' ' -f1)
    [[ "$(cat -- "$CHECK/$NAME.sha256" 2>/dev/null)" = "$zsha  $NAME" ]] \
        || fail "$CHECK/$NAME isn't the zip $NAME.sha256 names (changed since it was packed?): run eos-pack.sh again"
    PO=$CHECK/$NAME.pack-ok
    [[ -f $PO ]] || fail "no $PO: pack the candidate again with eos-pack.sh (out/ is needed for that), which writes it"
    po() { sed -n "s/^$1 //p" "$PO" | head -1; }
    [[ "$(po sha256)" = "$zsha" ]] || fail "$PO is another zip's (sha256 '$(po sha256)'): run eos-pack.sh again"
    # A quick candidate (images only) never goes to testers; a .pack-ok from before quick
    # builds has no build line, and those were all full builds
    [[ "$(po build)" != quick ]] \
        || fail "$CHECK/$NAME is a quick build (images only, no OTA package or target-files): testers get full builds only, whose phones can take incremental OTAs. Build without quick, pack, then send that"
    [[ "$(po keys)" = OK ]] \
        || fail "the candidate was packed with ExpressiveOS's keys '$(po keys)', not pinned in eos.conf (KEYS_CHECK=OK) as testers' builds need (README.md, \"Keys\"): put back the pins eos.conf was committed with (never pins for other keys), then run eos-pack.sh again"
    [[ "$(po incremental-base)" = OK ]] \
        || fail "the fastboot zip's images aren't its target-files' ($PO: incremental-base '$(po incremental-base)'): no incremental OTA could update phones installed from it"
    # Never a rooted candidate: a .pack-ok from a kit that still built KernelSU Next says how
    # that candidate was built ("ksu lkm" for a rooted one); ExpressiveOS ships no root
    [[ "$(po ksu)" = "" || "$(po ksu)" = none ]] \
        || fail "the candidate was packed with KernelSU Next (ksu '$(po ksu)' in $PO), and ExpressiveOS ships no root: build and pack one with today's kit first"
    # ...and its signer is the AVB key eos.conf pins today (keys restored or rotated since the pack)
    unzip -p -- "$CHECK/$NAME" vbmeta.img > "$T/vbmeta.img" 2> /dev/null || fail "can't read $NAME's vbmeta.img"
    "$kit/tools/eos-keys-check.sh" vbmeta "$T/vbmeta.img" "$top" > "$T/keys.log" 2>&1 || true
    [[ "$(tail -1 "$T/keys.log")" = KEYS_CHECK=OK ]] \
        || { grep -E '^(FAIL|UNPINNED)' "$T/keys.log" >&2 || tail -3 "$T/keys.log" >&2; fail "$NAME's vbmeta isn't signed with the AVB key eos.conf pins now"; }
    # This phone's, as its check/ folder is
    unzip -p -- "$CHECK/$NAME" android-info.txt > "$T/android-info.txt" 2> /dev/null || fail "can't read $NAME's android-info.txt"
    { [[ "$(grep -cE '^(require )?board=' "$T/android-info.txt")" = 1 ]] && grep -qx "require board=$EOS_BOARD" "$T/android-info.txt"; } \
        || fail "$NAME's android-info.txt doesn't say 'require board=$EOS_BOARD' only"
    echo "OK: $NAME (sha256 $zsha), packed $(po date) by kit $(po kit): keys pinned, its images its target-files'"

    TD=$DEST/testers
    echo "== upload to SourceForge: $EOS_SF_DIR/testers"
    # The '-' lets a mkdir fail when the folder exists; the cd must work
    printf -- '-mkdir %s\n-mkdir %s\n-mkdir %s/testers\ncd %s/testers\nbye\n' "${EOS_SF_DIR%/*}" "$EOS_SF_DIR" "$EOS_SF_DIR" "$EOS_SF_DIR" \
        | sf > "$T/sftp.log" 2>&1 || { tail -5 "$T/sftp.log" >&2; fail "can't reach $EOS_SF_DIR/testers on SourceForge"; }
    # Never another file under a name testers may already have, here or on SourceForge: a
    # different zip under an existing name gets -r2, -r3...
    TREL=$NAME; r=2
    while taken "testers/$TREL" "$CHECK/$NAME"; do
        (( r <= 20 )) || fail "$base-r2 to -r20 are all taken (here or on SourceForge); look at $TD and $EOS_SF_DIR/testers"
        TREL=$base-r$r-fastboot.zip; r=$((r + 1))
    done
    mkdir -p -- "$TD"
    # A hard link to check/'s zip (no second copy on the disk; a candidate run removes its
    # zip before it writes another, never writes into it), else a copy made under another
    # name first (a copy cut short must not take the name)
    if [[ ! -e $TD/$TREL ]] && ! ln -- "$CHECK/$NAME" "$TD/$TREL" 2>/dev/null; then
        rm -f -- "$TD/.$TREL.part"
        { cp -- "$CHECK/$NAME" "$TD/.$TREL.part" && mv -- "$TD/.$TREL.part" "$TD/$TREL"; } || fail "can't copy $CHECK/$NAME to $TD"
    fi
    # Names only, so testers can run sha256sum -c
    (cd "$TD" && sha256sum -- "$TREL" > "$TREL.sha256")
    [[ "$(cut -d' ' -f1 "$TD/$TREL.sha256")" = "$zsha" ]] || fail "$TD/$TREL isn't $CHECK/$NAME"
    # Each .sha256 before its file: a cut-short upload leaves a matching .sha256 beside a partial
    # file, so taken() keeps the name and the rerun's put replaces it (not a new -rN beside it)
    up=("$TREL.sha256" "$TREL")
    # -b: any failed put fails the upload
    {
        for f in "${up[@]}"; do printf 'put %s %s/testers/%s\n' "$TD/$f" "$EOS_SF_DIR" "$f"; done
        printf 'ls -l %s/testers\nbye\n' "$EOS_SF_DIR"
    } | sf > "$T/sftp.log" 2>&1 || { tail -5 "$T/sftp.log" >&2; fail "the SourceForge upload to $EOS_SF_DIR/testers failed"; }
    touch -- "$TD/$TREL.uploaded"
    for f in "${up[@]}"; do [[ $f != *.sha256 ]] || cat -- "$TD/$f"; done
    echo "TESTERS $TD/$TREL"
    echo "UPLOADED_TESTERS https://sourceforge.net/projects/denson9874-s-user-builds/files/${EOS_SF_DIR#/home/frs/project/denson9874-s-user-builds/}/testers/"
    eos_step end
    done=1
    echo "PACK=OK"
    exit 0
fi

if [[ $quick = 1 ]]; then
    echo "== the build: quick (EOS_QUICK=1: the images only, no OTA package or target-files)"
    "$kit/tools/eos-verify.sh" "$top" > "$EOS_STATE/verify.log" 2>&1 || true
    tail -1 "$EOS_STATE/verify.log" | grep -qx VERIFY=OK || { grep -E '^FAIL' "$EOS_STATE/verify.log" >&2 || tail -5 "$EOS_STATE/verify.log" >&2; fail "eos-verify.sh failed ($EOS_STATE/verify.log)"; }
    ver=$(sed -n 's/^VERIFIED_QUICK //p' "$EOS_STATE/verify.log" | tail -1)
    [[ -n $ver ]] || fail "eos-verify.sh didn't check a quick build ($EOS_STATE/verify.log)"
    # Every file the zip takes is the one eos-images.sh built and verified: quick.ok names
    # exactly those (fastboot_files) and they match
    mapfile -t qfiles < <(fastboot_files)
    qfiles=("${qfiles[@]/#/$EOS_PRODUCT_OUT/}")
    [[ "$(printf '%s\n' "${qfiles[@]}" | sort)" = "$(sed -E 's/^[0-9a-f]{64}  //' "$EOS_STATE/quick.ok" | sort)" ]] \
        || fail "$EOS_STATE/quick.ok doesn't name exactly the files the fastboot zip takes now (fastboot-info.txt or devices/$EOS_DEVICE.conf changed since the build?): run eos-images.sh again"
    sha256sum --quiet --strict -c -- "$EOS_STATE/quick.ok" >&2 \
        || fail "out/ isn't the quick build eos-images.sh built and verified (out/ changed since, above): run eos-images.sh again"
    echo "OK: $ver verified, quick ($EOS_STATE/verify.log); the ${#qfiles[@]} files in $EOS_STATE/quick.ok unchanged"
    base=$ver-quick
else
    echo "== the build"
    [[ -f $EOS_STATE/build.ok ]] || fail "no $EOS_STATE/build.ok: the last eos-images.sh run didn't finish (or ran KERNEL_ONLY)"
    read -r sha name < "$EOS_STATE/build.ok" || true
    ota=$O/$name
    [[ -f $ota && "$(sha256sum -- "$ota" | cut -d' ' -f1)" = "$sha" ]] || fail "$ota isn't the package eos-images.sh built and verified (out/ changed since)"
    "$kit/tools/eos-verify.sh" "$top" > "$EOS_STATE/verify.log" 2>&1 || true
    tail -1 "$EOS_STATE/verify.log" | grep -qx VERIFY=OK || { grep -E '^FAIL' "$EOS_STATE/verify.log" >&2 || tail -5 "$EOS_STATE/verify.log" >&2; fail "eos-verify.sh failed ($EOS_STATE/verify.log)"; }
    [[ "$(sed -n 's/^VERIFIED //p' "$EOS_STATE/verify.log")" = "$top/$ota" ]] || fail "eos-verify.sh checked another package"
    echo "OK: $name verified ($EOS_STATE/verify.log)"
    # The target-files zip eos-images.sh kept with it (eos-verify.sh checked it's the package's)
    tf=$(tf_zip)
    [[ -f $EOS_STATE/target-files.ok ]] || fail "no $EOS_STATE/target-files.ok: the last eos-images.sh run kept no target-files (patches/vendor_lineage/0003)"
    read -r tfsha tfname < "$EOS_STATE/target-files.ok" || true
    [[ "${tfname:-}" = "${tf##*/}" && -f $tf && "$(sha256sum -- "$tf" | cut -d' ' -f1)" = "$tfsha" ]] \
        || fail "$tf isn't the target-files eos-images.sh kept with $name (out/ changed since)"
    echo "OK: ${tf##*/} is its target-files ($EOS_STATE/target-files.ok)"
    base=${name%.zip}
fi
NAME=$base-fastboot.zip
TFN=$base-target_files.zip

echo "== pack"
T=$(mktemp -d "${TMPDIR:-/tmp}/eos-pack.XXXXXX")
mkdir -- "$T/z"
fbi=$O/fastboot-info.txt
if [[ $EOS_FLASH_VKB = 1 ]]; then
    # The Pixel 11 trees' fastboot-info.txt doesn't flash vendor_kernel_boot (a stock radio
    # image there, not a built one), but a clean install needs the one that goes with the
    # stock kernel: added right after dtbo (or init_boot), where the build puts it when it
    # makes one. Flashed images parsed as below (the last word of each flash line)
    at=$(awk '$1 == "flash" { i = $NF; sub(/\.img$/, "", i)
            if (i == "vendor_kernel_boot") v = 1; else if (i == "dtbo" && !d) d = NR; else if (i == "init_boot" && !b) b = NR }
        END { print (v ? 0 : (d ? d : (b ? b : -1))) }' "$O/fastboot-info.txt") || fail "can't read $O/fastboot-info.txt"
    case $at in
        0) ;;   # the tree's flashes it already
        -1) fail "$O/fastboot-info.txt flashes neither dtbo nor init_boot: nowhere to put 'flash vendor_kernel_boot' (EOS_FLASH_VKB=1)" ;;
        *) fbi=$T/fastboot-info.in
           awk -v at="$at" '{ print } NR == at { print "flash vendor_kernel_boot" }' "$O/fastboot-info.txt" > "$fbi" \
               || fail "can't add vendor_kernel_boot to fastboot-info.txt" ;;
    esac
fi
: > "$T/z/fastboot-info.txt"
while IFS= read -r line; do
    read -r cmd rest <<<"$line" || true
    if [[ "${cmd:-}" = flash ]]; then
        img=${rest##* }; [[ $img == *.img ]] || img=$img.img
        if [[ ! -f $O/$img ]]; then
            # No dexpreopt to the other slot: there's no system_other to flash
            [[ $img = system_other.img ]] && continue
            fail "fastboot-info.txt flashes $img, which the build didn't make"
        fi
        [[ -f $T/z/$img ]] || ln -- "$O/$img" "$T/z/" 2>/dev/null || cp -p -- "$O/$img" "$T/z/"
    fi
    printf '%s\n' "$line" >> "$T/z/fastboot-info.txt"
done < "$fbi"
fz=
if [[ $EOS_SUPER_EMPTY = out ]]; then
    cp -p -- "$O/super_empty.img" "$T/z/"
else
    # The Pixel 11 trees build no super_empty.img: the stock one (the same super layout as
    # BoardConfig.mk) from the newest factory image zip, as prepare.sh picks it, with that
    # zip's time, so the same out/ and zip pack into the same bytes
    fz=$(find ~/android-dt/firmware -maxdepth 1 -name "image-$EOS_DEVICE-*.zip" 2>/dev/null | sort | tail -1) || true
    [[ -n $fz ]] || fail "no ~/android-dt/firmware/image-$EOS_DEVICE-*.zip to take super_empty.img from (EOS_SUPER_EMPTY=factory)"
    unzip -p -- "$fz" super_empty.img > "$T/z/super_empty.img" 2> /dev/null && [[ -s $T/z/super_empty.img ]] \
        || fail "can't extract super_empty.img from $fz"
    touch -r "$fz" -- "$T/z/super_empty.img"
fi
# Only this phone: a tree's board-info can name others (pantah's says cheetah|panther, and
# fastboot would flash this onto a Pixel 7 too), and where a tree has none the build writes
# 'board=<device>' (the Pixel 11s): the zip's line is 'require board=<device>' either way
sed -E "s/^(require )?board=.*/require board=$EOS_BOARD/" "$O/android-info.txt" > "$T/z/android-info.txt"
{ [[ "$(grep -cE '^(require )?board=' "$T/z/android-info.txt")" = 1 ]] && grep -qx "require board=$EOS_BOARD" "$T/z/android-info.txt"; } \
    || fail "can't make android-info.txt say 'require board=$EOS_BOARD' only"
# Same out/, same bytes: the written files keep out/'s times, and zip -X stores no owners
touch -r "$O/fastboot-info.txt" -- "$T/z/fastboot-info.txt"
touch -r "$O/android-info.txt" -- "$T/z/android-info.txt"
(cd "$T/z" && LC_ALL=C zip -q -0 -X "$T/$NAME" ./*)
zsha=$(sha256sum -- "$T/$NAME" | cut -d' ' -f1)

echo "== check the zip"
mkdir -- "$T/x"; unzip -q -o -d "$T/x" -- "$T/$NAME"
for f in "$T"/x/*.img; do
    if [[ ${f##*/} = super_empty.img && -n $fz ]]; then
        unzip -p -- "$fz" super_empty.img | cmp -s -- - "$f" || fail "super_empty.img differs from ${fz##*/}'s"
        continue
    fi
    cmp -s -- "$f" "$O/${f##*/}" || fail "${f##*/} differs from out/"
done
grep -qx "require board=$EOS_BOARD" "$T/x/android-info.txt" || fail "the zip's android-info.txt doesn't require board=$EOS_BOARD"
[[ -f $T/x/init_boot.img && -f $T/x/vbmeta.img ]] || fail "the zip has no init_boot.img or vbmeta.img"
grep -q 'init_boot' "$T/x/fastboot-info.txt" || fail "the zip's fastboot-info.txt doesn't flash init_boot"
if [[ $EOS_FLASH_VKB = 1 ]]; then
    { [[ -f $T/x/vendor_kernel_boot.img ]] && awk '$1 == "flash" { i = $NF; sub(/\.img$/, "", i); if (i == "vendor_kernel_boot") f = 1 }
          END { exit !f }' "$T/x/fastboot-info.txt"; } || fail "the zip doesn't flash vendor_kernel_boot (EOS_FLASH_VKB=1)"
fi
# No root: the zip's init_boot is the build's stock one (eos-verify.sh checked it verifies and
# is signed with the tree's key), with no kernelsu.ko in it
out/host/linux-x86/bin/unpack_bootimg --boot_img "$T/x/init_boot.img" --out "$T/ib" > /dev/null || fail "can't unpack the zip's init_boot.img"
mkdir -- "$T/r"
# Only the files checked here: the ramdisk's device nodes (dev/console...) need root to make
(cd "$T/r" && { lz4 -dc "$T/ib/ramdisk" 2>/dev/null || gzip -dc "$T/ib/ramdisk"; } \
    | cpio -id --quiet --no-absolute-filenames init kernelsu.ko) || fail "can't unpack the zip's init_boot ramdisk"
[[ -e $T/r/init && ! -e $T/r/kernelsu.ko ]] || fail "the zip's init_boot.img isn't a stock one (no init, or kernelsu.ko in it): ExpressiveOS ships no root"
se=; [[ -z $fz ]] || se=" (super_empty.img to ${fz##*/}'s)"
echo "OK: $(find "$T/x" -type f | wc -l) files, identical to out/$se, stock init_boot (no root), board=$EOS_BOARD only"

if [[ -z "$mode" ]]; then
    # What --testers needs to know of this candidate once out/ may be gone: the release
    # gates' keys check (UNPINNED is fine for a candidate) and incremental base, as they
    # stand now, for this zip. Read before check/ changes, and never this run's failure:
    # --testers takes OK only
    "$kit/tools/eos-keys-check.sh" out "$top" > "$T/keys.log" 2>&1 || true
    keys=$(tail -1 "$T/keys.log" | sed -n 's/^KEYS_CHECK=\(OK\|UNPINNED\)$/\1/p')
    keys=${keys:-FAIL}
    ib=NO build=full
    if [[ $quick = 1 ]]; then build=quick
    elif grep -q '^OK: incremental base:' "$EOS_STATE/verify.log"; then ib=OK; fi
    # A check isn't a release: one candidate in check/, replaced each time
    if ! cmp -s -- "$T/$NAME" "$CHECK/$NAME" 2>/dev/null; then
        find "$CHECK" -maxdepth 1 -type f \( -name '*-fastboot.zip' -o -name '*.sha256' -o -name '*.img' \
            -o -name '*-manifest.xml' -o -name '*-sources.txt' -o -name '*-changelog.txt' -o -name '*-announcement.md' \
            -o -name '*-incremental-from-*' \) -delete
        cp -- "$T/$NAME" "$CHECK/$NAME"
    fi
    (cd "$CHECK" && sha256sum -- "$NAME" > "$NAME.sha256")
    for r in manifest.xml kernel-manifest.xml sources.txt; do cp -- "$EOS_STATE/$r" "$CHECK/$base-$r"; done
    if [[ $quick = 1 ]]; then
        # Release notes are for a build that can be released: a quick one never is
        rm -f -- "$CHECK/changelogs/$EOS_DEVICE.txt"
        rmdir -- "$CHECK/changelogs" 2>/dev/null || true
    else
        mkdir -p -- "$CHECK/changelogs"
        generate_changelog "$CHECK/changelogs/$EOS_DEVICE.txt" "$CHECK/$base-announcement.md" "$base" "$CHECK/$NAME"
        cp -- "$CHECK/changelogs/$EOS_DEVICE.txt" "$CHECK/$base-changelog.txt"
    fi
    # Its target-files, removed before they're replaced and never written over: a release
    # folder may hold a hard link to check/'s copy. A quick candidate has none: an older
    # candidate's go, with their .sha256
    find "$CHECK" -maxdepth 1 -type f -name '*-target_files.zip' ! -name "$TFN" -delete
    if [[ $quick = 1 ]]; then
        find "$CHECK" -maxdepth 1 -type f -name '*-target_files.zip.sha256' -delete
    else
        if ! cmp -s -- "$tf" "$CHECK/$TFN" 2>/dev/null; then
            rm -f -- "$CHECK/$TFN"
            cp -- "$tf" "$CHECK/$TFN"
        fi
        (cd "$CHECK" && sha256sum -- "$TFN" > "$TFN.sha256")
        [[ "$(cut -d' ' -f1 "$CHECK/$TFN.sha256")" = "$tfsha" ]] || fail "$CHECK/$TFN isn't a whole copy of $tf"
    fi
    # A copy the runner installed (rsync, no .git) names the commit it came from
    kv=$(git -C "$kit" rev-parse HEAD 2>/dev/null || sed -n '1s/^/installed from /p' "$kit/INSTALLED_FROM" 2>/dev/null || echo "not a git checkout")
    [[ -z "$(git -C "$kit" status --porcelain -- . 2>/dev/null)" ]] || kv+=" (with local changes)"
    find "$CHECK" -maxdepth 1 -type f -name '*.pack-ok' ! -name "$NAME.pack-ok" -delete
    printf 'sha256 %s\nkeys %s\nincremental-base %s\nbuild %s\nkit %s\ndate %s\n' "$zsha" "$keys" "$ib" "$build" "$kv" "$(date -u '+%F %T UTC')" \
        > "$CHECK/.$NAME.pack-ok.part" && mv -f -- "$CHECK/.$NAME.pack-ok.part" "$CHECK/$NAME.pack-ok" \
        || fail "can't write $CHECK/$NAME.pack-ok"
    echo "== candidate: $CHECK/$NAME"
    if [[ $quick = 1 ]]; then
        cat "$CHECK/$NAME.sha256"
        echo "a quick build: flash and test $CHECK/$NAME on a phone; it's never released or sent to testers (no OTA package or target-files): for that, build again without quick, pack, flash and test that zip"
    else
        cat "$CHECK/$NAME.sha256" "$CHECK/$TFN.sha256"
        M=$CHECK/$NAME.device-ok
        if [[ -f "$M" ]] && grep -qF -- "$zsha" "$M"; then
            echo "on-device check: $(head -c 300 "$M")"
        else
            echo "not verified on a phone yet: flash and test $CHECK/$NAME, then write $M with the line \"sha256 $zsha\""
        fi
    fi
    if [[ $quick = 1 ]]; then
        echo "testers: never (a quick build, $CHECK/$NAME.pack-ok)"
    elif [[ $keys = OK && $ib = OK ]]; then
        echo "testers: eos-pack.sh --testers can send it ($CHECK/$NAME.pack-ok)"
    else
        echo "testers: not yet (keys $keys, incremental base $ib in $CHECK/$NAME.pack-ok): --testers needs both OK"
    fi
    eos_step end
    done=1
    echo "CANDIDATE $CHECK/$NAME"
    echo "PACK=OK"
    exit 0
fi

echo "== release gates"
"$kit/tools/eos-keys-check.sh" out "$top" > "$T/keys.log" 2>&1 || true
tail -1 "$T/keys.log" | grep -qx KEYS_CHECK=OK \
    || { grep -E '^(FAIL|UNPINNED)' "$T/keys.log" >&2 || true; fail "ExpressiveOS's keys must be pinned in eos.conf (KEYS_CHECK=OK) before a release (README.md, \"Keys\")"; }
echo "OK: signed with the pinned ExpressiveOS keys"
# Every incremental OTA from a release starts from its target-files, and ExpressiveOS is
# installed with the fastboot zip: its images must be the target-files' (eos-target-files.sh)
grep -q '^OK: incremental base:' "$EOS_STATE/verify.log" \
    || fail "the fastboot zip's images aren't its target-files' ($EOS_STATE/verify.log, \"incremental base\"): no incremental OTA from this release could update phones installed from it"
cmp -s -- "$T/$NAME" "$CHECK/$NAME" || fail "out/ doesn't pack into the tested $CHECK/$NAME (run eos-pack.sh, flash and test that)"
# The on-device gate: <zip>.device-ok names the zip's sha256 (someone flashed and tested it)
# (zsha is the packed zip's, which the cmp above found the same as check/'s)
M=$CHECK/$NAME.device-ok
{ [[ -f "$M" ]] && grep -qF -- "$zsha" "$M"; } \
    || fail "the on-device gate: not verified on a phone yet: flash and test $CHECK/$NAME, then write $M with the line \"sha256 $zsha\""
echo "OK: on-device check: $(head -c 300 "$M")"

if [[ "$mode" = --upload ]]; then
    # Releases go to R2 only (no SourceForge since 2026-11-03)
    [[ -n "$R2TF" ]] || fail "--upload sends the target-files to R2: set EOS_R2_REMOTE in eos.conf"
    [[ -x ~/bin/rclone ]] || fail "no ~/bin/rclone for the target-files upload to $R2TF (tools/ota_mirror/README.md)"
    rc2 lsf "$EOS_R2_REMOTE" > /dev/null 2> "$T/rclone.log" \
        || { tail -3 "$T/rclone.log" >&2; fail "can't reach $EOS_R2_REMOTE (rclone's ${EOS_R2_REMOTE%%:*}: remote, tools/ota_mirror/README.md)"; }
fi
# Never overwrite a released name, here or in R2's target-files: a different zip or
# target-files under an existing name gets -r2, -r3...
REL=$NAME; RTF=$TFN; r=2
while taken "$REL" "$T/$NAME" || taken "target-files/$RTF" "$tf"; do
    (( r <= 20 )) || fail "$base-r2 to -r20 are all taken (here or in R2); look at $DEST and $R2TF"
    REL=$base-r$r-fastboot.zip; RTF=$base-r$r-target_files.zip; r=$((r + 1))
done
[[ -e $DEST/$REL ]] || cp -- "$T/$NAME" "$DEST/$REL"
# Names only, so users can run sha256sum -c
(cd "$DEST" && sha256sum -- "$REL" > "$REL.sha256")
pub=("$REL.sha256" "$REL")
for f in manifest.xml kernel-manifest.xml sources.txt; do cp -- "$EOS_STATE/$f" "$DEST/${REL%-fastboot.zip}-$f"; done
mkdir -p -- "$DEST/changelogs"
generate_changelog "$DEST/changelogs/$EOS_DEVICE.txt" "$DEST/${REL%-fastboot.zip}-announcement.md" "$base" "$DEST/$REL"
cp -- "$DEST/changelogs/$EOS_DEVICE.txt" "$DEST/${REL%-fastboot.zip}-changelog.txt"
if [[ -d "$HOME/expressiveos_ota" ]]; then
    mkdir -p -- "$HOME/expressiveos_ota/changelogs"
    cp -- "$DEST/changelogs/$EOS_DEVICE.txt" "$HOME/expressiveos_ota/changelogs/$EOS_DEVICE.txt"
fi
# The target-files the release's OTA package was made from: a hard link to check/'s copy
# when that's this build's (no second copy on the disk), else a copy of out/'s, made
# under another name first (a copy cut short must not take the release's name)
TFD=$DEST/target-files
mkdir -p -- "$TFD"
if [[ ! -e $TFD/$RTF ]]; then
    if [[ -f $CHECK/$TFN && "$(sha256sum -- "$CHECK/$TFN" | cut -d' ' -f1)" = "$tfsha" ]] && ln -- "$CHECK/$TFN" "$TFD/$RTF" 2>/dev/null; then
        echo "note: $TFD/$RTF is a hard link to $CHECK/$TFN"
    else
        rm -f -- "$TFD/.$RTF.part"
        cp -- "$tf" "$TFD/.$RTF.part" && mv -- "$TFD/.$RTF.part" "$TFD/$RTF"
    fi
fi
(cd "$TFD" && sha256sum -- "$RTF" > "$RTF.sha256")
[[ "$(cut -d' ' -f1 "$TFD/$RTF.sha256")" = "$tfsha" ]] || fail "$TFD/$RTF isn't $tf"
# The release's OTA package, out/'s (build.ok's: eos-verify.sh checked it), for eos-ota.sh
# to publish: a hard link (the next build writes a new file, never into this one), else a
# copy made under another name first
OTAD=$DEST/ota ROTA=${REL%-fastboot.zip}.zip
mkdir -p -- "$OTAD"
if [[ -e $OTAD/$ROTA ]]; then
    cmp -s -- "$ota" "$OTAD/$ROTA" || fail "$OTAD/$ROTA holds another package than $ota"
elif ! ln -- "$ota" "$OTAD/$ROTA" 2>/dev/null; then
    rm -f -- "$OTAD/.$ROTA.part"
    { cp -- "$ota" "$OTAD/.$ROTA.part" && mv -- "$OTAD/.$ROTA.part" "$OTAD/$ROTA"; } || fail "can't copy $ota to $OTAD"
fi
(cd "$OTAD" && sha256sum -- "$ROTA" > "$ROTA.sha256")
[[ "$(cut -d' ' -f1 "$OTAD/$ROTA.sha256")" = "$sha" ]] || fail "$OTAD/$ROTA isn't $ota"
# The newest release's target-files, which server-cleanup.sh never removes
printf '%s\n' "$RTF" > "$TFD/LATEST"
for f in "${pub[@]}"; do [[ $f != *.sha256 ]] || cat "$DEST/$f"; done
cat "$TFD/$RTF.sha256" "$OTAD/$ROTA.sha256"
echo "RELEASED $DEST/$REL"

if [[ "$mode" = --upload ]]; then
    # Released for the web installer (expressiveos-flasher-release reads .uploaded); the zip
    # itself goes to R2 with tools/expressiveos_flasher/publish/flasher_publish.py
    touch -- "$DEST/$REL.uploaded"
    {
        echo "== upload the target-files to R2: $R2TF"
        for f in "$RTF" "$RTF.sha256"; do
            rc2 copyto --s3-no-check-bucket "$TFD/$f" "$R2TF/$f" > "$T/rclone.log" 2>&1 \
                || { tail -5 "$T/rclone.log" >&2; fail "the target-files upload to $R2TF failed"; }
        done
        # All of it: R2 has its size and the same .sha256
        size=$(rc2 lsf --format s "$R2TF/$RTF" 2> /dev/null || true)
        [[ "$size" = "$(stat -c %s -- "$TFD/$RTF")" ]] || fail "R2's $RTF is ${size:-not there}, not $(stat -c %s -- "$TFD/$RTF") bytes"
        [[ "$(rc2 cat "$R2TF/$RTF.sha256" 2> /dev/null)" = "$(cat -- "$TFD/$RTF.sha256")" ]] || fail "R2's $RTF.sha256 isn't $TFD/$RTF.sha256"
        where=$R2TF/$RTF
    }
    touch -- "$TFD/$RTF.uploaded"
    echo "UPLOADED_TARGET_FILES $where"
    echo "next: the web installer (runner action expressiveos-flasher-release, or tools/expressiveos_flasher/publish/flasher_publish.py $EOS_DEVICE $DEST/$REL)"
fi
echo "next: tools/eos-ota.sh (--upload) for the Updater: the OTA package and an incremental from the feed's build"
eos_step end
done=1
echo "PACK=OK"
