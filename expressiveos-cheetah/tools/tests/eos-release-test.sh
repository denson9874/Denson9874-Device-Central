#!/usr/bin/env bash
# Offline test of eos-release.sh (the runner's expressiveos-pack release devices=) and what
# eos-progress.py makes of its session: a fake home, with eos-pack.sh, eos-ota.sh and
# flasher_publish.py stubbed. It checks the order of the steps, that it stops at the first
# failure and touches no phone after it, the DEVICE and TIME lines, and the progress and feed
# readings; the steps themselves have their own tests (eos-ota-test.sh, test_flasher_publish.py)
# and run on the server.
#
#   tools/tests/eos-release-test.sh     # a few seconds; needs python3 and tmux
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-release-test.XXXXXX")
# tmux's server for this test only (eos-progress.py asks it whether eos-pack runs), never the
# server's own eos-pack session; in /tmp, as a socket's path has to be short
export TMUX_TMPDIR
TMUX_TMPDIR=$(mktemp -d /tmp/eos-release-tmux.XXXXXX)
trap 'tmux kill-server 2>/dev/null || true; rm -rf -- "$W" "$TMUX_TMPDIR"' EXIT
export HOME=$W/home
jobs=$HOME/expressiveos-jobs
mkdir -p "$HOME" "$jobs"
kit=$W/kit
cp -a "$KITSRC" "$kit"
pass=0 failed=0
ok() { if eval "$2"; then echo "ok   $1"; pass=$((pass + 1)); else echo "FAIL $1"; failed=$((failed + 1)); fi; }

cat > "$kit/tools/eos-pack.sh" <<'EOF'
#!/usr/bin/env bash
echo "pack $EOS_DEVICE $*" >> "$HOME/calls"
echo "STEP pack device=$EOS_DEVICE kind=upload fresh=- at=2026-11-09T01:41:22Z"
echo "== the build"
[[ ${FAKE_FAIL:-} != "pack:$EOS_DEVICE" ]] || { echo "FAIL: no device-ok"; echo "PACK=FAIL"; exit 1; }
[[ ${FAKE_FAIL:-} != "packlast:$EOS_DEVICE" ]] || { echo "PACK=OK"; echo "something after"; exit 0; }
r=$HOME/releases/expressiveos-$EOS_DEVICE n=ExpressiveOS-17.0-20261109-$EOS_DEVICE-1.1.2-Official
mkdir -p "$r/target-files"
echo "$n-target_files.zip" > "$r/target-files/LATEST"
echo zip > "$r/$n-fastboot.zip"
echo "x  $n-fastboot.zip" > "$r/$n-fastboot.zip.sha256"
[[ ${FAKE_FAIL:-} = "noupload:$EOS_DEVICE" ]] || touch "$r/$n-fastboot.zip.uploaded"
echo "RELEASED $r/$n-fastboot.zip"
echo "PACK=OK"
EOF
cat > "$kit/tools/eos-ota.sh" <<'EOF'
#!/usr/bin/env bash
echo "ota $EOS_DEVICE $*" >> "$HOME/calls"
echo "== the feed: https://example/builds/$EOS_DEVICE.json"
echo "== the candidate: $HOME/releases/expressiveos-$EOS_DEVICE/check/x"
[[ ${FAKE_FAIL:-} != "ota:$EOS_DEVICE" ]] || { echo "OTA_SUPERSEDED newer"; echo "OTA=FAIL"; exit 3; }
echo "UPLOADED_OTA https://example/$EOS_DEVICE.zip"
echo "===== OTA_FEED builds/$EOS_DEVICE.json"
echo "{\"response\": [\"$EOS_DEVICE\"]}"
echo "===== OTA_FEED changelogs/$EOS_DEVICE.txt"
echo "notes for $EOS_DEVICE"
echo "===== OTA_FEED_END"
echo "OTA_FEED_READY $HOME/releases/expressiveos-$EOS_DEVICE/ota/feed: commit it"
echo "OTA=OK"
EOF
cat > "$W/flasher_publish.py" <<'EOF'
import os, sys
open(os.environ['HOME'] + '/calls', 'a').write('web ' + ' '.join(sys.argv[1:]) + '\n')
print('== the release: ' + sys.argv[2])
if os.environ.get('FAKE_FAIL') == 'web:' + sys.argv[1]:
    print('FLASHER_PUBLISH=FAIL')
    sys.exit(1)
print('FLASHER_PUBLISH=OK')
EOF
z() { echo "$HOME/releases/expressiveos-$1/ExpressiveOS-17.0-20261109-$1-1.1.2-Official-fastboot.zip"; }

