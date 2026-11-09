#!/usr/bin/env bash
# ViPER4Android RE checks for ExpressiveOS. Each check prints PASS, FAIL or
# INFO; all of them run, the exit status is 1 if any FAILed, and the last line is
# V4A_CHECK=OK or V4A_CHECK=FAIL. Only for a phone with EOS_V4A=1 (the HIDL driver: cheetah),
# aidl (the AIDL driver: husky) or aidl-overlay (the AIDL driver laid over Google's stock vendor at
# boot: the Pixel 11s, kodiak first) in its devices/<device>.conf (EOS_DEVICE, cheetah unless set;
# out falls back to the product out's name): tree and device read the phone's device tree, vendor
# repo and name from there (cheetah: device/google/pantah, vendor/google/cheetah, and gs201,
# whose HIDL effect HAL the HIDL driver needs; husky: device/google/shusky, vendor/google/husky,
# and zuma, which carries the vendor sepolicy for the AIDL driver's viper.control service;
# kodiak: device/google/kodiak and vendor/google/kodiak-images' vendor.img).
#
#   v4a-check.sh tree <top>
#       Before the build (apply-v4a.sh runs it). HIDL: Evolution X's ViPER loader is still in
#       libeffects, the effect HAL is still HIDL @7.0 and built 64-bit. AIDL: the vendor VINTF
#       declares the AIDL effect HAL, the trees ship no effects config of their own, and
#       viper.control is labelled and allowed. Overlay: the phone ships Google's vendor.img as it
#       is, and nothing in its trees ships ViPER or installs under vendor_overlay. All: nothing else registers or ships ViPER,
#       this kit's frameworks/av patches are in, vendor/extra/viper4android matches the kit
#       and v4a.conf, and nothing the kit writes leads out of the tree.
#   v4a-check.sh out <product_out> [host_out]
#       After the build, before packing (the ExpressiveOS OTA script runs it):
#       what landed in the product out it's given (out/target/product/<device>).
#       host_out (out/host/linux-x86) is used for apksigner, and on an overlay phone (where it's
#       needed) for fsck.erofs and secilc: out unpacks the vendor.img the build ships, checks Google's
#       image still fits the overlay, and compiles the split policy with it (check-sepolicy.sh).
#   v4a-check.sh device
#       On a phone over adb (ANDROID_SERIAL picks one). Read-only. Run it soon after a
#       boot, while logcat still holds the boot. HIDL: whether libeffects loaded the driver
#       comes from dumpsys media.audio_flinger --effects. AIDL: whether the audio HAL loaded it
#       comes from viper.control in the service list; overlay: also the two mounts and the off
#       switch. On a user build adb shell may not read the
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
eos_device() {   # sets EOS_DEVICE, EOS_DEVICE_TREE, EOS_VENDOR_DIR and EOS_V4A as ../../lib.sh reads them (devices/<device>.conf)
    local v
    v=$(source "$kit/../lib.sh" && printf '%s %s %s %s' "$EOS_DEVICE" "$EOS_DEVICE_TREE" "$EOS_VENDOR_DIR" "$EOS_V4A") || return 1
    read -r EOS_DEVICE EOS_DEVICE_TREE EOS_VENDOR_DIR EOS_V4A <<<"$v"
    [[ -n $EOS_DEVICE && -n $EOS_DEVICE_TREE && -n $EOS_VENDOR_DIR && $EOS_V4A =~ ^(1|aidl|aidl-overlay)$ ]] \
        || { echo "FAIL: $EOS_DEVICE has EOS_V4A=${EOS_V4A:-?} in devices/$EOS_DEVICE.conf: no ViPER4Android to check" >&2; return 1; }
}


