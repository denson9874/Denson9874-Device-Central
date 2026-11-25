#!/usr/bin/env bash
# Offline unit test of eos-stage.sh: verifies local release staging + OTA preview generation
# without R2 upload, try.txt rejection, device-ok creation, and stop-on-first-failure.
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-stage-test.XXXXXX")
trap 'rm -rf -- "$W"' EXIT
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
[[ "$*" = "--release" ]] || { echo "FAIL: expected --release, got $*"; echo "PACK=FAIL"; exit 1; }
ck=$HOME/releases/expressiveos-$EOS_DEVICE/check
z=("$ck"/*-fastboot.zip)
[[ -f "${z[0]}.device-ok" ]] || { echo "FAIL: missing device-ok"; echo "PACK=FAIL"; exit 1; }
[[ ${FAKE_FAIL:-} != "pack:$EOS_DEVICE" ]] || { echo "PACK=FAIL"; exit 1; }
echo "PACK=OK"
EOF
chmod +x "$kit/tools/eos-pack.sh"

cat > "$kit/tools/eos-ota.sh" <<'EOF'
#!/usr/bin/env bash
echo "ota $EOS_DEVICE $*" >> "$HOME/calls"
[[ $# -eq 0 ]] || { echo "FAIL: expected preview mode (no args), got $*"; echo "OTA=FAIL"; exit 1; }
[[ ${FAKE_FAIL:-} != "ota:$EOS_DEVICE" ]] || { echo "OTA=FAIL"; exit 1; }
echo "===== OTA_FEED builds/$EOS_DEVICE.json"
echo "{\"response\": [\"$EOS_DEVICE\"]}"
echo "===== OTA_FEED_END"
echo "OTA_PREVIEW $HOME/releases/expressiveos-$EOS_DEVICE/ota/feed: nothing uploaded"
echo "OTA=OK"
EOF
chmod +x "$kit/tools/eos-ota.sh"

seed_candidates() {
    rm -rf -- "$HOME/calls" "$HOME/releases" "$HOME/expressiveos"
    for d in "$@"; do
        mkdir -p "$HOME/releases/expressiveos-$d/check"
        printf 'cand-%s' "$d" > "$HOME/releases/expressiveos-$d/check/ExpressiveOS-17.0-20261125-$d-1.3.1-Official-fastboot.zip"
    done
}

# 1. Happy path across multiple phones: never passes --upload
seed_candidates cheetah husky kodiak
rc=0
out=$(bash "$kit/tools/eos-stage.sh" cheetah husky kodiak 2>&1) || rc=$?
ok "three phones stage cleanly with STAGE=OK" '[[ $rc = 0 && "$(tail -n 1 <<< "$out")" = STAGE=OK ]]'
printf 'pack cheetah --release\nota cheetah \npack husky --release\nota husky \npack kodiak --release\nota kodiak \n' > "$W/want"
ok "calls eos-pack.sh --release and eos-ota.sh (preview, no --upload)" 'cmp -s "$W/want" "$HOME/calls"'
ok "writes ota-<phone>.log for each phone" 'for d in cheetah husky kodiak; do [[ "$(tail -n 1 "$jobs/ota-$d.log")" = OTA=OK ]] || exit 1; done'

# 2. Refuses candidate with try.txt
seed_candidates cheetah husky
mkdir -p "$HOME/expressiveos/out/eos-husky"
echo "frameworks/base deadbeef" > "$HOME/expressiveos/out/eos-husky/try.txt"
rc=0
out=$(bash "$kit/tools/eos-stage.sh" cheetah husky 2>&1) || rc=$?
ok "refuses staging when try.txt exists before touching any phone" '[[ $rc = 1 && ! -e "$HOME/calls" && "$(tail -n 1 <<< "$out")" = STAGE=FAIL ]]'

# 3. Stops on first failure without touching remaining phones
seed_candidates cheetah husky kodiak
rc=0
out=$(FAKE_FAIL=ota:husky bash "$kit/tools/eos-stage.sh" cheetah husky kodiak 2>&1) || rc=$?
ok "stops on husky OTA failure without staging kodiak" '[[ $rc = 1 && "$out" == *"DEVICE husky: STAGE=FAIL at ota (exit 1); not staged: kodiak"* ]] && ! grep -q kodiak "$HOME/calls"'

echo "PASSED $pass FAILED $failed"
[[ $failed = 0 ]]
