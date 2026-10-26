#!/usr/bin/env bash
# Release checks for an ExpressiveOS cheetah build with KernelSU Next, for the kit's
# verify and pack scripts. Stops at the first problem; the last line is KSU_CHECK=OK or
# KSU_CHECK=FAIL.
#
#   ksu-check.sh manager [top]
#       the manager is in the build as fetch-ksu.sh downloaded it: ksu.conf's APK byte
#       for byte (so it keeps the signature the kernel trusts), the APK's four arm64
#       libs next to it, equal to the APK's own, and libksud.so executable (0755,
#       root) in the build's fs_config, or the manager can't run it.
#   ksu-check.sh images <dir> [top]
#       <dir> holds a full set of the build's images (a fastboot zip unpacked, or
#       out/target/product/cheetah): init_boot carries ExpressiveOS's kernelsu.ko, built
#       for the same struct module as vendor_kernel_boot's modules, the whole AVB chain
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

case "$mode" in
manager)
    [[ $# -le 2 ]] || fail "$usage"
    eos_top "${2:-}"
    O=$top/out/target/product/cheetah
    d=$O/product/app/KernelSUNext
    apk=$d/KernelSUNext.apk
    [[ -f "$apk" ]] || fail "the KernelSU Next manager isn't in the build (apply-ksu.sh, patches/device_google_pantah/0101)"
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
            || fail "${f#"$O"/} has no entry for $lib/libksud.so (TARGET_FS_CONFIG_GEN += device/google/pantah/ksu/config.fs missing?)"
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
    ;;
images)
    [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
    dir=$2
    eos_top "${3:-}"
    for i in init_boot vbmeta; do [[ -f "$dir/$i.img" ]] || fail "no $i.img in $dir"; done
    H=$top/out/host/linux-x86/bin
    unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I "$top/system/tools/mkbootimg/unpack_bootimg.py" "$@"; fi; }
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
    # Built for the kernel's struct module, as vendor_kernel_boot's modules are: 6.1 loads a
    # kernelsu.ko built for another one and crashes at boot (tools/ko-info.py)
    [[ -f "$dir/vendor_kernel_boot.img" ]] || fail "no vendor_kernel_boot.img in $dir"
    unpack --boot_img "$dir/vendor_kernel_boot.img" --out "$T/vkb" >/dev/null || fail "can't unpack $dir/vendor_kernel_boot.img"
    mkdir "$T/m"
    for rd in "$T"/vkb/vendor_ramdisk*; do   # vendor_ramdisk00, 01... (header v4) or vendor_ramdisk (v3)
        [[ -f $rd ]] || continue
        (cd "$T/m" && { lz4 -dc "$rd" 2>/dev/null || gzip -dc "$rd"; } \
            | cpio -id --quiet --no-absolute-filenames 'lib/modules/*.ko') \
            || fail "can't unpack ${rd##*/} from $dir/vendor_kernel_boot.img"
    done
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
