#!/usr/bin/env bash
# Release checks for an ExpressiveOS build with SukiSU (a phone with EOS_KSU=lkm; EOS_DEVICE,
# cheetah unless set), for the kit's verify and pack scripts. Stops at the first problem; the
# last line is KSU_CHECK=OK or KSU_CHECK=FAIL.
#
#   ksu-check.sh manager [top]
#       the manager is in the build as fetch-ksu.sh downloaded it: ksu.conf's APK byte for byte
#       at product/etc/eos/sukisu-manager.apk (so it keeps the signature the kernel trusts), and
#       the first-boot setup that installs it is the kit's (tree/eos-ksu-firstboot.rc,
#       tree/ksu-firstboot.sh).
#   ksu-check.sh images <dir> [top]
#       <dir> holds a full set of the build's images (a fastboot zip unpacked, or
#       out/target/product/<device>): init_boot carries SukiSU's ksuinit and a kernelsu.ko of
#       ksu.conf's version, built for the same struct module as vendor_kernel_boot's modules,
#       with the init.rc lines the first-boot setup relies on (the ksu domain), the whole AVB
#       chain verifies, and vbmeta is signed by the tree's own AVB key and nobody else's
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
    [[ $EOS_KSU = lkm ]] || fail "SukiSU is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): its build has no manager to check"
    eos_top "${2:-}"
    O=$top/$EOS_PRODUCT_OUT
    apk=$O/product/etc/eos/sukisu-manager.apk
    # The device tree patch that adds it: cheetah's in ../patches/, another phone's in devices/<device>/ksu-patches/
    if [[ $EOS_DEVICE = cheetah ]]; then p0101=ksu/patches/device_google_pantah/0101; else p0101="devices/$EOS_DEVICE/ksu-patches/*/0101"; fi
    [[ -f "$apk" ]] || fail "SukiSU's manager isn't in the build (apply-ksu.sh, $p0101)"
    [[ "$(sha256sum -- "$apk" | cut -d' ' -f1)" = "$(get manager_sha256)" ]] \
        || fail "$apk isn't ksu.conf's manager APK byte for byte: the build changed it"
    want=$(get manager_cert_sha256)
    have=$(python3 -I "$here/tools/apk-cert.py" "$apk") || fail "can't read $apk's signature"
    [[ "$have" = "$want" ]] || fail "$apk is signed by $have; the kernel trusts only $want"
    echo "OK: the manager is ksu.conf's APK, signed by $have"
    for f in etc/init/eos-ksu-firstboot.rc etc/eos/ksu-firstboot.sh; do
        cmp -s -- "$O/product/$f" "$here/tree/${f##*/}" || fail "product/$f isn't the kit's tree/${f##*/} (apply-ksu.sh, tree/Android.mk)"
    done
    echo "OK: the first-boot setup is the kit's"
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
        | cpio -id --quiet --no-absolute-filenames init init.real kernelsu.ko) \
        || fail "can't unpack $dir/init_boot.img's ramdisk"
    [[ -f "$T/r/kernelsu.ko" ]] || fail "$dir/init_boot.img has no kernelsu.ko (pass 2 shipped the stock init_boot?)"
    [[ -e "$T/r/init.real" ]] || fail "$dir/init_boot.img has kernelsu.ko but no init.real: cheetah-ksu.sh didn't patch it"
    # ksu.conf's SukiSU: its version and manager (the version must match the manager's)
    strings "$T/r/kernelsu.ko" | grep -F "version $(get version_code), package name $(get manager_package)" >/dev/null \
        || fail "$dir/init_boot.img's kernelsu.ko isn't SukiSU $(get version_code) for $(get manager_package)"
    echo "OK: init_boot carries SukiSU $(get version) ($(get version_code))"
    ksuinit=$HOME/android-dt/ksu/$(get version)/$(get ksuinit_file)
    if [[ -f $ksuinit ]]; then
        cmp -s -- "$ksuinit" "$T/r/init" || fail "$dir/init_boot.img's init isn't SukiSU's ksuinit ($ksuinit)"
    else
        [[ "$(sha256sum -- "$T/r/init" | cut -d' ' -f1)" = "$(get ksuinit_sha256)" ]] || fail "$dir/init_boot.img's init isn't ksu.conf's ksuinit"
    fi
    # The first-boot setup's services run in the domain these lines run ksud in, and put
    # ksud where they look for it (tree/eos-ksu-firstboot.rc)
    for stage in post-fs-data services boot-completed; do
        grep -aqF -- "exec u:r:ksu:s0 root -- /data/adb/ksud $stage" "$T/r/kernelsu.ko" \
            || fail "kernelsu.ko no longer runs '/data/adb/ksud $stage' in u:r:ksu:s0: check tree/eos-ksu-firstboot.rc against this SukiSU"
    done
    echo "OK: kernelsu.ko runs /data/adb/ksud in u:r:ksu:s0, as the first-boot setup expects"
    # Built for the kernel's struct module, as vendor_kernel_boot's modules are: 6.1 loads a
    # kernelsu.ko built for another one and crashes at boot (tools/ko-info.py)
    [[ -f "$dir/vendor_kernel_boot.img" ]] || fail "no vendor_kernel_boot.img in $dir"
    kernel_modules "$dir/vendor_kernel_boot.img" "$T/m"
    r=$(python3 -I "$kit/tools/ko-info.py" same-struct "$T/r/kernelsu.ko" "$T/m") \
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
