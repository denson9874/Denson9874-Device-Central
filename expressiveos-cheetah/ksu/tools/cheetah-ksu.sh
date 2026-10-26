#!/bin/bash
# KernelSU Next init_boot for ExpressiveOS on cheetah: patches the init_boot.img
# the first make pass just built (ksu-images.sh) with our own kernelsu.ko
# (ksu-module.sh) and ksuinit, using the host ksud from fetch-ksu.sh. The kernel stays Google's signed GKI; susfs is
# the guard module ksud loads at boot once the user turns on SUSFS auto-load in
# the manager. ksu-images.sh then builds again with
# CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img (patches/device_google_pantah/0002),
# so the images and the OTA ship it.
#
#   cheetah-ksu.sh [top]   # default ~/expressiveos; writes out/ksu/init_boot-{ksu,stock}.img
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "${1:-$HOME/expressiveos}"
O=out/target/product/cheetah
H=out/host/linux-x86/bin
K=out/ksu
conf=$here/ksu.conf
fail() { echo "FAIL: $*" >&2; exit 1; }
unpack() { if [ -x $H/unpack_bootimg ]; then $H/unpack_bootimg "$@"; else python3 system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
version=$(sed -n 's/^version=//p' $conf); kmi=$(sed -n 's/^kmi=//p' $conf)
ksud=~/android-dt/ksu/$version/ksud
[ -x "$ksud" ] || fail "no $ksud (run $here/fetch-ksu.sh)"
ko=$K/kernelsu.ko
[ -s $ko ] || fail "no $ko (run $here/tools/ksu-module.sh)"
[ -f $O/init_boot.img ] && [ -f $O/boot.img ] || fail "no init_boot.img or boot.img in $O"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ramdisk() {   # ramdisk <boot image> <dir>: unpack its ramdisk into <dir>
    unpack --boot_img "$1" --out $T/u >/dev/null
    mkdir -p "$2"; (cd "$2" && { lz4 -dc $T/u/ramdisk 2>/dev/null || gzip -dc $T/u/ramdisk; } | cpio -id --quiet)
    rm -rf $T/u
}

# kernelsu.ko only loads into the KMI it was built for: check boot.img's kernel
unpack --boot_img $O/boot.img --out $T/boot >/dev/null
k=$T/boot/kernel
[ "$(head -c4 $k | od -An -tx1 | tr -d ' ')" = 02214c18 ] && { lz4 -dc $k > $T/Image; k=$T/Image; }
# awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
uname=$(strings $k | awk '/^Linux version / && !f { print; f = 1 }')
[ -n "$uname" ] || fail "no Linux version string in boot.img's kernel"
grep -Eq "^Linux version ${kmi#*-}\.[0-9]+-${kmi%%-*}-" <<<"$uname" || fail "boot.img is '$uname', not $kmi"
echo "OK: boot.img kernel is $kmi (${uname:14:60})"
# ...and our module must be built from the same sublevel, e.g. 6.1.145
sub=$(grep -Eo "^Linux version ${kmi#*-}\.[0-9]+" <<<"$uname"); sub=${sub#Linux version }
vermagic=$(strings $ko | sed -n 's/^vermagic=//p')
[[ "$vermagic" == "$sub"[-\ ]* ]] || fail "$ko is built for '$vermagic', boot.img's kernel is $sub (build_kernel synced another GKI?)"
echo "OK: $ko matches ($vermagic)"

# The input must be this build's own init_boot, never one a previous run patched
ramdisk $O/init_boot.img $T/stock
[ -e $T/stock/kernelsu.ko ] && fail "$O/init_boot.img is already KernelSU-patched (make it again without CHEETAH_KSU_INIT_BOOT)"
mkdir -p $K; rm -f $K/init_boot-ksu.img $K/init_boot-stock.img
cp $O/init_boot.img $K/init_boot-stock.img
"$ksud" boot-patch -b $K/init_boot-stock.img --kmi "$kmi" -m $ko -o $K --out-name init_boot-ksu.img
[ -s $K/init_boot-ksu.img ] || fail "ksud wrote no init_boot-ksu.img"

# The patched ramdisk must hold ksuinit as init, the real init and the module
ramdisk $K/init_boot-ksu.img $T/ksu
for f in init init.real kernelsu.ko; do [ -e $T/ksu/$f ] || fail "init_boot-ksu.img's ramdisk has no $f"; done
cmp -s $T/stock/init $T/ksu/init.real || fail "init_boot-ksu.img's init.real isn't this build's init"
cmp -s $ko $T/ksu/kernelsu.ko || fail "init_boot-ksu.img's kernelsu.ko isn't $ko"
echo "$version $kmi $(cat $ko.info 2>/dev/null)" > $K/VERSION
echo "OK: $K/init_boot-ksu.img (KernelSU Next $version, $kmi)"
echo "KSU_EXIT=0"
