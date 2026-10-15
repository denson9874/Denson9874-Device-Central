#!/bin/bash
# No-wipe update of Daryl's kodiak with a personal keep-init_boot zip, then logcat
# from the first moment adb is up (for the lock-screen fingerprint test).
#   flash-and-log.sh <zip> <expected sha256>
set -uo pipefail
S=66020DLDV0049F; zip=$1; want=$2
cd ~/Downloads/kodiak-evox
got=$(shasum -a 256 "$zip" | cut -d' ' -f1)
[ "$got" = "$want" ] || { echo "sha256 mismatch: $got"; exit 1; }
echo "sha256 OK"
adb -s $S reboot bootloader
for i in $(seq 1 60); do fastboot devices | grep -q $S && break; sleep 2; done
fastboot devices | grep -q $S || { echo "no fastboot device"; exit 1; }
fastboot -s $S getvar current-slot 2>&1 | grep current-slot
fastboot -s $S update "$zip" || { echo "FLASH FAILED"; exit 1; }
echo "== flashed; waiting for adb"
adb -s $S wait-for-device
log=~/Downloads/kodiak-evox/aod-flash/boot-$(date +%H%M%S).txt
nohup adb -s $S logcat -b all -v time > "$log" 2>&1 &
echo "logcat -> $log (pid $!)"
for i in $(seq 1 120); do [ "$(adb -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 3; done
echo "boot_completed=$(adb -s $S shell getprop sys.boot_completed | tr -d '\r') build=$(adb -s $S shell getprop ro.evolution.build.version | tr -d '\r')"
