#!/usr/bin/env bash
# Offline test of eos-keys-move.sh: a fake home and tree with a fake key folder (files of
# filler bytes and a keys.mk like the template's; nothing in it is a key). It checks what the
# script refuses, that move and revert change nothing but the folder's name and keys.mk's
# paths, the backups, and that it never prints a file's contents.
#
#   tools/tests/eos-keys-move-test.sh        # a few seconds; needs python3, tar, flock
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
S=$KITSRC/tools/eos-keys-move.sh
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-keys-move-test.XXXXXX")
export HOME=$W/home TMPDIR=$W/tmp TMUX_TMPDIR=$W/tmux
mkdir -p "$HOME" "$TMPDIR" "$TMUX_TMPDIR"
top=$HOME/expressiveos
OLD=$top/vendor/evolution-priv NEW=$top/vendor/expressiveos-priv
mkdir -p "$top/build" "$top/vendor/lineage/config"
touch "$top/build/envsetup.sh"
echo 'include vendor/expressiveos-priv/keys/keys.mk' > "$top/vendor/lineage/config/expressiveos.mk"

# The fake folder: filler files under the template's names (each its own bytes, with a marker
# that must never reach the output), the template's relative links (BUILD.bazel's out of the
# folder, to nothing, as on the server), a subfolder, a README naming the folder as the
# template's clone step does, git's own folder, and keys.mk
mkfolder() {
    rm -rf -- "$OLD" "$NEW"
    mkdir -p "$OLD/keys/sub"
    local n
    for n in avb platform media networkstack sdk_sandbox shared testkey bluetooth nfc; do
        { printf 'MARKER-%s-not-a-key\n' "$n"; head -c 1500 /dev/zero | tr '\0' "\\$(printf %03o $(( ${#n} + 40 )))"; } > "$OLD/keys/$n.pk8"
        [[ $n = avb ]] || printf 'MARKER-%s-cert-not-a-cert\n' "$n" > "$OLD/keys/$n.x509.pem"
    done
    printf 'MARKER-avb-public-not-a-key\n' > "$OLD/keys/avb_custom_key.bin"
    printf '// MARKER-bp\nandroid_app_certificate {\n    name: "com.android.x.certificate.override",\n    certificate: "testkey",\n}\n' > "$OLD/keys/Android.bp"
    printf 'MARKER-sub\n' > "$OLD/keys/sub/extra.txt"
    ln -s testkey.pk8 "$OLD/keys/releasekey.pk8"
    ln -s testkey.x509.pem "$OLD/keys/releasekey.x509.pem"
    ln -s ../testkey.pk8 "$OLD/keys/sub/up.pk8"
    ln -s ../../../build/make/target/product/security/BUILD.bazel "$OLD/keys/BUILD.bazel"
    printf '# MARKER-readme\nClone this into vendor/evolution-priv/keys, then run keys.sh there.\n' > "$OLD/keys/README.md"
    printf '#!/bin/sh\n# MARKER-keys-sh\n' > "$OLD/keys/keys.sh"
    mkdir -p "$OLD/keys/.git/info"
    printf 'ref: refs/heads/main\n' > "$OLD/keys/.git/HEAD"
    printf '[core]\n\tbare = false\n' > "$OLD/keys/.git/config"
    printf '# MARKER-git vendor/evolution-priv/keys\n' > "$OLD/keys/.git/info/exclude"
    cat > "$OLD/keys/keys.mk" <<'EOF'
# MARKER-mk (the template's keys.mk, made for the test)
PRODUCT_CERTIFICATE_OVERRIDES := com.android.x:com.android.x.certificate.override
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/evolution-priv/keys/testkey
PRODUCT_EXTRA_RECOVERY_KEYS :=

AVB_CUSTOM_KEY_PATH := vendor/evolution-priv/keys/avb.pk8
AVB_CUSTOM_ALGORITHM := SHA256_RSA4096
# vendor/evolution-private-notes stays as it is: not the folder's path
EOF
    printf 'BOARD_AVB_EXTRA := $(TOP)/vendor/evolution-priv/keys/avb.pk8' >> "$OLD/keys/keys.mk"   # no newline at the end
    chmod 700 "$OLD/keys"; chmod 600 "$OLD"/keys/*.pk8
}
# Every file, folder and link (type, mode, size, sha256 or link target, name), as find sees them
snap() { (cd "$1" && find . -mindepth 1 -printf '%y %m %P %l\n' | sort && find . -type f -exec sha256sum {} + | sort -k2); }
run() { local rc=0; bash "$S" "$@" > "$W/out.log" 2>&1 || rc=$?; echo "$rc"; }
last() { tail -n 1 "$W/out.log"; }
pass=0; failn=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out.log" | tail -25; fi; }
quiet() { ! grep -q 'MARKER' "$W/out.log"; }   # no file's contents in the output
nbak() { find "$HOME" -maxdepth 1 -name 'expressiveos-keys-*.tar.gz' | wc -l; }
bg_pids=()
hold() { "$@" & bg_pids+=($!); sleep 0.5; }
release() {   # stop what hold started, and its children (flock's sleep)
    local p
    for p in ${bg_pids[@]+"${bg_pids[@]}"}; do
        pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
    done
    bg_pids=()
}
trap release EXIT

mkfolder
snap "$OLD" > "$W/orig.snap"
cp -p "$OLD/keys/keys.mk" "$W/keys.mk.orig"

rc=$(run bogus); ok "usage: refuses" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: usage"'
rc=$(run); ok "check (the default): read-only report" '[[ $rc = 0 ]] && last | grep -q "^KEYS_MOVE=OK (check only, nothing changed" && grep -qx "MOVE_READY=yes: vendor/evolution-priv -> vendor/expressiveos-priv, keys/keys.mk lines 3,6,9 rewritten" "$W/out.log" && grep -q "^REVERT_READY=no" "$W/out.log"'
ok "  names each file with its sha256" 'grep -q "$(sha256sum < "$OLD/keys/avb.pk8" | cut -d" " -f1) keys/avb.pk8$" "$W/out.log" && grep -q "keys/releasekey.pk8 -> testkey.pk8" "$W/out.log" && grep -q "^  26 files, 4 links" "$W/out.log"'
ok "  takes the template's BUILD.bazel link out of the folder, to nothing, with a note" 'grep -q "keys/BUILD.bazel -> ../../../build/make/target/product/security/BUILD.bazel$" "$W/out.log" && grep -q "^  note: keys/BUILD.bazel is a link out of the folder, to build/make/target/product/security/BUILD.bazel in the tree (nothing there): the same place after the move" "$W/out.log"'
ok "  notes the README naming the folder (the build doesn't read it), and no file the build reads" 'grep -q "^  note: other files name a key folder path, and stay as they are (the build doesn.t read them): keys/README.md$" "$W/out.log" && grep -q "^  files the build reads, keys/keys.mk aside, that name a key folder path: none" "$W/out.log"'
ok "  says which folder vendor/lineage includes, and what builds" 'grep -q "^vendor/lineage.s config includes vendor/expressiveos-priv/keys/keys.mk" "$W/out.log" && grep -q "^nothing builds or syncs now" "$W/out.log" && grep -q "free$" "$W/out.log"'
ok "  prints no file's contents" 'quiet'
ok "  changes nothing: no lock file, no backup, the folder as it was" '[[ ! -e $HOME/.expressiveos.lock && ! -e $HOME/.expressiveos-tree.lock && $(nbak) = 0 ]] && snap "$OLD" | cmp -s - "$W/orig.snap"'

# Refusals: each leaves everything as it was
unchanged() { [[ -d $OLD && ! -e $NEW && $(nbak) = 0 ]] && snap "$OLD" | cmp -s - "$W/orig.snap"; }
for l in .expressiveos.lock .expressiveos-tree.lock .evolution-tree.lock; do
    hold flock -o "$HOME/$l" sleep 30
    rc=$(run move); ok "move refuses while ~/$l is held" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: ~/$l is held" && unchanged'
    release
done
hold bash -c 'exec -a soong_ui sleep 30'
rc=$(run move); ok "move refuses while a build (soong_ui) runs" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: a build runs" && unchanged'
rc=$(run check); ok "  check reports it, MOVE_READY=no" '[[ $rc = 0 ]] && grep -q "^a build runs: " "$W/out.log" && grep -q "^MOVE_READY=no: something builds or syncs" "$W/out.log"'
release
hold bash -c 'exec -a /home/build/bin/repo sleep 30'
rc=$(run move); ok "move refuses while repo runs" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: a repo command runs" && unchanged'
release
if command -v tmux > /dev/null; then
    tmux new-session -d -s eos-build sleep 30
    rc=$(run move); ok "move refuses while the eos-build session is open" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: the tmux session eos-build is open" && unchanged'
    tmux kill-server 2>/dev/null || true
fi
mkdir "$NEW"
rc=$(run move); ok "move refuses when vendor/expressiveos-priv is there already" '[[ $rc = 1 ]] && last | grep -q "vendor/expressiveos-priv is there already" && [[ $(nbak) = 0 ]]'
rmdir "$NEW"
ok "  (and changed nothing)" 'unchanged'
mv "$OLD" "$W/elsewhere"; ln -s "$W/elsewhere" "$OLD"
rc=$(run move); ok "move refuses a key folder that is a symlink" '[[ $rc = 1 ]] && last | grep -q "vendor/evolution-priv is a symlink" && [[ -L $OLD && ! -e $NEW && $(nbak) = 0 ]]'
rm "$OLD"; mv "$W/elsewhere" "$OLD"
ln -s /etc/hostname "$OLD/keys/abs"
rc=$(run move); ok "move refuses a link that leads out of the folder" '[[ $rc = 1 ]] && last | grep -q "keys/abs is a link to /etc/hostname" && [[ ! -e $NEW && $(nbak) = 0 ]]'
rm "$OLD/keys/abs"
ln "$OLD/keys/shared.pk8" "$W/hard"
rc=$(run move); ok "move refuses a hard-linked file" '[[ $rc = 1 ]] && last | grep -q "keys/shared.pk8 has other hard links" && [[ ! -e $NEW && $(nbak) = 0 ]]'
rm "$W/hard"
ln -s ../../../../outside "$OLD/keys/far"
rc=$(run move); ok "move refuses a link that leads out of the tree" '[[ $rc = 1 ]] && last | grep -q "keys/far is a link to ../../../../outside, which leads out of the tree" && [[ ! -e $NEW && $(nbak) = 0 ]]'
rm "$OLD/keys/far"
for t in ../../evolution-priv/keys/testkey.pk8 ../../expressiveos-priv/keys/testkey.pk8; do
    ln -s "$t" "$OLD/keys/back"
    rc=$(run move); ok "move refuses a link that comes back in through a key folder's name ($t)" '[[ $rc = 1 ]] && last | grep -q "keys/back is a link to $t, which leaves the folder and comes back in through the name" && [[ ! -e $NEW && $(nbak) = 0 ]]'
    rm "$OLD/keys/back"
done
ln -s evolution-priv "$top/vendor/lnk"; ln -s ../../lnk/keys/testkey.pk8 "$OLD/keys/via"
rc=$(run move); ok "move refuses a link out of the folder that comes back in through another link" '[[ $rc = 1 ]] && last | grep -q "keys/via is a link to ../../lnk/keys/testkey.pk8, which comes back into vendor/evolution-priv through other links" && [[ ! -e $NEW && $(nbak) = 0 ]]'
rm "$OLD/keys/via" "$top/vendor/lnk"
ln -s avb.pk8 "$OLD/keys/.keys.mk.eos-keys-move"
rc=$(run move); ok "move refuses a link named as its temporary keys.mk (it would write through it)" '[[ $rc = 1 ]] && last | grep -q "keys/.keys.mk.eos-keys-move is a symlink: only this script makes that name" && [[ ! -e $NEW && $(nbak) = 0 ]] && [[ -L $OLD/keys/.keys.mk.eos-keys-move ]]'
rc=$(run check); ok "  check: MOVE_READY=no for it" 'grep -q "^MOVE_READY=no: vendor/evolution-priv holds an entry it refuses" "$W/out.log"'
rm "$OLD/keys/.keys.mk.eos-keys-move"
ok "  (avb.pk8 untouched)" 'unchanged'
echo '// vendor/evolution-priv/keys/testkey' >> "$OLD/keys/Android.bp"
rc=$(run move); ok "move refuses when a file other than keys.mk names the folder" '[[ $rc = 1 ]] && last | grep -q "keys/Android.bp in vendor/evolution-priv name vendor/evolution-priv, and the build reads them" && [[ ! -e $NEW && $(nbak) = 0 ]]'
rc=$(run check); ok "  check: MOVE_READY=no for it" 'grep -q "^MOVE_READY=no: a file in vendor/evolution-priv that the build reads, other than keys/keys.mk, names vendor/evolution-priv" "$W/out.log"'
sed -i '$d' "$OLD/keys/Android.bp"
sed -i 's|^AVB_CUSTOM_KEY_PATH := .*|AVB_CUSTOM_KEY_PATH := somewhere/avb.pk8|' "$OLD/keys/keys.mk"
rc=$(run move); ok "move refuses a keys.mk without the template's key path line" '[[ $rc = 1 ]] && last | grep -q "keys/keys.mk can.t be rewritten" && grep -q "would lack the line .AVB_CUSTOM_KEY_PATH := vendor/expressiveos-priv/keys/avb.pk8" "$W/out.log" && [[ ! -e $NEW && $(nbak) = 0 ]]'
cp -p "$W/keys.mk.orig" "$OLD/keys/keys.mk"
ok "  (the fake folder is back as it was)" 'unchanged'
rc=$(run revert); ok "revert refuses: vendor/expressiveos-priv isn't there" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: vendor/expressiveos-priv isn.t in the tree" && unchanged'
quiet || { failn=$((failn+1)); echo "FAIL a refusal printed a file's contents"; }

# The move
ino=$(stat -c %i "$OLD")
rc=$(run move)
ok "move: KEYS_MOVE=OK" '[[ $rc = 0 ]] && last | grep -q "^KEYS_MOVE=OK (move: vendor/evolution-priv -> vendor/expressiveos-priv"'
ok "  renamed, not copied, and no link left behind" '[[ ! -e $OLD && ! -L $OLD && -d $NEW && ! -L $NEW && $(stat -c %i "$NEW") = "$ino" ]]'
ok "  every file but keys.mk byte-identical, modes and links as they were" 'diff <(grep -v "keys/keys\.mk" "$W/orig.snap") <(snap "$NEW" | grep -v "keys/keys\.mk") > /dev/null && grep -q "keys/releasekey.pk8" "$W/orig.snap"'
ok "  keys.mk: only the three path lines rewritten, byte for byte" 'sed "s|vendor/evolution-priv/|vendor/expressiveos-priv/|g" "$W/keys.mk.orig" | cmp -s - "$NEW/keys/keys.mk" && [[ $(diff "$W/keys.mk.orig" "$NEW/keys/keys.mk" | grep -c "^>") = 3 ]] && grep -q "vendor/evolution-private-notes" "$NEW/keys/keys.mk" && [[ $(stat -c %a "$NEW/keys/keys.mk") = $(stat -c %a "$W/keys.mk.orig") ]]'
ok "  two backups in ~, mode 600, holding keys/" '[[ $(nbak) = 2 ]] && for b in "$HOME"/expressiveos-keys-*.tar.gz; do [[ $(stat -c %a "$b") = 600 ]] && tar -tzf "$b" | grep -qx "keys/" || exit 1; done'
b1=$(ls "$HOME"/expressiveos-keys-*.tar.gz | sort | head -1) b2=$(ls "$HOME"/expressiveos-keys-*.tar.gz | sort | tail -1)
ok "  the first backup is the folder before, the second after" 'tar -xzOf "$b1" keys/keys.mk | cmp -s - "$W/keys.mk.orig" && tar -xzOf "$b2" keys/keys.mk | cmp -s - "$NEW/keys/keys.mk" && tar -xzOf "$b1" keys/avb.pk8 | cmp -s - "$NEW/keys/avb.pk8" && tar -tvzf "$b1" | grep -q "keys/releasekey.pk8 -> testkey.pk8"'
ok "  keeps the BUILD.bazel link as it was, and the README byte-identical, with notes" '[[ $(readlink "$NEW/keys/BUILD.bazel") = ../../../build/make/target/product/security/BUILD.bazel ]] && grep -q "^note: keys/README.md names vendor/evolution-priv; left as it is" "$W/out.log" && grep -q "^note: keys/BUILD.bazel is a link out of the folder" "$W/out.log" && grep "keys/README.md$" "$W/orig.snap" | cmp -s - <(snap "$NEW" | grep "keys/README.md$")'
ok "  prints no file's contents" 'quiet'
ok "  no temporary file left in the folder" '[[ -z $(find "$NEW" -name ".keys.mk*") ]]'
rc=$(run check); ok "check after the move: REVERT_READY=yes, MOVE_READY=no" '[[ $rc = 0 ]] && grep -q "^REVERT_READY=yes: vendor/expressiveos-priv -> vendor/evolution-priv, keys/keys.mk lines 3,6,9 rewritten" "$W/out.log" && grep -q "^MOVE_READY=no: vendor/evolution-priv isn.t in the tree" "$W/out.log" && quiet'
rc=$(run move); ok "a second move refuses" '[[ $rc = 1 ]] && last | grep -q "vendor/evolution-priv isn.t in the tree" && [[ $(nbak) = 2 ]]'
sleep 1

# The revert puts back exactly what was there
rc=$(run revert)
ok "revert: KEYS_MOVE=OK, the folder and keys.mk exactly as before the move" '[[ $rc = 0 ]] && last | grep -q "^KEYS_MOVE=OK (revert:" && [[ -d $OLD && ! -e $NEW && $(stat -c %i "$OLD") = "$ino" ]] && snap "$OLD" | cmp -s - "$W/orig.snap" && [[ $(nbak) = 4 ]] && quiet'

# keys.mk already naming the new folder (rewritten by hand before the move): the move takes it as it is
sed -i 's|vendor/evolution-priv/|vendor/expressiveos-priv/|g' "$OLD/keys/keys.mk"
cp -p "$OLD/keys/keys.mk" "$W/keys.mk.new"
sleep 1
rc=$(run move); ok "move with keys.mk rewritten already: nothing to rewrite, still OK" '[[ $rc = 0 ]] && grep -q "names vendor/evolution-priv on lines none" "$W/out.log" && cmp -s "$W/keys.mk.new" "$NEW/keys/keys.mk" && last | grep -q "^KEYS_MOVE=OK"'
sleep 1
rc=$(run revert); ok "  and its revert writes the old paths back" '[[ $rc = 0 ]] && cmp -s "$W/keys.mk.orig" "$OLD/keys/keys.mk"'

# A failure after the rename (keys.mk can't be written) says where the folder is; revert takes it back
if [[ $(id -u) != 0 ]]; then
    mkfolder; snap "$OLD" > "$W/orig2.snap"
    chmod 500 "$OLD/keys"
    sleep 1
    rc=$(run move); ok "a failure after the rename: says where the folder is" '[[ $rc = 1 ]] && grep -q "^NOTE: the folder is at $NEW now" "$W/out.log" && last | grep -q "^KEYS_MOVE=FAIL: can.t write the new keys/keys.mk" && [[ -d $NEW && ! -e $OLD ]]'
    chmod 700 "$NEW/keys"
    sleep 1
    rc=$(run revert); ok "  revert takes it back from there, as it was" '[[ $rc = 0 ]] && [[ -d $OLD && ! -e $NEW ]] && cmp -s "$W/keys.mk.orig" "$OLD/keys/keys.mk" && snap "$OLD" | cmp -s - "$W/orig2.snap"'
fi

# Signals. A python3 in front of the real one sends the script (its parent) signals when the
# helper named in EOS_TEST_AT starts: list (step 1, before anything changes) or plan-write
# (step 4, between the rename and keys.mk's), then runs the real helper and marks it done
real_py=$(command -v python3)
mkdir -p "$W/bin"
cat > "$W/bin/python3" <<EOF2
#!/usr/bin/env bash
case \${4:-}:\${8:-} in plan:*.keys.mk.eos-keys-move) at=plan-write ;; list:*) at=list ;; *) at= ;; esac
if [[ -n \$at && \$at = "\${EOS_TEST_AT:-}" && ! -e \$EOS_TEST_DONE ]]; then
    for s in \$EOS_TEST_SIG; do kill -s "\$s" "\$PPID"; done
    sleep 0.3
    rc=0; "$real_py" "\$@" || rc=\$?
    : > "\$EOS_TEST_DONE"
    exit \$rc
fi
exec "$real_py" "\$@"
EOF2
chmod 755 "$W/bin/python3"
sig_run() {   # sig_run <at> <signals> <mode>: run the script with the python3 above
    rm -f "$W/py-done"
    ( export PATH="$W/bin:$PATH" EOS_TEST_AT=$1 EOS_TEST_SIG=$2 EOS_TEST_DONE=$W/py-done; run "$3" ) 2>/dev/null   # (bash's "Killed")
}
settle() {   # the helper done, and the locks it inherited free again
    local i
    for i in $(seq 100); do
        [[ -e $W/py-done ]] && flock -n "$HOME/.expressiveos.lock" true && break
        sleep 0.1
    done
}
mkfolder; snap "$OLD" > "$W/orig3.snap"; nb=$(nbak)
sleep 1
rc=$(sig_run list TERM move); settle
ok "SIGTERM before the rename: stops through its last line, nothing moved" '[[ $rc = 1 ]] && last | grep -q "^KEYS_MOVE=FAIL: stopped by SIGTERM$" && ! grep -q "^NOTE" "$W/out.log" && [[ -d $OLD && ! -e $NEW && $(nbak) = "$nb" ]] && snap "$OLD" | cmp -s - "$W/orig3.snap"'
rc=$(sig_run plan-write "INT TERM HUP" move); settle
ok "INT, TERM and HUP between the rename and keys.mk's: ignored, the move ends whole" '[[ $rc = 0 ]] && last | grep -q "^KEYS_MOVE=OK (move:" && [[ ! -e $OLD && -d $NEW && -z $(find "$NEW" -name ".keys.mk*") ]] && sed "s|vendor/evolution-priv/|vendor/expressiveos-priv/|g" "$W/keys.mk.orig" | cmp -s - "$NEW/keys/keys.mk" && quiet'
sleep 1
rc=$(run revert); ok "  and it reverts" '[[ $rc = 0 ]] && snap "$OLD" | cmp -s - "$W/orig3.snap"'
sleep 1
rc=$(sig_run plan-write KILL move); settle
ok "SIGKILL between the rename and keys.mk's: the folder renamed, keys.mk whole, the new one left beside it" '[[ $rc = 137 ]] && [[ ! -e $OLD && -d $NEW && -f $NEW/keys/.keys.mk.eos-keys-move && ! -L $NEW/keys/.keys.mk.eos-keys-move ]] && cmp -s "$W/keys.mk.orig" "$NEW/keys/keys.mk"'
rc=$(run check); ok "  check names the leftover, REVERT_READY=yes" '[[ $rc = 0 ]] && grep -q "^  note: keys/.keys.mk.eos-keys-move is there, the new keys/keys.mk of a run that was stopped" "$W/out.log" && grep -q "^REVERT_READY=yes: vendor/expressiveos-priv -> vendor/evolution-priv, keys/keys.mk lines none rewritten" "$W/out.log" && quiet'
sleep 1
rc=$(run revert); ok "  revert removes it and puts the folder back as it was" '[[ $rc = 0 ]] && grep -q "^note: removed vendor/expressiveos-priv/keys/.keys.mk.eos-keys-move" "$W/out.log" && last | grep -q "^KEYS_MOVE=OK (revert:" && snap "$OLD" | cmp -s - "$W/orig3.snap"'

echo "PASSED $pass FAILED $failn"
[[ $failn = 0 ]] && rm -rf "$W"
[[ $failn = 0 ]]
