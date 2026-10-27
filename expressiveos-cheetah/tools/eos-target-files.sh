#!/usr/bin/env bash
# Check the target-files zip an ExpressiveOS cheetah build keeps with its OTA package
# (patches/vendor_lineage/0003; tf_zip in lib.sh). Every incremental OTA from this build
# will start from it, so it has to be exactly this build's. eos-verify.sh runs it; the
# last line is TF_CHECK=OK or TF_CHECK=FAIL.
#
#   eos-target-files.sh <package> [top]      # default ~/expressiveos
#
#   1. it's the package's: its build.prop has the package's post-timestamp and name
#      (ro.evolution.build.version), its ab_partitions.txt is the build's, and its
#      misc_info.txt names the tree's own release key (what an incremental is signed with);
#   2. it holds an image (IMAGES/ or RADIO/) of every partition the package's payload writes;
#   3. its init_boot carries out/'s KernelSU Next ramdisk (pass 2's);
#   4. for incrementals: every image the fastboot zip flashes (out/'s, as fastboot-info.txt
#      names them) is the target-files' copy byte for byte (patches/device_google_gs201/0006
#      has target-files take the built images). If not, a WARNING names them: an incremental
#      OTA from this build can't patch them on phones installed from the fastboot zip, and
#      eos-pack.sh --release refuses the build. The fastboot zip itself is still fine.
set -euo pipefail
done=0 T=''
cleanup() {
    local rc=$?
    [[ -z "$T" ]] || rm -rf -- "$T"
    [[ $done = 1 ]] || echo "TF_CHECK=FAIL"
    exit $rc
}
trap cleanup EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || fail "usage: eos-target-files.sh <package> [top]"
ota=$(realpath -e -- "$1") || fail "no package $1"
eos_top "${2:-}"
cd "$top"
O=out/target/product/cheetah
H=out/host/linux-x86/bin
[[ -x $H/unpack_bootimg ]] || fail "no $H/unpack_bootimg (m evolution builds it)"
tf=$(tf_zip)
[[ -f $tf ]] || fail "no $tf: m evolution keeps it only with patches/vendor_lineage/0003 (apply.sh), then build again"
T=$(mktemp -d "${TMPDIR:-/tmp}/eos-tf.XXXXXX")
unzip -Z1 -- "$tf" > "$T/list" || fail "can't read $tf"
has() { grep -qxF -- "$1" "$T/list"; }
for f in META/misc_info.txt META/ab_partitions.txt SYSTEM/build.prop; do has "$f" || fail "$tf has no $f"; done
tfprop() {   # tfprop <name>: its value in the first of the target-files' build.props that sets it
    local f
    for f in SYSTEM/build.prop SYSTEM_EXT/etc/build.prop PRODUCT/etc/build.prop VENDOR/build.prop; do
        has "$f" || continue
        unzip -p -- "$tf" "$f" > "$T/prop" || fail "can't read $f in $tf"
        grep -q "^$1=" "$T/prop" && { sed -n "/^${1//./\\.}=/{s/^[^=]*=//p;q}" "$T/prop"; return; }
    done
    true
}

