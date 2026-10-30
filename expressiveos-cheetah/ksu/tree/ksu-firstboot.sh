#!/system/bin/sh
# ExpressiveOS: KernelSU Next's setup on a new phone, so root, susfs and Zygisk work
# without opening the manager first (Daryl, 2026-10-27: susfs auto-load on, a Zygisk provider
# preinstalled). Installed as /product/etc/eos/ksu-firstboot.sh (0644); eos-ksu-firstboot.rc
# runs it with /system/bin/sh, as root, in the ksu domain.
#   post-fs-data    put ksud in /data/adb when it's missing, or when an OTA changed the ROM's
#                   libksud.so: until then the kernel's own init.rc lines find no ksud to run.
#                   On this /data's first boot only, turn susfs auto-load on: ksud's own
#                   post-fs-data loads it from the next boot on (this boot had no ksud yet to
#                   do it), honouring the user's switch and KernelSU's safe mode.
#   boot-completed  on this /data's first boot only, install the bundled Zygisk provider
#                   (NeoZygisk): active from the next boot, like any KernelSU module, so susfs
#                   and Zygisk both start on boot 2.
# Only ksud writes ksud's state. Each one-time step has its own marker in /data/adb/eos, is
# tried on at most three boots, and is never repeated once done, so nothing the user turns
# off or removes later comes back; pending goes only when both steps are done or out of
# tries. The provider is never installed over a Zygisk already there (the user's own, a
# NeoZygisk they updated, or one turned off), nor in safe mode, nor again once the user
# removed what a try of ours left. A /data that has booted Android before (an older build,
# or a no-root user an OTA rooted) gets ksud and nothing else. What happened is in
# /data/adb/eos/log.
set -u
umask 022                    # init starts services with umask 077; ksud's own su shell uses 022
KSUD=/product/app/KernelSUNext/lib/arm64/libksud.so
LIBADBROOT=/product/app/KernelSUNext/lib/arm64/libadbroot.so
ZIP=/product/etc/eos/zygisk-provider.zip
ZYGISK_CODE=289              # the zip's versionCode (ksu.conf's zygisk_version_code; apply-ksu.sh checks)
KMIS="android14-6.1 android16-6.12"   # those ExpressiveOS ships KernelSU Next for (apply-ksu.sh checks)
# The running kernel's KMI, as ksud names it: 6.12.69-android16-6-g...-4k is android16-6.12
r=$(uname -r); v=${r%%-*}; a=${r#*-}; KMI=${a%%-*}-${v%.*}
S=/data/adb/eos              # this script's state, outside ksud's own folders

[ -x "$KSUD" ] || exit 0
case "$("$KSUD" debug version 2>/dev/null)" in *": "[1-9]*) ;; *) exit 0 ;; esac   # KernelSU not live
log() { echo "$(date -u '+%F %T') ${1:-}: $2" >> "$S/log"; }
tries() { cat "$S/$1.tries" 2>/dev/null || echo 0; }
try() {   # try <step>: count one more try of it; false once it has had three
    t=$(tries "$1")
    [ "$t" -lt 3 ] || return 1
    echo $((t + 1)) > "$S/$1.tries"
}
over() { [ -e "$S/$1.done" ] || [ "$(tries "$1")" -ge 3 ]; }
zygisk_there() {   # a Zygisk is installed, or waits in modules_update, other than what an unfinished try of ours left
    for m in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
        [ -f "$m" ] || continue
        id=$(sed -n 's/^id=//p' "$m")
        case "$id" in zygisksu|rezygisk) ;; *) continue ;; esac
        # provider.trying: a try of ours failed or was cut off after it began writing the
        # module, so that NeoZygisk is ours to finish (ksud moves a half-done
        # modules_update/zygisksu into modules/ at the next post-fs-data, before this runs).
        # Not once it's turned off (safe mode and the manager's switch leave a disable file,
        # which an install would remove) or removed (boot-completed below)
        if [ -e "$S/provider.trying" ] && [ ! -e "/data/adb/modules/$id/disable" ] \
            && [ "$(sed -n 's/^name=//p' "$m")" = NeoZygisk ] \
            && [ "$(sed -n 's/^versionCode=//p' "$m")" = "$ZYGISK_CODE" ]; then
            continue
        fi
        return 0
    done
    return 1
}

case "${1:-}" in
post-fs-data)
    # Decided once, before system_server first writes packages.xml: is this /data new?
    mkdir -p "$S"
    if [ ! -e "$S/done" ] && [ ! -e "$S/pending" ]; then
        if [ -e /data/system/packages.xml ]; then : > "$S/done"; else : > "$S/pending"; fi
    fi
    # Never merely because /data/adb/ksud differs: that's a manager update the user took
    rom=$(sha256sum "$KSUD" | cut -d' ' -f1)
    if [ ! -e /data/adb/ksud ] || [ "$(cat "$S/ksud.sha256" 2>/dev/null)" != "$rom" ]; then
        if "$KSUD" install --libadbroot "$LIBADBROOT"; then echo "$rom" > "$S/ksud.sha256"; log ksud installed
        else log ksud "install failed"; fi
    fi
    if [ -e "$S/pending" ] && ! over susfs; then
        case " $KMIS " in
        *" $KMI "*)
            if try susfs; then
                if "$KSUD" susfs autoload enable --kmi "$KMI"; then : > "$S/susfs.done"; log susfs "auto-load on ($KMI)"
                else log susfs "autoload enable failed for $KMI (try $(tries susfs) of 3)"; fi
            fi ;;
        *) : > "$S/susfs.done"; log susfs "kernel $r isn't on a KMI this build has susfs for ($KMIS): left off" ;;
        esac
    fi
    ;;
boot-completed)
    [ -e "$S/pending" ] || exit 0
    if ! over provider; then
        # What an unfinished try of ours left shows in the manager once ksud has moved it into
        # modules/; if it's gone after that, the user removed it
        if [ -e "$S/provider.trying" ] && [ -f /data/adb/modules/zygisksu/module.prop ]; then : > "$S/provider.seen"; fi
        if [ -e "$S/provider.trying" ] && [ -e "$S/provider.seen" ] \
            && [ ! -e /data/adb/modules/zygisksu ] && [ ! -e /data/adb/modules_update/zygisksu ]; then
            : > "$S/provider.done"; log provider "the NeoZygisk an earlier try left was removed: not installed again"
        # Safe mode turned every module off (ksud checks the same properties): a later boot tries
        elif [ "$(getprop ro.sys.safemode)" = 1 ] || [ "$(getprop persist.sys.safemode)" = 1 ]; then
            log provider "safe mode: not tried on this boot"
        elif zygisk_there; then
            : > "$S/provider.done"; log provider "a Zygisk is already there (installed, waiting or turned off): NeoZygisk not installed"
        elif [ ! -f "$ZIP" ]; then
            : > "$S/provider.done"; log provider "no $ZIP"
        elif try provider; then
            # Stays while what this try leaves is the only NeoZygisk there (see zygisk_there)
            : > "$S/provider.trying"
            if "$KSUD" module install "$ZIP"; then : > "$S/provider.done"; log provider "NeoZygisk installed (active from the next boot)"
            else
                [ -e /data/adb/modules_update/zygisksu ] || [ -e /data/adb/modules/zygisksu ] || rm -f "$S/provider.trying" "$S/provider.seen"
                log provider "install failed (try $(tries provider) of 3)"
            fi
        fi
    fi
    if over susfs && over provider; then
        : > "$S/done"
        rm -f "$S/pending" "$S/provider.trying" "$S/provider.seen"
    fi
    ;;
esac
exit 0
