#!/usr/bin/env bash
# Release checks for an ExpressiveOS build with Wild Kernels' BakaSU kernel (a phone with
# EOS_KSU=wild; EOS_DEVICE, cheetah unless set), for the kit's verify and pack scripts. Stops at
# the first problem; the last line is KSU_CHECK=OK or KSU_CHECK=FAIL.
#
#   ksu-check.sh manager [top]
#       no root manager or old SukiSU first-boot setup is in the build: users install the BakaSU
#       APK they want themselves (ksu.conf's manager links, in the release notes).
#   ksu-check.sh images <dir> [top]
#       <dir> holds a full set of the build's images (a fastboot zip unpacked, or
#       out/target/product/<device>): boot.img's kernel is ksu.conf's Wild kernel for the
#       phone's KMI, init_boot is the stock one (init, no kernelsu.ko), the whole AVB chain
#       verifies with boot in it, and vbmeta is signed by the tree's own AVB key and nobody
#       else's (../../tools/eos-keys-check.sh vbmeta).
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

case "$mode" in
manager)
    [[ $# -le 2 ]] || fail "$usage"
    [[ $EOS_KSU = wild ]] || fail "Wild is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf)"
    eos_top "${2:-}"
    O=$top/$EOS_PRODUCT_OUT
    for f in product/etc/eos/sukisu-manager.apk product/etc/init/eos-ksu-firstboot.rc product/etc/eos/ksu-firstboot.sh; do
        [[ ! -e $O/$f ]] || fail "$f is in the build: no manager ships with Wild (users install BakaSU's APK), an old vendor/extra/ksu? (apply-ksu.sh removes it)"
    done
    echo "OK: no root manager or first-boot setup in the build (users install BakaSU themselves)"
    ;;
images)
    [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"
    dir=$2
    eos_top "${3:-}"
    for i in boot init_boot vbmeta; do [[ -f "$dir/$i.img" ]] || fail "no $i.img in $dir"; done
    H=$top/out/host/linux-x86/bin
    avbtool() { if [[ -x $H/avbtool ]]; then "$H/avbtool" "$@"; else python3 -I "$top/external/avb/avbtool.py" "$@"; fi; }
    want=$(get "uname_$EOS_KMI")
    [[ -n $want ]] || fail "ksu.conf has no uname_$EOS_KMI"
    unpack --boot_img "$dir/boot.img" --out "$T/b" >/dev/null || fail "can't unpack $dir/boot.img"
    k=$T/b/kernel
    [[ "$(head -c4 "$k" | od -An -tx1 | tr -d ' ')" != 02214c18 ]] || { lz4 -dc "$k" > "$T/Image"; k=$T/Image; }
    # awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
    got=$(strings "$k" | awk '/^Linux version / && !f { print $3; f = 1 }')
    [[ $got = "$want" ]] || fail "$dir/boot.img's kernel is Linux $got, not Wild's $want (EOS_WILD_BOOT, ksu-patches)"
    echo "OK: boot carries Wild $(get version)'s kernel (Linux $got)"
    unpack --boot_img "$dir/init_boot.img" --out "$T/ib" >/dev/null || fail "can't unpack $dir/init_boot.img"
    # Only the files checked here: the ramdisk's device nodes (dev/console...) need root to make
    mkdir "$T/r"
    (cd "$T/r" && { lz4 -dc "$T/ib/ramdisk" 2>/dev/null || gzip -dc "$T/ib/ramdisk"; } \
        | cpio -id --quiet --no-absolute-filenames init init.real kernelsu.ko) \
        || fail "can't unpack $dir/init_boot.img's ramdisk"
    [[ -e $T/r/init && ! -e $T/r/kernelsu.ko && ! -e $T/r/init.real ]] || fail "$dir/init_boot.img isn't the stock one (no init, or a KernelSU module in it): Wild's root is in the kernel"
    echo "OK: init_boot is the stock one"
    (cd "$dir" && avbtool verify_image --image vbmeta.img --follow_chain_partitions) > "$T/avb.log" 2>&1 \
        || { tail -5 "$T/avb.log" >&2; fail "avbtool verify_image failed on $dir"; }
    # verify_image only checks what vbmeta lists: boot must be one of them
    avbtool info_image --image "$dir/vbmeta.img" > "$T/avb.info" 2>&1 || fail "avbtool can't read $dir/vbmeta.img"
    grep -qE '^ +Partition Name: +boot$' "$T/avb.info" || fail "$dir/vbmeta.img doesn't cover boot"
    echo "OK: the AVB chain verifies, boot included"
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
