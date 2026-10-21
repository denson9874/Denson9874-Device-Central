#!/usr/bin/env bash
# Collect stability, fluidity and charging evidence from a Pixel 8 Pro (husky)
# running Evolution X. Read-only on the device apart from resetting gfxinfo
# counters and writing a trace under /data/misc/perfetto-traces.
#
#   husky-audit.sh baseline            # build, kernel, dexopt, denials, crashes
#   husky-audit.sh fluidity [seconds]  # perfetto + gfxinfo while you swipe (default 20)
#   husky-audit.sh charge [minutes]    # charging telemetry CSV every 10 s (default 30)
#   husky-audit.sh all                 # baseline + fluidity
#
# Output: ./husky-audit-<timestamp>/ (override with OUT=dir). ADB_SERIAL selects a device.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT:-$PWD/husky-audit-$(date +%Y%m%d-%H%M%S)}"
adb=(adb ${ADB_SERIAL:+-s "$ADB_SERIAL"})
mkdir -p "$out"

sh() { "${adb[@]}" shell "$@" 2>&1 || true; }
say() { printf '== %s\n' "$*" >&2; }

require_husky() {
    "${adb[@]}" get-state >/dev/null 2>&1 || { echo "no adb device" >&2; exit 1; }
    local dev; dev="$(sh getprop ro.product.device | tr -d '\r')"
    [[ "$dev" == husky ]] || echo "warning: device is '$dev', not husky" >&2
}

baseline() {
    say "baseline -> $out/baseline.txt"
    {
        echo "### build"
        sh getprop | grep -E 'ro\.build\.(fingerprint|type|tags)|ro\.evolution|ro\.debuggable|ro\.boot\.slot_suffix|ro\.boot\.verifiedbootstate'
        sh uname -a
        echo; echo "### uptime / load"; sh uptime
        echo; echo "### memory"; sh cat /proc/meminfo | head -20
        sh getprop | grep -E 'mmd\.zram|lmkd|ro\.lmk'
        echo; echo "### dexopt state of the UI path (want speed-profile or better)"
        for pkg in com.android.systemui com.android.launcher3 com.google.android.apps.nexuslauncher android; do
            sh dumpsys package dexopt "$pkg" | grep -E '^\s*\[|status=' | head -6
        done
        echo; echo "### SystemUI / system_server restarts and crashes (dropbox)"
        sh dumpsys dropbox --print 2>/dev/null | grep -E '^20[0-9-]+ .*(system_server|system_app|SYSTEM_TOMBSTONE|data_app_anr|system_app_anr|watchdog)' | tail -30
        echo; echo "### lmkd kills since boot"
        sh logcat -b events -d -s am_kill:* | tail -40
        echo; echo "### SELinux denials"
        sh logcat -b all -d | grep -E 'avc:  denied' | sed 's/.*avc:/avc:/' | sort | uniq -c | sort -rn | head -40
        echo; echo "### power HAL (hints, ADPF sessions, BODEGA)"
        sh dumpsys android.hardware.power.IPower/default | head -80
        echo; echo "### thermal"
        sh dumpsys thermalservice | head -60
        sh getprop | grep -E 'vendor\.thermal\..*profile'
        echo; echo "### Extreme Charging"
        for k in bodega_supported bodega_enabled bodega_eligible; do echo "$k=$(sh settings get global $k)"; done
        sh dumpsys battery | sed -n '/ExtremeCharging/,$p' | head -20
        echo; echo "### refresh rate"
        sh dumpsys SurfaceFlinger | grep -E 'refresh-rate|activeMode|mode [0-9]+:' | head -10
    } >"$out/baseline.txt"
}