# --- The AIDL driver (EOS_V4A=aidl: husky) ---------------------------------------------------
# husky's audio HAL is Google's aoc HAL. It serves the AIDL effect IFactory and loads the effect
# libraries /vendor/etc/audio_effects_config.xml names, from /vendor/lib64/soundfx. husky's vendor
# has no audio_effects_config.xml of its own, so the AIDL zip's config is installed as it. The
# driver then publishes viper.control, labelled by the SoC tree's sepolicy (zuma, kit patch 0008).
aidl_soc_tree() {   # the tree with the phone's vendor sepolicy
    case $EOS_DEVICE in
        husky) echo device/google/zuma ;;
        *) return 1 ;;
    esac
}
tree_aidl() {   # uses $top
    local soc dt vgc hits f
    soc=$(aidl_soc_tree) || { bad "no AIDL layout is known for $EOS_DEVICE (aidl_soc_tree in v4a-check.sh)"; return; }
    dt="$top/$EOS_DEVICE_TREE" vgc="$top/$EOS_VENDOR_DIR" soc="$top/$soc"
    for f in "$soc" "$dt" "$vgc"; do [[ -d "$f" ]] || bad "missing ${f#"$top"/}"; done
    # The AIDL driver needs the AIDL effect HAL, which husky's vendor VINTF (Google's aoc HAL) declares
    hits=$(aidl_effect "$vgc/proprietary/vendor/etc/vintf" "$soc/vintf" "$dt")
    if [[ -n "$hits" ]]; then
        pass "the AIDL effect HAL (android.hardware.audio.effect IFactory) is declared: $(paste -sd' ' <<<"${hits//"$top/"/}")"
    else
        bad "no AIDL effect HAL declared in $EOS_DEVICE's vendor VINTF, ${soc#"$top"/} or ${dt#"$top"/}: the AIDL driver would never load"
    fi
    # The kit's audio_effects_config.xml is the only effects config: one from the trees or the
    # blobs would collide with it (or need ViPER's lines added to it instead)
    hits=$(find "$soc" "$dt" "$vgc" -name 'audio_effects*' -not -path '*/.git/*' 2>/dev/null | sort | sed "s#^$top/##" | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then
        pass "no audio_effects config in ${soc#"$top"/}, ${dt#"$top"/} or ${vgc#"$top"/} (the kit's is the one installed)"
    else
        bad "effects configs in $EOS_DEVICE's trees: $hits (the kit installs /vendor/etc/audio_effects_config.xml itself; put ViPER's lines into that one instead)"
    fi
    # (makefiles, blueprints, XML and blob lists; the sepolicy below names the driver on purpose)
    hits=$(grep -rIlE --exclude-dir=.git --include='*.mk' --include='*.bp' --include='*.xml' --include='*.txt' \
        'libv4a|v4a_standard|90380da3' -- "$soc" "$dt" "$vgc" 2>/dev/null | sed "s#^$top/##" | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then pass "nothing in $EOS_DEVICE's trees ships or registers ViPER"; else bad "ViPER already in $EOS_DEVICE's trees: $hits"; fi
    # viper.control's label and rules (kit patch devices/husky/patches/device_google_zuma/0008)
    if grep -qxF "$V4A_AIDL_SERVICE u:object_r:viper_control_service:s0" "$soc/sepolicy/vendor/service_contexts" 2>/dev/null; then
        pass "${soc#"$top"/} labels $V4A_AIDL_SERVICE viper_control_service"
    else
        bad "${soc#"$top"/}/sepolicy/vendor/service_contexts doesn't label $V4A_AIDL_SERVICE: the driver couldn't publish it (kit patch 0008)"
    fi
    f="$soc/sepolicy/vendor/viper4android.te"
    if grep -qE '^type viper_control_service, service_manager_type;' "$f" 2>/dev/null \
        && grep -qE '^allow hal_audio_default viper_control_service:service_manager add;' "$f" \
        && grep -qE '^allow priv_app viper_control_service:service_manager find;' "$f" \
        && grep -qE '^allow priv_app servicemanager:service_manager list;' "$f" \
        && grep -qE '^binder_call\(priv_app, hal_audio_default\)' "$f"; then
        pass "${f#"$top"/} lets the audio HAL publish $V4A_AIDL_SERVICE and the app (priv_app) use it"
    else
        bad "${f#"$top"/} is missing or lacks viper_control_service's rules (kit patch 0008)"
    fi
    if [[ -e "$top/packages/apps/ViPER4AndroidFX" ]]; then
        bad "packages/apps/ViPER4AndroidFX exists: Evolution X's other ViPER stack (libv4a_re, libviperaidl) would fight this one"
    else
        pass "no packages/apps/ViPER4AndroidFX"
    fi
    hits=$(grep -rIl --exclude-dir=.git TARGET_INCLUDE_VIPERFX -- "$soc" "$dt" "$vgc"/*.mk 2>/dev/null || true)
    if [[ -z "$hits" ]]; then pass "no TARGET_INCLUDE_VIPERFX in the $EOS_DEVICE trees"; else bad "TARGET_INCLUDE_VIPERFX set in: $hits"; fi
}
out_aidl() {   # uses $O
    local lib cfg hits configs f sc cil
    lib="$O/vendor/lib64/soundfx/libv4a_aidl.so"
    if [[ -f "$lib" && "$(sha "$lib")" = "$V4A_AIDL_LIB_SHA256" ]]; then
        pass "vendor/lib64/soundfx/libv4a_aidl.so is upstream's $V4A_FX_VERSION AIDL arm64 library ($V4A_AIDL_LIB_SHA256)"
    else
        bad "vendor/lib64/soundfx/libv4a_aidl.so is $( [[ -f "$lib" ]] && sha "$lib" || echo missing), want $V4A_AIDL_LIB_SHA256"
    fi
    hits=$(cd "$O" && find vendor odm system system_ext product \( -name 'libv4a_aidl*' -o -name 'libv4a_re*' \) 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$hits" = vendor/lib64/soundfx/libv4a_aidl.so ]]; then pass "one ViPER driver in the images: vendor/lib64/soundfx/libv4a_aidl.so (no 32-bit copy, no HIDL driver)"; else bad "ViPER driver files: ${hits:-none} (want only vendor/lib64/soundfx/libv4a_aidl.so)"; fi
    cfg="$O/vendor/etc/audio_effects_config.xml"
    if [[ -f "$cfg" && "$(sha "$cfg")" = "$V4A_AIDL_CONFIG_SHA256" ]]; then
        pass "vendor/etc/audio_effects_config.xml is the AIDL zip's config, unchanged ($V4A_AIDL_CONFIG_SHA256)"
    else
        bad "vendor/etc/audio_effects_config.xml is $( [[ -f "$cfg" ]] && sha "$cfg" || echo missing), want the AIDL zip's $V4A_AIDL_CONFIG_SHA256"
    fi
    # The AIDL HAL reads the first audio_effects_config.xml in /odm/etc, /vendor/etc, /system/etc;
    # an AOSP system/etc/audio_effects.xml (the legacy name) is never read by it
    configs=$(cd "$O" && find vendor odm system system_ext product -name 'audio_effects*' 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$configs" = vendor/etc/audio_effects_config.xml ||
          "$configs" = "system/etc/audio_effects.xml vendor/etc/audio_effects_config.xml" ]]; then
        pass "effects configs: $configs (vendor's audio_effects_config.xml is the one the AIDL HAL reads)"
    else
        bad "effects configs: ${configs:-none} (want vendor/etc/audio_effects_config.xml, and at most AOSP's system/etc/audio_effects.xml)"
    fi
    hits=0
    for f in "$O"/vendor/bin/hw/android.hardware.audio.service*; do
        [[ -f "$f" ]] || continue
        hits=1
        elf_arm64 "$f" && pass "the audio HAL ${f#"$O"/} is a 64-bit arm64 binary, so it loads the lib64 driver" \
            || bad "${f#"$O"/} isn't a 64-bit arm64 binary"
    done
    [[ $hits = 1 ]] || bad "no vendor/bin/hw/android.hardware.audio.service* in the build"
    hits=$([[ ! -d "$O/vendor/etc/vintf" ]] || aidl_effect "$O/vendor/etc/vintf")
    if [[ -n "$hits" ]]; then pass "built VINTF declares the AIDL effect HAL"; else bad "built VINTF (vendor/etc/vintf) doesn't declare the AIDL effect HAL"; fi
    sc="$O/vendor/etc/selinux/vendor_service_contexts" cil="$O/vendor/etc/selinux/vendor_sepolicy.cil"
    if grep -qE "^${V4A_AIDL_SERVICE}[[:space:]]+u:object_r:viper_control_service:s0" "$sc" 2>/dev/null; then
        pass "vendor_service_contexts labels $V4A_AIDL_SERVICE viper_control_service"
    else
        bad "vendor/etc/selinux/vendor_service_contexts doesn't label $V4A_AIDL_SERVICE"
    fi
    if grep -qE '\(allow hal_audio_default viper_control_service \(service_manager \(.*add' "$cil" 2>/dev/null \
        && grep -qE '\(allow priv_app(_[0-9]+)? viper_control_service \(service_manager \(.*find' "$cil" \
        && grep -qE '\(allow priv_app(_[0-9]+)? servicemanager(_[0-9]+)? \(service_manager \(.*list' "$cil"; then
        pass "vendor_sepolicy.cil lets the audio HAL add $V4A_AIDL_SERVICE and the app find it"
    else
        bad "vendor/etc/selinux/vendor_sepolicy.cil lacks viper_control_service's add (hal_audio_default) or find (priv_app) rule, or priv_app's servicemanager list (the app's AIDL mode needs it)"
    fi
}
device_aidl() {   # uses a, a2, denied, $T
    local l s n hits
    l=$(a2 ls -lZ /vendor/lib64/soundfx/libv4a_aidl.so)
    if denied "$l"; then
        info "adb shell may not read /vendor/lib64/soundfx/libv4a_aidl.so here (a user build): its label and sha256 aren't checked (viper.control below shows whether it loaded)"
    else
        [[ "$l" = *u:object_r:vendor_file:s0* ]] && pass "/vendor/lib64/soundfx/libv4a_aidl.so is labelled vendor_file" \
            || bad "/vendor/lib64/soundfx/libv4a_aidl.so: ${l:-missing} (want u:object_r:vendor_file:s0)"
        s=$(a sha256sum /vendor/lib64/soundfx/libv4a_aidl.so | cut -d' ' -f1)
        [[ "$s" = "$V4A_AIDL_LIB_SHA256" ]] && pass "libv4a_aidl.so is upstream's $V4A_FX_VERSION" || bad "libv4a_aidl.so sha256 is ${s:-unreadable}, want $V4A_AIDL_LIB_SHA256"
    fi
    s=$(a sha256sum /vendor/etc/audio_effects_config.xml | cut -d' ' -f1)
    case "$s" in
        "$V4A_AIDL_CONFIG_SHA256") pass "/vendor/etc/audio_effects_config.xml is the build's (no module patching it)" ;;
        '') info "can't read /vendor/etc/audio_effects_config.xml from adb shell" ;;
        *) bad "/vendor/etc/audio_effects_config.xml is $s, not the build's $V4A_AIDL_CONFIG_SHA256: a ViPER module (or another audio mod) is mounted over it (remove it, reboot)" ;;
    esac
    a service list > "$T/services"
    grep -qF 'android.hardware.audio.effect.IFactory/default' "$T/services" \
        && pass "the AIDL effect HAL is running (android.hardware.audio.effect.IFactory/default)" \
        || bad "android.hardware.audio.effect.IFactory/default isn't registered"
    if grep -qE "(^|[[:space:]])$V4A_AIDL_SERVICE: \[viper\.fx\.IViperControl\]" "$T/services"; then
        pass "the audio HAL loaded the driver: $V4A_AIDL_SERVICE (viper.fx.IViperControl) is registered"
    else
        bad "$V4A_AIDL_SERVICE isn't registered: the audio HAL didn't load libv4a_aidl.so, or SELinux kept it from publishing the service"
    fi
    n=$(grep -F "AServiceManager_addService $V4A_AIDL_SERVICE ->" "$T/logs" | tail -1 || true)
    case "$n" in
        *'-> 0') pass "logcat: $n" ;;
        '') info "logcat has no '$V4A_AIDL_SERVICE' registration line (rotated?): the service list decides" ;;
        *) bad "logcat: $n (registration failed)" ;;
    esac
    a dumpsys android.hardware.audio.effect.IFactory/default > "$T/factory" 2>/dev/null
    if grep -qiF "$V4A_FX_UUID" "$T/factory"; then
        pass "the effect HAL's dump lists ViPER's effect ($V4A_FX_UUID)"
    else
        info "the effect HAL's dump (dumpsys android.hardware.audio.effect.IFactory/default) doesn't name $V4A_FX_UUID here; the service list decides"
    fi
    info "by hand, once per new build: the effects the HAL lists (dumpsys android.hardware.audio.effect.IFactory/default) are a build without ViPER4Android's plus ViPER's, so Pixel's own effects still load"
}

# --- The AIDL driver over Google's stock vendor (EOS_V4A=aidl-overlay: the Pixel 11s) ---------
# The Pixel 11s ship Google's vendor.img as it is (read-only erofs, BOARD_PREBUILT_VENDORIMAGE).
# Its audio HAL is Google's aoc HAL, as husky's: it loads the libraries
# /vendor/etc/audio_effects_config.xml names from /vendor/lib64/soundfx, and the stock image has
# no such config. So husky's two files install under /product/vendor_overlay/0 (Android.mk),
# init.viper4android.rc lays them over those two vendor folders at boot (read-only overlayfs,
# with an off switch), and product policy (viper4android.te and its contexts) labels viper.control.
# Everything here depends on what Google's image holds, so out reads the vendor.img this build
# ships and checks it still fits (the stock guard) and that the split policy compiles with it.
OVL=product/vendor_overlay/0
OVL_HAL=bin/hw/android.hardware.audio.service-aidl.aoc OVL_HAL_SVC=vendor.audio-hal-aidl
tree_overlay() {   # uses $top
    local dt vgc img f hits
    dt="$top/$EOS_DEVICE_TREE" vgc="$top/$EOS_VENDOR_DIR" img="$top/vendor/google/$EOS_DEVICE-images/images/vendor.img"
    [[ -d "$dt" ]] || bad "missing ${dt#"$top"/}"
    # The overlay is for a phone that ships Google's vendor image as it is
    if grep -qE '^[[:space:]]*BOARD_PREBUILT_VENDORIMAGE[[:space:]]*:?=' "$dt"/BoardConfig*.mk 2>/dev/null && [[ -f "$img" ]]; then
        pass "${dt#"$top"/} ships Google's prebuilt vendor image (${img#"$top"/}), which the overlay leaves as it is"
    else
        bad "${dt#"$top"/} sets no BOARD_PREBUILT_VENDORIMAGE or ${img#"$top"/} is missing: aidl-overlay is for a stock prebuilt vendor (a vendor built from source takes EOS_V4A=aidl)"
    fi
    # v4a-check.sh out compiles the split policy with the tree's own check-sepolicy.sh
    [[ -f "$dt/check-sepolicy.sh" ]] && pass "${dt#"$top"/}/check-sepolicy.sh is there (v4a-check.sh out compiles the policy with it)" \
        || bad "no ${dt#"$top"/}/check-sepolicy.sh: v4a-check.sh out couldn't check the policy against the stock vendor's"
    # The build reads vendor/extra/viper4android/Android.mk only if no Android.mk above it stops the search
    [[ ! -e "$top/vendor/extra/Android.mk" ]] && pass "no vendor/extra/Android.mk (the build reads vendor/extra/viper4android/Android.mk)" \
        || bad "vendor/extra/Android.mk exists: the build would never read vendor/extra/viper4android/Android.mk (the overlay's files)"
    # The phone's own trees must not label viper.control or the off switch's properties, ship an
    # effects config, or ViPER, or anything under /product/vendor_overlay (it would cover stock files)
    hits=$(grep -rIlE --exclude-dir=.git 'viper|libv4a|90380da3|eos\.v4a|vendor_overlay' -- "$dt" "$vgc" 2>/dev/null | sed "s#^$top/##" | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then pass "nothing in ${dt#"$top"/} or ${vgc#"$top"/} ships ViPER, labels viper.control or installs under vendor_overlay"; else bad "ViPER, viper.control, eos.v4a or vendor_overlay already in $EOS_DEVICE's trees: $hits"; fi
    hits=$(find "$dt" "$vgc" -name 'audio_effects*' -not -path '*/.git/*' 2>/dev/null | sort | sed "s#^$top/##" | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then pass "no audio_effects config in ${dt#"$top"/} or ${vgc#"$top"/}"; else bad "effects configs in $EOS_DEVICE's trees: $hits (the overlay's would cover or collide with them)"; fi
    if [[ -e "$top/packages/apps/ViPER4AndroidFX" ]]; then
        bad "packages/apps/ViPER4AndroidFX exists: Evolution X's other ViPER stack (libv4a_re, libviperaidl) would fight this one"
    else
        pass "no packages/apps/ViPER4AndroidFX"
    fi
    hits=$(grep -rIl --exclude-dir=.git TARGET_INCLUDE_VIPERFX -- "$dt" "$vgc"/*.mk 2>/dev/null || true)
    if [[ -z "$hits" ]]; then pass "no TARGET_INCLUDE_VIPERFX in the $EOS_DEVICE trees"; else bad "TARGET_INCLUDE_VIPERFX set in: $hits"; fi
}
ovl_extract() {   # ovl_extract <vendor.img> <dir>: Google's image, unpacked rootless with the host's fsck.erofs
    local raw=$1 fsck=$H/bin/fsck.erofs s2i=$H/bin/simg2img
    [[ -x "$fsck" ]] || { echo "no $fsck (host_out with a built fsck.erofs)"; return 1; }
    if [[ "$(od -An -tx1 -N4 -- "$1" | tr -d ' \n')" = 3aff26ed ]]; then   # a sparse image
        [[ -x "$s2i" ]] || { echo "a sparse image and no $s2i"; return 1; }
        raw=$T/vendor.raw
        "$s2i" "$1" "$raw" > /dev/null 2>&1 || { echo "simg2img failed"; return 1; }
    fi
    "$fsck" --extract="$2" --no-preserve-owner "$raw" > "$T/fsck.log" 2>&1 \
        || { rm -rf -- "$2"; "$fsck" --extract="$2" --no-preserve "$raw" > "$T/fsck.log" 2>&1; } \
        || { echo "fsck.erofs: $(tail -2 "$T/fsck.log" | tr '\n' ' ')"; return 1; }
    [[ $raw = "$1" ]] || rm -f -- "$raw"
}
ovl_stock_guard() {   # ovl_stock_guard <vendor dir>: Google's vendor still fits the overlay
    local V=$1 se=$1/etc/selinux hits rc types vft t odd
    hits=$(cd "$V" && find . \( -iname '*audio_effects*' -o -name 'libv4a*' \) 2>/dev/null | sed 's#^\./##' | sort | paste -sd' ' || true)
    if [[ -z "$hits" ]]; then pass "stock vendor: no effects config and no ViPER of its own (the overlay's config adds, covers nothing)"
    else bad "stock vendor now has $hits: the overlay's audio_effects_config.xml would hide Google's (merge ViPER's library and effect into a copy of it instead; README.md)"; fi
    if [[ -f "$V/$OVL_HAL" ]] && grep -aqF /vendor/etc/audio_effects_config.xml "$V/$OVL_HAL" && grep -aqF /vendor/lib64/soundfx/ "$V/$OVL_HAL"; then
        pass "stock vendor: /vendor/$OVL_HAL still reads /vendor/etc/audio_effects_config.xml and loads from /vendor/lib64/soundfx/"
    else
        bad "stock vendor: /vendor/$OVL_HAL is gone or no longer names /vendor/etc/audio_effects_config.xml and /vendor/lib64/soundfx/: the overlaid folders may not be the ones it reads"
    fi
    [[ -d "$V/lib64/soundfx" && -d "$V/etc" ]] && pass "stock vendor: lib64/soundfx and etc are folders (overlayfs needs them)" || bad "stock vendor: no lib64/soundfx or etc folder"
    rc=$(grep -lE "^service $OVL_HAL_SVC /vendor/$OVL_HAL" "$V"/etc/init/*.rc "$V"/etc/init/hw/*.rc 2>/dev/null | head -1 || true)
    if [[ -n "$rc" ]] && grep -qE '^[[:space:]]+class[[:space:]]+hal([[:space:]]|$)' "$rc" && ! grep -qE '^[[:space:]]+critical([[:space:]]|$)' "$rc"; then
        pass "stock vendor: service $OVL_HAL_SVC (class hal, not critical) runs the HAL: it starts after the mounts, and the off switch watches it"
    else
        bad "stock vendor: no 'service $OVL_HAL_SVC /vendor/$OVL_HAL' with class hal and not critical in etc/init: init.viper4android.rc's mounts may come too late or its off switch watch the wrong service"
    fi
    if grep -hqE '^ro\.vndk\.version=' "$V/build.prop" "$V/etc/build.prop" "$V/default.prop" 2>/dev/null; then
        bad "stock vendor sets ro.vndk.version: fs_mgr would mount its own /product/vendor_overlay/<version> too"
    else
        pass "stock vendor sets no ro.vndk.version (fs_mgr's own vendor overlay stays off)"
    fi
    hits=$(grep -oE '\(typeattributeset hal_audio_server \([^)]*\)\)' "$se/vendor_sepolicy.cil" 2>/dev/null | sed -E 's/.*\(([^()]*)\)\)$/\1/' || true)
    [[ -n "$hits" ]] && pass "stock vendor policy: hal_audio_server is $hits (viper4android.te's rules reach the HAL through it)" \
        || bad "stock vendor policy puts nothing in hal_audio_server: viper4android.te's rules wouldn't reach the audio HAL"
    hits=$(grep -rliE 'viper|eos_v4a' "$se" 2>/dev/null | sed "s#^$V/##" | paste -sd' ' || true)
    [[ -z "$hits" ]] && pass "stock vendor policy names no viper or eos_v4a" || bad "stock vendor policy names viper or eos_v4a: $hits (two labels for one service abort servicemanager)"
    # overlayfs checks the mounter's (init's) access on every file it serves from /vendor/etc: each
    # label there must be one init reads. init reads every vendor_file_type; the others allowed
    # here are the platform types /vendor/etc/selinux carries, which init reads too
    types=$(grep -E '^/(\(vendor\|system/vendor\)|vendor|system/vendor)/etc' "$se/vendor_file_contexts" 2>/dev/null | awk '{print $NF}' | sed -E 's/^u:object_r:([^:]+):.*/\1/' | sort -u)
    vft=$(grep -oE '\(typeattributeset vendor_file_type \([^)]*\)\)' "$se/vendor_sepolicy.cil" 2>/dev/null | tr ' ()' '\n\n\n' | sort -u)
    odd=
    for t in $types; do
        grep -qx -- "$t" <<<"$vft" && continue
        case $t in vendor_configs_file|vendor_service_contexts_file|sepolicy_file|file_contexts_file|property_contexts_file) continue ;; esac
        odd="$odd $t"
    done
    [[ -z "$odd" ]] && pass "stock vendor labels under /vendor/etc are all ones init reads ($(paste -sd' ' <<<"$types"))" \
        || bad "stock vendor labels files under /vendor/etc with types init may not read:$odd (overlaying /vendor/etc would break whatever reads them: add init's read in viper4android.te)"
    hits=$(for l in libbase libfmq libcutils; do [[ -f "$V/lib64/$l.so" ]] || printf '%s ' "$l.so"; done)
    [[ -z "$hits" ]] && pass "stock vendor has the driver's vendor libraries (libbase, libfmq, libcutils)" || bad "stock vendor lacks $hits: the driver wouldn't load"
}
out_overlay() {   # uses $O, $H
    local lib cfg hits configs se top dt img V out n f
    lib="$O/$OVL/lib64/soundfx/libv4a_aidl.so" cfg="$O/$OVL/etc/audio_effects_config.xml"
    if [[ -f "$lib" && "$(sha "$lib")" = "$V4A_AIDL_LIB_SHA256" ]]; then
        pass "$OVL/lib64/soundfx/libv4a_aidl.so is upstream's $V4A_FX_VERSION AIDL arm64 library ($V4A_AIDL_LIB_SHA256)"
    else
        bad "$OVL/lib64/soundfx/libv4a_aidl.so is $( [[ -f "$lib" ]] && sha "$lib" || echo missing), want $V4A_AIDL_LIB_SHA256"
    fi
    if [[ -f "$cfg" && "$(sha "$cfg")" = "$V4A_AIDL_CONFIG_SHA256" ]]; then
        pass "$OVL/etc/audio_effects_config.xml is the AIDL zip's config, unchanged ($V4A_AIDL_CONFIG_SHA256)"
    else
        bad "$OVL/etc/audio_effects_config.xml is $( [[ -f "$cfg" ]] && sha "$cfg" || echo missing), want the AIDL zip's $V4A_AIDL_CONFIG_SHA256"
    fi
    # Anything else under the overlay would cover a stock vendor file of the same name
    hits=$(cd "$O" && find product/vendor_overlay -mindepth 1 \! -type d 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$hits" = "$OVL/etc/audio_effects_config.xml $OVL/lib64/soundfx/libv4a_aidl.so" ]]; then
        pass "product/vendor_overlay holds ViPER's two files only (nothing else covers a stock vendor file)"
    else
        bad "product/vendor_overlay holds: ${hits:-nothing} (want only $OVL/etc/audio_effects_config.xml and $OVL/lib64/soundfx/libv4a_aidl.so)"
    fi
    hits=$(cd "$O" && find vendor odm system system_ext product \( -name 'libv4a_aidl*' -o -name 'libv4a_re*' \) 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$hits" = "$OVL/lib64/soundfx/libv4a_aidl.so" ]]; then pass "one ViPER driver in the images: $OVL/lib64/soundfx/libv4a_aidl.so"; else bad "ViPER driver files: ${hits:-none} (want only $OVL/lib64/soundfx/libv4a_aidl.so)"; fi
    configs=$(cd "$O" && find vendor odm system system_ext product -name 'audio_effects*' 2>/dev/null | sort | paste -sd' ' || true)
    if [[ "$configs" = "$OVL/etc/audio_effects_config.xml" || "$configs" = "$OVL/etc/audio_effects_config.xml system/etc/audio_effects.xml" ]]; then
        pass "effects configs: $configs (the overlay's becomes /vendor/etc/audio_effects_config.xml, the one the AIDL HAL reads)"
    else
        bad "effects configs: ${configs:-none} (want $OVL/etc/audio_effects_config.xml, and at most AOSP's system/etc/audio_effects.xml)"
    fi
    f="$O/product/etc/init/init.viper4android.rc"
    cmp -s -- "$f" "$kit/tree/init.viper4android.rc" && pass "product/etc/init/init.viper4android.rc is the kit's (the mounts and the off switch)" \
        || bad "product/etc/init/init.viper4android.rc is missing or not the kit's: nothing would lay the overlay over /vendor"
    grep -qxF 'persist.eos.v4a.off=0' "$O/product/etc/build.prop" 2>/dev/null && pass "product build.prop sets the off switch's default (persist.eos.v4a.off=0, on)" \
        || bad "product/etc/build.prop lacks persist.eos.v4a.off=0: init.viper4android.rc would never mount"
    se="$O/product/etc/selinux"
    grep -qE "^${V4A_AIDL_SERVICE}[[:space:]]+u:object_r:viper_control_service:s0" "$se/product_service_contexts" 2>/dev/null \
        && pass "product_service_contexts labels $V4A_AIDL_SERVICE viper_control_service" || bad "product/etc/selinux/product_service_contexts doesn't label $V4A_AIDL_SERVICE"
    grep -qF '/(product|system/product)/vendor_overlay/0/etc(/.*)?' "$se/product_file_contexts" 2>/dev/null \
        && grep -F '/(product|system/product)/vendor_overlay/0/etc(/.*)?' "$se/product_file_contexts" | grep -qF u:object_r:vendor_configs_file:s0 \
        && pass "product_file_contexts labels $OVL/etc vendor_configs_file (/vendor/etc keeps its label)" \
        || bad "product/etc/selinux/product_file_contexts doesn't label $OVL/etc vendor_configs_file: /vendor/etc would turn vendor_file"
    grep -qE '^persist\.eos\.v4a\.[[:space:]]+u:object_r:eos_v4a_prop:s0' "$se/product_property_contexts" 2>/dev/null \
        && grep -qE '^eos\.v4a\.[[:space:]]+u:object_r:eos_v4a_prop:s0' "$se/product_property_contexts" \
        && pass "product_property_contexts labels the off switch's properties eos_v4a_prop" || bad "product/etc/selinux/product_property_contexts doesn't label persist.eos.v4a. and eos.v4a."
    f="$se/product_sepolicy.cil"
    if grep -qE '\(allow hal_audio_server viper_control_service \(service_manager \(.*add' "$f" 2>/dev/null \
        && grep -qE '\(allow priv_app viper_control_service \(service_manager \(.*find' "$f" \
        && grep -qE '\(allow priv_app servicemanager \(service_manager \(.*list' "$f" \
        && grep -qE '\(allow priv_app hal_audio_server \(binder \(.*call' "$f" \
        && grep -qE '\(allow init vendor_configs_file \(dir \(.*mounton' "$f" \
        && grep -qE '\(allow shell eos_v4a_prop \(property_service \(.*set' "$f"; then
        pass "product_sepolicy.cil: the HAL adds $V4A_AIDL_SERVICE, the app lists, finds and calls it, init mounts on /vendor/etc, adb shell sets the off switch"
    else
        bad "product/etc/selinux/product_sepolicy.cil lacks viper4android.te's rules (hal_audio_server add, priv_app list/find/call, init mounton, shell set)"
    fi
    # Google's image as this build ships it
    img="$O/vendor.img" V="$T/stock-vendor"
    if [[ -z "$H" ]]; then
        bad "no host_out given: the stock vendor.img can't be unpacked (fsck.erofs) nor the policy compiled (secilc)"
        return
    fi
    if [[ ! -f "$img" ]]; then bad "no vendor.img in $O: nothing to check the overlay against"; return; fi
    if ! out=$(ovl_extract "$img" "$V"); then bad "can't unpack $O/vendor.img: $out"; return; fi
    info "stock vendor: $(grep -hE '^ro\.vendor\.build\.fingerprint=' "$V/build.prop" "$V/etc/build.prop" 2>/dev/null | head -1)"
    ovl_stock_guard "$V"
    # Exactly one label for viper.control across the partitions (servicemanager refuses two)
    n=$(cat "$O"/system/etc/selinux/plat_service_contexts "$O"/system_ext/etc/selinux/system_ext_service_contexts \
        "$se/product_service_contexts" "$V/etc/selinux/vendor_service_contexts" 2>/dev/null | grep -cE "^${V4A_AIDL_SERVICE}[[:space:]]" || true)
    [[ $n = 1 ]] && pass "one $V4A_AIDL_SERVICE label across system, system_ext, product and the stock vendor" || bad "$V4A_AIDL_SERVICE is labelled $n times across the partitions (want 1)"
    # The split policy as init compiles it at boot, with the stock vendor's: a failure is a bootloop
    top=${O%/out/target/product/*} dt=
    [[ $top = "$O" ]] || dt="$top/$EOS_DEVICE_TREE"
    if [[ -z "$dt" || ! -f "$dt/check-sepolicy.sh" ]]; then
        bad "can't find $EOS_DEVICE's check-sepolicy.sh (the product out isn't <top>/out/target/product/<device>?): the policy isn't compiled against the stock vendor's"
    elif [[ ! -x "$H/bin/secilc" ]]; then
        bad "no $H/bin/secilc: the policy isn't compiled against the stock vendor's"
    elif out=$(bash "$dt/check-sepolicy.sh" "$H/bin/secilc" "$O" "$V" 2>&1) && grep -q '^OK: split policy compiles' <<<"$out"; then
        pass "${dt#"$top"/}/check-sepolicy.sh: $(grep '^OK: split policy compiles' <<<"$out")"
    else
        bad "${dt#"$top"/}/check-sepolicy.sh fails with the stock vendor's policy (a bootloop):"$'\n'"$(tail -5 <<<"$out")"
    fi
    rm -rf -- "$V"
}
device_overlay() {   # uses a, a2, denied, $T
    local d m l off n
    a cat /proc/mounts > "$T/mounts"
    off=$(a getprop persist.eos.v4a.off) n=$(a getprop eos.v4a.restarts)
    case "$off" in
        0) pass "the off switch is on (persist.eos.v4a.off=0)" ;;
        1|2)
            if [[ $off = 1 ]]; then
                bad "ViPER4Android is turned off by hand (persist.eos.v4a.off=1): adb shell setprop persist.eos.v4a.off 0, then reboot"
            else
                bad "the automatic switch turned ViPER4Android off: the audio HAL kept restarting (persist.eos.v4a.off=2; logcat -b crash shows why). adb shell setprop persist.eos.v4a.off 0 and reboot to try again"
            fi
            m=$(awk '$2 == "/vendor/lib64/soundfx" && $3 == "overlay"' "$T/mounts")
            [[ -z "$m" ]] && pass "the driver is taken away as the switch says (no overlay on /vendor/lib64/soundfx; eos.v4a.restarts=${n:-unset})" \
                || bad "the switch is off but /vendor/lib64/soundfx is still overlaid: the rc's unmount failed (logcat -b all | grep init: shows why)"
            return ;;
        *) bad "persist.eos.v4a.off is '${off}', not 0, 1 or 2: the build's default (product build.prop) is missing" ;;
    esac
    info "audio HAL restarts counted this boot: ${n:-none (no mount this boot)} (6 turn it off)"
    for d in /vendor/lib64/soundfx /vendor/etc; do
        m=$(awk -v d="$d" '$2 == d && $3 == "overlay" { print $4 }' "$T/mounts" | tail -1)
        if [[ ",$m," = *,ro,* && "$m" = *"lowerdir=/$OVL/"* ]]; then
            pass "$d: ViPER's read-only overlay from /$OVL is mounted"
        else
            bad "$d: no read-only overlay from /$OVL (${m:-not mounted}): init.viper4android.rc didn't mount it (logcat -b all | grep init: shows why)"
        fi
    done
    l=$(a2 ls -dZ /vendor/etc)
    [[ "$l" = *u:object_r:vendor_configs_file:s0* ]] && pass "/vendor/etc keeps its label (vendor_configs_file)" || bad "/vendor/etc: ${l:-unreadable} (want u:object_r:vendor_configs_file:s0)"
    l=$(a2 ls -dZ /vendor/lib64/soundfx)
    if denied "$l"; then info "adb shell may not look at /vendor/lib64/soundfx here: its label isn't checked"
    else [[ "$l" = *u:object_r:vendor_file:s0* ]] && pass "/vendor/lib64/soundfx keeps its label (vendor_file)" || bad "/vendor/lib64/soundfx: ${l:-unreadable} (want u:object_r:vendor_file:s0)"; fi
    device_aidl
    info "by hand, once on kodiak's first build: adb shell setprop persist.eos.v4a.off 1 takes the driver away at once (this check then shows soundfx not overlaid, viper.control gone, Pixel's effects still listed), and again after a reboot; setprop 0 and a reboot bring it back"
}

mode=${1:-}; shift || true
case "$mode" in
tree)
    [[ $# = 1 && -d "$1" ]] || usage
    eos_device
    top="$(cd "$1" && pwd -P)"
    echo "== ViPER4Android RE tree checks: $top"
    # What apply-v4a.sh writes must stay in this tree, also through symlinks
    ok=1
    for p in vendor/extra vendor/extra/viper4android vendor/extra/product.mk frameworks/av; do
        r=$(realpath -m -- "$top/$p")
        if [[ "$r" != "$top"/* ]]; then ok=0; bad "$p leads to $r, outside $top (a symlink?)"; fi
    done
    gd=$(git -C "$top/frameworks/av" rev-parse --absolute-git-dir 2>/dev/null || true)
    [[ -z "$gd" ]] || gd=$(realpath -- "$gd")
    if [[ -n "$gd" && "$gd" != "$top"/* ]]; then ok=0; bad "frameworks/av's git folder is $gd, outside $top (shared with another tree?)"; fi
    [[ $ok = 0 ]] || pass "vendor/extra and frameworks/av are this tree's own (no symlink out of it)"
    fx="$top/frameworks/av/media/libeffects/factory/EffectsFactory.c"
    ecpp="$top/frameworks/av/services/audioflinger/Effects.cpp"
    if [[ $EOS_V4A = aidl ]]; then
        tree_aidl
    elif [[ $EOS_V4A = aidl-overlay ]]; then
        tree_overlay
    else
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
    fi
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
$V4A_AIDL_LIB_SHA256 libv4a_aidl_arm64-v8a.so
$V4A_AIDL_CONFIG_SHA256 audio_effects_config.aidl.xml
EOF
    [[ ! -d "$dest" ]] || for f in "$kit"/tree/*; do
        cmp -s -- "$f" "$dest/${f##*/}" || { ok=0; bad "vendor/extra/viper4android/${f##*/} differs from the kit's tree/${f##*/}"; }
    done
    [[ $ok = 0 ]] || pass "vendor/extra/viper4android matches the kit and v4a.conf (app $V4A_APP_VERSION, drivers $V4A_FX_VERSION)"
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
    # The phone: EOS_DEVICE, else the product out's own name (out/target/product/<device>)
    export EOS_DEVICE=${EOS_DEVICE:-${O##*/}}
    eos_device
    echo "== ViPER4Android RE build checks: $O"
    if [[ $EOS_V4A = aidl ]]; then
        out_aidl
    elif [[ $EOS_V4A = aidl-overlay ]]; then
        out_overlay
    else
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
    # (the overlay's driver and config are product modules, so their notices are product's)
    for p in $([[ $EOS_V4A = aidl-overlay ]] && echo product || echo vendor) system_ext; do
        n="$O/$p/etc/NOTICE.xml.gz"
        if [[ ! -f "$n" ]]; then bad "no $p/etc/NOTICE.xml.gz: the build must ship the ViPER4Android licence texts"; continue; fi
        gzip -dc -- "$n" > "$T/notice" 2>/dev/null || { bad "$p/etc/NOTICE.xml.gz doesn't decompress"; continue; }
        if [[ $p = product || ( $p = vendor && $EOS_V4A = aidl ) ]]; then
            grep -qF 'Zhuhang' "$T/notice" && grep -qF 'Julien Pommier' "$T/notice" \
                && pass "$p NOTICE carries the ViPERDSP and PFFFT notices (the AIDL driver)" \
                || bad "$p NOTICE lacks NOTICE.viperdsp or NOTICE.pffft"
        elif [[ $p = vendor ]]; then
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
    adb logcat -b all -d > "$T/log" 2>/dev/null || true
    tr -d '\r' < "$T/log" > "$T/logs"
    if [[ $EOS_V4A = aidl ]]; then
        device_aidl
    elif [[ $EOS_V4A = aidl-overlay ]]; then
        device_overlay
    else
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
    fi
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
        | grep -E "hal_audio_default|$V4A_APP_PACKAGE|libv4a_re|libv4a_aidl|viper_control_service|eos_v4a_prop|scontext=u:r:priv_app:[^ ]* tcontext=u:r:servicemanager:|scontext=u:r:init:s0 tcontext=u:object_r:vendor_(configs_)?file:" | tail -5 || true)
    [[ -z "$hits" ]] && pass "no SELinux denials for hal_audio_default, the app or init's overlay" || bad "SELinux denials:"$'\n'"$hits"
    grep -qF 'Welcome to ViPER FX' "$T/logs" && info "logcat: a ViPER effect instance was created (the app is on)" \
        || info "no ViPER effect instance in the log yet: turn the app's master switch on, play something, run again"
    info "by hand: ViPER4Android > menu > Driver Status shows Version $V4A_FX_VERSION, Version Code $V4A_FX_VERSION_CODE, Streaming: Active while music plays"
    ;;
*) usage ;;
esac
finish