echo "== the package's"
unzip -p -- "$ota" META-INF/com/android/metadata > "$T/metadata" || fail "${ota##*/} has no OTA metadata"
ts=$(sed -n 's/^post-timestamp=//p' "$T/metadata")
ver=${ota##*/}; ver=${ver%.zip}
v=$(tfprop ro.build.date.utc)
[[ -n "$ts" && "$v" = "$ts" ]] || fail "${tf##*/} isn't ${ota##*/}'s: its ro.build.date.utc is '$v', the package's post-timestamp '$ts'"
v=$(tfprop ro.evolution.build.version)
[[ "$v" = "$ver" ]] || fail "${tf##*/} is $v's, not $ver's"
unzip -p -- "$tf" META/ab_partitions.txt > "$T/ab0" || fail "can't read its META/ab_partitions.txt"
[[ -f $O/ab_partitions.txt ]] || fail "no $O/ab_partitions.txt (ksu-images.sh writes it)"
sed '/^$/d' "$T/ab0" | sort -u > "$T/ab"
sed '/^$/d' "$O/ab_partitions.txt" | sort -u > "$T/ab-out"
cmp -s -- "$T/ab" "$T/ab-out" || fail "its ab_partitions.txt isn't the build's AB_OTA_PARTITIONS ($O/ab_partitions.txt)"
unzip -p -- "$tf" META/misc_info.txt > "$T/misc" || fail "can't read its META/misc_info.txt"
grep -qx 'ab_update=true' "$T/misc" || fail "its misc_info.txt isn't an A/B build's"
# The key ota_from_target_files signs an incremental with when -k isn't given (the source's)
grep -qx 'default_system_dev_certificate=vendor/evolution-priv/keys/testkey' "$T/misc" \
    || fail "its misc_info.txt doesn't name the tree's own release key (vendor/evolution-priv/keys/testkey)"
echo "OK: ${tf##*/} ($(stat -c %s -- "$tf") bytes) is $ver's, built $(date -ud "@$ts" '+%F %T') UTC, with the build's A/B partitions and release key"

echo "== images"
python3 -I "$kit/tools/payload.py" partitions "$ota" > "$T/partitions" || fail "can't read ${ota##*/}'s payload manifest"
missing=$(while read -r p; do has "IMAGES/$p.img" || has "RADIO/$p.img" || echo "$p"; done < "$T/partitions" | tr '\n' ' ')
[[ -z "$missing" ]] || fail "it has no image of $missing(the payload writes them)"
echo "OK: an image of each of the payload's $(wc -l < "$T/partitions") partitions"
mkdir -- "$T/img"
for i in init_boot vbmeta vbmeta_system vbmeta_vendor; do
    has "IMAGES/$i.img" || fail "it has no IMAGES/$i.img"
    unzip -p -- "$tf" "IMAGES/$i.img" > "$T/img/$i.img" || fail "can't extract IMAGES/$i.img"
done
ramdisk() { "$H/unpack_bootimg" --boot_img "$1" --out "$2" > /dev/null || fail "can't unpack $1"; }
ramdisk "$T/img/init_boot.img" "$T/ib-tf"; ramdisk "$O/init_boot.img" "$T/ib-out"
cmp -s -- "$T/ib-tf/ramdisk" "$T/ib-out/ramdisk" || fail "its init_boot ramdisk isn't out/'s (pass 2's KernelSU Next one)"
echo "OK: its init_boot carries out/'s KernelSU Next ramdisk"

echo "== incremental base"
# An incremental OTA reads its source blocks from the phone and update_engine refuses any
# that isn't the target-files image's, so every image the fastboot zip flashes must be the
# target-files' own. Parsed as eos-pack.sh does (the last word of each flash line).
[[ -f $O/fastboot-info.txt ]] || fail "no $O/fastboot-info.txt"
n=0 differ=()
while IFS= read -r line; do
    read -r cmd rest <<<"$line" || true
    [[ "${cmd:-}" = flash ]] || continue
    img=${rest##* }; [[ $img == *.img ]] || img=$img.img
    # No system_other in this build (eos-verify.sh checks the others are there)
    [[ -f $O/$img ]] || continue
    if has "IMAGES/$img"; then e=IMAGES/$img; elif has "RADIO/$img"; then e=RADIO/$img; else differ+=("${img%.img} (none in target-files)"); continue; fi
    n=$((n + 1))
    a=$(unzip -p -- "$tf" "$e" | sha256sum | cut -d' ' -f1) || fail "can't read $e in $tf"
    [[ "$a" = "$(sha256sum -- "$O/$img" | cut -d' ' -f1)" ]] || differ+=("${img%.img}")
done < "$O/fastboot-info.txt"
(( n > 0 || ${#differ[@]} > 0 )) || fail "$O/fastboot-info.txt flashes no image"
if (( ${#differ[@]} == 0 )); then
    # eos-pack.sh --release looks for this line in eos-verify.sh's log
    echo "OK: incremental base: the fastboot zip's $n images are the target-files' own, byte for byte"
else
    d=$(printf '%s, ' "${differ[@]}"); d=${d%, }
    if (( ${#differ[@]} == 1 )); then d="$d isn't the target-files' image" it=it; else d="$d aren't the target-files' images" it=them; fi
    echo "WARNING: incremental base: the fastboot zip's (out/'s) $d, so an incremental OTA from this build can't patch $it on phones installed from it (eos-pack.sh --release refuses the build)"
fi
done=1
echo "TF_CHECK=OK"