fluidity() {
    local secs="${1:-20}"
    local pkgs=(com.android.systemui com.android.launcher3 com.google.android.apps.nexuslauncher)
    say "resetting gfxinfo for ${pkgs[*]}"
    for p in "${pkgs[@]}"; do sh dumpsys gfxinfo "$p" reset >/dev/null; done
    sh logcat -c

    say "recording ${secs}s perfetto trace: pull the shade, expand QS, open the app drawer, scroll, go home"
    "${adb[@]}" shell perfetto --txt -c - -o /data/misc/perfetto-traces/husky-fluidity.pftrace \
        <"$here/husky-fluidity.pbtxt" >/dev/null 2>&1 &
    local tracer=$!
    sleep 2
    for i in $(seq "$secs" -1 1); do printf '\r   %3ss left ' "$i" >&2; sleep 1; done; echo >&2
    wait "$tracer" || true
    "${adb[@]}" pull /data/misc/perfetto-traces/husky-fluidity.pftrace "$out/" >/dev/null 2>&1 \
        && say "trace -> $out/husky-fluidity.pftrace (open in ui.perfetto.dev)" \
        || say "trace pull failed (on a user build run 'adb shell perfetto' as shell; see README)"

    for p in "${pkgs[@]}"; do sh dumpsys gfxinfo "$p" framestats >"$out/gfxinfo-$p.txt"; done
    sh dumpsys SurfaceFlinger --timestats -dump >"$out/sf-timestats.txt"
    sh logcat -d | grep -E 'Choreographer.*Skipped|Davey!|Slow (dispatch|delivery|Looper)|Long monitor contention|lmkd|ANR in|FATAL EXCEPTION|PowerHalWrapper|ADPF' \
        >"$out/logcat-jank.txt"
    summarize_gfxinfo
}

summarize_gfxinfo() {
    say "gfxinfo summary"
    for f in "$out"/gfxinfo-*.txt; do
        printf '%s\n' "$(basename "$f" .txt)"
        grep -E 'Total frames rendered|Janky frames|50th|90th|95th|99th|Number (Missed Vsync|High input latency|Slow UI thread|Slow bitmap uploads|Slow issue draw commands|Frame deadline missed)' "$f" \
            | sed 's/^/    /' | head -14
    done | tee "$out/gfxinfo-summary.txt" >&2
}

# One sysfs/prop read per column, "-" when unreadable on this build.
charge_sample() {
    sh 'r(){ v=$(cat "$1" 2>/dev/null) && echo -n "$v" || echo -n -; }
        cd /sys/class/power_supply
        md=-; for c in /sys/class/thermal/cooling_device*; do [ "$(cat $c/type 2>/dev/null)" = chg_mdis ] && md=$(cat $c/cur_state); done
        echo "$(date +%s),$(r battery/capacity),$(r battery/status),$(r battery/current_now),$(r battery/voltage_now),$(r battery/temp),$(r usb/online),$(r usb/usb_type),$(r usb/input_current_limit),$(r dc-mains/online),$(r dc-mains/current_max),$(r wireless/online),$md,$(getprop vendor.thermal.VIRTUAL-SKIN-CHARGE-WIRED.profile),$(settings get global bodega_enabled),$(dumpsys power | grep -m1 -o "mWakefulness=[A-Za-z]*" | cut -d= -f2),$(dumpsys thermalservice | grep -m1 -o "Thermal Status: [0-9]" | cut -d" " -f3)"' \
        | tr -d '\r'
}

charge() {
    local mins="${1:-30}" csv="$out/charge.csv"
    echo "epoch,soc,status,current_ua,voltage_uv,batt_temp_dc,usb_online,usb_type,usb_icl_ua,dc_online,dc_imax_ua,wlc_online,chg_mdis,bodega_profile,bodega_enabled,wakefulness,thermal_status" >"$csv"
    say "logging charging every 10 s for ${mins} min -> $csv (Ctrl-C stops early)"
    local end=$(( $(date +%s) + mins * 60 ))
    while (( $(date +%s) < end )); do
        charge_sample | tee -a "$csv" >&2
        sleep 10
    done
}

cmd="${1:-all}"; shift || true
require_husky
case "$cmd" in
    baseline) baseline ;;
    fluidity) fluidity "$@" ;;
    charge)   charge "$@" ;;
    all)      baseline; fluidity "$@" ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
say "done: $out"