# run <phones...>: eos-release.sh as the runner's session runs it, its log as pack.log; prints the exit
run() {
    rm -rf -- "$HOME/calls" "$HOME/expressiveos-build-times.txt" "$HOME/releases"
    printf '#!/bin/bash\n# expressiveos-pack from the runner, test\n# phones: %s\ncd ~ || exit 1\n{ bash %q/tools/eos-release.sh %q/flasher_publish.py %s; }\n' \
        "$*" "$kit" "$W" "$*" > "$jobs/pack.sh"
    local rc=0
    { echo "== eos-pack, 2026-11-09 01:41:22 UTC"; bash "$kit/tools/eos-release.sh" "$W/flasher_publish.py" "$@" || rc=$?; echo "SESSION_EXIT=$rc"; } > "$jobs/pack.log" 2>&1
    echo "$rc"
}
L=$jobs/pack.log
progress() { python3 -I "$kit/tools/eos-progress.py" "$@" > "$W/progress.txt" 2>&1; }
P=$W/progress.txt

# 1. Three phones, every step OK
rc=$(run cheetah husky kodiak)
ok "all three: exit 0, RELEASE=OK last" '[[ $rc = 0 && "$(tail -n 2 "$L" | head -n 1)" = RELEASE=OK ]]'
printf 'pack %s --upload\nota %s --upload\nweb %s %s --keep 1\n' cheetah cheetah cheetah "$(z cheetah)" husky husky husky "$(z husky)" kodiak kodiak kodiak "$(z kodiak)" > "$W/want"
ok "each phone in turn: pack, OTA upload, web installer (--keep 1, the released zip)" 'cmp -s "$W/want" "$HOME/calls"'
ok "a DEVICE RELEASE=OK line per phone" '[[ "$(grep -c "^DEVICE [a-z]*: RELEASE=OK" "$L")" = 3 ]]'
ok "the progress headers, in order" '[[ "$(grep -oE "^== [a-z]+ \([0-9] of 3\): [a-z_.-]+" "$L" | tr "\n" "|")" = "== cheetah (1 of 3): eos-pack.sh|== cheetah (1 of 3): eos-ota.sh|== cheetah (1 of 3): flasher_publish.py|== husky (2 of 3): eos-pack.sh|== husky (2 of 3): eos-ota.sh|== husky (2 of 3): flasher_publish.py|== kodiak (3 of 3): eos-pack.sh|== kodiak (3 of 3): eos-ota.sh|== kodiak (3 of 3): flasher_publish.py|" ]]'
ok "each phone's OTA output in ota-<phone>.log" 'for d in cheetah husky kodiak; do [[ "$(tail -n 1 "$jobs/ota-$d.log")" = OTA=OK ]] || exit 1; done'
ok "TIME lines for the ota and web steps, kind=publish" '[[ "$(grep -cE "^TIME (ota|web) device=(cheetah|husky|kodiak) kind=publish fresh=- at=[0-9T:Z-]+ secs=[0-9]+$" "$HOME/expressiveos-build-times.txt")" = 6 ]]'
progress
ok "progress: each phone done, kind publish" '[[ "$(grep -cE "^PROGRESS device=(cheetah|husky|kodiak) state=done step=done kind=publish " "$P")" = 3 ]] && grep -q "^SESSION name=eos-pack state=done exit=0" "$P"'
ok "progress in words: released" '[[ "$(grep -c ": release, released: packed, OTA packages uploaded, on the web installer" "$P")" = 3 ]]'
progress --feed
ok "feed: every phone ready, their feed files, FEED_OK" '[[ "$(grep -c "^FEED device=[a-z]* ready$" "$P")" = 3 && "$(grep -c "^===== OTA_FEED builds/" "$P")" = 3 && "$(grep -c "^===== OTA_FEED_END$" "$P")" = 3 && "$(tail -n 1 "$P")" = FEED_OK ]] && grep -qx "{\"response\": \[\"husky\"\]}" "$P" && grep -q "^OTA_FEED_READY .*kodiak" "$P"'

