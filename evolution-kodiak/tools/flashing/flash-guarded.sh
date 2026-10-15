#!/bin/bash
# No-wipe flash of a personal zip with automatic rollback: if the phone falls back to
# fastboot instead of finishing boot, flash the rollback zip.
#   flash-guarded.sh <zip> <sha256> <rollback zip>
set -uo pipefail
S=66020DLDV0049F; zip=$1; want=$2; rollback=$3
cd ~/Downloads/kodiak-evox
[ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" = "$want" ] || { echo "sha256 mismatch"; exit 1; }
[ -f "$rollback" ] || { echo "no rollback zip"; exit 1; }
echo "sha256 OK"
if [ "$(adb -s $S get-state 2>/dev/null)" = device ]; then adb -s $S reboot bootloader; fi
for i in $(seq 1 60); do fastboot devices | grep -q $S && break; sleep 2; done
fastboot -s $S update "$zip" > /tmp/flash-guarded.log 2>&1 || { echo "FLASH FAILED"; tail -5 /tmp/flash-guarded.log; exit 1; }
echo "== flashed $zip"
wait_boot() {
    sleep 20
    for i in $(seq 1 80); do
        if [ "$(adb -s $S get-state 2>/dev/null)" = device ]; then
            [ -z "${LOGPID:-}" ] && { log=~/Downloads/kodiak-evox/aod-flash/boot-$(date +%H%M%S).txt; nohup adb -s $S logcat -b all -v time > "$log" 2>&1 & LOGPID=$!; echo "logcat -> $log"; }
            [ "$(adb -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0
        fi
        fastboot devices 2>/dev/null | grep -q $S && return 1
        sleep 3
    done
    return 1
}
if wait_boot; then
    echo "BOOT_OK $(adb -s $S shell getprop ro.evolution.build.version | tr -d '\r')"
    sleep 30   # give system_server time to crash if it's going to
    [ "$(adb -s $S get-state 2>/dev/null)" = device ] && { echo "STILL_UP"; exit 0; }
fi
echo "BOOT_FAILED: $(fastboot -s $S getvar enter-reason 2>&1 | head -1); rolling back to $rollback"
[ -n "${LOGPID:-}" ] && kill $LOGPID 2>/dev/null
LOGPID=""
fastboot devices | grep -q $S || { adb -s $S reboot bootloader 2>/dev/null; sleep 10; }
fastboot -s $S update "$rollback" > /tmp/flash-guarded-rb.log 2>&1 || { echo "ROLLBACK FLASH FAILED"; exit 2; }
wait_boot && echo "ROLLED_BACK_OK" || echo "ROLLBACK DID NOT BOOT"
exit 3
