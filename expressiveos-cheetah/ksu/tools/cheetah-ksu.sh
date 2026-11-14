#!/usr/bin/env bash
# SukiSU init_boot for ExpressiveOS on a phone with EOS_KSU=lkm (EOS_DEVICE, cheetah unless set;
# the name is cheetah's, the first): patches the init_boot.img the first make pass just built
# (eos-make.sh) as SukiSU's ksud boot-patch does (ramdisk-ksu.py: ksuinit as /init, the real one
# as /init.real, and kernelsu.ko), then packs it again with the tree's mkbootimg. The module is
# our own on a phone whose kernel we build (EOS_KERNEL=gs-6.1: ksu-module.sh), SukiSU's release
# module for the phone's KMI on one with Google's prebuilt GKI (fetch-ksu.sh). The kernel stays
# Google's signed GKI. eos-make.sh then builds again with CHEETAH_KSU_INIT_BOOT=
# out/ksu/init_boot-ksu.img (patches/device_google_pantah/0102; another phone's
# EOS_KSU_INIT_BOOT=out/ksu-<device>/init_boot-ksu.img, its ksu-patches' 0102), so the images
# and the OTA ship it, signed with the tree's init_boot AVB key. The last line is KSU_EXIT=0 or
# KSU_EXIT=1.
#
#   cheetah-ksu.sh [top]   # default ~/expressiveos; writes EOS_KSU_OUT's init_boot-{ksu,stock}.img
#                          # (out/ksu/ for cheetah, out/ksu-<device>/ for another phone)
set -euo pipefail
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    # Quiet while run_locked's marker is there: the run waiting for the locks prints it then
    [[ $done = 1 || -e "${EOS_STARTED:-}" ]] || echo "KSU_EXIT=1"
    exit $rc
}
trap cleanup EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
# shellcheck source=../../lib.sh
source "$here/../lib.sh"
[[ $# -le 1 ]] || fail "usage: cheetah-ksu.sh [top]"
[[ $EOS_KSU = lkm ]] || fail "SukiSU is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): its build ships the stock init_boot, there's nothing to patch"
eos_top "${1:-}"
# Run alone, this runs again under eos_lock (the locks eos-images.sh holds) and exits with it
run_locked KSU_EXIT=1 "$0" "$top"
cd "$top"
for c in lz4 cpio strings od python3; do command -v "$c" >/dev/null || fail "$c isn't installed"; done
O=$EOS_PRODUCT_OUT
H=out/host/linux-x86/bin
K=$EOS_KSU_OUT
in_top "$top/$K"
unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
mkboot() { if [[ -x $H/mkbootimg ]]; then "$H/mkbootimg" "$@"; else python3 -I system/tools/mkbootimg/mkbootimg.py "$@"; fi; }
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
version=$(get version); kmi=$EOS_KMI
dl=$HOME/android-dt/ksu/$version
ksuinit=$dl/$(get ksuinit_file)
[[ -s "$ksuinit" && "$(sha256sum -- "$ksuinit" | cut -d' ' -f1)" = "$(get ksuinit_sha256)" ]] \
    || fail "$ksuinit isn't ksu.conf's ksuinit_sha256 (run $here/fetch-ksu.sh)"
ko=$K/kernelsu.ko
mkdir -p -- "$K"
if [[ $EOS_KERNEL = prebuilt ]]; then
    # Google's GKI: SukiSU's release module for this KMI, as fetch-ksu.sh checked it
    rel=$dl/$(get "ko_${kmi}_file")
    [[ -n "$(get "ko_${kmi}_file")" ]] || fail "ksu.conf has no ko_${kmi}_file: SukiSU's release module for $EOS_DEVICE's $kmi GKI"
    [[ -s "$rel" && "$(sha256sum -- "$rel" | cut -d' ' -f1)" = "$(get "ko_${kmi}_sha256")" ]] \
        || fail "$rel isn't ksu.conf's ko_${kmi}_sha256 (run $here/fetch-ksu.sh)"
    cp -- "$rel" "$ko"
    echo "$version $(get version_code) release ${rel##*/}" > "$ko.info"
fi
[[ -s $ko ]] || fail "no $ko (run $here/tools/ksu-module.sh)"
[[ -f $O/init_boot.img && -f $O/boot.img ]] || fail "no init_boot.img or boot.img in $O"
T=$(mktemp -d "${TMPDIR:-/tmp}/cheetah-ksu.XXXXXX")
ramdisk() {   # ramdisk <boot image> <dir>: unpack init, init.real and kernelsu.ko from its ramdisk into <dir>
    unpack --boot_img "$1" --out "$T/u" >/dev/null || fail "can't unpack $1"
    mkdir -p "$2"
    # Only the files the checks read: an Android ramdisk also holds device nodes (dev/console,
    # dev/null...), and making those needs root
    (cd "$2" && { lz4 -dc "$T/u/ramdisk" 2>/dev/null || gzip -dc "$T/u/ramdisk"; } \
        | cpio -id --quiet --no-absolute-filenames init init.real kernelsu.ko) \
        || fail "can't unpack $1's ramdisk"
    rm -rf -- "$T/u"
}

# kernelsu.ko only loads into the KMI it was built for: check boot.img's kernel
unpack --boot_img "$O/boot.img" --out "$T/boot" >/dev/null || fail "can't unpack $O/boot.img"
k=$T/boot/kernel
[[ "$(head -c4 "$k" | od -An -tx1 | tr -d ' ')" != 02214c18 ]] || { lz4 -dc "$k" > "$T/Image"; k=$T/Image; }
# awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
uname=$(strings "$k" | awk '/^Linux version / && !f { print; f = 1 }')
[[ -n "$uname" ]] || fail "no Linux version string in boot.img's kernel"
grep -Eq "^Linux version ${kmi#*-}\.[0-9]+-${kmi%%-*}-" <<<"$uname" || fail "boot.img is '$uname', not $kmi"
echo "OK: boot.img kernel is $kmi (${uname:14:60})"
# ...and our module must be built from the same sublevel, e.g. 6.1.145. SukiSU's release module
# is built for the KMI (its symbol CRCs are the KMI's), not for Google's sublevel
sub=$(grep -Eo "^Linux version ${kmi#*-}\.[0-9]+" <<<"$uname"); sub=${sub#Linux version }
vermagic=$(strings "$ko" | sed -n 's/^vermagic=//p')
if [[ $EOS_KERNEL = prebuilt ]]; then
    [[ "$vermagic" == "${kmi#*-}".* ]] || fail "$ko is built for '$vermagic', not $kmi"
else
    [[ "$vermagic" == "$sub"[-\ ]* ]] || fail "$ko is built for '$vermagic', boot.img's kernel is $sub (build_kernel synced another GKI?)"
fi
echo "OK: $ko matches ($vermagic)"
# ...and for its struct module, with its config. kernelsu.ko has no symbol versions, so 6.1
# loads one built for another struct module and crashes reading past it: the first build
# did, its module built without pahole (2026-10-26). The first-stage modules in this build
# were built with the kernel's own config. A tree that doesn't stage them in out/ has them in
# its vendor_kernel_boot.img's ramdisk, read as ksu-check.sh does
mods=$O/vendor_kernel_ramdisk/lib/modules
if [[ ! -d $mods ]]; then
    [[ -f $O/vendor_kernel_boot.img ]] || fail "no $mods or $O/vendor_kernel_boot.img: no first-stage modules to compare $ko with"
    unpack --boot_img "$O/vendor_kernel_boot.img" --out "$T/vkb" >/dev/null || fail "can't unpack $O/vendor_kernel_boot.img"
    mkdir -p -- "$T/vkm"
    for rd in "$T"/vkb/vendor_ramdisk*; do   # vendor_ramdisk00, 01... (header v4) or vendor_ramdisk (v3)
        [[ -f $rd ]] || continue
        (cd "$T/vkm" && { lz4 -dc "$rd" 2>/dev/null || gzip -dc "$rd"; } \
            | cpio -id --quiet --no-absolute-filenames 'lib/modules/*.ko') \
            || fail "can't unpack ${rd##*/} from $O/vendor_kernel_boot.img"
    done
    rm -rf -- "$T/vkb"
    mods=$T/vkm
fi
r=$(python3 -I "$kit/tools/ko-info.py" same-struct "$ko" "$mods") \
    || fail "$ko doesn't fit this kernel's struct module (tools/ksu-module.sh)"
echo "OK: $ko is built for the kernel's struct module (${r% *} bytes, as its ${r#* } first-stage modules)"
if [[ $EOS_KERNEL != prebuilt ]]; then
    python3 -I "$kit/tools/ko-info.py" config-diff "$k" "$K/kbuild/.config" > "$T/config.diff" \
        || { cat "$T/config.diff" >&2; fail "$K/kbuild/.config isn't boot.img's kernel config (tools/ksu-module.sh)"; }
    echo "OK: $ko was built with boot.img's kernel config"
fi

# The input must be this build's own init_boot, never one a previous run patched
ramdisk "$O/init_boot.img" "$T/stock"
[[ ! -e $T/stock/kernelsu.ko ]] || fail "$O/init_boot.img is already KernelSU-patched (make it again without $EOS_KSU_INIT_BOOT_VAR)"
rm -f -- "$K/init_boot-ksu.img" "$K/init_boot-stock.img" "$K/VERSION"
cp -- "$O/init_boot.img" "$K/init_boot-stock.img"
# The ramdisk as SukiSU's ksud boot-patch leaves it, packed with the stock ramdisk's compression
# (lz4 legacy, as the build makes it) into an image with the stock header's own arguments
unpack --boot_img "$K/init_boot-stock.img" --out "$T/ib" --format=mkbootimg > "$T/ib.args" || fail "can't unpack $K/init_boot-stock.img"
lz4 -t "$T/ib/ramdisk" 2>/dev/null || fail "$O/init_boot.img's ramdisk isn't lz4: ramdisk-ksu.py's repack would change its compression"
lz4 -dc "$T/ib/ramdisk" > "$T/stock.cpio" || fail "can't decompress the stock ramdisk"
python3 -I "$here/tools/ramdisk-ksu.py" "$T/stock.cpio" "$T/ksu.cpio" "$ksuinit" "$ko" || fail "ramdisk-ksu.py failed"
lz4 -l -12 --favor-decSpeed -c "$T/ksu.cpio" > "$T/ramdisk.lz4" || fail "lz4 failed"
grep -q -- '--ramdisk ' "$T/ib.args" || fail "unpack_bootimg's mkbootimg arguments name no ramdisk: $(cat "$T/ib.args")"
eval "args=($(cat "$T/ib.args"))"
for i in "${!args[@]}"; do [[ ${args[$i]} != --ramdisk ]] || args[$((i + 1))]=$T/ramdisk.lz4; done
mkboot "${args[@]}" --output "$K/init_boot-ksu.img" || fail "mkbootimg failed"
[[ -s $K/init_boot-ksu.img ]] || fail "mkbootimg wrote no init_boot-ksu.img"
# The same header as the stock image (version, OS version and patch level) apart from the ramdisk
unpack --boot_img "$K/init_boot-ksu.img" --out "$T/ib2" --format=mkbootimg > "$T/ib2.args" || fail "can't unpack init_boot-ksu.img"
[[ "$(sed "s#$T/ib2/#X/#g" "$T/ib2.args")" = "$(sed "s#$T/ib/#X/#g" "$T/ib.args")" ]] \
    || fail "init_boot-ksu.img's header isn't the stock one's: $(cat "$T/ib2.args") vs $(cat "$T/ib.args")"

# The patched ramdisk must hold ksuinit as init, the real init and the module
ramdisk "$K/init_boot-ksu.img" "$T/ksu"
for f in init init.real kernelsu.ko; do [[ -e $T/ksu/$f ]] || fail "init_boot-ksu.img's ramdisk has no $f"; done
cmp -s -- "$T/stock/init" "$T/ksu/init.real" || fail "init_boot-ksu.img's init.real isn't this build's init"
cmp -s -- "$ko" "$T/ksu/kernelsu.ko" || fail "init_boot-ksu.img's kernelsu.ko isn't $ko"
cmp -s -- "$ksuinit" "$T/ksu/init" || fail "init_boot-ksu.img's init isn't SukiSU's ksuinit"
echo "$version $kmi $(cat "$ko.info" 2>/dev/null)" > "$K/VERSION"
echo "OK: $K/init_boot-ksu.img (SukiSU $version, $kmi)"
done=1
echo "KSU_EXIT=0"
