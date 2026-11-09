#!/usr/bin/env bash
# Release checks for an ExpressiveOS build with KernelSU Next (a phone with EOS_KSU=lkm;
# EOS_DEVICE, cheetah unless set), for the kit's verify and pack scripts. Stops at the first
# problem; the last line is KSU_CHECK=OK or KSU_CHECK=FAIL.
#
#   ksu-check.sh manager [top]
#       the manager is in the build as fetch-ksu.sh downloaded it: ksu.conf's APK byte
#       for byte (so it keeps the signature the kernel trusts), the APK's four arm64
#       libs next to it, equal to the APK's own, and libksud.so executable (0755,
#       root) in the build's fs_config (EOS_PRODUCT_OUT's), or the manager can't run it.
#       The first-boot setup is the kit's (tree/eos-ksu-firstboot.rc, tree/ksu-firstboot.sh), the Zygisk
#       provider is ksu.conf's zip byte for byte and no KernelSU Next risk rule stops its
#       install, and the susfs guard module libksud.so loads is built for the kernel's
#       struct module, like kernelsu.ko (a mismatch crashes every boot with susfs on), the
#       phone's KMI (EOS_KMI).
#   ksu-check.sh images <dir> [top]
#       <dir> holds a full set of the build's images (a fastboot zip unpacked, or
#       out/target/product/<device>): init_boot carries ExpressiveOS's kernelsu.ko, built
#       for the same struct module as vendor_kernel_boot's modules, with the init.rc lines
#       the first-boot setup relies on (ksud in the ksu domain), the whole AVB chain
#       verifies, and vbmeta is signed by the tree's own AVB key and nobody else's
#       (../../tools/eos-keys-check.sh vbmeta).
#   ksu-check.sh device-ok <zip>
#       <zip>.device-ok names <zip>'s sha256: someone flashed and tested it.
set -euo pipefail
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "KSU_CHECK=FAIL"
    exit $rc
}
trap cleanup EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../../lib.sh
source "$here/../lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/ksu-check.XXXXXX")
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
mode=${1:-}
usage="usage: ksu-check.sh manager [top] | images <dir> [top] | device-ok <zip>"
lib=product/app/KernelSUNext/lib/arm64
H=''
unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I "$top/system/tools/mkbootimg/unpack_bootimg.py" "$@"; fi; }
kernel_modules() {   # kernel_modules <vendor_kernel_boot.img> <dir>: its modules (lib/modules/*.ko) into <dir>
    unpack --boot_img "$1" --out "$T/vkb" >/dev/null || fail "can't unpack $1"
    mkdir -p -- "$2"
    for rd in "$T"/vkb/vendor_ramdisk*; do   # vendor_ramdisk00, 01... (header v4) or vendor_ramdisk (v3)
        [[ -f $rd ]] || continue
        (cd "$2" && { lz4 -dc "$rd" 2>/dev/null || gzip -dc "$rd"; } \
            | cpio -id --quiet --no-absolute-filenames 'lib/modules/*.ko') \
            || fail "can't unpack ${rd##*/} from $1"
    done
    rm -rf -- "$T/vkb"
}

