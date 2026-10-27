#!/usr/bin/env bash
# Check a finished ExpressiveOS cheetah build offline, before anything is packed or
# published. eos-images.sh runs it as its last step; it can also run alone after a build.
# Stops at the first problem. Prints "VERIFIED <OTA package>" and, last, VERIFY=OK;
# otherwise the last line is VERIFY=FAIL.
#
#   eos-verify.sh [top]      # default ~/expressiveos
#
#   1. the package: one ExpressiveOS-17.x-<date>-cheetah-<version>-<type>.zip in out/, the
#      build's own, A/B, for cheetah;
#   2. identity: cheetah, Pixel 7 Pro, a user build, every kit patch in its project, the
#      Updater on ExpressiveOS's feed and never Evolution X's;
#   3. keys: eos-keys-check.sh out, and the package's zip and payload signatures verify
#      against the one certificate the build trusts for updates, which is the pinned one;
#      update_engine checks payload signatures again (and refuses older builds, and checks
#      in recovery too, with patches/system_update_engine 0002 and 0003);
#   4. the payload: every partition the build lists plus the firmware; its init_boot
#      carries the same KernelSU Next ramdisk as out/; its vbmeta (and every partition it
#      chains), boot, init_boot and vbmeta_system are ExpressiveOS's; its patch levels are
#      the build's; the target-files zip kept with it, for incremental OTAs, is its own
#      (eos-target-files.sh);
#   5. KernelSU Next (ksu-check.sh manager and images), and the stock init_boot kept for
#      users who want no root (no kernelsu.ko, signed with the tree's key);
#   6. ViPER4Android (v4a-check.sh out), the boot animation (bootanim.conf's zip, no
#      other styles) and the wallpaper (wallpapers.conf's default on ro.config.wallpaper,
#      the theme from the wallpaper);
#   7. branding: no app, framework string or crash report header names Evolution X
#      (brand-check.py), apart from the few links it lists on purpose;
#   8. firmware and the fastboot files the pack script reads.
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
O=out/target/product/cheetah
H=out/host/linux-x86/bin
# check_ota_package_signature runs delta_generator from its own folder
for t in avbtool ota_extractor check_ota_package_signature delta_generator unpack_bootimg; do
    [[ -x $H/$t ]] || fail "no $H/$t (m evolution builds it)"
