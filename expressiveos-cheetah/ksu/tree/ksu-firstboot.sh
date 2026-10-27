#!/system/bin/sh
# ExpressiveOS (cheetah): KernelSU Next's setup on a new phone, so root, susfs and Zygisk work
# without opening the manager first (Daryl, 2026-10-27: susfs auto-load on, a Zygisk provider
# preinstalled). Installed as /product/etc/eos/ksu-firstboot.sh (0644); eos-ksu-firstboot.rc
# runs it with /system/bin/sh, as root, in the ksu domain.
#   post-fs-data    put ksud in /data/adb when it's missing, or when an OTA changed the ROM's
#                   libksud.so: until then the kernel's own init.rc lines find no ksud to run.
#                   On this /data's first boot only, turn susfs auto-load on, and load it this
#                   one boot (ksud loads it itself from the next one).
#   boot-completed  on this /data's first boot only, install the bundled Zygisk provider
#                   (NeoZygisk): active from the next boot, like any KernelSU module.
# Only ksud writes ksud's state. Each one-time step has its own marker in /data/adb/eos and is
# never repeated once done, so nothing the user turns off or removes later comes back. A /data
# that has booted Android before (an older build, or a no-root user an OTA rooted) gets ksud
# and nothing else.
set -u
umask 022                    # init starts services with umask 077; ksud's own su shell uses 022
KSUD=/product/app/KernelSUNext/lib/arm64/libksud.so
LIBADBROOT=/product/app/KernelSUNext/lib/arm64/libadbroot.so
ZIP=/product/etc/eos/zygisk-provider.zip
KMI=android14-6.1
S=/data/adb/eos              # this script's state, outside ksud's own folders

[ -x "$KSUD" ] || exit 0
case "$("$KSUD" debug version 2>/dev/null)" in *": "[1-9]*) ;; *) exit 0 ;; esac   # KernelSU not live
safemode() { [ "$(getprop persist.sys.safemode)" = 1 ] || [ "$(getprop ro.sys.safemode)" = 1 ]; }

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
        "$KSUD" install --libadbroot "$LIBADBROOT" && echo "$rom" > "$S/ksud.sha256"
    fi
    if [ -e "$S/pending" ] && [ ! -e "$S/susfs.done" ]; then
        if "$KSUD" susfs autoload enable --kmi "$KMI"; then
            : > "$S/susfs.done"
            # This boot only: ksud's own post-fs-data didn't run (there was no /data/adb/ksud).
            # From the next boot ksud loads it, honouring the user's switch and KernelSU's
            # safe mode.
            safemode || "$KSUD" susfs load --kmi "$KMI"
        fi
    fi
    ;;
boot-completed)
    [ -e "$S/pending" ] || exit 0
    n=$(cat "$S/provider.tries" 2>/dev/null || echo 0)
    if [ -f "$ZIP" ] && [ "$n" -lt 3 ]; then
        echo $((n + 1)) > "$S/provider.tries"
        "$KSUD" module install "$ZIP" || exit 0          # tried again next boot, three times at most
    fi
    : > "$S/done"
    rm -f "$S/pending"
    ;;
esac
exit 0
