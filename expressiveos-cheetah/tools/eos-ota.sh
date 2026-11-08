#!/usr/bin/env bash
# Publish an ExpressiveOS release of a phone (EOS_DEVICE, cheetah unless set; made by
# eos-pack.sh --release or --upload) for the Updater: its full OTA package, plus one
# incremental from the build the Updater feed offers now (Daryl, 2026-11-02: a full package
# every release and one delta from the release before it). Phones on that build download
# the incremental, a fraction of the full package; every other phone takes the full one.
#
#   eos-ota.sh               # make and check both in ~/<EOS_RELEASES>/ota, with the feed
#                            # files in ota/feed/; nothing is uploaded
#   eos-ota.sh --upload      # the same, then both to R2 (<EOS_R2_REMOTE>/<EOS_R2_PREFIX>ota/),
#                            # where the OTA mirror (EOS_OTA_MIRROR) serves them
#   eos-ota.sh --candidate   # an incremental from the feed's build to check/'s candidate, to
#                            # try on a phone on that build before the release: into check/
#                            # and R2's ota/test/, with a test feed of its own there that only
#                            # a phone pointed at it reads (setprop evolution.updater.uri)
#
# Nothing here writes the feed itself (EOS_FEED_REPO's builds/<device>.json and
# changelogs/<device>.txt): they go there as a pull request, and phones see the update once
# it's merged. They're printed between "===== OTA_FEED <path>" lines and kept in ota/feed/.
#
# What goes in:
# - the full package: the release's own, ota/<release>.zip (eos-pack.sh --release keeps
#   out/'s, the package eos-verify.sh checked, beside the fastboot zip it repacked)
# - the incremental, ota/<release>-incremental-from-<base date>.zip: ota_from_target_files -i
#   from the base build's target-files (the release folder's target-files/, else R2's, where
#   eos-pack.sh --upload put them) to the release's, signed with the tree's release key. Every
#   partition but the dynamic ones (misc_info.txt's dynamic_partition_list: system, vendor,
#   product...) is written whole (--full_ota_partitions): the fastboot zip flashes boot,
#   init_boot, vbmeta... as out/ made them, which target-files signs again with AVB salts of
#   its own, and the firmware is whichever stock release the user flashed. The dynamic
#   partitions are the target-files' byte for byte on every phone of the base build, however
#   it was installed (eos-target-files.sh's incremental base, which --release needs), so those
#   are patched block by block. When check/ still holds the candidate incremental --candidate
#   made from the same base to the same target-files (the one the phone test installed), the
#   release takes that very package instead of making another (about 3-4 minutes a phone).
# - the base: the build the feed's full entry offers now; when that is this release already
#   (a rerun), the base its incremental was made from the first time (ota/<release>.base).
#   With no full entry in the feed (the first release) there's no incremental.
#
# Both packages are checked: A/B, for this phone, of this build (post-timestamp and
# post-build-incremental), signed with the pinned OTA key (check_ota_package_signature and
# payload-sig.py against the release's otacerts.zip), writing each partition in its
# ab_partitions.txt; the incremental from the base build (pre-build-incremental), the full one
# the very file the release kept (its .sha256).
#
# The feed lists the incremental first, with base_timestamp (packages_apps_Updater 0005
# offers it only to the base build) and a timestamp one second after the build's: of the
# updates a phone may take, the Updater shows the one with the newest timestamp, so a phone on
# the base build gets the incremental, not the full package of the same build. Once either
# is installed the phone's build date is the build's own, and neither is offered again. Then
# the full package, for every other phone. No ota_property_files (no streaming) yet
# (README.md, "Not done yet"). The Updater never goes back: a release older than the feed's
# build stops with OTA_SUPERSEDED (exit 3); the same release again is fine.
#
# Holds ~/.expressiveos.lock: no build may rebuild out/host's tools meanwhile. The last line
# is OTA=OK or OTA=FAIL.
set -euo pipefail
umask 022
export LC_ALL=C TZ=UTC
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "OTA=FAIL"
    exit $rc
}
trap cleanup EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
mode=${1:-}
usage="usage: eos-ota.sh [--upload | --candidate]"
case "$mode" in ''|--upload|--candidate) ;; *) fail "$usage" ;; esac
[[ $# -le 1 ]] || fail "$usage"
eos_top ""
cd "$top"
exec 8>"$HOME/.expressiveos.lock"
flock -n 8 || fail "an ExpressiveOS build, setup or pack is running (~/.expressiveos.lock)"
b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"

# ExpressiveOS's own release folder, as eos-pack.sh checks it: no symlink on the way
[[ "$EOS_RELEASES" =~ ^releases/expressiveos-[a-z0-9-]+$ ]] || fail "devices/$EOS_DEVICE.conf's EOS_RELEASES ($EOS_RELEASES) isn't releases/expressiveos-<something>"
DEST=$HOME/$EOS_RELEASES; CHECK=$DEST/check; TFD=$DEST/target-files; OTAD=$DEST/ota
want=$(cd ~ && pwd -P)/$EOS_RELEASES
for f in "$DEST" "$CHECK" "$TFD" "$OTAD" "$OTAD/feed"; do
    d=$(realpath -m -- "$f") || fail "can't resolve $f"
    [[ "$d" = "$want${f#"$DEST"}" ]] || fail "$f leads to $d, not ExpressiveOS's own folder (a symlink?)"
done
# The packages go to R2, which the OTA mirror serves, never Evolution X's cheetah/17
R2OTA='' R2TF=''
if [[ -n "${EOS_R2_REMOTE:-}" ]]; then
    [[ "$EOS_R2_REMOTE" =~ ^[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*$ ]] || fail "eos.conf's EOS_R2_REMOTE ($EOS_R2_REMOTE) isn't <rclone remote>:<bucket>"
    [[ "$EOS_R2_PREFIX" =~ ^expressiveos/[a-z0-9-]+/$ ]] || fail "devices/$EOS_DEVICE.conf's EOS_R2_PREFIX ($EOS_R2_PREFIX) isn't expressiveos/<device>/"
    R2OTA=$EOS_R2_REMOTE/${EOS_R2_PREFIX}ota R2TF=$EOS_R2_REMOTE/${EOS_R2_PREFIX}target-files
elif [[ -n $mode ]]; then
    fail "eos.conf's EOS_R2_REMOTE is empty: the Updater downloads from the OTA mirror, which serves R2"
fi
[[ "${EOS_OTA_MIRROR:-}" =~ ^https://[a-z0-9.-]+$ ]] || fail "eos.conf's EOS_OTA_MIRROR (${EOS_OTA_MIRROR:-}) isn't https://<host>"
URL=$EOS_OTA_MIRROR/${EOS_R2_PREFIX}ota
FEED=https://raw.githubusercontent.com/$EOS_FEED_REPO/$EOS_FEED_BRANCH/builds/$EOS_DEVICE.json
rc2() { ~/bin/rclone "$@"; }
[[ -z $mode || -x ~/bin/rclone ]] || fail "no ~/bin/rclone for the R2 upload (tools/ota_mirror/README.md)"

T=$(mktemp -d "$HOME/.eos-ota.XXXXXX")
H=out/host/linux-x86/bin
for t in ota_from_target_files check_ota_package_signature delta_generator; do
    [[ -x $H/$t ]] || fail "no $H/$t (a full build, m bacon, builds it)"
done
# signapk.jar signs the package with the tree's own JDK, as in the build (soong's PATH)
jdk=$(find prebuilts/jdk -maxdepth 3 -path '*/linux-x86/bin' -type d 2>/dev/null | sort -V | tail -1) || true
[[ -n $jdk && -x $jdk/java ]] || fail "no prebuilts/jdk/<jdk>/linux-x86/bin/java in the tree"
# Signed with ExpressiveOS's own release key, the one eos.conf pins, as the build signs
# the full package (eos-target-files.sh checks target-files names it), from the tree's key
# folder: vendor/expressiveos-priv, or vendor/evolution-priv while that isn't there (lib.sh's
# eos_priv; the same files either way)
key=$(eos_priv)/keys/testkey
[[ $key = "$EOS_PRIV_NEW"/* ]] || echo "note: the release key is in $EOS_PRIV_OLD, the key folder's name before 1.1 ($EOS_PRIV_NEW isn't in the tree)"
[[ -f $key.pk8 && -f $key.x509.pem ]] || fail "no $key.pk8 and $key.x509.pem in the tree"
"$kit/tools/eos-keys-check.sh" tree "$top" > "$T/keys.log" 2>&1 || true
[[ "$(tail -1 "$T/keys.log")" = KEYS_CHECK=OK ]] \
    || { grep -E '^(FAIL|UNPINNED)' "$T/keys.log" >&2 || tail -3 "$T/keys.log" >&2; fail "the tree's keys aren't ExpressiveOS's pinned ones (eos-keys-check.sh tree)"; }
fp=$(openssl x509 -in "$key.x509.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')
[[ $fp = "$EOS_OTA_CERT_SHA256" ]] || fail "$key.x509.pem ($fp) isn't the OTA certificate eos.conf pins ($EOS_OTA_CERT_SHA256)"

tflist() { unzip -Z1 -- "$1" > "$2" || fail "can't read $1"; }
tfprop() {   # tfprop <target-files> <name>: its value in the first of its build.props that sets it
    local f
    for f in SYSTEM/build.prop SYSTEM_EXT/etc/build.prop PRODUCT/etc/build.prop VENDOR/build.prop; do
        unzip -p -- "$1" "$f" > "$T/prop" 2> /dev/null || continue
        grep -q "^$2=" "$T/prop" && { sed -n "/^${2//./\\.}=/{s/^[^=]*=//p;q}" "$T/prop"; return; }
    done
    true
}
sha_ok() {   # sha_ok <file>: <file>.sha256 names it and its sha256
    [[ -f $1 && "$(cat -- "$1.sha256" 2>/dev/null)" = "$(sha256sum -- "$1" | cut -d' ' -f1)  ${1##*/}" ]]
}
put() {   # put <file> <R2 folder>: upload it, then check the mirror serves all of it
    local f=$1 to=$2 len
    rc2 copyto --s3-no-check-bucket "$f" "$to/${f##*/}" > "$T/rclone.log" 2>&1 \
        || { tail -5 "$T/rclone.log" >&2; fail "the upload of ${f##*/} to $to failed"; }
    len=$(curl -sSI --max-time 60 "$EOS_OTA_MIRROR/${to#"$EOS_R2_REMOTE"/}/${f##*/}" | tr -d '\r' \
        | awk 'tolower($1) == "content-length:" { l = $2 } END { print l }' || true)
    [[ "$len" = "$(stat -c %s -- "$f")" ]] || fail "the OTA mirror doesn't serve ${f##*/} (length '$len', want $(stat -c %s -- "$f"))"
    echo "OK: $EOS_OTA_MIRROR/${to#"$EOS_R2_REMOTE"/}/${f##*/}"
}

echo "== the feed: $FEED"
code=$(curl -sS -L --max-time 60 -o "$T/live.json" -w '%{http_code}' -- "$FEED") || fail "can't fetch $FEED"
case $code in
    200) ;;
    404) echo '{"response": []}' > "$T/live.json" ;;   # this phone has no feed file yet
    *) fail "fetching $FEED: HTTP $code" ;;
esac
# live_full and live_inc: "<filename> <timestamp>" of the feed's full entry, and
# "<filename> <base_timestamp>" of its incremental, or nothing; live_spl: the full entry's
# os_patch_level, or nothing
python3 -I - "$T/live.json" > "$T/live.txt" <<'EOF' || fail "can't read the feed's builds JSON"
import json, sys
r = json.load(open(sys.argv[1])).get('response') or []
full = [e for e in r if e.get('base_timestamp') is None]
inc = [e for e in r if e.get('base_timestamp') is not None]
if len(full) > 1 or len(inc) > 1:
    sys.exit('the feed lists %d full and %d incremental packages; this script writes one of each at most' % (len(full), len(inc)))
print(' '.join([full[0]['filename'], str(int(full[0]['timestamp']))]) if full else '')
print(' '.join([inc[0]['filename'], str(int(inc[0]['base_timestamp']))]) if inc else '')
print((full[0].get('os_patch_level') or '') if full else '')
EOF
live_full=$(sed -n 1p "$T/live.txt") live_inc=$(sed -n 2p "$T/live.txt") live_spl=$(sed -n 3p "$T/live.txt")
echo "OK: the feed offers ${live_full:-nothing}${live_inc:+, and the incremental ${live_inc% *} to the build of ${live_inc#* }}"

if [[ $mode = --candidate ]]; then
    # check/'s candidate, as eos-pack.sh --testers takes it: a full build, packed with the
    # pinned keys and its images its target-files'
    echo "== the candidate: $CHECK"
    zips=()
    for f in "$CHECK"/*-fastboot.zip; do if [[ -f $f ]]; then zips+=("$f"); fi; done
    (( ${#zips[@]} == 1 )) || fail "$CHECK holds ${#zips[@]} fastboot zips, not one candidate (run eos-pack.sh)"
    NAME=${zips[0]##*/}
    [[ $NAME = ExpressiveOS-*-"$EOS_DEVICE"-*-fastboot.zip ]] || fail "$CHECK/$NAME isn't an ExpressiveOS $EOS_DEVICE fastboot zip"
    REL=${NAME%-fastboot.zip}
    PO=$CHECK/$NAME.pack-ok
    po() { sed -n "s/^$1 //p" "$PO" | head -1; }
    [[ -f $PO && "$(po sha256)" = "$(sha256sum -- "$CHECK/$NAME" | cut -d' ' -f1)" ]] || fail "$PO isn't $NAME's: run eos-pack.sh again"
    [[ "$(po build)" != quick ]] || fail "$NAME is a quick build (no OTA package or target-files): build without quick and pack"
    [[ "$(po keys)" = OK ]] || fail "$NAME was packed with keys '$(po keys)', not ExpressiveOS's pinned ones"
    [[ "$(po incremental-base)" = OK ]] || fail "$NAME's images aren't its target-files' (incremental-base '$(po incremental-base)')"
    TF=$CHECK/$REL-target_files.zip
    OUT=$CHECK
else
    echo "== the release: $DEST"
    [[ -f $TFD/LATEST ]] || fail "no $TFD/LATEST: nothing released yet (eos-pack.sh --release or --upload)"
    RTF=$(cat -- "$TFD/LATEST")
    [[ $RTF = ExpressiveOS-*-"$EOS_DEVICE"-*-target_files.zip && $RTF != */* ]] || fail "$TFD/LATEST names '$RTF', not an ExpressiveOS $EOS_DEVICE target-files zip"
    REL=${RTF%-target_files.zip}
    TF=$TFD/$RTF
    OUT=$OTAD
    FULL=$OTAD/$REL.zip
    [[ -f $FULL ]] || fail "no $FULL: the release was made by a kit from before eos-ota.sh, which kept no OTA package (release a new build)"
    sha_ok "$FULL" || fail "$FULL isn't the package its .sha256 names (changed since the release?)"
    # (The release zip itself may be cleaned up once it's uploaded; its .sha256 stays)
    [[ -f $DEST/$REL-fastboot.zip.sha256 ]] || fail "no $DEST/$REL-fastboot.zip.sha256: $TFD/LATEST isn't a release of this folder"
fi
sha_ok "$TF" || fail "$TF is missing or isn't the zip its .sha256 names"
tflist "$TF" "$T/tf.list"
for f in META/misc_info.txt META/ab_partitions.txt SYSTEM/build.prop SYSTEM/etc/security/otacerts.zip; do
    grep -qxF -- "$f" "$T/tf.list" || fail "${TF##*/} has no $f"
done
ts=$(tfprop "$TF" ro.build.date.utc) incr=$(tfprop "$TF" ro.build.version.incremental)
spl=$(tfprop "$TF" ro.build.version.security_patch) ver=$(tfprop "$TF" ro.evolution.build.version)
[[ $ts =~ ^[0-9]+$ && -n $incr ]] || fail "${TF##*/} has no ro.build.date.utc or ro.build.version.incremental"
# The release name is the build's, with -r<n> for a second release of the same day
[[ $REL = "$ver" || $REL =~ ^"$ver"-r[0-9]+$ ]] || fail "${TF##*/} is $ver's build, not $REL's"
# The feed's "version" is the release's (ExpressiveOS-17.0-<date>-<device>-<version>-...), not the
# installed kit's: eos.conf may already be bumped for the next version when a late upload or a
# rerun of this one runs
relver=$(cut -d- -f5 <<< "$REL")
[[ -n $relver ]] || fail "can't read the version from $REL"
[[ $relver = "$EOS_VERSION" ]] || echo "note: the kit is for $EOS_VERSION, the release is $relver; the feed says $relver"
echo "OK: $REL, built $(date -ud "@$ts" '+%F %T') UTC (security patch $spl)"
# Its own otacerts: what the phone checks the package against once it's running this build,
# the key eos.conf pins
unzip -p -- "$TF" SYSTEM/etc/security/otacerts.zip > "$T/otacerts.zip" || fail "can't extract otacerts.zip from ${TF##*/}"
mkdir -- "$T/otacerts"; unzip -q -o -d "$T/otacerts" -- "$T/otacerts.zip"
certs=("$T"/otacerts/*)
[[ ${#certs[@]} = 1 && -f ${certs[0]} ]] || fail "expected one certificate in ${TF##*/}'s otacerts.zip, found ${#certs[@]}"
[[ "$(openssl x509 -in "${certs[0]}" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')" = "$EOS_OTA_CERT_SHA256" ]] \
    || fail "${TF##*/}'s otacerts.zip doesn't hold the OTA certificate eos.conf pins"
unzip -p -- "$TF" META/ab_partitions.txt | sed '/^$/d' | sort -u > "$T/ab" || fail "can't read ${TF##*/}'s ab_partitions.txt"
unzip -p -- "$TF" META/misc_info.txt > "$T/misc" || fail "can't read ${TF##*/}'s misc_info.txt"
dyn=$(sed -n 's/^dynamic_partition_list=//p' "$T/misc" | tr ' ' '\n' | sed '/^$/d' | sort -u)
[[ -n $dyn ]] || fail "${TF##*/}'s misc_info.txt has no dynamic_partition_list"
# Written whole by the incremental: every A/B partition that isn't dynamic
whole=$(comm -23 "$T/ab" <(printf '%s\n' "$dyn") | paste -sd, -)
[[ -n $whole ]] || fail "${TF##*/} has no A/B partition outside super"

# The Updater never goes back: a feed whose build is newer than this one stays as it is
if [[ -n $live_full && ${live_full% *} != "$REL.zip" ]] && (( ${live_full#* } >= ts )); then
    echo "the feed already offers ${live_full% *} (timestamp ${live_full#* }), not older than $REL ($ts): the Updater never goes back"
    echo "OTA_SUPERSEDED ${live_full% *}"
    done=1
    echo "OTA=FAIL"
    exit 3
fi

# Never an older security patch than the feed's build: update_engine installs one on these
# unlocked phones and wipes their data at the reboot (the Updater refuses it too, since 1.1.1)
if [[ -n $live_full && ${live_full% *} != "$REL.zip" && -n $live_spl ]]; then
    [[ $spl =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "${TF##*/}'s security patch is '$spl', not YYYY-MM-DD"
    [[ $live_spl =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "the feed's ${live_full% *} has os_patch_level '$live_spl', not YYYY-MM-DD"
    [[ ! $spl < $live_spl ]] \
        || fail "$REL's security patch $spl is older than $live_spl, the feed's ${live_full% *}'s: installing it would wipe those phones (build from a tree with that patch or newer)"
fi

# The base: the feed's build, or for a rerun of this release, the one it was made from
BASE='' BTS=''
if [[ -n $live_full && ${live_full% *} != "$REL.zip" ]]; then
    BASE=${live_full% *}; BASE=${BASE%.zip} BTS=${live_full#* }
elif [[ -n $live_full && $mode != --candidate && -f $OTAD/$REL.base ]]; then
    read -r BASE BTS < "$OTAD/$REL.base" || true
    echo "note: the feed offers $REL already; the incremental is from $BASE again, as the first time ($OTAD/$REL.base)"
fi
[[ -n $BASE || $mode != --candidate ]] || fail "the feed offers no other build to make an incremental from"
inc=
if [[ -z $BASE ]]; then
    echo "note: no build in the feed to make an incremental from: the full package only"
else
    [[ $BASE = ExpressiveOS-*-"$EOS_DEVICE"-* && $BASE != */* && $BTS =~ ^[0-9]+$ ]] || fail "the base '$BASE' ($BTS) isn't an ExpressiveOS $EOS_DEVICE release"
    (( BTS < ts )) || fail "the base $BASE ($BTS) isn't older than $REL ($ts)"
    echo "== the base: $BASE"
    BTF=$TFD/$BASE-target_files.zip
    if ! sha_ok "$BTF"; then
        # The server may have cleaned it up since: R2 keeps every release's (eos-pack.sh --upload)
        [[ -n $R2TF ]] || fail "no $BTF here (or not the zip its .sha256 names), and no R2 to fetch it from (EOS_R2_REMOTE)"
        [[ -x ~/bin/rclone ]] || fail "no $BTF here, and no ~/bin/rclone to fetch it from $R2TF"
        echo "note: no $BTF here: fetching it from $R2TF"
        mkdir -- "$T/base"
        for f in "$BASE-target_files.zip" "$BASE-target_files.zip.sha256"; do
            rc2 copyto "$R2TF/$f" "$T/base/$f" > "$T/rclone.log" 2>&1 || { tail -3 "$T/rclone.log" >&2; fail "can't fetch $R2TF/$f"; }
        done
        BTF=$T/base/$BASE-target_files.zip
        sha_ok "$BTF" || fail "$R2TF/$BASE-target_files.zip isn't the zip its .sha256 names"
    fi
    [[ "$(tfprop "$BTF" ro.build.date.utc)" = "$BTS" ]] || fail "${BTF##*/} isn't the build the feed offers (its ro.build.date.utc isn't $BTS)"
    bincr=$(tfprop "$BTF" ro.build.version.incremental)
    [[ -n $bincr ]] || fail "${BTF##*/} has no ro.build.version.incremental"
    # Its date (the release name's third field), and -r<n> for a second release that day
    bid=$(cut -d- -f3 <<<"$BASE"); [[ ! $BASE =~ -(r[0-9]+)$ ]] || bid+=-${BASH_REMATCH[1]}
    inc=$OUT/$REL-incremental-from-$bid.zip
    echo "OK: ${BTF##*/}, built $(date -ud "@$BTS" '+%F %T') UTC"
fi

check_pkg() {   # check_pkg <package> [<base incremental>]: A/B, this phone and build (from that base), signed with the pinned key, every A/B partition
    local p=$1 n=${1##*/}
    unzip -p -- "$p" META-INF/com/android/metadata > "$T/metadata" || fail "$n has no OTA metadata"
    grep -qx 'ota-type=AB' "$T/metadata" || fail "$n isn't an A/B package"
    grep -qx "pre-device=$EOS_DEVICE" "$T/metadata" || fail "$n isn't for $EOS_DEVICE"
    grep -qx "post-timestamp=$ts" "$T/metadata" || fail "$n isn't $REL's (post-timestamp)"
    grep -qx "post-build-incremental=$incr" "$T/metadata" || fail "$n isn't $REL's (post-build-incremental)"
    if [[ -n ${2:-} ]]; then
        grep -qx "pre-build-incremental=$2" "$T/metadata" || fail "$n isn't from $BASE (pre-build-incremental)"
    else
        ! grep -q '^pre-build' "$T/metadata" || fail "$n is an incremental package, not a full one"
    fi
    "$H/check_ota_package_signature" "${certs[0]}" "$p" > "$T/sig.log" 2>&1 || { tail -5 "$T/sig.log" >&2; fail "$n's signature doesn't verify against the release's otacerts"; }
    grep -q "Payload signatures VERIFIED" "$T/sig.log" || fail "$n's payload signatures aren't verified"
    # check_ota_package_signature's delta_generator, like Evolution X's, may take any payload
    # signature (eos-verify.sh): payload-sig.py checks it without update_engine's code
    r=$(python3 -I "$kit/tools/payload-sig.py" "$p" "$T/otacerts.zip" 2>&1 | tail -1) || true
    [[ $r = "PAYLOAD_SIG=OK $EOS_OTA_CERT_SHA256" ]] || fail "$n's payload isn't signed with ExpressiveOS's OTA key ($r)"
    python3 -I "$kit/tools/payload.py" partitions "$p" > "$T/parts" || fail "can't read $n's payload manifest"
    cmp -s -- "$T/ab" "$T/parts" || fail "$n's payload doesn't write exactly ${TF##*/}'s A/B partitions"
    echo "OK: $n ($(stat -c %s -- "$p") bytes): $EOS_DEVICE, $REL${2:+ from $BASE}, signed with the pinned key, all $(wc -l < "$T/ab") A/B partitions"
}

if [[ $mode != --candidate ]]; then
    echo "== the full package"
    check_pkg "$FULL"
fi

if [[ -n $inc ]]; then
    echo "== the incremental: ${inc##*/}"
    # <inc>.base: the base's name, timestamp and target-files sha256, then the sha256 of the
    # target-files it goes to (a .base of three fields, from a kit before that, never matches:
    # the incremental is made again)
    ibase="$BASE $BTS $(sha256sum -- "$BTF" | cut -d' ' -f1) $(cut -d' ' -f1 "$TF.sha256")"
    # The release's incremental is check/'s candidate one when that was made from the same base
    # to the same target-files: the very package the phone test installed (eos-ota.sh
    # --candidate), not a second one made from the same files. check_pkg checks it as any other
    tested=
    if [[ $mode != --candidate ]]; then
        for f in "$CHECK"/*-incremental-from-"$bid".zip; do
            [[ -f $f && -f $f.base && "$(cat -- "$f.base")" = "$ibase" ]] && sha_ok "$f" && tested=$f
        done
    fi
    if sha_ok "$inc" && [[ -f $inc.base && "$(cat -- "$inc.base")" = "$ibase" ]]; then
        echo "note: made already from the same base ($inc.base)"
    elif [[ -n $tested ]]; then
        echo "OK: the candidate incremental the phone test installed, from the same base to the same target-files: $tested"
        mkdir -p -- "$OUT"
        rm -f -- "$inc" "$inc.sha256" "$inc.base"
        ln -- "$tested" "$inc" 2>/dev/null \
            || { cp -- "$tested" "$OUT/.${inc##*/}.part" && mv -- "$OUT/.${inc##*/}.part" "$inc"; } || fail "can't write $inc"
        (cd "$OUT" && sha256sum -- "${inc##*/}" > "${inc##*/}.sha256")
        [[ "$(cut -d' ' -f1 "$inc.sha256")" = "$(cut -d' ' -f1 "$tested.sha256")" ]] || fail "$inc isn't $tested"
        echo "$ibase" > "$inc.base"
    else
        # Its own temporary folder: ota_from_target_files unpacks both target-files there
        mkdir -- "$T/tmp"
        echo "ota_from_target_files -i ${BTF##*/} ${TF##*/}, written whole: $whole"
        if ! PATH=$top/$H:$top/$jdk:$PATH TMPDIR=$T/tmp "$H/ota_from_target_files" --path out/host/linux-x86 -k "$key" \
                -i "$BTF" --full_ota_partitions "$whole" "$TF" "$T/inc.zip" > "$T/ota.log" 2>&1; then
            grep -E 'Error|error:|Exception|FAIL' "$T/ota.log" | tail -10 >&2 || tail -10 "$T/ota.log" >&2
            fail "ota_from_target_files failed (above)"
        fi
        rm -rf -- "$T/tmp"
        [[ -s $T/inc.zip ]] || fail "ota_from_target_files wrote no package"
        # Under another name first: a copy cut short must not take the package's. check/
        # holds one candidate's: an older candidate's incremental goes
        mkdir -p -- "$OUT"
        [[ $mode != --candidate ]] || find "$CHECK" -maxdepth 1 -type f -name '*-incremental-from-*' -delete
        rm -f -- "$inc" "$inc.sha256" "$inc.base"
        cp -- "$T/inc.zip" "$OUT/.${inc##*/}.part" && mv -- "$OUT/.${inc##*/}.part" "$inc" || fail "can't write $inc"
        rm -f -- "$T/inc.zip"
        (cd "$OUT" && sha256sum -- "${inc##*/}" > "${inc##*/}.sha256")
        echo "$ibase" > "$inc.base"
    fi
    check_pkg "$inc" "$bincr"
    if [[ $mode != --candidate ]]; then
        echo "$BASE $BTS" > "$OTAD/$REL.base"
    fi
    if [[ $mode = --candidate ]]; then of="the target-files (${TF##*/})" ref=$TF; else of="the full package" ref=$FULL; fi
    echo "OK: ${inc##*/} is $(( $(stat -c %s -- "$inc") * 100 / $(stat -c %s -- "$ref") ))% the size of $of"
fi

entry() {   # entry <package> [<base_timestamp>]: one feed entry, as JSON, on one line
    python3 -I - "$1" "$(sha256sum -- "$1" | cut -d' ' -f1)" "$(md5sum -- "$1" | cut -d' ' -f1)" "$(stat -c %s -- "$1")" \
        "$ts" "${2:-}" "$URL$3" "$EOS_MODEL" "$relver" "$spl" "$EOS_DEVICE" <<'EOF'
import json, sys
path, sha256, md5, size, ts, base, url, model, version, spl, dev = sys.argv[1:]
name = path.rsplit('/', 1)[-1]
e = {}
if base:
    # Offered only to the build it's from (packages_apps_Updater 0005), and listed one second
    # after the full package of the same build, so that's the one the Updater shows there
    e['base_timestamp'] = int(base)
e.update({
    'maintainer': 'denson9874',
    'currently_maintained': True,
    'oem': 'Google',
    'device': model,
    'filename': name,
    'download': url + '/' + name,
    'timestamp': int(ts) + (1 if base else 0),
    'md5': md5,
    'sha256': sha256,
    'size': int(size),
    'version': version,
    'buildtype': 'user',
    'os_patch_level': spl,
    'forum': '',
    'firmware': 'https://developers.google.com/android/images#' + dev,
    'paypal': '',
    'github': 'denson9874',
})
print(json.dumps(e))
EOF
}
feed() {   # feed <file> <entry>...: a builds JSON of those entries
    local out=$1; shift
    printf '%s\n' "$@" | python3 -I -c '
import json, sys
json.dump({"response": [json.loads(l) for l in sys.stdin if l.strip()]}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")' "$out"
}

if [[ $mode = --candidate ]]; then
    echo "== upload for a phone test: $R2OTA/test"
    tf="$T/test/$EOS_DEVICE.json"; mkdir -p -- "$T/test"
    feed "$tf" "$(entry "$inc" "$BTS" /test)"
    # Only this test's files stay in test/
    rc2 lsf --files-only "$R2OTA/test/" > "$T/test.ls" 2> "$T/rclone.log" || true
    put "$inc" "$R2OTA/test"; put "$inc.sha256" "$R2OTA/test"; put "$tf" "$R2OTA/test"
    while IFS= read -r f; do
        case $f in "${inc##*/}"|"${inc##*/}.sha256"|"$EOS_DEVICE.json") ;; *) rc2 deletefile "$R2OTA/test/$f" || echo "note: couldn't remove test/$f from R2" ;; esac
    done < "$T/test.ls"
    echo "===== OTA_FEED test/$EOS_DEVICE.json"; cat -- "$tf"; echo "===== OTA_FEED_END"
    cat <<EOF
To try it: a phone on $BASE (root), then the Updater's "check for updates":
  adb shell "su -c 'setprop evolution.updater.uri $URL/test/$EOS_DEVICE.json'"
It should offer ${inc##*/} ($(stat -c %s -- "$inc") bytes). The setting goes away with the reboot into $REL.
EOF
    echo "OTA_TEST $URL/test/$EOS_DEVICE.json"
    done=1
    echo "OTA=OK"
    exit 0
fi

echo "== the feed files: $OTAD/feed"
mkdir -p -- "$OTAD/feed/builds" "$OTAD/feed/changelogs"
entries=()
[[ -z $inc ]] || entries+=("$(entry "$inc" "$BTS" "")")
entries+=("$(entry "$FULL" "" "")")
feed "$OTAD/feed/builds/$EOS_DEVICE.json" "${entries[@]}"
# The release notes eos-pack.sh --release wrote for it
[[ -f $DEST/$REL-changelog.txt ]] || fail "no $DEST/$REL-changelog.txt (eos-pack.sh --release writes it)"
cp -- "$DEST/$REL-changelog.txt" "$OTAD/feed/changelogs/$EOS_DEVICE.txt"

if [[ $mode = --upload ]]; then
    echo "== upload to R2: $R2OTA"
    rc2 lsf "$EOS_R2_REMOTE" > /dev/null 2> "$T/rclone.log" \
        || { tail -3 "$T/rclone.log" >&2; fail "can't reach $EOS_R2_REMOTE (rclone's ${EOS_R2_REMOTE%%:*}: remote, tools/ota_mirror/README.md)"; }
    for f in ${inc:+"$inc" "$inc.sha256"} "$FULL" "$FULL.sha256"; do put "$f" "$R2OTA"; done
    # R2 keeps what this feed and the one phones read now point at, nothing older
    keep=" ${inc##*/} ${inc:+${inc##*/}.sha256} $REL.zip $REL.zip.sha256 "
    for e in $live_full $live_inc; do [[ $e = *.zip ]] && keep+="$e $e.sha256 "; done
    rc2 lsf --files-only "$R2OTA/" > "$T/ota.ls" 2> "$T/rclone.log" || { tail -3 "$T/rclone.log" >&2; fail "can't list $R2OTA"; }
    while IFS= read -r f; do
        [[ $keep == *" $f "* ]] || { rc2 deletefile "$R2OTA/$f" && echo "removed $f from R2 (no feed names it)"; } || echo "note: couldn't remove $f from $R2OTA"
    done < "$T/ota.ls"
    echo "UPLOADED_OTA $URL/$REL.zip${inc:+ $URL/${inc##*/}}"
fi
for f in "builds/$EOS_DEVICE.json" "changelogs/$EOS_DEVICE.txt"; do
    echo "===== OTA_FEED $f"; cat -- "$OTAD/feed/$f"
done
echo "===== OTA_FEED_END"
if [[ $mode = --upload ]]; then
    echo "OTA_FEED_READY $OTAD/feed: commit it to $EOS_FEED_REPO ($EOS_FEED_BRANCH) as a pull request; phones see the update once it's merged"
else
    echo "OTA_PREVIEW $OTAD/feed: nothing uploaded (eos-ota.sh --upload uploads the packages)"
fi
done=1
echo "OTA=OK"