# 2. husky's OTA upload fails (a newer build in the feed): kodiak is never touched
echo stale > "$jobs/ota-kodiak.log"
rc=$(FAKE_FAIL=ota:husky run cheetah husky kodiak)
ok "OTA fails on the second phone: exit 1, RELEASE=FAIL last" '[[ $rc = 1 && "$(tail -n 2 "$L" | head -n 1)" = RELEASE=FAIL ]]'
ok "its DEVICE line names the step, the exit and the phones not released" 'grep -qx "DEVICE husky: RELEASE=FAIL at ota (exit 3); not released: kodiak" "$L"'
ok "nothing after it ran: no web installer for husky, nothing for kodiak" '[[ "$(cut -d" " -f1,2 "$HOME/calls" | tr "\n" "|")" = "pack cheetah|ota cheetah|web cheetah|pack husky|ota husky|" ]]'
ok "the named phones' older ota logs went first" '[[ ! -e $jobs/ota-kodiak.log ]]'
progress
ok "progress: cheetah done, husky failed at ota, kodiak skipped" 'grep -q "^PROGRESS device=cheetah state=done step=done kind=publish" "$P" && grep -q "^PROGRESS device=husky state=failed step=ota kind=publish" "$P" && grep -q "^PROGRESS device=kodiak state=skipped step=- kind=publish" "$P" && grep -q "^SESSION name=eos-pack state=failed exit=1" "$P"'
ok "progress in words: husky failed at ota, kodiak not released" 'grep -q "^husky: release, failed at ota" "$P" && grep -q "^kodiak: not released" "$P"'
progress --feed
ok "feed: cheetah only, FEED_INCOMPLETE" 'grep -qx "FEED device=cheetah ready" "$P" && grep -q "^FEED device=husky none (its OTA step ended .OTA=FAIL.)" "$P" && grep -q "^FEED device=kodiak none (no " "$P" && [[ "$(grep -c "^===== OTA_FEED builds/" "$P")" = 1 && "$(tail -n 1 "$P")" = FEED_INCOMPLETE ]]'

# 3. A pack that exits 0 without PACK=OK as its last line stops it there
rc=$(FAKE_FAIL=packlast:cheetah run cheetah husky)
ok "pack without PACK=OK last: stopped at pack, nothing else ran" '[[ $rc = 1 ]] && grep -qx "DEVICE cheetah: RELEASE=FAIL at pack (exit 0); not released: husky" "$L" && [[ "$(cat "$HOME/calls")" = "pack cheetah --upload" ]]'
rc=$(FAKE_FAIL=pack:husky run cheetah husky)
ok "a pack that fails (no device-ok): the last phone, no 'not released'" '[[ $rc = 1 ]] && grep -qx "DEVICE husky: RELEASE=FAIL at pack (exit 1)" "$L" && ! grep -q "^ota husky" "$HOME/calls"'

# 4. The web installer: only a released zip, and its failure stops the session
rc=$(FAKE_FAIL=noupload:cheetah run cheetah husky)
ok "no .uploaded: stopped at web before flasher_publish.py runs" '[[ $rc = 1 ]] && grep -q "^FAIL: .*isn.t released yet" "$L" && grep -qx "DEVICE cheetah: RELEASE=FAIL at web (exit 1); not released: husky" "$L" && ! grep -q "^web " "$HOME/calls"'
rc=$(FAKE_FAIL=web:cheetah run cheetah husky)
ok "flasher_publish.py fails: stopped at web" '[[ $rc = 1 ]] && grep -qx "DEVICE cheetah: RELEASE=FAIL at web (exit 1); not released: husky" "$L" && ! grep -q "husky" "$HOME/calls"'

# 5. Refused before anything runs
for a in "cheetah pixel9" "cheetah cheetah" "../cheetah"; do
    # shellcheck disable=SC2086
    rc=$(run $a)
    ok "refused: $a" '[[ $rc = 1 && ! -e $HOME/calls && "$(tail -n 2 "$L" | head -n 1)" = RELEASE=FAIL ]]'
done
rc=0; out=$(bash "$kit/tools/eos-release.sh" "$W/none.py" cheetah 2>&1) || rc=$?
ok "refused: no flasher_publish.py" '[[ $rc = 1 && $out == *"FAIL: no $W/none.py"* && ! -e $HOME/calls ]]'
rc=0; out=$(bash "$kit/tools/eos-release.sh" "$W/flasher_publish.py" 2>&1) || rc=$?
ok "refused: no phone" '[[ $rc = 1 && $out == *usage* && "$(tail -n 1 <<< "$out")" = RELEASE=FAIL ]]'

# 6. While it runs: the step it's at and when it should end
rc=$(run cheetah husky kodiak)
sed -i '/^== husky (2 of 3): eos-ota.sh/,$d' "$L"
echo "== husky (2 of 3): eos-ota.sh, $(date -u '+%F %T') UTC" >> "$L"
tmux new-session -d -s eos-pack 'sleep 120'
progress
ok "progress mid-way: husky at its OTA step with an estimate, kodiak queued with one" 'grep -qE "^PROGRESS device=husky state=running step=ota kind=publish .* eta_s=[0-9]+ " "$P" && grep -qE "^PROGRESS device=kodiak state=queued step=- kind=publish .* eta_s=[0-9]+ " "$P" && grep -q "^husky: release, making and uploading the OTA packages" "$P"'
tmux kill-server 2>/dev/null || true

echo "PASSED $pass FAILED $failed"
[[ $failed = 0 ]]
