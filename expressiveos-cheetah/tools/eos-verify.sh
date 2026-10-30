#!/usr/bin/env bash
# Check a finished ExpressiveOS build of a phone (EOS_DEVICE, cheetah unless set;
# devices/<device>.conf) offline, before anything is packed or published. eos-images.sh
# runs it as its last step; it can also run alone after a build.
# Stops at the first problem. Prints "VERIFIED <OTA package>" and, last, VERIFY=OK;
# otherwise the last line is VERIFY=FAIL.
#
#   eos-verify.sh [top]      # default ~/expressiveos
#
#   1. the package: one ExpressiveOS-17.x-<date>-<device>-<version>-<type>.zip in out/, the
#      build's own, A/B, for the phone;
#   2. identity: the phone (EOS_MODEL), a user build, every kit patch in its project
#      (kit_patch_dirs), the Updater (EOS_UPDATER_OVERLAY) on ExpressiveOS's feed and
#      never Evolution X's, SCONE (EOS_SCONE_PATCH) and SystemUIGoogle's odex
#      (EOS_SYSUI_ODEX) where the phone ships them;
#   3. keys: eos-keys-check.sh out, and the package's zip and payload signatures verify
#      against the one certificate the build trusts for updates, which is the pinned one;
#      update_engine checks payload signatures again (and refuses older builds, and checks
#      in recovery too, with patches/system_update_engine 0002 and 0003);
#   4. the payload: every partition the build lists plus the firmware (EOS_FIRMWARE); its
#      init_boot carries the same ramdisk as out/ (KernelSU Next's, or with EOS_KSU=none
#      the build's own); its vbmeta (and every partition it chains), boot, init_boot and
#      vbmeta_system are ExpressiveOS's; its patch levels are the build's; the
#      target-files zip kept with it, for incremental OTAs, is its own (eos-target-files.sh);
#   5. EOS_KSU=lkm: KernelSU Next (ksu-check.sh manager and images), and the stock
#      init_boot kept for users who want no root (no kernelsu.ko, signed with the tree's
#      key); EOS_KSU=none: out/'s init_boot is that stock one;
#   6. ViPER4Android (v4a-check.sh out; with EOS_V4A=0, none of its files shipped), the
#      boot animation (bootanim.conf's zip, no other styles) and the wallpaper
#      (wallpapers.conf's default on ro.config.wallpaper, the theme from the wallpaper);
#   7. branding: no app, framework string or crash report header names Evolution X
#      (brand-check.py), apart from the few links it lists on purpose;
#   8. firmware (EOS_RADIO_MK) and the fastboot files the pack script reads (super_empty.img
#      from out/, or with EOS_SUPER_EMPTY=factory from the newest factory image zip).
set -euo pipefail
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "VERIFY=FAIL"
    exit $rc
}
trap cleanup EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
[[ $# -le 1 ]] || fail "usage: eos-verify.sh [top]"
eos_top "${1:-}"
cd "$top"
O=$EOS_PRODUCT_OUT
H=out/host/linux-x86/bin
# check_ota_package_signature runs delta_generator from its own folder
for t in avbtool ota_extractor check_ota_package_signature delta_generator unpack_bootimg; do
    [[ -x $H/$t ]] || fail "no $H/$t (m evolution builds it)"
done
# Only a build in this tree changes out/ under the checks
b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"
# The phone's firmware partitions (EOS_FIRMWARE), flashed from radio/ (EOS_RADIO_MK: the
# vendor repo's Android.mk, or the Pixel 11s' vendor/google/<device>-images/Android.mk,
# which lists the stock vendor_kernel_boot the same way)
FIRMWARE=$EOS_FIRMWARE
radio=$(grep -oE 'radio/[a-z0-9_]+\.img,[0-9a-f]{40}' "$EOS_RADIO_MK" || true)
for f in $FIRMWARE; do
    grep -q "^radio/$f\.img," <<<"$radio" || fail "$EOS_RADIO_MK doesn't list radio/$f.img with its sha1"
done
T=$(mktemp -d "${TMPDIR:-/tmp}/eos-verify.XXXXXX")
prop() {   # prop <name>: its value in the first of the build's build.props that sets it
    local f
    for f in "$O"/system/build.prop "$O"/system_ext/etc/build.prop "$O"/product/etc/build.prop "$O"/vendor/build.prop; do
        [[ -f $f ]] && grep -q "^$1=" "$f" && { sed -n "/^${1//./\\.}=/{s/^[^=]*=//p;q}" "$f"; return; }
    done
    true
}
checked() {   # checked <title> <regex> <command>...: run it quietly; its last line must match
    local title=$1 want=$2
    shift 2
    "$@" > "$T/sub.log" 2>&1 || true
    tail -1 "$T/sub.log" | grep -qxE -- "$want" || { grep -E '^(FAIL|WARNING)' "$T/sub.log" >&2 || tail -5 "$T/sub.log" >&2; fail "$title"; }
    grep -E '^(OK|PASS|UNPINNED|WARNING|note)' "$T/sub.log" || true
}

echo "== package"
ver=$(prop ro.evolution.build.version)
[[ "$ver" =~ ^ExpressiveOS-17\.[0-9]+-[0-9]{8}-$EOS_DEVICE-${EOS_VERSION//./\\.}-$EOS_BUILD_TYPE$ ]] \
    || fail "ro.evolution.build.version is '$ver', not ExpressiveOS-17.x-<date>-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE"
ota=$O/$ver.zip
[[ -f $ota ]] || fail "no $ota (m evolution makes it)"
others=$(find "$O" -maxdepth 1 -name 'ExpressiveOS-*.zip' ! -name "$ver.zip" -printf '%f ')
[[ -z "$others" ]] || fail "out/ also holds $others; it must hold only this build's package"
unzip -p -- "$ota" META-INF/com/android/metadata > "$T/metadata" || fail "$ota has no OTA metadata"
grep -qx "ota-type=AB" "$T/metadata" || fail "$ota isn't an A/B package"
grep -qx "pre-device=$EOS_DEVICE" "$T/metadata" || fail "$ota isn't for $EOS_DEVICE"
ts=$(sed -n 's/^post-timestamp=//p' "$T/metadata")
[[ -n "$ts" && "$ts" = "$(prop ro.build.date.utc)" ]] || fail "$ota isn't from this build (post-timestamp '$ts', build date $(prop ro.build.date.utc))"
echo "OK: $ver.zip ($(stat -c %s "$ota") bytes), A/B, $EOS_DEVICE, built $(date -ud "@$ts" '+%F %T') UTC"

echo "== identity"
for kv in "ro.product.product.device=$EOS_DEVICE" "ro.product.product.model=$EOS_MODEL" "ro.product.vendor.device=$EOS_DEVICE" \
          "ro.evolution.device=$EOS_DEVICE" ro.build.type=user; do
    [[ "$(prop "${kv%%=*}")" = "${kv#*=}" ]] || fail "${kv%%=*} is '$(prop "${kv%%=*}")', want '${kv#*=}'"
done
# A tree with a board-info file writes 'require board=<boards>' (pantah: cheetah|panther); the
# Pixel 11 trees have none, and the build writes 'board=<device>'. eos-pack.sh makes either
# 'require board=<device>'
grep -qE '^(require )?board=' "$O/android-info.txt" || fail "no 'require board=' or 'board=' in $O/android-info.txt"
echo "OK: $EOS_DEVICE, $EOS_MODEL, user build"
n=0
# The shared patches/, ksu/ and viper4android/ ones, then the phone's own devices/<device>/
mapfile -t dirs < <(kit_patch_dirs)
for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    # Only those this phone's build applies: KernelSU Next's as apply-ksu.sh picks them
    # (cheetah's ksu/patches/, another phone's devices/<device>/ksu-patches/, none with
    # EOS_KSU=none), ViPER4Android's with EOS_V4A=1 only (eos-images.sh)
    case $d in
        "$kit"/ksu/patches/*) [[ $EOS_KSU = lkm && $EOS_DEVICE = cheetah ]] || continue ;;
        "$kit/devices/$EOS_DEVICE"/ksu-patches/*) [[ $EOS_KSU = lkm && $EOS_DEVICE != cheetah ]] || continue ;;
        "$kit"/viper4android/patches/*) [[ $EOS_V4A = 1 ]] || continue ;;
    esac
    p=$(patch_project "$d")
    [[ -d $p ]] || fail "${d#"$kit"/} patches $p, which this tree doesn't have"
    git -C "$p" log --format=%s > "$T/log" || fail "can't read $p's log"
    for f in "$d"/*.patch; do
        s=$(subject_of "$f")
        grep -qxF -- "$s" "$T/log" || fail "$p lacks the kit's '$s' (${f#"$kit"/}): this build isn't the kit's"
        n=$((n + 1))
    done
done
echo "OK: all $n kit patches are in their projects"
ovl=$(find "$O/product/overlay" -name "$EOS_UPDATER_OVERLAY.apk" -print -quit 2>/dev/null || true)
[[ -n "$ovl" ]] || fail "no $EOS_UPDATER_OVERLAY.apk under $O/product/overlay"
python3 -I - "$ovl" "$EOS_UPDATER_OVERLAY" <<'EOF' || fail "the Updater doesn't read ExpressiveOS's feed only"
import sys, zipfile
arsc = zipfile.ZipFile(sys.argv[1]).read('resources.arsc')
def has(s):
    return s.encode() in arsc or s.encode('utf-16-le') in arsc
if not has('https://raw.githubusercontent.com/denson9874/expressiveos_ota/main/builds/{device}.json'):
    sys.exit('FAIL: %s has no denson9874/expressiveos_ota/main feed URL' % sys.argv[2])
if has('evolution_ota'):
    sys.exit('FAIL: %s names evolution_ota' % sys.argv[2])
EOF
echo "OK: the Updater reads denson9874/expressiveos_ota/main"
# Where the phone ships them as stock does: the SCONE module its kit patch names
# (EOS_SCONE_PATCH), and SystemUIGoogle's odex on /system_ext (EOS_SYSUI_ODEX=1)
short() { local b=${1##*/} d=${1#"$kit"/}; printf '%s/%s\n' "${d%/*}" "${b%%-*}"; }   # patches/device_google_pantah/0004
shipped=()
if [[ -n ${EOS_SCONE_PATCH:-} ]]; then
    sp=$(short "$EOS_SCONE_PATCH")
    [[ -f $kit/$EOS_SCONE_PATCH ]] || fail "no $EOS_SCONE_PATCH in the kit (devices/$EOS_DEVICE.conf's EOS_SCONE_PATCH)"
    scone=$(grep -m1 -oE 'SCONE-v[0-9]+' "$kit/$EOS_SCONE_PATCH" || true)
    [[ -n "$scone" ]] || fail "$sp names no SCONE-v<n> module"
    [[ -f $O/product/priv-app/$scone/$scone.apk ]] || fail "$scone isn't installed ($sp)"
    shipped+=("SCONE installed")
fi
if [[ $EOS_SYSUI_ODEX = 1 ]]; then
    if [[ ! -d $O/system_ext/priv-app/SystemUIGoogle/oat/arm64 ]]; then
        # Named after the kit patch that keeps it there (pantah's 0007), the phone's own if it has one
        op="devices/$EOS_DEVICE.conf: EOS_SYSUI_ODEX=1"
        for d in "${dirs[@]}"; do
            for f in "$d"/*-keep-app-odex-on-system-*.patch; do
                if [[ -f $f ]]; then op=$(short "$f"); fi
            done
        done
        fail "SystemUIGoogle's odex isn't on /system_ext ($op)"
    fi
    shipped+=("SystemUIGoogle odex on /system_ext")
fi
if (( ${#shipped[@]} > 0 )); then
    s=$(printf '%s, ' "${shipped[@]}")
    echo "OK: ${s%, }"
fi

echo "== keys"
checked "the build isn't signed with ExpressiveOS's own keys only" 'KEYS_CHECK=(OK|UNPINNED)' \
    "$kit/tools/eos-keys-check.sh" out "$top"
unzip -q -o -d "$T/otacerts" -- "$O/system/etc/security/otacerts.zip"
certs=("$T"/otacerts/*)
[[ ${#certs[@]} = 1 && -f ${certs[0]} ]] || fail "expected one certificate in otacerts.zip, found ${#certs[@]}"
"$H/check_ota_package_signature" "${certs[0]}" "$ota" > "$T/sig.log" 2>&1 || { tail -5 "$T/sig.log" >&2; fail "the package's signature doesn't verify against otacerts.zip"; }
grep -q "Payload signatures VERIFIED" "$T/sig.log" || fail "the payload signatures aren't verified"
echo "OK: the package's zip and payload signatures verify against the build's otacerts"
# Evolution X's update_engine took any payload signature (59fbd47), and so did the host's
# delta_generator, built from the same payload_verifier.cc, under the check above. So
# payload-sig.py checks both signatures without update_engine's code, against the pinned
# certificate, and delta_generator must refuse a key that didn't sign the payload.
pin=${EOS_OTA_CERT_SHA256:-$(openssl x509 -in "${certs[0]}" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')}
r=$(python3 -I "$kit/tools/payload-sig.py" "$ota" "$O/system/etc/security/otacerts.zip" 2>&1 | tail -1) || true
[[ $r = "PAYLOAD_SIG=OK $pin" ]] || fail "payload.bin isn't signed with ExpressiveOS's OTA key $pin ($r)"
unzip -p -- "$ota" payload.bin > "$T/payload.bin" || fail "can't extract payload.bin from $ota"
openssl x509 -in build/make/target/product/security/testkey.x509.pem -noout -pubkey > "$T/aosp.pub.pem" \
    || fail "can't read AOSP's test key (build/make/target/product/security/testkey.x509.pem)"
if "$H/delta_generator" --in_file="$T/payload.bin" --public_key="$T/aosp.pub.pem" > "$T/dg.log" 2>&1; then
    fail "delta_generator takes AOSP's test key for this payload: the tree's payload_verifier.cc checks no signature (patches/system_update_engine 0001)"
fi
rm -f -- "$T/payload.bin"
ue=$O/system/bin/update_engine
[[ -f $ue ]] || fail "no $ue"
! grep -aqF 'Payload signature verification skipped' "$ue" || fail "$ue still skips payload signatures (patches/system_update_engine 0001)"
grep -aqF ' signatures is correct. Expected hash before padding:' "$ue" || fail "$ue has no payload signature check (patches/system_update_engine 0001)"
ue_checks="payload signatures"
if compgen -G "$kit/patches/system_update_engine/0002-*.patch" > /dev/null; then
    grep -aqF ro.ota.allow_downgrade "$ue" || fail "$ue installs older builds (patches/system_update_engine 0002)"
    ue_checks+=", no downgrades"
fi
if compgen -G "$kit/patches/system_update_engine/0003-*.patch" > /dev/null; then
    ues=$O/recovery/root/system/bin/update_engine_sideload
    [[ -f $ues ]] || fail "no $ues"
    ! grep -aqF 'Payload signature verification skipped' "$ues" || fail "$ues still skips payload signatures (patches/system_update_engine 0001)"
    grep -aqF 'Public key verification failed, thus update failed.' "$ues" || fail "$ues doesn't check payload signatures in recovery (patches/system_update_engine 0003)"
    # update_engine_sideload is built from the same hardware_android.cc as update_engine
    if compgen -G "$kit/patches/system_update_engine/0002-*.patch" > /dev/null; then
        grep -aqF ro.ota.allow_downgrade "$ues" || fail "$ues installs older builds in recovery (patches/system_update_engine 0002)"
    fi
    ue_checks+=", and in recovery's sideload too"
fi
echo "OK: payload.bin is signed with the pinned OTA key, and update_engine checks $ue_checks"

echo "== payload"
off=$(python3 -I "$kit/tools/payload.py" offset "$ota") || fail "can't find payload.bin in $ota"
python3 -I "$kit/tools/payload.py" partitions "$ota" > "$T/partitions" || fail "can't read $ota's payload manifest"
need="boot init_boot vendor_boot vendor_kernel_boot dtbo vbmeta vbmeta_system vbmeta_vendor system system_ext product vendor"
need+=" $FIRMWARE $(sed 's|^radio/||; s|\.img,.*||' <<<"$radio" | tr '\n' ' ')"
# ksu-images.sh writes the build's AB_OTA_PARTITIONS here
grep -qx init_boot "$O/ab_partitions.txt" 2>/dev/null || fail "no AB_OTA_PARTITIONS list in $O/ab_partitions.txt (ksu-images.sh writes it)"
need+=" $(tr '\n' ' ' < "$O/ab_partitions.txt")"
missing=$(for p in $need; do grep -qx "$p" "$T/partitions" || echo "$p"; done | sort -u | tr '\n' ' ')
[[ -z "$missing" ]] || fail "the payload lacks: $missing"
echo "OK: $(wc -l < "$T/partitions") partitions, the firmware and everything AB_OTA_PARTITIONS lists included"
AVB="init_boot boot vbmeta vbmeta_system"
mkdir -- "$T/x"
"$H/ota_extractor" -payload "$ota" -payload_offset "$off" -output_dir "$T/x" -partitions "${AVB// /,}" > "$T/x.log" 2>&1 \
    || { tail -3 "$T/x.log" >&2; fail "couldn't extract $AVB from the payload"; }
ramdisk() { "$H/unpack_bootimg" --boot_img "$1" --out "$2" > /dev/null || fail "can't unpack $1"; }
cpio_same() {   # cpio_same <ramdisk> <ramdisk>: the same entries (name, mode, owner, device, bytes), whatever their times, order or compression
    python3 - "$1" "$2" <<'PY'
import subprocess, sys
def entries(path):
    raw = None
    for cmd in (["lz4", "-dc", path], ["gzip", "-dc", path]):
        try:
            r = subprocess.run(cmd, capture_output=True)
        except OSError:
            continue
        if r.returncode == 0 and r.stdout:
            raw = r.stdout
            break
    if raw is None:
        sys.exit(f"can't decompress {path}")
    out, i = {}, 0
    while i + 110 <= len(raw):
        if raw[i:i + 6] not in (b"070701", b"070702"):
            sys.exit(f"{path}: not a newc cpio at byte {i}")
        f = [int(raw[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        mode, uid, gid, size, rmaj, rmin, nsz = f[1], f[2], f[3], f[6], f[9], f[10], f[11]
        n = i + 110
        name = raw[n:n + nsz - 1].decode("utf-8", "surrogateescape")
        d = (n + nsz + 3) & ~3
        if name == "TRAILER!!!":
            break
        out[name] = (mode, uid, gid, rmaj, rmin, raw[d:d + size])
        i = (d + size + 3) & ~3
    return out
a, b = entries(sys.argv[1]), entries(sys.argv[2])
bad = sorted(n for n in set(a) | set(b) if a.get(n) != b.get(n))
for n in bad[:20]:
    print(f"  differs: {n} ({'only one side' if n not in a or n not in b else 'mode, owner or bytes'})", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}
ramdisk "$T/x/init_boot.img" "$T/ib-ota"; ramdisk "$O/init_boot.img" "$T/ib-out"
# With EOS_KSU=none out/'s init_boot is the build's own, which the KernelSU section checks is stock
if [[ $EOS_KSU = lkm ]]; then
    cmp -s -- "$T/ib-ota/ramdisk" "$T/ib-out/ramdisk" || fail "the payload's init_boot ramdisk isn't out/'s (KernelSU Next) one"
    echo "OK: the payload's init_boot carries out/'s KernelSU Next ramdisk"
elif cmp -s -- "$T/ib-ota/ramdisk" "$T/ib-out/ramdisk"; then
    echo "OK: the payload's init_boot carries out/'s ramdisk (no KernelSU: EOS_KSU=none)"
else
    # target-files packs the build's own ramdisk again (mkbootfs with its fs_config), so the
    # bytes may differ while every file, mode, owner and device node is the same: compare those
    cpio_same "$T/ib-ota/ramdisk" "$T/ib-out/ramdisk" \
        || fail "the payload's init_boot ramdisk has other files than out/'s (above)"
    echo "OK: the payload's init_boot ramdisk holds out/'s files, packed again (no KernelSU: EOS_KSU=none)"
fi
checked "the payload's vbmeta isn't ExpressiveOS's" 'KEYS_CHECK=(OK|UNPINNED)' \
    "$kit/tools/eos-keys-check.sh" vbmeta "$T/x/vbmeta.img" "$top"
for i in init_boot boot vbmeta_system; do
    checked "the payload's $i isn't signed with ExpressiveOS's key" 'KEYS_CHECK=(OK|UNPINNED)' \
        "$kit/tools/eos-keys-check.sh" vbmeta "$T/x/$i.img" "$top"
done
# gs201 and zuma chain boot and system: their patch levels are in boot.img's footer and
# vbmeta_system. The Pixel 11 trees also put both in vbmeta itself (--prop: with --flags 3 the
# bootloader reads no chained image's)
props() { local i; for i in vbmeta vbmeta_system boot; do "$H/avbtool" info_image --image "$1/$i.img"; done |
    grep -oE "com\.android\.build\.(boot|system)\.security_patch -> '[0-9-]+'" | sort -u; }
[[ "$(props "$T/x" | wc -l)" = 2 ]] || fail "the payload's vbmeta, vbmeta_system and boot lack the boot or system patch level"
[[ "$(props "$T/x")" = "$(props "$O")" ]] || fail "the payload's patch levels differ from out/'s images"
spl=$(props "$T/x" | sed -n "s/.*system.security_patch -> '\(.*\)'/\1/p")
bspl=$(props "$T/x" | sed -n "s/.*boot.security_patch -> '\(.*\)'/\1/p")
echo "OK: patch levels system $spl, boot $bspl"
echo "== target-files"
checked "the target-files zip kept with the package isn't its own (eos-target-files.sh)" 'TF_CHECK=OK' \
    "$kit/tools/eos-target-files.sh" "$top/$ota" "$top"

stock_ib() {   # stock_ib <init_boot.img>: a stock init_boot (init, no kernelsu.ko) that verifies and is signed with the tree's key
    local stock=$1
    ramdisk "$stock" "$T/ib-stock"
    mkdir -- "$T/r"
    # Only the files checked here: the ramdisk's device nodes (dev/console...) need root to make
    (cd "$T/r" && { lz4 -dc "$T/ib-stock/ramdisk" 2>/dev/null || gzip -dc "$T/ib-stock/ramdisk"; } \
        | cpio -id --quiet --no-absolute-filenames init kernelsu.ko) || fail "can't unpack $stock's ramdisk"
    [[ -e $T/r/init && ! -e $T/r/kernelsu.ko ]] || fail "$stock isn't a stock init_boot (no init, or kernelsu.ko in it)"
    # verify_image looks for the partition's image by its name, next to the one it checks
    mkdir -- "$T/sv"; cp -- "$stock" "$T/sv/init_boot.img"
    "$H/avbtool" verify_image --image "$T/sv/init_boot.img" > "$T/stock.log" 2>&1 || { tail -3 "$T/stock.log" >&2; fail "$stock doesn't verify"; }
    checked "$stock isn't signed with ExpressiveOS's key" 'KEYS_CHECK=(OK|UNPINNED)' "$kit/tools/eos-keys-check.sh" vbmeta "$stock" "$top"
}
if [[ $EOS_KSU = lkm ]]; then
    echo "== KernelSU Next"
    checked "KernelSU Next manager" 'KSU_CHECK=OK' "$kit/ksu/tools/ksu-check.sh" manager "$top"
    checked "KernelSU Next images" 'KSU_CHECK=OK' "$kit/ksu/tools/ksu-check.sh" images "$top/$O" "$top"
    stock=$EOS_KSU_OUT/init_boot-stock.img
    [[ -f $stock ]] || fail "no $stock (cheetah-ksu.sh keeps the stock init_boot for users who want no root)"
    stock_ib "$stock"
    echo "OK: $stock has no KernelSU Next, verifies and is signed with the tree's key"
else
    # No KernelSU (EOS_KSU=none): the build's own init_boot is the stock one, and no
    # separate stock image is kept or published
    echo "== init_boot (no KernelSU: EOS_KSU=none)"
    stock_ib "$O/init_boot.img"
    echo "OK: $O/init_boot.img has no KernelSU, verifies and is signed with the tree's key"
fi

echo "== ViPER4Android, boot animation and wallpaper"
if [[ $EOS_V4A = 1 ]]; then
    checked "ViPER4Android" 'V4A_CHECK=OK' "$kit/viper4android/tools/v4a-check.sh" out "$top/$O" "$top/out/host/linux-x86"
else
    # No ViPER4Android for this phone (EOS_V4A=0: its effect HAL isn't gs201's HIDL one): none
    # of the files v4a-check.sh out looks for, nor Evolution X's other ViPER stack
    v4apkg=$(sed -n 's/^V4A_APP_PACKAGE=//p' "$kit/viper4android/v4a.conf")
    [[ -n $v4apkg ]] || fail "viper4android/v4a.conf names no V4A_APP_PACKAGE"
    hits=$(cd "$O" && { find vendor odm system system_ext product \( -name 'libv4a_re*' -o -name 'libviperaidl*' \
            -o -name "privapp-permissions-$v4apkg.xml" -o -name "hiddenapi-$v4apkg.xml" \) -print 2>/dev/null
        find system system_ext product vendor -path '*app/ViPER4Android*' -prune -print 2>/dev/null; } | sort -u | paste -sd' ' || true)
    [[ -z "$hits" ]] || fail "ViPER4Android shipped, but devices/$EOS_DEVICE.conf says EOS_V4A=0: $hits"
    echo "OK: no ViPER4Android (EOS_V4A=0): no libv4a_re, ViPER app or its permissions in the images"
fi
# shellcheck source=../bootanimation/bootanim.conf
source "$kit/bootanimation/bootanim.conf"
ba=$O/product/media/bootanimation.zip
[[ -f $ba && "$(sha256sum -- "$ba" | cut -d' ' -f1)" = "$BOOTANIM_ZIP_SHA256" ]] || fail "$ba isn't bootanim.conf's boot animation"
extra=$(find "$O/product/media" -maxdepth 1 -name 'bootanimation_*.zip' -printf '%f ')
[[ -z "$extra" ]] || fail "Evolution X's other boot animation styles shipped: $extra(TARGET_INCLUDE_BOOT_ANIMATIONS)"
echo "OK: ExpressiveOS's boot animation, no other styles"
# shellcheck source=../wallpapers/wallpapers.conf
source "$kit/wallpapers/wallpapers.conf"
wpd=$O$WALLPAPER_DEFAULT_PATH dvar="WALLPAPER_${WALLPAPER_DEFAULT#expressiveos_}"; dvar="${dvar^^}_SHA256"
[[ -n "${!dvar:-}" && -f $wpd && "$(sha256sum -- "$wpd" | cut -d' ' -f1)" = "${!dvar}" ]] || fail "$wpd isn't wallpapers.conf's $WALLPAPER_DEFAULT"
[[ "$(prop ro.config.wallpaper)" = "$WALLPAPER_DEFAULT_PATH" ]] \
    || fail "ro.config.wallpaper is '$(prop ro.config.wallpaper)', not $WALLPAPER_DEFAULT_PATH (wallpapers/wallpapers.mk)"
# 1.0 keeps Pixel's wallpapers in the picker, which reads one partner APK only (wallpapers/README.md)
[[ ! -e $O/product/app/ExpressiveWallpapers ]] || fail "ExpressiveWallpapers shipped: 1.0's picker keeps PixelWallpapers2026 (wallpapers/wallpapers.mk)"
[[ -x $H/aapt2 ]] || fail "no $H/aapt2 (m evolution builds it)"
rros=("$O"/product/overlay/framework-res__*auto_generated_rro_product.apk)
[[ ${#rros[@]} = 1 && -f ${rros[0]} ]] || fail "not one framework-res product auto-RRO in $O/product/overlay: ${rros[*]}"
"$H/aapt2" dump resources "${rros[0]}" > "$T/rro.txt" 2>&1 || fail "aapt2 can't read ${rros[0]}"
# The array's own lines: from its resource line to the next resource
awk '/^ *resource 0x/ { on = /array\/theming_defaults/ } on' "$T/rro.txt" > "$T/td.txt"
[[ -s $T/td.txt ]] || fail "${rros[0]##*/} has no theming_defaults (wallpapers/overlay)"
{ grep -qF '*|TONAL_SPOT|home_wallpaper' "$T/td.txt" && ! grep -qiF '#0049c7' "$T/td.txt"; } \
    || fail "framework-res's theming_defaults isn't *|TONAL_SPOT|home_wallpaper (wallpapers/overlay), so the theme won't follow the wallpaper: $(tr -s ' \n' ' ' < "$T/td.txt" | head -c 300)"
echo "OK: $WALLPAPER_DEFAULT is the first-boot wallpaper and the theme follows the wallpaper"

echo "== branding"
checked "the build still shows Evolution X somewhere (patches/: Settings, Evolver, Updater...)" 'BRAND_CHECK=OK' \
    python3 -I "$kit/tools/brand-check.py" "$top/$O"

echo "== firmware and fastboot files"
if [[ $EOS_FIRMWARE_MODE = images ]]; then
    # extract-images.sh names the factory image it made vendor/google/<device>-images from
    fw=$(cat "${EOS_RADIO_MK%/*}/SOURCE" 2>/dev/null || echo "${EOS_RADIO_MK%/*}")
else
    fw=$(cat "$EOS_VENDOR_DIR/FIRMWARE_SOURCE" 2>/dev/null || echo "the vendor repo's own")
fi
n=0
while IFS=, read -r f want; do
    f=${f#radio/}
    [[ -f $O/$f ]] || fail "the build has no $f"
    [[ "$(sha1sum -- "$O/$f" | cut -d' ' -f1)" = "$want" ]] || fail "out/$f doesn't match $EOS_RADIO_MK"
    n=$((n + 1))
done <<<"$radio"
files="fastboot-info.txt android-info.txt"
[[ $EOS_SUPER_EMPTY != out ]] || files+=" super_empty.img"
# eos-pack.sh adds 'flash vendor_kernel_boot' where the tree's fastboot-info.txt has none
[[ $EOS_FLASH_VKB != 1 ]] || files+=" vendor_kernel_boot.img"
for f in $files; do [[ -f $O/$f ]] || fail "the build has no $f"; done
while read -r cmd rest; do
    [[ $cmd = flash ]] || continue
    img=${rest##* }; [[ $img == *.img ]] || img=$img.img
    [[ -f $O/$img || $img = system_other.img ]] || fail "fastboot-info.txt flashes $img, which the build didn't make"
done < "$O/fastboot-info.txt"
if [[ $EOS_SUPER_EMPTY = out ]]; then
    echo "OK: firmware $fw ($n images); fastboot-info.txt, android-info.txt and super_empty.img present"
else
    # The Pixel 11 trees build no super_empty.img: eos-pack.sh takes the stock one (the same
    # super layout as BoardConfig.mk) from the newest factory image zip, as prepare.sh picks it
    fz=$(find ~/android-dt/firmware -maxdepth 1 -name "image-$EOS_DEVICE-*.zip" 2>/dev/null | sort | tail -1) || true
    [[ -n $fz ]] || fail "no ~/android-dt/firmware/image-$EOS_DEVICE-*.zip, whose super_empty.img the fastboot zip takes (EOS_SUPER_EMPTY=factory)"
    unzip -l -- "$fz" super_empty.img > /dev/null 2>&1 || fail "${fz##*/} has no super_empty.img (EOS_SUPER_EMPTY=factory)"
    echo "OK: firmware $fw ($n images); fastboot-info.txt and android-info.txt present, super_empty.img in ${fz##*/}"
fi

done=1
echo "VERIFIED $top/$ota"
echo "VERIFY=OK"
