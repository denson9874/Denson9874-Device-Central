#!/usr/bin/env bash
# KernelSU Next init_boot for ExpressiveOS on cheetah: patches the init_boot.img
# the first make pass just built (ksu-images.sh) with our own kernelsu.ko
# (ksu-module.sh) and ksuinit, using the host ksud from fetch-ksu.sh. The kernel stays
# Google's signed GKI; susfs is the guard module ksud loads at boot once the user turns
# on SUSFS auto-load in the manager. ksu-images.sh then builds again with
# CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img (patches/device_google_pantah/0102),
# so the images and the OTA ship it. The last line is KSU_EXIT=0 or KSU_EXIT=1.
#
#   cheetah-ksu.sh [top]   # default ~/expressiveos; writes out/ksu/init_boot-{ksu,stock}.img
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
eos_top "${1:-}"
# Run alone, this runs again under eos_lock (the locks eos-images.sh holds) and exits with it
run_locked KSU_EXIT=1 "$0" "$top"
cd "$top"
for c in lz4 cpio strings od; do command -v "$c" >/dev/null || fail "$c isn't installed"; done
O=out/target/product/cheetah
H=out/host/linux-x86/bin
K=out/ksu
in_top "$top/$K"
unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
version=$(get version); kmi=$(get kmi)
ksud=$HOME/android-dt/ksu/$version/ksud
[[ -x "$ksud" ]] || fail "no $ksud (run $here/fetch-ksu.sh)"
[[ "$(sha256sum -- "$ksud" | cut -d' ' -f1)" = "$(get ksud_sha256)" ]] || fail "$ksud isn't ksu.conf's ksud_sha256 (run fetch-ksu.sh)"
ko=$K/kernelsu.ko
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
# ...and our module must be built from the same sublevel, e.g. 6.1.145
sub=$(grep -Eo "^Linux version ${kmi#*-}\.[0-9]+" <<<"$uname"); sub=${sub#Linux version }
vermagic=$(strings "$ko" | sed -n 's/^vermagic=//p')
[[ "$vermagic" == "$sub"[-\ ]* ]] || fail "$ko is built for '$vermagic', boot.img's kernel is $sub (build_kernel synced another GKI?)"
echo "OK: $ko matches ($vermagic)"
# ...and for its struct module, with its config. kernelsu.ko has no symbol versions, so 6.1
# loads one built for another struct module and crashes reading past it: the first build
# did, its module built without pahole (2026-10-26). The first-stage modules in this build
# were built with the kernel's own config
r=$(python3 -I "$here/tools/ko-info.py" same-struct "$ko" "$O/vendor_kernel_ramdisk/lib/modules") \
    || fail "$ko doesn't fit this kernel's struct module (tools/ksu-module.sh)"
echo "OK: $ko is built for the kernel's struct module (${r% *} bytes, as its ${r#* } first-stage modules)"
python3 -I "$here/tools/ko-info.py" config-diff "$k" "$K/kbuild/.config" > "$T/config.diff" \
    || { cat "$T/config.diff" >&2; fail "$K/kbuild/.config isn't boot.img's kernel config (tools/ksu-module.sh)"; }
echo "OK: $ko was built with boot.img's kernel config"

# The input must be this build's own init_boot, never one a previous run patched
ramdisk "$O/init_boot.img" "$T/stock"
[[ ! -e $T/stock/kernelsu.ko ]] || fail "$O/init_boot.img is already KernelSU-patched (make it again without CHEETAH_KSU_INIT_BOOT)"
mkdir -p -- "$K"; rm -f -- "$K/init_boot-ksu.img" "$K/init_boot-stock.img" "$K/VERSION"
cp -- "$O/init_boot.img" "$K/init_boot-stock.img"
"$ksud" boot-patch -b "$K/init_boot-stock.img" --kmi "$kmi" -m "$ko" -o "$K" --out-name init_boot-ksu.img \
    || fail "ksud boot-patch failed"
[[ -s $K/init_boot-ksu.img ]] || fail "ksud wrote no init_boot-ksu.img"

# The patched ramdisk must hold ksuinit as init, the real init and the module
ramdisk "$K/init_boot-ksu.img" "$T/ksu"
for f in init init.real kernelsu.ko; do [[ -e $T/ksu/$f ]] || fail "init_boot-ksu.img's ramdisk has no $f"; done
cmp -s -- "$T/stock/init" "$T/ksu/init.real" || fail "init_boot-ksu.img's init.real isn't this build's init"
cmp -s -- "$ko" "$T/ksu/kernelsu.ko" || fail "init_boot-ksu.img's kernelsu.ko isn't $ko"
echo "$version $kmi $(cat "$ko.info" 2>/dev/null)" > "$K/VERSION"
echo "OK: $K/init_boot-ksu.img (KernelSU Next $version, $kmi)"
done=1
echo "KSU_EXIT=0"
