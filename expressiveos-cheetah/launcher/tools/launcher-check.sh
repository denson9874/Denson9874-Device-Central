#!/usr/bin/env bash
# Expressive Launcher checks for ExpressiveOS (every phone). Each check prints PASS, FAIL or
# INFO; all of them run, the exit status is 1 if any FAILed, and the last line is
# LAUNCHER_CHECK=OK or LAUNCHER_CHECK=FAIL.
#
#   launcher-check.sh tree <top>
#       Before the build (apply-launcher.sh runs it): vendor/extra/launcher matches the kit and
#       launcher.conf, vendor/extra/product.mk inherits launcher.mk for every ExpressiveOS
#       phone, the privapp allowlist covers every privileged permission the APK asks for (as
#       this tree's frameworks/base declares them: a missing one stops the boot), the
#       overlays still replace what Pixel's own config sets for Pixel Launcher, and the
#       modules the launcher overrides are still the ones the tree builds.
#   launcher-check.sh out <product_out> [host_out]
#       After the build, before packing (the ExpressiveOS OTA script runs it): the APK
#       landed unchanged with its permissions, sysconfig and two overlays, Pixel Launcher,
#       AOSP's Launcher3 and Pixel Launcher's overlays did not, no other app ships an
#       enabled Home activity, and nothing reorders the overlays.
#       host_out (out/host/linux-x86) is only used for apksigner.
#   launcher-check.sh device
#       On a phone over adb (ANDROID_SERIAL picks one). Read-only. Run it soon after a boot,
#       with the phone unlocked once, while logcat still holds the boot: Expressive Launcher
#       is the Home app and the Recents app SystemUI is bound to, Pixel Launcher is gone,
#       the privileged permissions are granted, nothing crashed, and no binder call into it
#       failed (run it again after trying the gestures).
set -euo pipefail
fails=0 finished=0 T=
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $finished = 1 ]] || { echo "FAIL: stopped by an unexpected error (exit $rc)"; echo "LAUNCHER_CHECK=FAIL"; }
    exit $rc
}
trap cleanup EXIT
kit="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../launcher.conf
source "$kit/launcher.conf"
T=$(mktemp -d "${TMPDIR:-/tmp}/launcher-check.XXXXXX")
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }
info() { echo "INFO: $*"; }
finish() {
    finished=1
    if [[ $fails = 0 ]]; then echo "LAUNCHER_CHECK=OK"; exit 0; fi
    echo "$fails check(s) failed"
    echo "LAUNCHER_CHECK=FAIL"; exit 1
}
usage() {
    echo "usage: launcher-check.sh tree <top> | out <product_out> [host_out] | device" >&2
    finished=1; echo "LAUNCHER_CHECK=FAIL"; exit 2
}
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
xq() { python3 -I "$kit/tools/launcher-xml.py" "$@"; }
words() { tr ' ' '\n' <<<"$*" | sed '/^$/d' | LC_ALL=C sort -u; }
# Pixel Launcher's package, and what Pixel's config names it for
PIXEL=com.google.android.apps.nexuslauncher
RECENTS="$EL_PACKAGE/$EL_RECENTS_ACTIVITY"
ALL_SET="$EL_PACKAGE/$EL_ALL_SET_ACTION"
SUW=com.google.android.pixel.setupwizard
FW_OVERLAY=ExpressiveLauncherFrameworkOverlay SUW_OVERLAY=ExpressiveLauncherSetupWizardOverlay
# The kit's own values, which every mode compares with
fw_res="$kit/tree/overlay/framework/res/values/config.xml"
want_recents=$(xq string "$fw_res" config_recentsComponentName)
want_listeners=$(xq string "$fw_res" config_defaultListenerAccessPackages)
want_allset=$(xq string "$kit/tree/overlay/setupwizard/res/values/strings.xml" exit_to_action_in_initial_setup)
[[ "$want_recents" = "$RECENTS" ]] || bad "tree/overlay/framework config_recentsComponentName is '$want_recents', launcher.conf says $RECENTS"
[[ "$want_allset" = "$ALL_SET" ]] || bad "tree/overlay/setupwizard exit_to_action_in_initial_setup is '$want_allset', launcher.conf says $ALL_SET"
# The lists in tree/overlay/framework: the build's own with Expressive Launcher in Pixel
# Launcher's place, or added at the end
LISTS="config_defaultListenerAccessPackages config_launcherPackages vendor_required_apps_managed_device vendor_required_apps_managed_user"
for n in $LISTS; do
    v=$(xq string "$fw_res" "$n")
    [[ ":$v:" = *":$EL_PACKAGE:"* && ":$v:" != *":$PIXEL:"* ]] \
        || bad "tree/overlay/framework's $n must name $EL_PACKAGE and not $PIXEL: '$v'"
done
# ExpressiveOS's phones: devices/<device>.conf
phones=()
for f in "$kit"/../devices/*.conf; do f=${f##*/}; phones+=("${f%.conf}"); done

