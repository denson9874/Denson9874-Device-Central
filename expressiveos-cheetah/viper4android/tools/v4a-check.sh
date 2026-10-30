#!/usr/bin/env bash
# ViPER4Android RE checks for ExpressiveOS cheetah. Each check prints PASS, FAIL or
# INFO; all of them run, the exit status is 1 if any FAILed, and the last line is
# V4A_CHECK=OK or V4A_CHECK=FAIL. Only for a phone with EOS_V4A=1 in its devices/<device>.conf
# (EOS_DEVICE, cheetah unless set; today cheetah alone): tree and device read the phone's
# device tree, vendor repo and name from there (cheetah: device/google/pantah,
# vendor/google/cheetah), and gs201 stays, since the driver needs gs201's HIDL effect HAL.
#
#   v4a-check.sh tree <top>
#       Before the build (apply-v4a.sh runs it): Evolution X's ViPER loader is still in
#       libeffects, the effect HAL is still HIDL @7.0 and built 64-bit, nothing else
#       registers or ships ViPER, this kit's frameworks/av patches are in,
#       vendor/extra/viper4android matches the kit and v4a.conf, and nothing the kit
#       writes leads out of the tree.
#   v4a-check.sh out <product_out> [host_out]
#       After the build, before packing (the ExpressiveOS OTA script runs it):
#       what landed in the product out it's given (out/target/product/<device>).
#       host_out (out/host/linux-x86) is only used for apksigner.
#   v4a-check.sh device
#       On a phone over adb (ANDROID_SERIAL picks one). Read-only. Run it soon after a
#       boot, while logcat still holds the boot. Whether libeffects loaded the driver comes from
#       dumpsys media.audio_flinger --effects. On a user build adb shell may not read the
#       driver or the audio HAL: those checks are INFO there (v4a-check.sh out checks the
#       files in the build).
set -euo pipefail
fails=0 finished=0 T=
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $finished = 1 ]] || { echo "FAIL: stopped by an unexpected error (exit $rc)"; echo "V4A_CHECK=FAIL"; }
    exit $rc
}
trap cleanup EXIT
kit="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../v4a.conf
source "$kit/v4a.conf"
T=$(mktemp -d "${TMPDIR:-/tmp}/v4a-check.XXXXXX")
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }
info() { echo "INFO: $*"; }
finish() {
    finished=1
    if [[ $fails = 0 ]]; then echo "V4A_CHECK=OK"; exit 0; fi
    echo "$fails check(s) failed"
    echo "V4A_CHECK=FAIL"; exit 1
}
usage() {
    echo "usage: v4a-check.sh tree <top> | out <product_out> [host_out] | device" >&2
    finished=1; echo "V4A_CHECK=FAIL"; exit 2
}
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
xmlq() { python3 -I "$kit/tools/v4a-xml.py" "$@"; }
subject_of() {   # the commit subject a format-patch file carries
    awk '/^Subject: /{s=substr($0,10); while ((getline l) > 0 && l ~ /^ /) s = s l; print s; exit}' "$1" | sed 's/^\[PATCH[^]]*\] //'
}
# AIDL effect HAL markers: its service name, its service packages, or a VINTF <hal format="aidl">
aidl_effect() {   # aidl_effect <dir>...: prints what it finds
    local d xmls=()
    grep -rIl --exclude-dir=.git -e 'android\.hardware\.audio\.effect\.IFactory' -e 'android\.hardware\.audio\.effect\.service' -- "$@" 2>/dev/null || true
    while IFS= read -r -d '' d; do xmls+=("$d"); done < <(grep -rIlZ --exclude-dir=.git --include='*.xml' -e 'android.hardware.audio.effect' -- "$@" 2>/dev/null || true)
    [[ ${#xmls[@]} = 0 ]] || xmlq aidl-effect "${xmls[@]}"
}
elf_arm64() {   # ELF, 64-bit class, machine AArch64 (183)
    [[ "$(od -An -tx1 -N5 -- "$1" 2>/dev/null | tr -d ' \n')" = 7f454c4602 \
        && "$(od -An -tu2 -j18 -N2 -- "$1" 2>/dev/null | tr -d ' \n')" = 183 ]]
}
eos_device() {   # sets EOS_DEVICE, EOS_DEVICE_TREE and EOS_VENDOR_DIR as ../../lib.sh reads them (devices/<device>.conf)
    local v
    v=$(source "$kit/../lib.sh" && printf '%s %s %s' "$EOS_DEVICE" "$EOS_DEVICE_TREE" "$EOS_VENDOR_DIR") || return 1
    read -r EOS_DEVICE EOS_DEVICE_TREE EOS_VENDOR_DIR <<<"$v"
    [[ -n $EOS_DEVICE && -n $EOS_DEVICE_TREE && -n $EOS_VENDOR_DIR ]]
}

mode=${1:-}; shift || true
case "$mode" in
tree)
    [[ $# = 1 && -d "$1" ]] || usage
    eos_device
    top="$(cd "$1" && pwd -P)"
    echo "== ViPER4Android RE tree checks: $top"
    if [[ "$top" = */evolution ]]; then bad "$top is the Evolution X tree; this kit is for the ExpressiveOS tree only"; finish; fi
    evo=$(cd "$HOME/evolution" 2>/dev/null && pwd -P || true)
    if [[ -n "$evo" && "$top" = "$evo" ]]; then bad "$top is the Evolution X tree (~/evolution); this kit is for the ExpressiveOS tree only"; finish; fi
    # What apply-v4a.sh writes must stay in this tree, also through symlinks
    ok=1
    for p in vendor/extra vendor/extra/viper4android vendor/extra/product.mk frameworks/av; do
        r=$(realpath -m -- "$top/$p")
        if [[ "$r" != "$top"/* ]]; then ok=0; bad "$p leads to $r, outside $top (a symlink?)"
        elif [[ -n "$evo" && ( "$r" = "$evo" || "$r" = "$evo"/* ) ]]; then ok=0; bad "$p leads into the Evolution X tree ($r)"; fi
    done
    gd=$(git -C "$top/frameworks/av" rev-parse --absolute-git-dir 2>/dev/null || true)
    [[ -z "$gd" ]] || gd=$(realpath -- "$gd")
    if [[ -n "$gd" && -n "$evo" && ( "$gd" = "$evo" || "$gd" = "$evo"/* ) ]]; then ok=0; bad "frameworks/av's git folder is in the Evolution X tree ($gd)"; fi
    [[ $ok = 0 ]] || pass "vendor/extra and frameworks/av are this tree's own (no symlink out of it or into ~/evolution)"
    fx="$top/frameworks/av/media/libeffects/factory/EffectsFactory.c"
    ecpp="$top/frameworks/av/services/audioflinger/Effects.cpp"
    # gs201's HIDL effect HAL is what the driver needs; the phone's own device tree and vendor
    # repo are its devices/<device>.conf's (cheetah: device/google/pantah, vendor/google/cheetah)
    gs201="$top/device/google/gs201" pantah="$top/$EOS_DEVICE_TREE" vgc="$top/$EOS_VENDOR_DIR"
    for d in "$gs201" "$pantah" "$vgc"; do [[ -d "$d" ]] || bad "missing ${d#"$top"/}"; done

    # The driver only loads through Evolution X's loader (frameworks_av 468ace0): its path,
    # and the indented call statement inside init()'s body (not the column-0 prototype)
    called=$(awk '/^(static )?int init\((void)?\)[[:space:]]*(\{[[:space:]]*)?$/ { f = 1; next }
        f && /^\}/ { f = 0 }
        f && /^[[:space:]]+loadViperEffect\(\);[[:space:]]*$/ { c = 1 }
        END { print c + 0 }' "$fx" 2>/dev/null || echo 0)
    if [[ -f "$fx" ]] && grep -qF '"/vendor/lib64/soundfx/libv4a_re.so"' "$fx" && [[ $called = 1 ]]; then
        pass "Evolution X's ViPER loader is in libeffects (EffectsFactory.c's init() calls loadViperEffect(), which loads /vendor/lib64/soundfx/libv4a_re.so)"
    else
        bad "Evolution X's ViPER loader is gone from $fx: libv4a_re.so would never load (README.md: 'If Evolution X drops its loader')"
    fi
    # The non-AIDL driver needs the HIDL effect HAL
    if grep -qF '@7.0::IEffectsFactory/default' "$gs201/vintf/manifest.xml" 2>/dev/null; then
        pass "gs201 VINTF manifest declares the HIDL effect HAL @7.0::IEffectsFactory/default"
    else
        bad "gs201 vintf/manifest.xml no longer declares @7.0::IEffectsFactory/default"
    fi
    # The 64-bit-only driver needs a 64-bit audio HAL. android.hardware.audio.service defaults to
    # prefer32 (hardware/interfaces android_hardware_audio_config_defaults) and gs201 still has a
    # 32-bit second arch; IGNORE_PREFER32_ON_DEVICE turns prefer32 into the first (arm64) arch.
    if grep -qE '^[[:space:]]*IGNORE_PREFER32_ON_DEVICE[[:space:]]*:?=[[:space:]]*true[[:space:]]*$' "$gs201"/BoardConfig*.mk "$pantah"/BoardConfig*.mk 2>/dev/null \
        || grep -rqsE --exclude-dir=.git '^[^#]*android_hardware_audio[^#]*run_64bit[^#]*true' -- "$gs201" "$pantah"; then
        pass "the audio HAL is built 64-bit (gs201 IGNORE_PREFER32_ON_DEVICE := true), so it loads the lib64 driver"
    else
        bad "gs201 no longer sets IGNORE_PREFER32_ON_DEVICE := true (nor android_hardware_audio run_64bit): android.hardware.audio.service would be 32-bit and never load the 64-bit libv4a_re.so"
    fi
    hits=$(aidl_effect "$gs201" "$pantah" "$vgc/proprietary/vendor/etc/vintf" "$vgc"/*.mk "$vgc"/*.bp)
    if [[ -z "$hits" ]]; then
        pass "no AIDL effect HAL (android.hardware.audio.effect IFactory) in gs201, ${pantah##*/} or $EOS_DEVICE's vendor VINTF"
    else
        bad "AIDL effect HAL markers (the non-AIDL driver won't work; see README.md 'Risks'):"$'\n'"$hits"
    fi
    # One registration only: Evolution X's loader, not audio_effects.xml
    ae="$vgc/proprietary/vendor/etc/audio_effects.xml"
    if [[ ! -f "$ae" ]]; then
        bad "missing ${ae#"$top"/} (the only effects config $EOS_DEVICE ships)"
    elif grep -qiE 'v4a|90380da3' "$ae"; then
        bad "${ae#"$top"/} registers ViPER; with the built-in loader it would be registered twice"
    else
        pass "${ae#"$top"/} has no v4a lines"
    fi
    while IFS= read -r f; do
        [[ "$f" = "$ae" ]] && continue
        if grep -qiE 'v4a|90380da3' "$f"; then bad "${f#"$top"/} registers ViPER"; else info "another effects config: ${f#"$top"/} (no v4a lines)"; fi
    done < <(find "$gs201" "$pantah" "$vgc" -name 'audio_effects*' -not -path '*/.git/*' 2>/dev/null | sort)
    # Evolution X's own ViPER stack must stay out
    if [[ -e "$top/packages/apps/ViPER4AndroidFX" ]]; then
        bad "packages/apps/ViPER4AndroidFX exists: Evolution X's other ViPER stack (libv4a_re, libviperaidl) would fight this one"
    else
        pass "no packages/apps/ViPER4AndroidFX"
    fi
    hits=$(grep -rIl --exclude-dir=.git TARGET_INCLUDE_VIPERFX -- "$gs201" "$pantah" "$vgc"/*.mk 2>/dev/null || true)
    if [[ -z "$hits" ]]; then pass "no TARGET_INCLUDE_VIPERFX in the $EOS_DEVICE trees"; else bad "TARGET_INCLUDE_VIPERFX set in: $hits"; fi
    # This kit's frameworks/av patches
    for p in "$kit"/patches/frameworks_av/*.patch; do
        s=$(subject_of "$p")
        if git -C "$top/frameworks/av" log --format=%s 2>/dev/null | grep -xF -- "$s" >/dev/null; then
            pass "frameworks/av has kit patch ${p##*/}"
        else
            bad "frameworks/av lacks kit patch ${p##*/} ($s): run apply-v4a.sh"
        fi
    done
    grep -qF 'ViPER effect already registered by library' "$fx" 2>/dev/null \
        && pass "EffectsFactory.c skips a second ViPER registration" \
        || bad "EffectsFactory.c lacks the kit's double-registration guard"
    grep -qF 'memcmp(&desc.uuid, SL_V4A_RE, sizeof(effect_uuid_t))' "$ecpp" 2>/dev/null \
        && pass "Effects.cpp exempts ViPER from suspend by uuid" \
        || bad "Effects.cpp doesn't compare desc.uuid with SL_V4A_RE"
    # What apply-v4a.sh staged
    dest="$top/vendor/extra/viper4android"
    ok=1
    [[ -d "$dest" ]] || { ok=0; bad "vendor/extra/viper4android isn't staged: run apply-v4a.sh"; }
    [[ $ok = 0 ]] || while read -r want f; do
        [[ -f "$dest/$f" && "$(sha "$dest/$f")" = "$want" ]] || { ok=0; bad "vendor/extra/viper4android/$f is missing or not the pinned file"; }
    done <<EOF
$V4A_APP_SHA256 ViPER4Android.apk
$V4A_APP_LICENSE_SHA256 LICENSE.app
$V4A_FX_LIB_SHA256 libv4a_re_arm64-v8a.so
$V4A_FX_LICENSE_SHA256 LICENSE.driver
EOF
    [[ ! -d "$dest" ]] || for f in "$kit"/tree/*; do
        cmp -s -- "$f" "$dest/${f##*/}" || { ok=0; bad "vendor/extra/viper4android/${f##*/} differs from the kit's tree/${f##*/}"; }
    done
    [[ $ok = 0 ]] || pass "vendor/extra/viper4android matches the kit and v4a.conf (app $V4A_APP_VERSION, driver $V4A_FX_VERSION)"
    line='$(call inherit-product, vendor/extra/viper4android/viper4android.mk)'
    where=$(want="$line" awk -f "$kit/tools/mk-line.awk" -- "$top/vendor/extra/product.mk" 2>/dev/null || true)
    case "$where" in
        top) pass "vendor/extra/product.mk inherits viper4android.mk (outside any conditional)" ;;
        nested) bad "vendor/extra/product.mk inherits viper4android.mk only inside an ifeq/ifdef/define block: move the line to the top level" ;;
        *) bad "vendor/extra/product.mk doesn't inherit viper4android.mk: run apply-v4a.sh" ;;
    esac
    # Evolution X's vendor_evolution is checked out at vendor/lineage (manifest
    # snippets/evolution.xml:146); its config/common.mk line 2 (cnb e717ec3) reads vendor/extra/product.mk
    if grep -qE '^\s*\$\(call inherit-product-if-exists, *vendor/extra/product\.mk\)' "$top/vendor/lineage/config/common.mk" 2>/dev/null; then
        pass "vendor/lineage/config/common.mk inherits vendor/extra/product.mk"
    else
        bad "vendor/lineage/config/common.mk is missing or no longer inherits vendor/extra/product.mk: ViPER4Android would silently not ship"
    fi
    ;;

out)
    [[ $# -ge 1 && $# -le 2 && -d "$1" ]] || usage
    O="$(cd "$1" && pwd -P)" H=${2:-}
    echo "== ViPER4Android RE build checks: $O"
    lib="$O/vendor/lib64/soundfx/libv4a_re.so"
    if [[ -f "$lib" && "$(sha "$lib")" = "$V4A_FX_LIB_SHA256" ]]; then
        pass "vendor/lib64/soundfx/libv4a_re.so is upstream's $V4A_FX_VERSION arm64 library ($V4A_FX_LIB_SHA256)"
    else
        bad "vendor/lib64/soundfx/libv4a_re.so is $( [[ -f "$lib" ]] && sha "$lib" || echo missing), want $V4A_FX_LIB_SHA256"
    fi
    if [[ -e "$O/vendor/lib/soundfx/libv4a_re.so" ]]; then bad "a 32-bit vendor/lib/soundfx/libv4a_re.so shipped"; else pass "no 32-bit libv4a_re.so"; fi
    hits=$(cd "$O" && find vendor odm system system_ext product -name 'libv4a_re*' 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$hits" = vendor/lib64/soundfx/libv4a_re.so ]]; then pass "one libv4a_re in the images"; else bad "libv4a_re files: ${hits:-none} (want only vendor/lib64/soundfx/libv4a_re.so)"; fi
    le="$O/vendor/lib64/libeffects.so"
    if [[ -f "$le" ]] && grep -aqF '/vendor/lib64/soundfx/libv4a_re.so' "$le"; then
        pass "vendor/lib64/libeffects.so has Evolution X's ViPER loader"
    else
        bad "vendor/lib64/libeffects.so lacks /vendor/lib64/soundfx/libv4a_re.so: the driver would never load"
    fi
    if [[ -f "$le" ]] && grep -aqF 'ViPER effect already registered by library' "$le"; then
        pass "vendor/lib64/libeffects.so has kit patch 0001 (no double registration)"
    else
        bad "vendor/lib64/libeffects.so lacks kit patch 0001's log string"
    fi
    hal="$O/vendor/bin/hw/android.hardware.audio.service"
    if [[ -f "$hal" ]] && elf_arm64 "$hal"; then
        pass "the audio HAL is a 64-bit arm64 binary, so it loads the lib64 driver"
    else
        bad "vendor/bin/hw/android.hardware.audio.service is missing or not 64-bit arm64"
    fi
    if [[ -f "$O/vendor/lib64/hw/android.hardware.audio.effect@7.0-impl.so" ]]; then
        pass "vendor/lib64/hw/android.hardware.audio.effect@7.0-impl.so (HIDL effect HAL) built"
    else
        bad "no vendor/lib64/hw/android.hardware.audio.effect@7.0-impl.so"
    fi
    vintf=()
    for d in "$O/vendor/etc/vintf" "$O/odm/etc/vintf"; do [[ -d "$d" ]] && vintf+=("$d"); done
    if [[ ${#vintf[@]} -gt 0 ]] && grep -rqF 'IEffectsFactory/default' -- "${vintf[@]}"; then
        pass "built VINTF declares the HIDL IEffectsFactory/default"
    else
        bad "built VINTF (vendor/etc/vintf) doesn't declare IEffectsFactory/default"
    fi
    hits=$([[ ${#vintf[@]} = 0 ]] || aidl_effect "${vintf[@]}")
    if [[ -z "$hits" ]]; then pass "built VINTF has no AIDL effect HAL"; else bad "built VINTF has AIDL effect HAL markers:"$'\n'"$hits"; fi
    configs=$(cd "$O" && find vendor odm system system_ext product -name 'audio_effects*' 2>/dev/null | sort | paste -sd' ' || true)
    # Stock cheetah also ships AOSP's system/etc copy (framework-audio_effects.xml). Configs are
    # read from /odm/etc, /vendor/etc, /system/etc in that order (system/media audio_config.h),
    # so vendor's is the one used and the system one is never read.
    if [[ "$configs" = vendor/etc/audio_effects.xml ||
          "$configs" = "system/etc/audio_effects.xml vendor/etc/audio_effects.xml" ]]; then
        pass "effects configs: $configs (vendor's is the one read)"
    else
        bad "effects configs: ${configs:-none} (want vendor/etc/audio_effects.xml, and at most AOSP's system/etc copy)"
    fi
    if [[ -f "$O/system/etc/audio_effects.xml" ]] && grep -qiE 'v4a|90380da3' "$O/system/etc/audio_effects.xml"; then
        bad "system/etc/audio_effects.xml registers ViPER"
    fi
    if [[ -f "$O/vendor/etc/audio_effects.xml" ]] && ! grep -qiE 'v4a|90380da3' "$O/vendor/etc/audio_effects.xml"; then
        pass "vendor/etc/audio_effects.xml has no v4a lines (the loader registers ViPER once)"
    else
        bad "vendor/etc/audio_effects.xml is missing or registers ViPER"
    fi
    apk="$O/system_ext/priv-app/ViPER4Android/ViPER4Android.apk"
    if [[ -f "$apk" && "$(sha "$apk")" = "$V4A_APP_SHA256" ]]; then
        pass "system_ext/priv-app/ViPER4Android/ViPER4Android.apk is upstream's $V4A_APP_VERSION APK, unchanged"
    else
        bad "system_ext/priv-app/ViPER4Android/ViPER4Android.apk is missing or was rewritten (want $V4A_APP_SHA256)"
    fi
    signer=
    for s in "$H/bin/apksigner" "$H/apksigner"; do [[ -n "$H" && -x "$s" ]] && { signer=$s; break; }; done
    if [[ -z "$signer" ]]; then
        info "no apksigner in host_out (${H:-not given}): signer not checked here; the APK's sha256 pins it ($V4A_APP_CERT_SHA256)"
    elif [[ -f "$apk" ]] && "$signer" verify --print-certs "$apk" 2>/dev/null | grep -F "certificate SHA-256 digest: $V4A_APP_CERT_SHA256" >/dev/null; then
        pass "apksigner: the APK verifies, signed by $V4A_APP_CERT_SHA256"
    else
        bad "apksigner: the APK doesn't verify or isn't signed by $V4A_APP_CERT_SHA256"
    fi
    hits=$(cd "$O" && find system system_ext product vendor -path '*app/ViPER4Android*' -prune -print 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$hits" = system_ext/priv-app/ViPER4Android ]]; then pass "one ViPER4Android app dir"; else bad "ViPER4Android app dirs: ${hits:-none}"; fi
    px="$O/system_ext/etc/permissions/privapp-permissions-$V4A_APP_PACKAGE.xml"
    got=$( [[ -f "$px" ]] && xmlq privapp "$px" "$V4A_APP_PACKAGE" 2>/dev/null | sort | paste -sd' ' || true)
    want=$(for p in $V4A_PRIVAPP_PERMS; do echo "permission $p"; done | sort | paste -sd' ')
    if [[ "$got" = "$want" ]]; then
        pass "privapp-permissions-$V4A_APP_PACKAGE.xml grants exactly $V4A_PRIVAPP_PERMS"
    else
        bad "system_ext/etc/permissions/privapp-permissions-$V4A_APP_PACKAGE.xml: [${got:-missing}], want [$want]"
    fi
    hits=$(grep -rlF -- "$V4A_APP_PACKAGE" "$O"/system/etc/permissions "$O"/system_ext/etc/permissions "$O"/product/etc/permissions "$O"/vendor/etc/permissions 2>/dev/null | grep -vxF -- "$px" || true)
    if [[ -z "$hits" ]]; then pass "no other permissions XML names $V4A_APP_PACKAGE"; else bad "other permissions XMLs name $V4A_APP_PACKAGE: $hits"; fi
    hx="$O/system_ext/etc/sysconfig/hiddenapi-$V4A_APP_PACKAGE.xml"
    if [[ -f "$hx" && "$(xmlq hiddenapi "$hx" "$V4A_APP_PACKAGE" 2>/dev/null || true)" = whitelisted ]]; then
        pass "system_ext/etc/sysconfig/hiddenapi-$V4A_APP_PACKAGE.xml lists the app"
    else
        bad "system_ext/etc/sysconfig/hiddenapi-$V4A_APP_PACKAGE.xml is missing or doesn't list $V4A_APP_PACKAGE"
    fi
    hits=$(cd "$O" && { find vendor odm system system_ext product -name 'libviperaidl*' 2>/dev/null; find system system_ext product vendor -maxdepth 2 -path '*app/ViPER4AndroidFX*' 2>/dev/null; } | sort | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then pass "no libviperaidl or ViPER4AndroidFX (Evolution X's other ViPER stack)"; else bad "Evolution X's other ViPER stack shipped: $hits"; fi
    hits=$(cd "$O" && find system system_ext product -maxdepth 2 -path '*app/MusicFX' 2>/dev/null | sort | paste -sd' ' || true)
    info "MusicFX: ${hits:-not in this build}"
    # The licence texts must ship with every build (the build writes these unless
    # DISABLE_NOTICE_XML_GENERATION is set)
    for p in vendor system_ext; do
        n="$O/$p/etc/NOTICE.xml.gz"
        if [[ ! -f "$n" ]]; then bad "no $p/etc/NOTICE.xml.gz: the build must ship the ViPER4Android licence texts"; continue; fi
        gzip -dc -- "$n" > "$T/notice" 2>/dev/null || { bad "$p/etc/NOTICE.xml.gz doesn't decompress"; continue; }
        if [[ $p = vendor ]]; then
            grep -qF 'Zhuhang' "$T/notice" && grep -qF 'Julien Pommier' "$T/notice" && grep -qF 'Version 2, June 1991' "$T/notice" \
                && pass "vendor NOTICE carries the ViPERDSP and PFFFT notices and the driver's GPL-2.0" \
                || bad "vendor NOTICE lacks NOTICE.viperdsp, NOTICE.pffft or LICENSE.driver (GPL-2.0)"
        else
            grep -qF 'ViPER4Android' "$T/notice" && grep -qF 'Version 3, 29 June 2007' "$T/notice" \
                && pass "system_ext NOTICE carries the app's GPL-3.0" || bad "system_ext NOTICE lacks the ViPER4Android licence (GPL-3.0)"
        fi
    done
    ;;

device)
    [[ $# = 0 ]] || usage
    eos_device
    command -v adb >/dev/null || { bad "adb is not installed"; finish; }
    state=$(adb get-state 2>/dev/null || true)
    [[ "$state" = device ]] || { bad "no phone over adb (adb get-state: ${state:-nothing}; several devices? set ANDROID_SERIAL)"; finish; }
    a() { adb shell "$@" 2>/dev/null | tr -d '\r' || true; }
    # With the command's own errors: SELinux keeps adb shell out of vendor files on a user build
    a2() { adb shell "$* 2>&1" 2>/dev/null | tr -d '\r' || true; }
    denied() { [[ "$1" = *'Permission denied'* ]]; }
    echo "== ViPER4Android RE on-device checks: $(a getprop ro.build.fingerprint)"
    dev=$(a getprop ro.product.device)
    [[ "$dev" = "$EOS_DEVICE" ]] && pass "device is $EOS_DEVICE" || bad "device is ${dev:-unknown}, not $EOS_DEVICE"
    l=$(a2 ls -lZ /vendor/lib64/soundfx/libv4a_re.so)
    if denied "$l"; then
        info "adb shell may not read /vendor/lib64/soundfx/libv4a_re.so here (a user build): its label and sha256 aren't checked (the effects dump shows whether it loaded)"
    else
        [[ "$l" = *u:object_r:vendor_file:s0* ]] && pass "/vendor/lib64/soundfx/libv4a_re.so is labelled vendor_file" \
            || bad "/vendor/lib64/soundfx/libv4a_re.so: ${l:-missing} (want u:object_r:vendor_file:s0)"
        s=$(a sha256sum /vendor/lib64/soundfx/libv4a_re.so | cut -d' ' -f1)
        [[ "$s" = "$V4A_FX_LIB_SHA256" ]] && pass "libv4a_re.so is upstream's $V4A_FX_VERSION" || bad "libv4a_re.so sha256 is ${s:-unreadable}, want $V4A_FX_LIB_SHA256"
    fi
    l=$(a2 ls /vendor/lib/soundfx/libv4a_re.so)
    if [[ "$l" = *'No such file'* ]]; then pass "no 32-bit libv4a_re.so"
    elif denied "$l"; then info "adb shell may not look in /vendor/lib/soundfx here (a user build): the 32-bit check is left to v4a-check.sh out"
    else bad "/vendor/lib/soundfx/libv4a_re.so exists"; fi
    f=$(a2 file /vendor/bin/hw/android.hardware.audio.service)
    if [[ -z "$f" ]]; then info "can't run file on /vendor/bin/hw/android.hardware.audio.service"
    elif denied "$f"; then info "adb shell may not read the audio HAL here (a user build): its 64-bit check is left to v4a-check.sh out"
    elif [[ "$f" = *64-bit* ]]; then pass "the audio HAL is 64-bit"
    else bad "the audio HAL isn't 64-bit: $f"; fi
    n=$(a service list | grep -c 'android.hardware.audio.effect.IFactory' || true)
    [[ "${n:-0}" = 0 ]] && pass "no AIDL effect HAL service (HIDL @7.0 is in use)" || bad "android.hardware.audio.effect.IFactory is registered: the HAL is AIDL, the non-AIDL driver won't load"
    # Whether libeffects loaded the driver: its loader's logcat lines when they're there, and
    # the effects dump below, which decides (on the first build the audio HAL's startup lines
    # weren't in logcat at all, two minutes after boot)
    loaded=0 loadfail=0
    adb logcat -b all -d > "$T/log" 2>/dev/null || true
    tr -d '\r' < "$T/log" > "$T/logs"
    if grep -qF 'loadViperEffect: ViPER effect already registered by library' "$T/logs"; then
        loadfail=1; bad "something registered ViPER before the built-in loader (a module patching audio_effects.xml?): $(grep -F 'already registered by library' "$T/logs" | tail -1)"
    elif grep -qF 'loadViperEffect: loaded ViPER library from /vendor/lib64/soundfx/libv4a_re.so' "$T/logs" \
        && grep -qF 'loadViperEffect: successfully registered ViPER4Android effect: ViPERDSP' "$T/logs"; then
        loaded=1; pass "logcat: libeffects loaded /vendor/lib64/soundfx/libv4a_re.so and registered ViPERDSP"
    elif grep -qF 'loadViperEffect:' "$T/logs"; then
        loadfail=1; bad "logcat: loadViperEffect failed: $(grep -F 'loadViperEffect:' "$T/logs" | tail -1)"
    else
        info "logcat has no loadViperEffect lines (not logged, or rotated): the effects dump decides"
    fi
    n=$(a "grep -ciE 'v4a|90380da3' /vendor/etc/audio_effects.xml")
    case "$n" in
        0) pass "/vendor/etc/audio_effects.xml has no v4a lines (no module patching it)" ;;
        ''|*[!0-9]*) info "can't read /vendor/etc/audio_effects.xml from adb shell" ;;
        *) bad "/vendor/etc/audio_effects.xml has $n v4a lines: a ViPER module is installed (remove it, reboot)" ;;
    esac
    # The effects dump (" ## BEGIN effects dump", then the audio HAL's "Libraries loaded:" and
    # " Library v4a_re"): audio_flinger prints it only when asked (--effects; a bug report
    # passes -a), and the HAL writes its part into adb shell's pipe, which policy allows
    # (hal_audio.te: shell:fd use, shell:fifo_file write)
    a dumpsys media.audio_flinger --effects > "$T/af"
    if ! grep -qF 'BEGIN effects dump' "$T/af"; then
        info "dumpsys media.audio_flinger --effects shows no effects dump here; a bug report's lists 'Library v4a_re'"
    elif ! grep -qE '^Libraries loaded:' "$T/af"; then
        info "the audio HAL wrote no effects list into dumpsys media.audio_flinger --effects here; a bug report's lists 'Library v4a_re'"
    else
        # Per list, and by the effect's uuid: libeffects names a library that failed to load
        # the same way, under "Libraries NOT loaded:", and lists each library's effects under
        # it ("    UUID: ..."), so a module's library carrying ViPER's uuid shows up too
        # (media/libeffects/factory/EffectsFactory.c, EffectsFactoryState.c)
        read -r n nf u others < <(awk -v want="$V4A_FX_UUID" '
            /^Libraries loaded:/ { s = 1; lib = ""; next }
            /^Libraries NOT loaded:/ { s = 2; lib = ""; next }
            /^[^ ]/ || /^ ##/ { s = 0; lib = "" }
            s && /^ Library / { lib = $2; if (lib == "v4a_re") c[s]++; next }
            s == 1 && lib != "" && $1 == "UUID:" && tolower($2) == want {
                if (lib == "v4a_re") u++; else o = o (o == "" ? "" : ",") lib }
            END { print c[1] + 0, c[2] + 0, u + 0, (o == "" ? "-" : o) }' "$T/af")
        [[ $nf = 0 ]] || { loadfail=1; bad "dumpsys media.audio_flinger --effects lists library v4a_re under 'Libraries NOT loaded': an effects config (audio_effects.xml in /odm/etc, /vendor/etc or /system/etc, likely a ViPER module's) names a v4a_re that libeffects couldn't load"; }
        [[ $others = - ]] || { loadfail=1; bad "dumpsys media.audio_flinger --effects lists ViPER's effect ($V4A_FX_UUID) under library $others too: a module patching audio_effects.xml registered it (remove it, reboot)"; }
        case "$n" in
            1) if [[ $u = 1 ]]; then
                   loaded=1; pass "dumpsys media.audio_flinger --effects lists library v4a_re once under 'Libraries loaded', with ViPER's effect"
               else
                   loadfail=1; bad "dumpsys media.audio_flinger --effects lists library v4a_re without ViPER's effect ($V4A_FX_UUID)"
               fi ;;
            0) loadfail=1; bad "dumpsys media.audio_flinger --effects doesn't list library v4a_re under 'Libraries loaded': libeffects didn't load it" ;;
            *) loadfail=1; bad "dumpsys media.audio_flinger --effects lists library v4a_re $n times under 'Libraries loaded' (registered more than once)" ;;
        esac
    fi
    [[ $loaded = 1 || $loadfail = 1 ]] \
        || bad "neither logcat nor dumpsys media.audio_flinger --effects shows libeffects loaded libv4a_re.so"
    p=$(a pm list packages -f "$V4A_APP_PACKAGE" | grep -E "=$V4A_APP_PACKAGE\$" || true)
    case "$p" in
        *"/system_ext/priv-app/ViPER4Android/"*) pass "the app is the built-in /system_ext/priv-app copy" ;;
        *"/data/app/"*) info "the app was updated over the built-in copy: $p" ;;
        *) bad "$V4A_APP_PACKAGE isn't installed" ;;
    esac
    a dumpsys package "$V4A_APP_PACKAGE" > "$T/pkg"
    grep -qF 'android.permission.MODIFY_AUDIO_ROUTING: granted=true' "$T/pkg" \
        && pass "MODIFY_AUDIO_ROUTING is granted (Per-App mode works without root)" || bad "MODIFY_AUDIO_ROUTING isn't granted to $V4A_APP_PACKAGE"
    hits=$(grep -F "$V4A_APP_PACKAGE" "$T/logs" | grep -iF 'not in privapp-permissions allowlist' | tail -3 || true)
    [[ -z "$hits" ]] && pass "no privapp-permissions allowlist violation" || bad "privapp allowlist violation: $hits"
    [[ -n "$(a ls /system_ext/etc/sysconfig/hiddenapi-$V4A_APP_PACKAGE.xml)" ]] \
        && pass "hidden-API sysconfig for the app is installed" || bad "no /system_ext/etc/sysconfig/hiddenapi-$V4A_APP_PACKAGE.xml"
    # Not adb shell's own: on a user build this check's ls, sha256sum and file are denied
    hits=$(grep -F 'avc:' "$T/logs" | grep -F 'denied' | grep -vF 'scontext=u:r:shell:s0' \
        | grep -E "hal_audio_default|$V4A_APP_PACKAGE|libv4a_re" | tail -5 || true)
    [[ -z "$hits" ]] && pass "no SELinux denials for hal_audio_default or the app" || bad "SELinux denials:"$'\n'"$hits"
    grep -qF 'Welcome to ViPER FX' "$T/logs" && info "logcat: a ViPER effect instance was created (the app is on)" \
        || info "no ViPER effect instance in the log yet: turn the app's master switch on, play something, run again"
    info "by hand: ViPER4Android > menu > Driver Status shows Version $V4A_FX_VERSION, Version Code $V4A_FX_VERSION_CODE, Streaming: Active while music plays"
    ;;
*) usage ;;
esac
finish