done
# Only a build in this tree changes out/ under the checks
b=$(tree_build); [[ -z "$b" ]] || fail "a build is running in $top: $b"
# gs201's firmware partitions, flashed from radio/ (vendor/google/cheetah/Android.mk)
FIRMWARE="abl bl1 bl2 bl31 gsa ldfw modem pbl tzsw"
radio=$(grep -oE 'radio/[a-z0-9_]+\.img,[0-9a-f]{40}' vendor/google/cheetah/Android.mk || true)
for f in $FIRMWARE; do
    grep -q "^radio/$f\.img," <<<"$radio" || fail "vendor/google/cheetah/Android.mk doesn't list radio/$f.img with its sha1"
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
[[ "$ver" =~ ^ExpressiveOS-17\.[0-9]+-[0-9]{8}-cheetah-${EOS_VERSION//./\\.}-$EOS_BUILD_TYPE$ ]] \
    || fail "ro.evolution.build.version is '$ver', not ExpressiveOS-17.x-<date>-cheetah-$EOS_VERSION-$EOS_BUILD_TYPE"
ota=$O/$ver.zip
[[ -f $ota ]] || fail "no $ota (m evolution makes it)"
others=$(find "$O" -maxdepth 1 -name 'ExpressiveOS-*.zip' ! -name "$ver.zip" -printf '%f ')
[[ -z "$others" ]] || fail "out/ also holds $others; it must hold only this build's package"
unzip -p -- "$ota" META-INF/com/android/metadata > "$T/metadata" || fail "$ota has no OTA metadata"
grep -qx "ota-type=AB" "$T/metadata" || fail "$ota isn't an A/B package"
grep -qx "pre-device=cheetah" "$T/metadata" || fail "$ota isn't for cheetah"
ts=$(sed -n 's/^post-timestamp=//p' "$T/metadata")
[[ -n "$ts" && "$ts" = "$(prop ro.build.date.utc)" ]] || fail "$ota isn't from this build (post-timestamp '$ts', build date $(prop ro.build.date.utc))"
echo "OK: $ver.zip ($(stat -c %s "$ota") bytes), A/B, cheetah, built $(date -ud "@$ts" '+%F %T') UTC"

echo "== identity"
for kv in ro.product.product.device=cheetah "ro.product.product.model=Pixel 7 Pro" ro.product.vendor.device=cheetah \
          ro.evolution.device=cheetah ro.build.type=user; do
    [[ "$(prop "${kv%%=*}")" = "${kv#*=}" ]] || fail "${kv%%=*} is '$(prop "${kv%%=*}")', want '${kv#*=}'"
done
grep -q '^require board=' "$O/android-info.txt" || fail "no 'require board=' in $O/android-info.txt"
echo "OK: cheetah, Pixel 7 Pro, user build"
n=0
for d in "$kit"/patches/* "$kit"/ksu/patches/* "$kit"/viper4android/patches/*; do
    [[ -d $d ]] || continue
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
ovl=$(find "$O/product/overlay" -name UpdaterOverlayCheetah.apk -print -quit 2>/dev/null || true)
[[ -n "$ovl" ]] || fail "no UpdaterOverlayCheetah.apk under $O/product/overlay"
python3 -I - "$ovl" <<'EOF' || fail "the Updater doesn't read ExpressiveOS's feed only"
import sys, zipfile
arsc = zipfile.ZipFile(sys.argv[1]).read('resources.arsc')
def has(s):
    return s.encode() in arsc or s.encode('utf-16-le') in arsc
if not has('https://raw.githubusercontent.com/denson9874/expressiveos_ota/main/builds/{device}.json'):
    sys.exit('FAIL: UpdaterOverlayCheetah has no denson9874/expressiveos_ota/main feed URL')
if has('evolution_ota'):
    sys.exit('FAIL: UpdaterOverlayCheetah names evolution_ota')
EOF
echo "OK: the Updater reads denson9874/expressiveos_ota/main"
scone=$(grep -m1 -oE 'SCONE-v[0-9]+' "$kit"/patches/device_google_pantah/0004-*.patch || true)
[[ -n "$scone" ]] || fail "patches/device_google_pantah/0004 names no SCONE-v<n> module"
[[ -f $O/product/priv-app/$scone/$scone.apk ]] || fail "$scone isn't installed (patches/device_google_pantah/0004)"
[[ -d $O/system_ext/priv-app/SystemUIGoogle/oat/arm64 ]] || fail "SystemUIGoogle's odex isn't on /system_ext (patches/device_google_pantah/0007)"
echo "OK: SCONE installed, SystemUIGoogle odex on /system_ext"

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
ramdisk "$T/x/init_boot.img" "$T/ib-ota"; ramdisk "$O/init_boot.img" "$T/ib-out"
cmp -s -- "$T/ib-ota/ramdisk" "$T/ib-out/ramdisk" || fail "the payload's init_boot ramdisk isn't out/'s (KernelSU Next) one"
echo "OK: the payload's init_boot carries out/'s KernelSU Next ramdisk"
checked "the payload's vbmeta isn't ExpressiveOS's" 'KEYS_CHECK=(OK|UNPINNED)' \
    "$kit/tools/eos-keys-check.sh" vbmeta "$T/x/vbmeta.img" "$top"
for i in init_boot boot vbmeta_system; do
    checked "the payload's $i isn't signed with ExpressiveOS's key" 'KEYS_CHECK=(OK|UNPINNED)' \
        "$kit/tools/eos-keys-check.sh" vbmeta "$T/x/$i.img" "$top"
done
# gs201 chains boot and system: their patch levels are in boot.img's footer and vbmeta_system
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

echo "== KernelSU Next"
checked "KernelSU Next manager" 'KSU_CHECK=OK' "$kit/ksu/tools/ksu-check.sh" manager "$top"
checked "KernelSU Next images" 'KSU_CHECK=OK' "$kit/ksu/tools/ksu-check.sh" images "$top/$O" "$top"
stock=out/ksu/init_boot-stock.img
[[ -f $stock ]] || fail "no $stock (cheetah-ksu.sh keeps the stock init_boot for users who want no root)"
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
echo "OK: $stock has no KernelSU Next, verifies and is signed with the tree's key"

echo "== ViPER4Android, boot animation and wallpaper"
checked "ViPER4Android" 'V4A_CHECK=OK' "$kit/viper4android/tools/v4a-check.sh" out "$top/$O" "$top/out/host/linux-x86"
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
fw=$(cat vendor/google/cheetah/FIRMWARE_SOURCE 2>/dev/null || echo "the vendor repo's own")
n=0
while IFS=, read -r f want; do
    f=${f#radio/}
    [[ -f $O/$f ]] || fail "the build has no $f"
    [[ "$(sha1sum -- "$O/$f" | cut -d' ' -f1)" = "$want" ]] || fail "out/$f doesn't match vendor/google/cheetah/Android.mk"
    n=$((n + 1))
done <<<"$radio"
for f in fastboot-info.txt android-info.txt super_empty.img; do [[ -f $O/$f ]] || fail "the build has no $f"; done
while read -r cmd rest; do
    [[ $cmd = flash ]] || continue
    img=${rest##* }; [[ $img == *.img ]] || img=$img.img
    [[ -f $O/$img || $img = system_other.img ]] || fail "fastboot-info.txt flashes $img, which the build didn't make"
done < "$O/fastboot-info.txt"
echo "OK: firmware $fw ($n images); fastboot-info.txt, android-info.txt and super_empty.img present"

done=1
echo "VERIFIED $top/$ota"
echo "VERIFY=OK"