mode=${1:-}; shift || true
case "$mode" in
tree)
    [[ $# = 1 && -d "$1" ]] || usage
    top="$(cd "$1" && pwd -P)"
    echo "== Expressive Launcher tree checks: $top"
    evo=$(cd "$HOME/evolution" 2>/dev/null && pwd -P || true)
    derp=$(cd "$HOME/derpfest" 2>/dev/null && pwd -P || true)
    if [[ "$top" = */evolution || "$top" = */derpfest || ( -n "$evo" && "$top" = "$evo" ) || ( -n "$derp" && "$top" = "$derp" ) ]]; then
        bad "$top is the Evolution X or DerpFest tree; Expressive Launcher is for the ExpressiveOS tree only"; finish
    fi
    # What apply-launcher.sh writes must stay in this tree, also through symlinks
    ok=1
    for p in vendor/extra vendor/extra/launcher vendor/extra/product.mk; do
        r=$(realpath -m -- "$top/$p")
        if [[ "$r" != "$top"/* ]]; then ok=0; bad "$p leads to $r, outside $top (a symlink?)"
        elif [[ -n "$evo" && ( "$r" = "$evo" || "$r" = "$evo"/* ) ]]; then ok=0; bad "$p leads into the Evolution X tree ($r)"
        elif [[ -n "$derp" && ( "$r" = "$derp" || "$r" = "$derp"/* ) ]]; then ok=0; bad "$p leads into the DerpFest tree ($r)"; fi
    done
    [[ $ok = 0 ]] || pass "vendor/extra is this tree's own (no symlink out of it, or into ~/evolution or ~/derpfest)"

    # What apply-launcher.sh staged: the pinned APK, LICENSE and notices, and tree/ as it is
    dest="$top/vendor/extra/launcher"
    ok=1
    if [[ ! -d "$dest" ]]; then
        ok=0; bad "vendor/extra/launcher isn't staged: run apply-launcher.sh"
    else
        [[ -f "$dest/ExpressiveLauncher.apk" && "$(sha "$dest/ExpressiveLauncher.apk")" = "$EL_SHA256" ]] \
            || { ok=0; bad "vendor/extra/launcher/ExpressiveLauncher.apk is missing or not the pinned $EL_VERSION APK ($EL_SHA256)"; }
        for f in LICENSE:EL_LICENSE_SHA256 NOTICE.calculator:EL_NOTICE_MIT_SHA256 NOTICE.font:EL_NOTICE_OFL_SHA256; do
            v=${f#*:} f=${f%%:*}
            [[ -f "$dest/$f" && "$(sha "$dest/$f")" = "${!v}" ]] \
                || { ok=0; bad "vendor/extra/launcher/$f is missing or not the pinned one ($v)"; }
        done
        while IFS= read -r -d '' f; do
            f=${f#"$kit/tree/"}
            cmp -s -- "$kit/tree/$f" "$dest/$f" || { ok=0; bad "vendor/extra/launcher/$f differs from the kit's tree/$f"; }
        done < <(find "$kit/tree" -type f -print0 | LC_ALL=C sort -z)
        while IFS= read -r -d '' f; do
            f=${f#"$dest/"}
            # Nothing staged may lead out of the tree (apply-launcher.sh refuses that too)
            r=$(realpath -m -- "$dest/$f")
            if [[ "$r" != "$top"/* || ( -n "$evo" && ( "$r" = "$evo" || "$r" = "$evo"/* ) ) || ( -n "$derp" && ( "$r" = "$derp" || "$r" = "$derp"/* ) ) ]]; then
                ok=0; bad "vendor/extra/launcher/$f leads to $r, outside this tree or into ~/evolution or ~/derpfest (a symlink?)"
            fi
            case $f in ExpressiveLauncher.apk|LICENSE|NOTICE.calculator|NOTICE.font) continue ;; esac
            [[ -f "$kit/tree/$f" ]] || { ok=0; bad "vendor/extra/launcher/$f isn't the kit's: run apply-launcher.sh"; }
        done < <(find "$dest" ! -type d -print0 | LC_ALL=C sort -z)
    fi
    [[ $ok = 0 ]] || pass "vendor/extra/launcher matches the kit and launcher.conf ($EL_PACKAGE $EL_VERSION, $EL_VERSION_CODE)"
    line='$(call inherit-product, vendor/extra/launcher/launcher.mk)'
    where=$(want="$line" awk -f "$kit/tools/mk-line.awk" -- "$top/vendor/extra/product.mk" 2>/dev/null || true)
    case "$where" in
        top) pass "vendor/extra/product.mk inherits launcher.mk (outside any conditional)" ;;
        nested) bad "vendor/extra/product.mk inherits launcher.mk only inside an ifeq/ifdef/define block: move the line to the top level" ;;
        *) bad "vendor/extra/product.mk doesn't inherit launcher.mk: run apply-launcher.sh" ;;
    esac
    # Evolution X's vendor_evolution is checked out at vendor/lineage; its config/common.mk
    # line 2 reads vendor/extra/product.mk
    if grep -qE '^\s*\$\(call inherit-product-if-exists, *vendor/extra/product\.mk\)' "$top/vendor/lineage/config/common.mk" 2>/dev/null; then
        pass "vendor/lineage/config/common.mk inherits vendor/extra/product.mk"
    else
        bad "vendor/lineage/config/common.mk is missing or no longer inherits vendor/extra/product.mk: Pixel Launcher would silently stay"
    fi
    # Every ExpressiveOS phone's product is in launcher.mk's list
    mk_filter=$(grep -m1 -E '^ifneq \(\$\(filter ' "$kit/tree/launcher.mk" || true)
    miss=()
    for d in "${phones[@]}"; do
        [[ " ${mk_filter//[(),]/ } " = *" lineage_$d "* ]] || miss+=("$d")
    done
    if [[ ${#miss[@]} = 0 && ${#phones[@]} -gt 0 ]]; then
        pass "launcher.mk covers every ExpressiveOS phone (${phones[*]})"
    else
        bad "launcher.mk's product list lacks: ${miss[*]:-no devices/*.conf found} (add lineage_<device> to its filter)"
    fi

    # The privapp allowlist. A privileged permission the APK asks for that the XML doesn't
    # grant stops a clean flash at boot under ro.control_privapp_permissions=enforce (the
    # build sets "log" today, which only logs it; an update installed over the built-in copy
    # is not checked either way, so a dirty flash can hide it).
    fwm="$top/frameworks/base/core/res/AndroidManifest.xml"
    if [[ ! -f "$fwm" ]]; then
        bad "no frameworks/base/core/res/AndroidManifest.xml: can't tell which permissions are privileged"
    else
        # shellcheck disable=SC2086 # one argument per permission
        priv=$(xq privileged "$fwm" $EL_PERMS | LC_ALL=C sort -u)
        listed=$(words "$EL_PRIVAPP_PERMS")
        missing=$(LC_ALL=C comm -23 <(echo "$priv") <(echo "$listed") | sed '/^$/d' | paste -sd' ')
        extra=$(LC_ALL=C comm -13 <(echo "$priv") <(echo "$listed") | sed '/^$/d' | paste -sd' ')
        if [[ -z "$missing" ]]; then
            pass "EL_PRIVAPP_PERMS covers every privileged permission the APK asks for ($(wc -w <<<"$priv") in this tree's frameworks/base)"
        else
            bad "privileged in this tree's frameworks/base but not in EL_PRIVAPP_PERMS: $missing (add them to launcher.conf and tree/privapp-permissions-$EL_PACKAGE.xml, or the phone won't boot)"
        fi
        [[ -z "$extra" ]] || info "EL_PRIVAPP_PERMS also lists $extra, which this tree's frameworks/base doesn't mark privileged (harmless)"
    fi
    notasked=$(LC_ALL=C comm -13 <(words "$EL_PERMS") <(words "$EL_PRIVAPP_PERMS") | paste -sd' ')
    [[ -z "$notasked" ]] || bad "EL_PRIVAPP_PERMS lists permissions the APK doesn't ask for: $notasked"
    px="$kit/tree/privapp-permissions-$EL_PACKAGE.xml"
    got=$(xq privapp "$px" "$EL_PACKAGE" 2>/dev/null | LC_ALL=C sort | paste -sd' ' || true)
    want=$(for p in $EL_PRIVAPP_PERMS; do echo "permission $p"; done | LC_ALL=C sort | paste -sd' ')
    [[ "$got" = "$want" ]] && pass "tree/privapp-permissions-$EL_PACKAGE.xml grants exactly EL_PRIVAPP_PERMS" \
        || bad "tree/privapp-permissions-$EL_PACKAGE.xml grants [$got], launcher.conf wants [$want]"

    # The framework config the overlay replaces: each list as the build would have it without
    # this kit (the highest-priority overlay's, else framework-res's), with Expressive Launcher
    # in Pixel Launcher's place or added at the end
    for n in $LISTS; do
        want=$(xq string "$fw_res" "$n")
        xq sources "$n" "$top" > "$T/src"
        if [[ ! -s "$T/src" ]]; then
            bad "nothing in the tree sets $n (frameworks/base, vendor/lineage/overlay/common, vendor/pixel-style): check tree/overlay/framework's by hand (README.md)"
            continue
        fi
        IFS=$'\t' read -r pr from val < "$T/src"
        if [[ "$(awk -F'\t' -v p="$pr" -v v="$val" 'NR > 1 && $1 == p && $3 != v' "$T/src" | head -1)" ]]; then
            bad "$n: two sources with priority $pr and different values ($(awk -F'\t' -v p="$pr" '$1 == p { print $2 }' "$T/src" | paste -sd' ')); which one wins depends on their paths: check by hand"
            continue
        fi
        if [[ ":$val:" = *":$PIXEL:"* ]]; then
            expect=$(tr ':' '\n' <<<"$val" | sed "s/^$PIXEL\$/$EL_PACKAGE/" | paste -sd:)
            how="with Pixel Launcher swapped for Expressive Launcher"
        elif [[ ":$val:" = *":$EL_PACKAGE:"* ]]; then
            expect=$val how="(it names Expressive Launcher already)"
        else
            expect="${val:+$val:}$EL_PACKAGE" how="with Expressive Launcher added"
        fi
        if [[ "$expect" = "$want" ]]; then
            pass "$n is $from's (priority $pr, the one the build uses) $how"
        else
            bad "$from (priority $pr, the one the build uses) changed its $n: set tree/overlay/framework's to '$expect' (now '$want'; a string-array has one <item> each)"
        fi
    done
    rro="$top/vendor/pixel-style/rro_overlays"
    if [[ ! -d "$rro" ]]; then
        bad "no vendor/pixel-style/rro_overlays: where Pixel's launcher config comes from has moved; check the overlays by hand (README.md)"
    else
        v=$(xq string "$rro/PixelConfigOverlayCommon/res/values/strings.xml" config_recentsComponentName 2>/dev/null || true)
        info "Pixel's config_recentsComponentName (PixelConfigOverlayCommon): ${v:-not set}; this kit's system_ext overlay sets $RECENTS over it"
        v=$(xq string "$rro/PixelSetupWizardOverlayExpressive/res/values/strings.xml" exit_to_action_in_initial_setup 2>/dev/null || true)
        t=$(xq overlay "$rro/PixelSetupWizardOverlayExpressive/AndroidManifest.xml" 2>/dev/null | cut -d' ' -f1 || true)
        if [[ -n "$v" && "$t" = "$SUW" ]]; then
            pass "Pixel's setup wizard overlay still sets exit_to_action_in_initial_setup ($v) on $SUW, which tree/overlay/setupwizard replaces"
        else
            bad "vendor/pixel-style's PixelSetupWizardOverlayExpressive no longer sets exit_to_action_in_initial_setup on $SUW: check what the setup wizard opens when it ends (README.md)"
        fi
    fi
    # Static overlays apply by partition (system_ext after product) unless a
    # partition_order.xml reorders them; this kit's overlays rely on that order
    hits=$(find "$top/device" "$top/vendor" -name partition_order.xml -not -path '*/.git/*' 2>/dev/null | sed "s|^$top/||" | paste -sd' ' || true)
    [[ -z "$hits" ]] && pass "no partition_order.xml in device/ or vendor/ (system_ext overlays apply after product ones)" \
        || bad "partition_order.xml found ($hits): it may put product overlays after system_ext ones, and Pixel's launcher config would win"

    # The modules ExpressiveLauncher overrides: Pixel Launcher's name must still be the one
    # its overrides list, or both launchers would ship
    if grep -rqsE --include=Android.mk --include=Android.bp '(LOCAL_MODULE[[:space:]]*:=[[:space:]]*NexusLauncherRelease[[:space:]]*$|name:[[:space:]]*"NexusLauncherRelease")' -- "$top/vendor/gms"; then
        pass "vendor/gms still builds Pixel Launcher as NexusLauncherRelease, which ExpressiveLauncher overrides"
    else
        hits=$(grep -rlsE --include=Android.mk --include=Android.bp -i 'nexuslauncher' -- "$top/vendor/gms" | sed "s|^$top/||" | paste -sd' ' || true)
        if [[ -n "$hits" ]]; then
            bad "vendor/gms builds Pixel Launcher under another module name ($hits): add it to tree/Android.bp's overrides"
        else
            info "vendor/gms has no Pixel Launcher module any more"
        fi
    fi
    for m in PixelLauncherNoGestureHintOverlay PixelLauncherOverlayCustom; do
        [[ -d "$top/vendor/pixel-style/rro_overlays/$m" ]] && info "$m (Pixel Launcher's overlay) is in vendor/pixel-style; $FW_OVERLAY overrides it" \
            || info "$m is gone from vendor/pixel-style (its override is a no-op)"
    done
    ;;

out)
    [[ $# -ge 1 && $# -le 2 && -d "$1" ]] || usage
    O="$(cd "$1" && pwd -P)" H=${2:-}
    echo "== Expressive Launcher build checks: $O"
    apk="$O/system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk"
    if [[ -f "$apk" && "$(sha "$apk")" = "$EL_SHA256" ]]; then
        pass "system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk is the $EL_VERSION ($EL_VERSION_CODE) release APK, unchanged"
    else
        bad "system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk is missing or was rewritten (want $EL_SHA256)"
    fi
    signer=
    for s in "$H/bin/apksigner" "$H/apksigner"; do [[ -n "$H" && -x "$s" ]] && { signer=$s; break; }; done
    if [[ -z "$signer" ]]; then
        info "no apksigner in host_out (${H:-not given}): signer not checked here; the APK's sha256 pins it ($EL_CERT_SHA256)"
    elif [[ -f "$apk" ]] && "$signer" verify --print-certs "$apk" 2>/dev/null | grep -F "certificate SHA-256 digest: $EL_CERT_SHA256" >/dev/null; then
        pass "apksigner: the APK verifies, signed by Expressive's release certificate $EL_CERT_SHA256"
    else
        bad "apksigner: the APK doesn't verify or isn't signed by $EL_CERT_SHA256"
    fi
    [[ -d "$O/system_ext/priv-app/ExpressiveLauncher/oat" ]] && info "dexpreopted (system_ext/priv-app/ExpressiveLauncher/oat)" \
        || info "not dexpreopted (no oat/ next to the APK): the phone compiles it after boot"
    # One Home app: Pixel Launcher, AOSP's Launcher3 and Trebuchet stay out
    hits=$(cd "$O" && find system system_ext product vendor -maxdepth 3 \( -path '*app/ExpressiveLauncher*' -o -path '*app/NexusLauncher*' \
        -o -path '*app/Launcher3*' -o -path '*app/Trebuchet*' -o -path '*app/Lawnchair*' -o -path '*app/QuickSearchBox*' \) -prune -print 2>/dev/null | LC_ALL=C sort | paste -sd' ' || true)
    if [[ "$hits" = system_ext/priv-app/ExpressiveLauncher ]]; then
        pass "the only launcher app is system_ext/priv-app/ExpressiveLauncher (no NexusLauncherRelease, Launcher3, Trebuchet or QuickSearchBox)"
    else
        bad "launcher apps in the images: ${hits:-none} (want only system_ext/priv-app/ExpressiveLauncher)"
    fi
    hits=$(cd "$O" && find system system_ext product vendor -path '*/overlay/*' -name 'PixelLauncher*' 2>/dev/null | LC_ALL=C sort | paste -sd' ' || true)
    [[ -z "$hits" ]] && pass "no Pixel Launcher overlays" || bad "Pixel Launcher overlays shipped: $hits"
    # One Home activity. The HOME role has no default holder: the highest-priority HOME
    # activity gets it, and a tie leaves nobody (the chooser comes up on Home). So no other
    # app may ship an enabled one at priority 0 or more, except a setup wizard's (above 0),
    # which runs first and turns itself off when setup ends. Negative ones (Settings'
    # FallbackHome) only stand in while nothing else can run.
    find "$O"/system/app "$O"/system/priv-app "$O"/system_ext/app "$O"/system_ext/priv-app "$O"/product/app \
        "$O"/product/priv-app "$O"/vendor/app "$O"/vendor/priv-app "$O"/odm/app "$O"/odm/priv-app \
        -mindepth 2 -maxdepth 2 -name '*.apk' -print0 2>/dev/null \
        | xargs -0 -r python3 -I "$kit/tools/apk-info.py" --home > "$T/home" 2>&1 || true
    others=() off=() unread=() suw=()
    while IFS=$'\t' read -r f what; do
        f=${f#"$O/"}
        case $what in
            "unreadable "*) unread+=("$f"); continue ;;
            "home $EL_PACKAGE/"*) continue ;;
            "home "*) ;;
            *) continue ;;
        esac
        read -r _ comp pr en <<<"$what"
        pr=${pr#priority=} en=${en#enabled=}
        [[ "$pr" =~ ^-?[0-9]+$ ]] || pr=0
        (( pr < 0 )) && continue
        case "$en:${comp%%/*}" in
            false:*) off+=("$comp") ;;
            true:com.google.android.setupwizard|true:com.google.android.pixel.setupwizard|true:org.lineageos.setupwizard|true:com.android.provision)
                (( pr > 0 )) && suw+=("$comp (priority $pr)") || others+=("$comp (priority $pr, $f)") ;;
            true:*) others+=("$comp (priority $pr, $f)") ;;
            *) others+=("$comp (priority $pr, enabled set by a resource: check by hand, $f)") ;;
        esac
    done < "$T/home"
    [[ ${#others[@]} = 0 ]] && pass "no other app ships an enabled Home activity (priority 0 or more)" \
        || bad "other enabled Home activities: ${others[*]} (they share or take Home from Expressive Launcher)"
    [[ ${#suw[@]} = 0 ]] || info "setup wizard Home activities (off once setup ends): ${suw[*]}"
    [[ ${#off[@]} = 0 ]] || info "${#off[@]} Home activities that ship turned off (their apps turn them on for restore, supervision or kiosk modes): $(printf '%s\n' "${off[@]%%/*}" | LC_ALL=C sort -u | paste -sd' ')"
    [[ ${#unread[@]} = 0 ]] || info "couldn't read ${#unread[@]} APK manifest(s) for Home activities: ${unread[*]}"
    # Static overlays apply partition by partition, system_ext last, unless system_ext's own
    # overlay config or product's partition_order.xml says otherwise
    hits=$(cd "$O" && ls -d system_ext/overlay/config/config.xml product/overlay/partition_order.xml 2>/dev/null | paste -sd' ' || true)
    [[ -z "$hits" ]] && pass "no system_ext overlay config or partition_order.xml (the two overlays apply after Pixel's)" \
        || bad "$hits shipped: it can reorder or turn off static overlays; check that $FW_OVERLAY and $SUW_OVERLAY still apply after Pixel's (README.md)"
    px="$O/system_ext/etc/permissions/privapp-permissions-$EL_PACKAGE.xml"
    got=$( [[ -f "$px" ]] && xq privapp "$px" "$EL_PACKAGE" 2>/dev/null | LC_ALL=C sort | paste -sd' ' || true)
    want=$(for p in $EL_PRIVAPP_PERMS; do echo "permission $p"; done | LC_ALL=C sort | paste -sd' ')
    if [[ "$got" = "$want" ]]; then
        pass "privapp-permissions-$EL_PACKAGE.xml grants exactly the $(wc -w <<<"$EL_PRIVAPP_PERMS") privileged permissions"
    else
        bad "system_ext/etc/permissions/privapp-permissions-$EL_PACKAGE.xml: [${got:-missing}], want [$want]"
    fi
    hits=$(grep -rlF -- "\"$EL_PACKAGE\"" "$O"/system/etc/permissions "$O"/system_ext/etc/permissions "$O"/product/etc/permissions "$O"/vendor/etc/permissions 2>/dev/null | grep -vxF -- "$px" || true)
    [[ -z "$hits" ]] && pass "no other permissions XML names $EL_PACKAGE" || bad "other permissions XMLs name $EL_PACKAGE: $hits"
    hx="$O/system_ext/etc/sysconfig/hiddenapi-$EL_PACKAGE.xml"
    if [[ -f "$hx" && "$(xq hiddenapi "$hx" "$EL_PACKAGE" 2>/dev/null || true)" = whitelisted ]]; then
        pass "system_ext/etc/sysconfig/hiddenapi-$EL_PACKAGE.xml lists the launcher"
    else
        bad "system_ext/etc/sysconfig/hiddenapi-$EL_PACKAGE.xml is missing or doesn't list $EL_PACKAGE"
    fi
    # Which users get it: the phone's own (SYSTEM and FULL), set by this kit's sysconfig alone
    ux="$O/system_ext/etc/sysconfig/preinstalled-packages-$EL_PACKAGE.xml"
    got=$( [[ -f "$ux" ]] && xq install-in "$ux" "$EL_PACKAGE" 2>/dev/null | LC_ALL=C sort | paste -sd' ' || true)
    if [[ "$got" = "install-in FULL install-in SYSTEM" ]]; then
        pass "preinstalled-packages-$EL_PACKAGE.xml installs it for the phone's own users only (SYSTEM, FULL)"
    else
        bad "system_ext/etc/sysconfig/preinstalled-packages-$EL_PACKAGE.xml: [${got:-missing}], want [install-in FULL install-in SYSTEM]"
    fi
    hits=()
    while IFS= read -r f; do
        [[ "$f" != "$ux" && -n "$(xq install-in "$f" "$EL_PACKAGE" 2>/dev/null || true)" ]] && hits+=("${f#"$O/"}")
    done < <(grep -rlF -- "\"$EL_PACKAGE\"" "$O"/system/etc/sysconfig "$O"/system_ext/etc/sysconfig "$O"/product/etc/sysconfig "$O"/vendor/etc/sysconfig "$O"/odm/etc/sysconfig 2>/dev/null || true)
    [[ ${#hits[@]} = 0 ]] && pass "no other sysconfig XML sets which users get $EL_PACKAGE" \
        || bad "other sysconfig XMLs set which users get $EL_PACKAGE: ${hits[*]}"
    # The two overlays, on system_ext (after every product overlay), with the kit's values
    ov() {   # ov <apk> <the kit's overlay folder> <resource value>...
        local a=$1 m="$kit/tree/overlay/$2/AndroidManifest.xml" got want r
        shift 2
        [[ -f "$O/$a" ]] || { bad "no $a"; return; }
        # The compiled manifest's package and <overlay> tag (target, priority, isStatic,
        # targetName) must be the kit's, exactly
        want="package $(xq overlay-package "$m")|overlay $(xq overlay "$m")"
        got=$(python3 -I "$kit/tools/apk-info.py" --overlay "$O/$a" 2>&1 | paste -sd'|' || true)
        [[ "$got" = "$want" ]] || { bad "$a's manifest is [$got], want [$want]"; return; }
        r=$(xq zip-has "$O/$a" resources.arsc "$@" 2>&1 || echo "unreadable")
        if grep -qv '^found ' <<<"$r"; then bad "$a: $(grep -v '^found ' <<<"$r" | paste -sd';')"; else pass "$a (${want//|/, }) carries ${*}"; fi
    }
    ov "system_ext/overlay/$FW_OVERLAY.apk" framework "$want_recents" "$want_listeners"
    ov "system_ext/overlay/$SUW_OVERLAY.apk" setupwizard "$want_allset"
    hits=$(cd "$O" && find system_ext product -maxdepth 3 -path '*app/SetupWizardPixel*' -prune -print 2>/dev/null | paste -sd' ' || true)
    info "Pixel's setup wizard (the second overlay's target): ${hits:-not in this build}"
    # The licence text must ship (the build writes NOTICE files unless DISABLE_NOTICE_XML_GENERATION is set)
    n="$O/system_ext/etc/NOTICE.xml.gz"
    if [[ ! -f "$n" ]]; then
        bad "no system_ext/etc/NOTICE.xml.gz: the build must ship Expressive Launcher's licence text"
    else
        notice=$(gzip -dc -- "$n" 2>/dev/null || true)
        miss=()
        # ExpressiveLauncher.apk's entry, then a line of each licence text (LICENSE, NOTICE.*)
        for t in 'ExpressiveLauncher.apk' 'Apache License' 'Copyright (c) 2018 Keelar' 'SIL OPEN FONT LICENSE Version 1.1'; do
            grep -qF -- "$t" <<<"$notice" || miss+=("$t")
        done
        if [[ ${#miss[@]} = 0 ]]; then
            pass "system_ext NOTICE carries Expressive Launcher's licences (Apache-2.0, the calculator's MIT, Google Sans Flex's OFL-1.1)"
        else
            bad "system_ext/etc/NOTICE.xml.gz lacks: ${miss[*]}"
        fi
    fi
    ;;

device)
    [[ $# = 0 ]] || usage
    command -v adb >/dev/null || { bad "adb is not installed"; finish; }
    state=$(adb get-state 2>/dev/null || true)
    [[ "$state" = device ]] || { bad "no phone over adb (adb get-state: ${state:-nothing}; several devices? set ANDROID_SERIAL)"; finish; }
    a() { adb shell "$@" 2>/dev/null | tr -d '\r' || true; }
    echo "== Expressive Launcher on-device checks: $(a getprop ro.build.fingerprint)"
    dev=$(a getprop ro.product.device)
    [[ " ${phones[*]} " = *" $dev "* ]] && pass "device is $dev, an ExpressiveOS phone" || bad "device is ${dev:-unknown}, not one of ${phones[*]}"
    a dumpsys package "$EL_PACKAGE" > "$T/pkg"
    p=$(a pm list packages -f "$EL_PACKAGE" | grep -E "=$EL_PACKAGE\$" || true)
    upd=0
    case "$p" in
        *"/system_ext/priv-app/ExpressiveLauncher/"*) pass "Expressive Launcher is the built-in /system_ext/priv-app copy" ;;
        *"/data/app/"*)
            upd=1
            if grep -qF '/system_ext/priv-app/ExpressiveLauncher' "$T/pkg"; then
                info "Expressive Launcher runs from an update installed over the built-in copy ($p): the privapp allowlist isn't checked for an update, so only a clean flash proves it"
            else
                bad "Expressive Launcher is installed only in /data ($p), not built in"
            fi ;;
        *) bad "$EL_PACKAGE isn't installed" ;;
    esac
    v=$(grep -m1 -oE 'versionCode=[0-9]+' "$T/pkg" | cut -d= -f2 || true)
    info "running versionCode ${v:-unknown} (built-in $EL_VERSION_CODE)"
    p=$(a pm list packages -f "$PIXEL" | grep -E "=$PIXEL\$" || true)
    [[ -z "$p" ]] && pass "Pixel Launcher ($PIXEL) isn't installed" \
        || bad "Pixel Launcher is still installed: $p (an update from the Play Store outlives the flash: adb uninstall $PIXEL)"
    r=$(a cmd role get-role-holders --user 0 android.app.role.HOME)
    case "$r" in
        "$EL_PACKAGE") pass "Expressive Launcher holds the Home role" ;;
        "") info "nobody holds the Home role yet (the chooser comes up on Home)" ;;
        *) bad "the Home role holder is '$r', not $EL_PACKAGE" ;;
    esac
    r=$(a cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)
    [[ "$r" = "$EL_PACKAGE/$EL_HOME_ACTIVITY" ]] && pass "Home resolves to $r" || bad "Home resolves to '${r:-nothing}', not $EL_PACKAGE/$EL_HOME_ACTIVITY"
    # The overlays' values as the framework and the setup wizard see them
    r=$(a cmd overlay lookup android android:string/config_recentsComponentName)
    [[ "$r" = "$RECENTS" ]] && pass "config_recentsComponentName is $r" || bad "config_recentsComponentName is '${r:-unreadable}', not $RECENTS ($FW_OVERLAY not applied?)"
    r=$(a cmd overlay lookup android android:string/config_defaultListenerAccessPackages)
    [[ "$r" = "$want_listeners" ]] && pass "config_defaultListenerAccessPackages is the kit's (Expressive Launcher in Pixel Launcher's place)" \
        || bad "config_defaultListenerAccessPackages is '${r:-unreadable}', not the kit's"
    r=$(a cmd overlay lookup android android:array/config_launcherPackages | tr -d '[]' | tr ', ' '\n\n' | sed '/^$/d' | paste -sd:)
    if [[ ":$r:" = *":$EL_PACKAGE:"* && ":$r:" != *":$PIXEL:"* ]]; then pass "config_launcherPackages (Evolution X's launchers) is $r"
    elif [[ -z "$r" ]]; then info "cmd overlay lookup can't print config_launcherPackages here (an array): $FW_OVERLAY's values above say it's applied"
    else bad "config_launcherPackages is '$r': Expressive Launcher isn't in Pixel Launcher's place"; fi
    if [[ -n "$(a pm list packages "$SUW")" ]]; then
        r=$(a cmd overlay lookup "$SUW" "$SUW:string/exit_to_action_in_initial_setup")
        [[ "$r" = "$ALL_SET" ]] && pass "the setup wizard ends on $r" || bad "the setup wizard's exit_to_action_in_initial_setup is '${r:-unreadable}', not $ALL_SET ($SUW_OVERLAY not applied?)"
        r=$(a cmd overlay lookup "$SUW" "$SUW:string/launcher_package")
        [[ "$r" = "$EL_PACKAGE" ]] && pass "the setup wizard's launcher_package is $r" || bad "the setup wizard's launcher_package is '${r:-unreadable}', not $EL_PACKAGE"
    else
        info "$SUW isn't installed here: the setup wizard overlay isn't checked"
    fi
    # SystemUI bound to the launcher's quickstep service: gestures, Overview and the taskbar work
    a dumpsys activity services "$EL_PACKAGE/$EL_QUICKSTEP_SERVICE" > "$T/svc"
    if grep -qF "$EL_PACKAGE/$EL_QUICKSTEP_SERVICE" "$T/svc" && grep -qF 'com.android.systemui' "$T/svc"; then
        pass "SystemUI is bound to $EL_QUICKSTEP_SERVICE"
    else
        bad "SystemUI isn't bound to $EL_PACKAGE/$EL_QUICKSTEP_SERVICE (gestures and Overview won't work): see dumpsys activity services $EL_PACKAGE"
    fi
    a dumpsys activity service com.android.systemui/.SystemUIService OverviewProxyService > "$T/ops"
    r=$(grep -m1 -oE 'mRecentsComponentName=[^ ]+' "$T/ops" | cut -d= -f2 || true)
    c=$(grep -m1 -oE 'isConnected=[a-z]+' "$T/ops" | cut -d= -f2 || true)
    [[ -n "$r$c" ]] && info "SystemUI's OverviewProxyService: recents ${r:-?}, connected ${c:-?}" \
        || info "SystemUI's dump has no OverviewProxyService state here"
    # The privileged permissions, granted at install
    miss=()
    for p in $EL_PRIVAPP_PERMS; do grep -qF "$p: granted=true" "$T/pkg" || miss+=("$p"); done
    [[ ${#miss[@]} = 0 ]] && pass "all $(wc -w <<<"$EL_PRIVAPP_PERMS") privileged permissions are granted" \
        || bad "privileged permissions not granted: ${miss[*]}"
    adb logcat -b all -d 2>/dev/null | tr -d '\r' > "$T/log" || true
    hits=$(grep -F "$EL_PACKAGE" "$T/log" | grep -iF 'not in privapp-permissions allowlist' | tail -3 || true)
    [[ -z "$hits" ]] && pass "no privapp-permissions allowlist violation" || bad "privapp allowlist violation: $hits"
    [[ $upd = 0 ]] || info "(an update over the built-in copy skips that check)"
    n=$(grep -cE "Process: $EL_PACKAGE(,|:| |$)" "$T/log" || true)
    [[ "${n:-0}" = 0 ]] && pass "Expressive Launcher hasn't crashed since logcat began" \
        || bad "Expressive Launcher crashed $n time(s): adb logcat -b crash"
    n=$(grep -cE 'Process: com\.android\.systemui(,|:| |$)' "$T/log" || true)
    [[ "${n:-0}" = 0 ]] && pass "SystemUI hasn't crashed since logcat began" || bad "SystemUI crashed $n time(s): adb logcat -b crash"
    # A launcher whose quickstep was built against another Android's WindowManager Shell can't
    # unparcel Shell's one-way calls (QA 5.0.4's IRecentsAnimationRunner: README.md, "Status").
    # That crashes nothing: Binder logs it in the launcher's process and the gesture just fails,
    # so look for those lines (logcat's threadtime format: the pid is the third field).
    pids=$(a pidof "$EL_PACKAGE")
    if [[ -z "$pids" ]]; then
        info "Expressive Launcher isn't running: can't look for failed binder calls into it"
    else
        n=0
        for p in $pids; do
            c=$(awk -v p="$p" '$3 == p && /Caught a RuntimeException from the binder stub implementation/' "$T/log" | wc -l)
            n=$((n + c))
        done
        [[ $n = 0 ]] && pass "no failed binder calls into Expressive Launcher (pid $pids) since logcat began" \
            || bad "$n binder call(s) into Expressive Launcher failed to run (its gesture code doesn't match this Android): adb logcat -b all -d --pid=${pids%% *} | grep -A8 'binder stub'"
    fi
    r=$(a cmd notification allowed_listeners | grep -F "$EL_PACKAGE" | head -1 || true)
    [[ -n "$r" ]] && pass "notification access (dots): $r" \
        || info "Expressive Launcher has no notification access yet (a dirty flash keeps the old grants: Settings > Notifications > Device & app notifications)"
    info "by hand: swipe up for Home and hold for Overview, swipe along the bottom to switch apps, check the taskbar on a large screen, then run this again (it looks for failed binder calls)"
    ;;
*) usage ;;
esac
finish
