#!/usr/bin/env bash
# Pack an ExpressiveOS cheetah build (eos-images.sh) as a `fastboot update` zip, the only
# way to install it (a clean flash), with the stock init_boot for users who want no root.
#
#   eos-pack.sh             # verify, then pack the candidate into ~/<EOS_RELEASES>/check
#                           # (replaced each time)
#   eos-pack.sh --release   # the tested candidate into ~/<EOS_RELEASES>
#   eos-pack.sh --upload    # --release, then upload it to SourceForge (EOS_SF_DIR)
#
# The on-device gate, as on husky: after flashing and testing check/<zip>, write
# check/<zip>.device-ok with the line "sha256 <its sha256>". --release and --upload also
# need ExpressiveOS's keys pinned in eos.conf (KEYS_CHECK=OK, not UNPINNED), and pack the
# zip again from out/: it must come out byte for byte the zip that was tested.
# Every run needs out/eos/build.ok naming out/'s OTA package (only a complete eos-images.sh
# run writes it) and runs eos-verify.sh again. A released name is never overwritten: a
# second release on the same day gets -r2, -r3...
# The zip holds what out/fastboot-info.txt flashes (ROM partitions, super_empty), not the
# bootloader and radio: users flash the latest stock firmware first, and the OTA carries
# it. The OTA package itself is published for the Updater by its own script, not this one.
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
case "$mode" in ''|--release|--upload) ;; *) fail "usage: eos-pack.sh [--release | --upload]" ;; esac
[[ $# -le 1 ]] || fail "usage: eos-pack.sh [--release | --upload]"
eos_top ""
cd "$top"
O=out/target/product/cheetah
# Not while an ExpressiveOS build or setup runs: out/ would change under the zip
exec 8>"$HOME/.expressiveos.lock"
flock -n 8 || fail "an ExpressiveOS build or setup is running (~/.expressiveos.lock)"
b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"

# ExpressiveOS's own release folder, never Evolution X's: ~/releases/expressiveos-*/ and
# its check/, as named, with no symlink anywhere on the way. Checked before anything is made
[[ "$EOS_RELEASES" =~ ^releases/expressiveos-[a-z0-9-]+$ ]] || fail "eos.conf's EOS_RELEASES ($EOS_RELEASES) isn't releases/expressiveos-<something>"
DEST=$HOME/$EOS_RELEASES; CHECK=$DEST/check
want=$(cd ~ && pwd -P)/$EOS_RELEASES
for f in "$DEST" "$CHECK"; do
    d=$(realpath -m -- "$f") || fail "can't resolve $f"
    [[ "$d" = "$want${f#"$DEST"}" ]] || fail "$f leads to $d, not ExpressiveOS's own folder (a symlink?)"
done
mkdir -p -- "$CHECK"
# And its own SourceForge folder, never Evolution X's cheetah/17
[[ "$EOS_SF_DIR" == /home/frs/project/*/expressiveos/* ]] || fail "eos.conf's EOS_SF_DIR ($EOS_SF_DIR) isn't an expressiveos/ folder"

echo "== the build"
[[ -f out/eos/build.ok ]] || fail "no out/eos/build.ok: the last eos-images.sh run didn't finish (or ran KERNEL_ONLY)"
read -r sha name < out/eos/build.ok || true
ota=$O/$name
[[ -f $ota && "$(sha256sum -- "$ota" | cut -d' ' -f1)" = "$sha" ]] || fail "$ota isn't the package eos-images.sh built and verified (out/ changed since)"
"$kit/tools/eos-verify.sh" "$top" > out/eos/verify.log 2>&1 || true
tail -1 out/eos/verify.log | grep -qx VERIFY=OK || { grep -E '^FAIL' out/eos/verify.log >&2 || tail -5 out/eos/verify.log >&2; fail "eos-verify.sh failed (out/eos/verify.log)"; }
[[ "$(sed -n 's/^VERIFIED //p' out/eos/verify.log)" = "$top/$ota" ]] || fail "eos-verify.sh checked another package"
echo "OK: $name verified (out/eos/verify.log)"
base=${name%.zip}
NAME=$base-fastboot.zip
STOCK=$base-init_boot-stock.img

echo "== pack"
T=$(mktemp -d "${TMPDIR:-/tmp}/eos-pack.XXXXXX")
mkdir -- "$T/z"
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
done < "$O/fastboot-info.txt"
cp -p -- "$O/super_empty.img" "$T/z/"
# Only a Pixel 7 Pro: the device tree's board-info says cheetah|panther, and fastboot
# would flash this onto a Pixel 7 (panther) too
sed -E 's/^require board=.*/require board=cheetah/' "$O/android-info.txt" > "$T/z/android-info.txt"
{ [[ "$(grep -c '^require board=' "$T/z/android-info.txt")" = 1 ]] && grep -qx 'require board=cheetah' "$T/z/android-info.txt"; } \
    || fail "can't make android-info.txt say 'require board=cheetah' only"
# Same out/, same bytes: the written files keep out/'s times, and zip -X stores no owners
touch -r "$O/fastboot-info.txt" -- "$T/z/fastboot-info.txt"
touch -r "$O/android-info.txt" -- "$T/z/android-info.txt"
(cd "$T/z" && LC_ALL=C zip -q -0 -X "$T/$NAME" ./*)
zsha=$(sha256sum -- "$T/$NAME" | cut -d' ' -f1)

echo "== check the zip"
mkdir -- "$T/x"; unzip -q -o -d "$T/x" -- "$T/$NAME"
for f in "$T"/x/*.img; do cmp -s -- "$f" "$O/${f##*/}" || fail "${f##*/} differs from out/"; done
grep -qx 'require board=cheetah' "$T/x/android-info.txt" || fail "the zip's android-info.txt doesn't require board=cheetah"
[[ -f $T/x/init_boot.img && -f $T/x/vbmeta.img ]] || fail "the zip has no init_boot.img or vbmeta.img"
grep -q 'init_boot' "$T/x/fastboot-info.txt" || fail "the zip's fastboot-info.txt doesn't flash init_boot"
"$kit/ksu/tools/ksu-check.sh" images "$T/x" "$top" > "$T/ksu.log" 2>&1 || true
tail -1 "$T/ksu.log" | grep -qx KSU_CHECK=OK || { grep -E '^FAIL' "$T/ksu.log" >&2 || tail -3 "$T/ksu.log" >&2; fail "the zip's images fail ksu-check.sh images"; }
echo "OK: $(find "$T/x" -type f | wc -l) files, identical to out/, KernelSU Next init_boot, the AVB chain verifies, board=cheetah only"

if [[ -z "$mode" ]]; then
    # A check isn't a release: one candidate in check/, replaced each time
    if ! cmp -s -- "$T/$NAME" "$CHECK/$NAME" 2>/dev/null; then
        find "$CHECK" -maxdepth 1 -type f \( -name '*-fastboot.zip' -o -name '*.sha256' -o -name '*.img' \
            -o -name '*-manifest.xml' -o -name '*-sources.txt' \) -delete
        cp -- "$T/$NAME" "$CHECK/$NAME"
    fi
    cp -- out/ksu/init_boot-stock.img "$CHECK/$STOCK"
    (cd "$CHECK" && sha256sum -- "$NAME" > "$NAME.sha256" && sha256sum -- "$STOCK" > "$STOCK.sha256")
    for r in manifest.xml kernel-manifest.xml sources.txt; do cp -- "out/eos/$r" "$CHECK/$base-$r"; done
    echo "== candidate: $CHECK/$NAME"
    cat "$CHECK/$NAME.sha256"
    M=$CHECK/$NAME.device-ok
    if [[ -f "$M" ]] && grep -qF -- "$zsha" "$M"; then
        echo "on-device check: $(head -c 300 "$M")"
    else
        echo "not verified on a phone yet: flash and test $CHECK/$NAME, then write $M with the line \"sha256 $zsha\""
    fi
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
cmp -s -- "$T/$NAME" "$CHECK/$NAME" || fail "out/ doesn't pack into the tested $CHECK/$NAME (run eos-pack.sh, flash and test that)"
"$kit/ksu/tools/ksu-check.sh" device-ok "$CHECK/$NAME" | grep -v '^KSU_CHECK=' || fail "the on-device gate"

sf() { sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 daryldenson0405@frs.sourceforge.net; }
if [[ "$mode" = --upload ]]; then
    # The '-' lets a mkdir fail when the folder exists; the cd must work
    printf -- '-mkdir %s\n-mkdir %s\ncd %s\nbye\n' "${EOS_SF_DIR%/*}" "$EOS_SF_DIR" "$EOS_SF_DIR" | sf > "$T/sftp.log" 2>&1 \
        || { tail -5 "$T/sftp.log" >&2; fail "can't reach $EOS_SF_DIR on SourceForge"; }
fi
taken() {   # taken <name> <file>: <name> already holds something other than <file>, here or (--upload) on SourceForge
    if [[ -e $DEST/$1 ]] && ! cmp -s -- "$2" "$DEST/$1"; then return 0; fi
    [[ "$mode" = --upload ]] || return 1
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
# Never overwrite a released name, here or on SourceForge (where the release folder may be
# all that's left): a different zip or stock image under an existing name gets -r2, -r3...
REL=$NAME; RSTOCK=$STOCK; r=2
while taken "$REL" "$T/$NAME" || taken "$RSTOCK" out/ksu/init_boot-stock.img; do
    (( r <= 20 )) || fail "$base-r2 to -r20 are all taken (here or on SourceForge); look at $DEST and $EOS_SF_DIR"
    REL=$base-r$r-fastboot.zip; RSTOCK=$base-r$r-init_boot-stock.img; r=$((r + 1))
done
[[ -e $DEST/$REL ]] || cp -- "$T/$NAME" "$DEST/$REL"
[[ -e $DEST/$RSTOCK ]] || cp -- out/ksu/init_boot-stock.img "$DEST/$RSTOCK"
# Names only, so users can run sha256sum -c
(cd "$DEST" && sha256sum -- "$REL" > "$REL.sha256" && sha256sum -- "$RSTOCK" > "$RSTOCK.sha256")
for f in manifest.xml kernel-manifest.xml sources.txt; do cp -- "out/eos/$f" "$DEST/${REL%-fastboot.zip}-$f"; done
cat "$DEST/$REL.sha256" "$DEST/$RSTOCK.sha256"
echo "RELEASED $DEST/$REL"

if [[ "$mode" = --upload ]]; then
    echo "== upload to SourceForge: $EOS_SF_DIR"
    # -b: any failed put fails the upload
    {
        for f in "$REL" "$REL.sha256" "$RSTOCK" "$RSTOCK.sha256"; do printf 'put %s %s/%s\n' "$DEST/$f" "$EOS_SF_DIR" "$f"; done
        printf 'ls -l %s\nbye\n' "$EOS_SF_DIR"
    } | sf > "$T/sftp.log" 2>&1 || { tail -5 "$T/sftp.log" >&2; fail "the SourceForge upload failed"; }
    touch -- "$DEST/$REL.uploaded"
    echo "UPLOADED https://sourceforge.net/projects/denson9874-s-user-builds/files/${EOS_SF_DIR#/home/frs/project/denson9874-s-user-builds/}/"
fi
done=1
echo "PACK=OK"
