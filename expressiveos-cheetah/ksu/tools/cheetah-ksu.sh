#!/usr/bin/env bash
# KernelSU Next init_boot for ExpressiveOS on a phone with EOS_KSU=lkm (EOS_DEVICE, cheetah
# unless set; the name is cheetah's, the first): patches the init_boot.img
# the first make pass just built (ksu-images.sh) with our own kernelsu.ko
# (ksu-module.sh) and ksuinit, using the host ksud from fetch-ksu.sh. The kernel stays
# Google's signed GKI; susfs is the guard module ksud loads at boot while SUSFS auto-load
# is on, which the first-boot setup (../tree/ksu-firstboot.sh) turns on for a new phone.
# ksu-images.sh then builds again with
# CHEETAH_KSU_INIT_BOOT=out/ksu/init_boot-ksu.img (patches/device_google_pantah/0102; another
# phone's EOS_KSU_INIT_BOOT=out/ksu-<device>/init_boot-ksu.img, its ksu-patches' 0102),
# so the images and the OTA ship it. The KMI is the phone's (EOS_KMI): with the kernel built
# from source (EOS_KERNEL=gs-6.1) it must be ksu.conf's, which kernelsu.ko is pinned for; with
# Google's prebuilt GKI (EOS_KERNEL=prebuilt, the Pixel 11s) ddk.conf must have a DDK for it, and
# kernelsu.ko must be built as the module ksud itself carries for that KMI. The last line is
# KSU_EXIT=0 or KSU_EXIT=1.
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
[[ $EOS_KSU = lkm ]] || fail "KernelSU Next is off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): its build ships the stock init_boot, there's nothing to patch"
eos_top "${1:-}"
# Run alone, this runs again under eos_lock (the locks eos-images.sh holds) and exits with it
run_locked KSU_EXIT=1 "$0" "$top"
cd "$top"
for c in lz4 cpio strings od; do command -v "$c" >/dev/null || fail "$c isn't installed"; done
O=$EOS_PRODUCT_OUT
H=out/host/linux-x86/bin
K=$EOS_KSU_OUT
in_top "$top/$K"
unpack() { if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" "$@"; else python3 -I system/tools/mkbootimg/unpack_bootimg.py "$@"; fi; }
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
version=$(get version); kmi=$EOS_KMI
if [[ $EOS_KERNEL = prebuilt ]]; then
    grep -q "^${kmi}_digest=" "$here/ddk.conf" || fail "ksu/ddk.conf has no DDK for $EOS_DEVICE's kernel, $kmi (devices/$EOS_DEVICE.conf)"
else
    [[ "$(get kmi)" = "$kmi" ]] || fail "ksu.conf's kmi is $(get kmi), but $EOS_DEVICE's kernel is $kmi (devices/$EOS_DEVICE.conf): its kernelsu.ko is built for that one"
fi
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
case $(head -c4 "$k" | od -An -tx1 | tr -d ' ') in
    02214c18) lz4 -dc "$k" > "$T/Image"; k=$T/Image ;;
    1f8b*) gzip -dc "$k" > "$T/Image"; k=$T/Image ;;
esac
# awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
uname=$(strings "$k" | awk '/^Linux version / && !f { print; f = 1 }')
[[ -n "$uname" ]] || fail "no Linux version string in boot.img's kernel"
grep -Eq "^Linux version ${kmi#*-}\.[0-9]+-${kmi%%-*}-" <<<"$uname" || fail "boot.img is '$uname', not $kmi"
echo "OK: boot.img kernel is $kmi (${uname:14:60})"
vermagic=$(strings "$ko" | sed -n 's/^vermagic=//p')
if [[ $EOS_KERNEL != prebuilt ]]; then
    # ...and our module must be built from the same sublevel, e.g. 6.1.145
    sub=$(grep -Eo "^Linux version ${kmi#*-}\.[0-9]+" <<<"$uname"); sub=${sub#Linux version }
    [[ "$vermagic" == "$sub"[-\ ]* ]] || fail "$ko is built for '$vermagic', boot.img's kernel is $sub (build_kernel synced another GKI?)"
    echo "OK: $ko matches ($vermagic)"
fi
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
r=$(python3 -I "$here/tools/ko-info.py" same-struct "$ko" "$mods") \
    || fail "$ko doesn't fit this kernel's struct module (tools/ksu-module.sh)"
echo "OK: $ko is built for the kernel's struct module (${r% *} bytes, as its ${r#* } first-stage modules)"
if [[ $EOS_KERNEL = prebuilt ]]; then
    # Built in the DDK, from its own GKI source: the sublevel and build in the release differ
    # from the phone's (6.12.76-4k against 6.12.69-android16-6-g...-4k), which the kernel
    # doesn't compare for a module with symbol versions (as Google's own vendor modules, built
    # from other GKI builds, load), and ksuinit replaces anyway. The rest must be the kernel's
    km=$(find "$mods" -name '*.ko' -print -quit)
    stock=$(strings "$km" | sed -n 's/^vermagic=//p')
    [[ $vermagic == "${kmi#*-}".* && "${vermagic#* }" = "${stock#* }" ]] \
        || fail "$ko is built for '$vermagic', this kernel's modules for '$stock'"
    echo "OK: $ko matches ($vermagic; this kernel's ${km##*/}: $stock)"
    # The DDK's config isn't Google's build's to the option (a later source, a config Google
    # changed since): built as the module ksud carries for this KMI, which KernelSU Next ships
    # to every phone on it, ours loads where that one does
    python3 -I "$here/tools/ko-info.py" embedded "$ksud" kernelsu "${kmi#*-}." "$T/ksud.ko" > /dev/null \
        || fail "$ksud carries no arm64 kernelsu.ko for $kmi"
    r=$(python3 -I "$here/tools/ko-info.py" like "$ko" "$T/ksud.ko") \
        || fail "$ko isn't built as ksud's own kernelsu.ko for $kmi (tools/ksu-module.sh, ddk.conf)"
    echo "OK: $ko is built as ksud's own module for $kmi (struct module ${r% *} bytes, vermagic, ${r#* } kernel symbols)"
    if ! python3 -I "$here/tools/ko-info.py" config-diff "$k" "$K/kbuild/.config" > "$T/config.diff"; then
        echo "NOTE: the DDK's config and boot.img's kernel differ in $(wc -l < "$T/config.diff") options (as for ksud's own module):"
        sed 's/^/NOTE:   /' "$T/config.diff"
    fi
else
    python3 -I "$here/tools/ko-info.py" config-diff "$k" "$K/kbuild/.config" > "$T/config.diff" \
        || { cat "$T/config.diff" >&2; fail "$K/kbuild/.config isn't boot.img's kernel config (tools/ksu-module.sh)"; }
    echo "OK: $ko was built with boot.img's kernel config"
fi

# The input must be this build's own init_boot, never one a previous run patched
ramdisk "$O/init_boot.img" "$T/stock"
[[ ! -e $T/stock/kernelsu.ko ]] || fail "$O/init_boot.img is already KernelSU-patched (make it again without $EOS_KSU_INIT_BOOT_VAR)"
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