case "$mode" in
manager)
    [[ $# -le 2 ]] || fail "$usage"
    [[ $EOS_KSU = lkm ]] || fail "KernelSU Next is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): its build has no manager to check"
    eos_top "${2:-}"
    O=$top/$EOS_PRODUCT_OUT
    H=$top/out/host/linux-x86/bin
    d=$O/product/app/KernelSUNext
    apk=$d/KernelSUNext.apk
    # The device tree patch that adds it: cheetah's in ../patches/, another phone's in devices/<device>/ksu-patches/
    if [[ $EOS_DEVICE = cheetah ]]; then p0101=patches/device_google_pantah/0101; else p0101="devices/$EOS_DEVICE/ksu-patches/*/0101"; fi
    [[ -f "$apk" ]] || fail "the KernelSU Next manager isn't in the build (apply-ksu.sh, $p0101)"
    [[ "$(sha256sum -- "$apk" | cut -d' ' -f1)" = "$(get manager_sha256)" ]] \
        || fail "$apk isn't ksu.conf's manager APK byte for byte: the build changed it (re-signed, or stripped)"
    want=$(get manager_cert_sha256)
    have=$(python3 -I "$here/tools/apk-cert.py" "$apk") || fail "can't read $apk's signature"
    [[ "$have" = "$want" ]] || fail "$apk is signed by $have; the kernel trusts only $want"
    echo "OK: the manager is ksu.conf's APK, signed by $have"
    libs=$(sed -n 's|^ *lib/arm64/\(lib[^ ]*\.so\).*|\1|p' "$here/tree/Android.mk" | sort)
    apklibs=$(unzip -Z1 -- "$apk" 'lib/arm64-v8a/*' | sed 's|^lib/arm64-v8a/||' | sort)
    [[ -n "$libs" && "$libs" = "$apklibs" ]] || fail "tree/Android.mk installs ($(tr '\n' ' ' <<<"$libs")), the APK has ($(tr '\n' ' ' <<<"$apklibs"))"
    built=$(find "$d/lib/arm64" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)
    [[ "$built" = "$libs" ]] || fail "$lib holds ($(tr '\n' ' ' <<<"$built")), want ($(tr '\n' ' ' <<<"$libs"))"
    for l in $libs; do
        unzip -p -- "$apk" "lib/arm64-v8a/$l" > "$T/$l"
        cmp -s -- "$T/$l" "$d/lib/arm64/$l" || fail "$lib/$l isn't the APK's lib/arm64-v8a/$l"
    done
    echo "OK: the APK's $(wc -w <<<"$libs") arm64 libs are installed in $lib, unchanged"
    # The manager runs libksud.so as a program: it must be executable on the device
    [[ -f "$O/product/etc/fs_config_files" ]] || fail "no product/etc/fs_config_files in $O (ksu/config.fs not built in)"
    for f in "$O"/{system,product}/etc/fs_config_files; do
        [[ -f "$f" ]] || continue
        e=$(python3 -I "$here/tools/fs-config.py" "$f" "$lib/libksud.so") \
            || fail "${f#"$O"/} has no entry for $lib/libksud.so (TARGET_FS_CONFIG_GEN += $EOS_DEVICE_TREE/ksu/config.fs missing?)"
        [[ "$e" = "755 0 0 0x0" ]] || fail "${f#"$O"/} gives $lib/libksud.so '$e' (mode uid gid caps), want '755 0 0 0x0'"
    done
    # And the image builder's own lookup agrees
    fsc=$top/out/host/linux-x86/bin/fs_config
    if [[ -x "$fsc" ]]; then
        e=$(echo "$lib/libksud.so" | "$fsc" -C -D "$O/system")
        [[ "$(awk '{print $2, $3, $4}' <<<"$e")" = "0 0 755" ]] || fail "the build's fs_config tool gives '$e' for $lib/libksud.so, want uid 0, gid 0, mode 755"
    else
        echo "note: no $fsc (host tools not built); checked the fs_config files only"
    fi
    echo "OK: $lib/libksud.so is root:root 0755 in the build's fs_config"
    for f in etc/init/eos-ksu-firstboot.rc etc/eos/ksu-firstboot.sh; do
        cmp -s -- "$O/product/$f" "$here/tree/${f##*/}" || fail "product/$f isn't the kit's tree/${f##*/} (apply-ksu.sh, tree/Android.mk)"
    done
    z=$O/product/etc/eos/zygisk-provider.zip
    [[ -f $z && "$(sha256sum -- "$z" | cut -d' ' -f1)" = "$(get zygisk_sha256)" ]] \
        || fail "product/etc/eos/zygisk-provider.zip isn't ksu.conf's NeoZygisk zip byte for byte"
    risk=$HOME/android-dt/ksu/$(get version)/src/risk/risk.json
    [[ -f $risk ]] || fail "no $risk (run fetch-ksu.sh): can't tell whether ksud would install the provider"
    python3 -I "$here/tools/zygisk-zip.py" "$z" "$(get zygisk_module_id)" "$(get zygisk_version_code)" "$risk" > "$T/zygisk.log" 2>&1 \
        || { grep '^FAIL' "$T/zygisk.log" >&2; fail "the Zygisk provider wouldn't install (tools/zygisk-zip.py)"; }
    echo "OK: the first-boot setup is the kit's, and the Zygisk provider is NeoZygisk $(get zygisk_version) as pinned, installable"
    # ksud loads the guard module itself (susfs load, and auto-load at every post-fs-data)
    kmi=$EOS_KMI
    python3 -I "$here/tools/ko-info.py" embedded "$d/lib/arm64/libksud.so" susfs_guard_lkm "${kmi#*-}." "$T/guard.ko" > "$T/guard.log" 2>&1 \
        || { cat "$T/guard.log" >&2; fail "can't find libksud.so's susfs guard module for $kmi"; }
    [[ -f $O/vendor_kernel_boot.img ]] || fail "no vendor_kernel_boot.img in $O"
    kernel_modules "$O/vendor_kernel_boot.img" "$T/m"
    r=$(python3 -I "$here/tools/ko-info.py" same-struct "$T/guard.ko" "$T/m") \
        || fail "libksud.so's susfs guard module doesn't fit the kernel's struct module: susfs auto-load would crash every boot"
    echo "OK: libksud.so's susfs guard module ($(cut -d' ' -f2- "$T/guard.log" | cut -c1-40)) is built for the kernel's struct module (${r% *} bytes)"
    ;;
images)
    [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
    dir=$2
    eos_top "${3:-}"
    for i in init_boot vbmeta; do [[ -f "$dir/$i.img" ]] || fail "no $i.img in $dir"; done
    H=$top/out/host/linux-x86/bin
    avbtool() { if [[ -x $H/avbtool ]]; then "$H/avbtool" "$@"; else python3 -I "$top/external/avb/avbtool.py" "$@"; fi; }
    unpack --boot_img "$dir/init_boot.img" --out "$T/ib" >/dev/null || fail "can't unpack $dir/init_boot.img"
    # Only the files checked here: the ramdisk's device nodes (dev/console...) need root to make
    mkdir "$T/r"
    (cd "$T/r" && { lz4 -dc "$T/ib/ramdisk" 2>/dev/null || gzip -dc "$T/ib/ramdisk"; } \
        | cpio -id --quiet --no-absolute-filenames init.real kernelsu.ko) \
        || fail "can't unpack $dir/init_boot.img's ramdisk"
    [[ -f "$T/r/kernelsu.ko" ]] || fail "$dir/init_boot.img has no kernelsu.ko (pass 2 shipped the stock init_boot?)"
    [[ -e "$T/r/init.real" ]] || fail "$dir/init_boot.img has kernelsu.ko but no init.real: ksud didn't patch it"
    # Ours, not ksud's built-in module, which never crowns the preinstalled manager
    strings "$T/r/kernelsu.ko" | grep -x /product/app/KernelSUNext/KernelSUNext.apk >/dev/null \
        || fail "$dir/init_boot.img's kernelsu.ko isn't ExpressiveOS's (tools/ksu-module.sh)"
    echo "OK: init_boot carries ExpressiveOS's KernelSU Next module"
    # The first-boot setup's services run in the domain these lines run ksud in, and put
    # ksud where they look for it (tree/eos-ksu-firstboot.rc)
    for stage in post-fs-data services boot-completed; do
        grep -aqF -- "exec u:r:ksu:s0 root -- /data/adb/ksud $stage" "$T/r/kernelsu.ko" \
            || fail "kernelsu.ko no longer runs '/data/adb/ksud $stage' in u:r:ksu:s0: check tree/eos-ksu-firstboot.rc against this KernelSU Next"
    done
    echo "OK: kernelsu.ko runs /data/adb/ksud in u:r:ksu:s0, as the first-boot setup expects"
    # Built for the kernel's struct module, as vendor_kernel_boot's modules are: 6.1 loads a
    # kernelsu.ko built for another one and crashes at boot (tools/ko-info.py)
    [[ -f "$dir/vendor_kernel_boot.img" ]] || fail "no vendor_kernel_boot.img in $dir"
    kernel_modules "$dir/vendor_kernel_boot.img" "$T/m"
    r=$(python3 -I "$here/tools/ko-info.py" same-struct "$T/r/kernelsu.ko" "$T/m") \
        || fail "init_boot's kernelsu.ko doesn't fit the kernel's struct module (tools/ksu-module.sh)"
    echo "OK: kernelsu.ko is built for the kernel's struct module (${r% *} bytes, as vendor_kernel_boot's ${r#* } modules)"
    (cd "$dir" && avbtool verify_image --image vbmeta.img --follow_chain_partitions) > "$T/avb.log" 2>&1 \
        || { tail -5 "$T/avb.log" >&2; fail "avbtool verify_image failed on $dir"; }
    # verify_image only checks what vbmeta lists: init_boot must be one of them
    avbtool info_image --image "$dir/vbmeta.img" > "$T/avb.info" 2>&1 || fail "avbtool can't read $dir/vbmeta.img"
    grep -qE '^ +Partition Name: +init_boot$' "$T/avb.info" || fail "$dir/vbmeta.img doesn't cover init_boot"
    echo "OK: the AVB chain verifies, init_boot included"
    "$here/../tools/eos-keys-check.sh" vbmeta "$dir/vbmeta.img" "$top" > "$T/keys.log" 2>&1 || true
    tail -1 "$T/keys.log" | grep -qxE 'KEYS_CHECK=(OK|UNPINNED)' \
        || { grep -E '^FAIL' "$T/keys.log" >&2 || tail -3 "$T/keys.log" >&2; fail "vbmeta isn't signed by ExpressiveOS's own AVB key"; }
    grep -E '^(OK|UNPINNED)' "$T/keys.log"
    ;;
device-ok)
    [[ $# -eq 2 ]] || fail "$usage"
    zip=$2; m=$zip.device-ok
    [[ -f "$zip" ]] || fail "no $zip"
    sha=$(sha256sum -- "$zip" | cut -d' ' -f1)
    { [[ -f "$m" ]] && grep -qF -- "$sha" "$m"; } || fail "not verified on a phone yet: flash and test $zip, then write $m with the line \"sha256 $sha\""
    echo "OK: on-device check: $(head -c 300 "$m")"
    ;;
*) fail "$usage" ;;
esac
done=1
echo "KSU_CHECK=OK"
