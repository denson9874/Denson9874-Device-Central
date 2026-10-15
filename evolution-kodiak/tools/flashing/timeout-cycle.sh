#!/bin/bash
# One screen-timeout-to-AOD cycle on Daryl's kodiak, logged. It wakes the screen
# and lets it time out by itself (about 10 s on the lock screen, the screen
# timeout when unlocked), then prints the brightness the display went through.
# Over USB, "Stay awake while charging" would keep the screen on and the charging
# screen saver would start instead of AOD, so both are switched off for the cycle
# and restored afterwards; nothing else is changed.
#   timeout-cycle.sh <label>
set -uo pipefail
S=66020DLDV0049F
label=${1:-run}
out=~/Downloads/kodiak-evox/aod-flash/$label-$(date +%H%M%S).txt
a() { adb -s $S shell "$@"; }
[ "$(adb -s $S get-state 2>/dev/null)" = device ] || { echo "phone not connected"; exit 1; }
echo "build:      $(a getprop ro.evolution.build.version)"
echo "AOD:        doze_always_on=$(a settings get secure doze_always_on)"
echo "brightness: mode=$(a settings get system screen_brightness_mode) (1 = auto)  doze_brightness=$(a settings get system doze_brightness)  force=$(a settings get system doze_brightness_force)"
echo "lux now:    $(a dumpsys display | grep -m1 -oE 'mAmbientLux=[0-9.]+')"
stay=$(a settings get global stay_on_while_plugged_in); ss=$(a settings get secure screensaver_activate_on_sleep)
restore() {
    a settings put global stay_on_while_plugged_in "$stay"; a settings put secure screensaver_activate_on_sleep "$ss"
    echo "restored: stay_on_while_plugged_in=$(a settings get global stay_on_while_plugged_in) screensaver_activate_on_sleep=$(a settings get secure screensaver_activate_on_sleep)"
}
trap restore EXIT
a settings put global stay_on_while_plugged_in 0; a settings put secure screensaver_activate_on_sleep 0
since=$(a "date '+%m-%d %H:%M:%S.000'")
a input keyevent KEYCODE_WAKEUP
echo "screen woken at $since; waiting ${WAIT:-45} s for it to time out (don't touch the phone)"
timeout ${WAIT:-45} adb -s $S logcat -T "$since" -v time > "$out" 2>/dev/null
grep -E "Brightness \[|Going to sleep|Waking up|UpdateDoze|hwc-pixel-bc.*nits" "$out" | sed -E 's/^([0-9-]+ [0-9:.]+) [A-Z]\/([^(]+)\([ 0-9]+\): /\1 \2: /' | grep -v 'path=sysfs' | head -60
echo "full log: $out"
