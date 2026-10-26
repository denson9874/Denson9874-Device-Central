#!/bin/bash
# Release checks for an ExpressiveOS cheetah build with KernelSU Next, for the
# kit's pack and OTA scripts. Fails (exit 1) on the first problem.
#
#   ksu-check.sh images <dir> --avb-key <pem> [top]
#       <dir> holds a full set of the build's images (a fastboot zip unpacked, or
#       out/target/product/cheetah): init_boot carries kernelsu.ko, the whole AVB
#       chain verifies (avbtool verify_image --follow_chain_partitions), and
#       vbmeta is signed by <pem>, ExpressiveOS's AVB key, not Evolution X's or
#       an AOSP test key.
#   ksu-check.sh manager [top]
#       the KernelSU Next manager is installed in the build, signed by the key
#       the kernel trusts (ksu.conf's manager_cert_sha256).
#   ksu-check.sh device-ok <zip>
#       <zip>.device-ok names <zip>'s sha256: someone flashed and tested it.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mode=${1:-}; shift || true
case "$mode" in
images)
    dir=${1:?}; [ "${2:-}" = --avb-key ] || fail "usage: ksu-check.sh images <dir> --avb-key <pem> [top]"
    key=${3:?}; top=${4:-$HOME/expressiveos}
    H=$top/out/host/linux-x86/bin
    unpack() { if [ -x $H/unpack_bootimg ]; then $H/unpack_bootimg "$@"; else python3 $top/system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
    unpack --boot_img "$dir/init_boot.img" --out $T/ib >/dev/null
    # Not grep -q: an early exit would kill cpio with SIGPIPE under pipefail
    mkdir $T/r; (cd $T/r && { lz4 -dc $T/ib/ramdisk 2>/dev/null || gzip -dc $T/ib/ramdisk; } | cpio -id --quiet 2>/dev/null) || true
    [ -f $T/r/kernelsu.ko ] || fail "$dir/init_boot.img has no kernelsu.ko"
    # Ours, not ksud's built-in module, which never crowns the preinstalled manager
    strings $T/r/kernelsu.ko | grep -x /product/app/KernelSUNext/KernelSUNext.apk >/dev/null \
        || fail "$dir/init_boot.img's kernelsu.ko isn't ExpressiveOS's (tools/ksu-module.sh)"
    echo "OK: init_boot carries ExpressiveOS's KernelSU Next module"
    $H/avbtool verify_image --image "$dir/vbmeta.img" --follow_chain_partitions > $T/avb.log 2>&1 \
        || { tail -5 $T/avb.log >&2; fail "avbtool verify_image failed on $dir"; }
    echo "OK: AVB chain verifies"
    [ -f "$key" ] || fail "no AVB key $key"
    sha1() { $H/avbtool extract_public_key --key "$1" --output $T/pk 2>/dev/null && sha1sum $T/pk | cut -d' ' -f1; }
    want=$(sha1 "$key")
    for t in "$top"/external/avb/test/data/testkey_rsa*.pem; do
        [ -f "$t" ] && [ "$(sha1 "$t")" = "$want" ] && fail "$key is an AOSP test key"
    done
    for e in ~/evolution/vendor/evolution-priv/keys/avb*.pem; do
        [ -f "$e" ] && [ "$(sha1 "$e")" = "$want" ] && fail "$key is Evolution X's AVB key ($e)"
    done
    have=$($H/avbtool info_image --image "$dir/vbmeta.img" | sed -n 's/^Public key (sha1): *//p')
    [ "$have" = "$want" ] || fail "vbmeta is signed by key sha1 ${have:-none}, want ExpressiveOS's $want"
    echo "OK: vbmeta signed by ExpressiveOS's AVB key ($want)"
    ;;
manager)
    top=${1:-$HOME/expressiveos}
    apk=$top/out/target/product/cheetah/product/app/KernelSUNext/KernelSUNext.apk
    [ -f "$apk" ] || fail "the KernelSU Next manager isn't installed (patches/device_google_pantah/0001)"
    want=$(sed -n 's/^manager_cert_sha256=//p' "$here/ksu.conf")
    have=$(python3 -I "$here/tools/apk-cert.py" "$apk") || fail "can't read $apk's signature"
    [ "$have" = "$want" ] || fail "$apk is signed by $have, the kernel trusts only $want (was it re-signed?)"
    echo "OK: KernelSU Next manager installed, signed by $have"
    ;;
device-ok)
    zip=${1:?}; m=$zip.device-ok
    sha=$(sha256sum "$zip" | cut -d' ' -f1)
    { [ -f "$m" ] && grep -q "$sha" "$m"; } || fail "not verified on a phone yet: flash and test $zip, then write $m with the line \"sha256 $sha\""
    echo "OK: on-device check: $(cat "$m")"
    ;;
*) fail "usage: ksu-check.sh images|manager|device-ok ..." ;;
esac
