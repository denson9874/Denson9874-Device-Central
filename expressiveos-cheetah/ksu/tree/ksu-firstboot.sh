#!/system/bin/sh
# ExpressiveOS: install SukiSU's manager (com.sukisu.ultra) for the phone's owner once, on the
# first boot with SukiSU loaded, so root can be granted without sideloading it (Daryl,
# 2026-11-14: root out of the box, SukiSU only). SukiSU's kernel crowns only a manager under
# /data/app, so the ROM carries the APK as a file and installs it like any app. Installed as
# /product/etc/eos/ksu-firstboot.sh (0644); eos-ksu-firstboot.rc runs it with /system/bin/sh, as
# root, in the ksu domain, at sys.boot_completed=1.
# Tried on at most three boots and never again once done, so a manager the user uninstalls stays
# gone. A phone that already has it (an update, or one the user installed) only gets the marker.
# What happened is in /data/adb/eos/log.
set -u
APK=/product/etc/eos/sukisu-manager.apk
PKG=com.sukisu.ultra
S=/data/adb/eos
[ -f "$APK" ] || exit 0
mkdir -p "$S" || exit 0
log() { echo "$(date -u '+%F %T') manager: $1" >> "$S/log"; }
[ -e "$S/manager.done" ] && exit 0
if pm path --user 0 "$PKG" 2>/dev/null | grep -q '^package:'; then
    : > "$S/manager.done"; log "already installed: not installed again"; exit 0
fi
t=$(cat "$S/manager.tries" 2>/dev/null || echo 0)
[ "$t" -lt 3 ] || exit 0
echo $((t + 1)) > "$S/manager.tries"
if out=$(pm install --user 0 "$APK" 2>&1); then
    : > "$S/manager.done"; log "installed ($out)"
else
    log "install failed (try $((t + 1)) of 3): $out"
fi
exit 0
