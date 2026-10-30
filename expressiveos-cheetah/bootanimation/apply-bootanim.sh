#!/usr/bin/env bash
# Put the ExpressiveOS boot animation into the ExpressiveOS tree (idempotent: a second run
# changes nothing), for every phone it builds:
#   1. check bootanimation.zip and bootanimation_holiday.zip against bootanim.conf;
#   2. stage them, expressiveos-bootanim-hint.rc and bootanimation.mk into
#      vendor/extra/bootanimation;
#   3. vendor/extra/product.mk inherits bootanimation.mk (Evolution X's vendor_evolution,
#      checked out at vendor/lineage, has config/common.mk inherit vendor/extra/product.mk),
#      which sets TARGET_BOOTANIMATION for ExpressiveOS's lineage_<device> products and
#      installs the holiday zip and its init rc.
# Before that, the phone's lineage_<device>.mk (EOS_DEVICE, cheetah unless set) mustn't turn
# Evolution X's other styles on, and frameworks/base and device/lineage/sepolicy must let
# bootanim read the holiday zip's /metadata hint. Notes, without failing, when the hint looks
# unneeded (README.md, "Holiday boot animations").
# Never on the Evolution X tree (~/evolution). Nothing is written through a symlink that
# leads out of the tree.
#
#   apply-bootanim.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "BOOTANIM_APPLY=FAIL"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=bootanim.conf
source "$here/bootanim.conf" || fail "can't read $here/bootanim.conf"

arg=${1:-$HOME/expressiveos}
[[ $# -le 1 ]] || fail "usage: apply-bootanim.sh [top]"
not_evo() {
    [[ "${1%/}" != */evolution && "${1%/}" != evolution && "${1%/}" != */derpfest && "${1%/}" != derpfest ]] \
        || fail "$arg is the Evolution X or DerpFest tree ($1); the ExpressiveOS boot animation is for the ExpressiveOS tree only"
}
not_evo "$arg"
[[ -d "$arg" ]] || fail "no tree at $arg"
top="$(cd "$arg" && pwd -P)"
not_evo "$top"
evo='' derp=''
if evo="$(cd "$HOME/evolution" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$evo" ]] || fail "$arg is the Evolution X tree (~/evolution); the ExpressiveOS boot animation is for the ExpressiveOS tree only"
fi
if derp="$(cd "$HOME/derpfest" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$derp" ]] || fail "$arg is the DerpFest tree (~/derpfest); the ExpressiveOS boot animation is for the ExpressiveOS tree only"
fi
[[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
bmk="$top/vendor/lineage/bootanimation/Android.mk"
grep -q 'TARGET_BOOTANIMATION' "$bmk" 2>/dev/null \
    || fail "$bmk is missing or no longer reads TARGET_BOOTANIMATION; check how Evolution X installs its boot animation now"
grep -qE '^\s*\$\(call inherit-product-if-exists, *vendor/extra/product\.mk\)' "$top/vendor/lineage/config/common.mk" 2>/dev/null \
    || fail "vendor/lineage/config/common.mk no longer inherits vendor/extra/product.mk: the boot animation would silently not ship"
# Evolution X's 12 other styles (about 190 MiB) stay out of /product/media only while
# TARGET_INCLUDE_BOOT_ANIMATIONS is false for this phone. Its lineage_<device>.mk sets that
# (cheetah: ../patches/device_google_pantah/0010; husky: ../devices/husky/patches/
# device_google_shusky/; the Pixel 11s: a commit on their own trees), and eos-images.sh
# exports it as well. The export only wins over vendor/lineage's common.mk default (?= true),
# never over a := true in the device tree (the Pixel 11 trees started with one), so that's
# refused here, before hours of building
read -r dev lmk vdir <<<"$(source "$here/../lib.sh" && printf '%s %s %s' "$EOS_DEVICE" "$EOS_DEVICE_TREE/lineage_$EOS_DEVICE.mk" "$EOS_VENDOR_DIR")"
[[ -n ${dev:-} && -n ${lmk:-} && -n ${vdir:-} ]] || fail "can't read this phone's device and vendor trees (lib.sh, devices/<device>.conf)"
ib=$(sed -nE 's/^[[:space:]]*TARGET_INCLUDE_BOOT_ANIMATIONS[[:space:]]*:?=[[:space:]]*([^[:space:]#]*).*$/\1/p' -- "$top/$lmk" 2>/dev/null | tail -1 || true)
[[ -z $ib || $ib = false ]] \
    || fail "$lmk sets TARGET_INCLUDE_BOOT_ANIMATIONS to '$ib', which eos-images.sh's export can't override: Evolution X's 12 other styles (about 190 MiB) would ship for $dev. Set it to false there: a commit on that tree, or a patch in devices/$dev/patches (bootanimation/README.md)"
in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and not in ~/evolution or ~/derpfest
    local r
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    [[ -z "$evo" || ( "$r" != "$evo" && "$r" != "$evo"/* ) ]] || fail "${1#"$top"/} leads into the Evolution X tree ($r)"
    [[ -z "$derp" || ( "$r" != "$derp" && "$r" != "$derp"/* ) ]] || fail "${1#"$top"/} leads into the DerpFest tree ($r)"
}
for p in vendor/extra vendor/extra/bootanimation vendor/extra/product.mk; do in_top "$top/$p"; done
echo "== ExpressiveOS boot animation -> $top"

pm="$top/vendor/extra/product.mk"
line='$(call inherit-product, vendor/extra/bootanimation/bootanimation.mk)'
where=$([[ ! -f "$pm" ]] || want="$line" awk -f "$here/tools/mk-line.awk" -- "$pm") || fail "can't read $pm"
[[ $where != nested ]] \
    || fail "vendor/extra/product.mk has '$line' only inside an ifeq/ifdef/define block; move it out to the top level"

# 1. The zips are the ones bootanim.conf names
zip="$here/bootanimation.zip" hzip="$here/bootanimation_holiday.zip" hint="$here/expressiveos-bootanim-hint.rc"
[[ -f "$zip" ]] || fail "no $zip"
sha=$(sha256sum -- "$zip" | cut -d' ' -f1)
[[ "$sha" = "$BOOTANIM_ZIP_SHA256" ]] \
    || fail "bootanimation.zip is $sha, bootanim.conf says $BOOTANIM_ZIP_SHA256 (a partial checkout, or a re-render without updating bootanim.conf?)"
for f in "$hzip" "$hint"; do [[ -f "$f" ]] || fail "no $f (a partial checkout?); the holiday zip and its init rc ship together"; done
hsha=$(sha256sum -- "$hzip" | cut -d' ' -f1)
[[ "$hsha" = "$BOOTANIM_HOLIDAY_ZIP_SHA256" ]] \
    || fail "bootanimation_holiday.zip is $hsha, bootanim.conf says $BOOTANIM_HOLIDAY_ZIP_SHA256 (a partial checkout, or a re-render without updating bootanim.conf?)"

# The /metadata hint is there because the phone's vendor init starts bootanim at late-fs, before
# /data and its persist properties (cheetah: init.gs201.rc). If none does any more, the hint may
# do nothing, which does no harm
late=$(find "$top/$vdir" -path '*/etc/init/hw/init.*.rc' -type f -exec awk '
    FNR == 1 { f = 0 }
    $1 == "on" || $1 == "service" || $1 == "import" { f = $1 == "on" && $2 == "late-fs" && NF == 2 }
    f && $1 == "start" && $2 == "bootanim" { print FILENAME; exit }' {} + 2>/dev/null | head -1 || true)
[[ -n $late ]] \
    || echo "note: no init rc in $vdir starts bootanim under 'on late-fs' (cheetah's init.gs201.rc did): check whether holiday boots still need the /metadata hint (README.md, \"Holiday boot animations\")"
# But the hint does nothing unless frameworks/base's BootAnimation reads it and
# device/lineage/sepolicy labels it for bootanim: without either, every holiday boot plays the
# everyday animation. eos-verify.sh fails such a build, so it's refused here, before hours of building
grep -qF '/metadata/bootanim' "$top/frameworks/base/cmds/bootanimation/BootAnimation.cpp" 2>/dev/null \
    || fail "frameworks/base's BootAnimation.cpp doesn't read /metadata/bootanim: holiday boots would play the everyday animation (README.md, \"Holiday boot animations\")"
grep -qF 'u:object_r:bootanim_metadata_file:s0' "$top/device/lineage/sepolicy/common/private/file_contexts" 2>/dev/null \
    || fail "device/lineage/sepolicy's common/private/file_contexts doesn't label /metadata/bootanim bootanim_metadata_file: bootanim couldn't read the hint, so holiday boots would play the everyday animation (README.md, \"Holiday boot animations\")"
grep -qF 'r_dir_file(bootanim, bootanim_metadata_file)' "$top/device/lineage/sepolicy/common/private/bootanim.te" 2>/dev/null \
    || fail "device/lineage/sepolicy's common/private/bootanim.te doesn't let bootanim read bootanim_metadata_file: holiday boots would play the everyday animation (README.md, \"Holiday boot animations\")"

# 2. Stage. The folder belongs to this kit: anything else in it goes.
dest="$top/vendor/extra/bootanimation"
mkdir -p -- "$dest"
for f in "$zip" "$hzip" "$hint" "$here/bootanimation.mk"; do
    n=${f##*/}
    if cmp -s -- "$f" "$dest/$n"; then
        echo "unchanged: vendor/extra/bootanimation/$n"
        continue
    fi
    cp -- "$f" "$dest/.$n.tmp" && chmod 0644 "$dest/.$n.tmp" && mv -f -- "$dest/.$n.tmp" "$dest/$n" \
        || fail "can't stage $n in $dest"
    echo "staged: vendor/extra/bootanimation/$n"
done
while IFS= read -r -d '' f; do
    n=${f##*/}
    [[ "$n" = bootanimation.zip || "$n" = bootanimation_holiday.zip || "$n" = expressiveos-bootanim-hint.rc || "$n" = bootanimation.mk ]] && continue
    [[ -f "$f" || -L "$f" ]] || fail "$f isn't a file this kit put there; move it out of the way"
    rm -f -- "$f"; echo "removed: vendor/extra/bootanimation/$n"
done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0)

# 3. vendor/extra/product.mk (ExpressiveOS's own; read for every phone the tree builds)
if [[ $where = top ]]; then
    echo "unchanged: vendor/extra/product.mk"
elif [[ -f "$pm" ]]; then
    [[ -z "$(tail -c1 -- "$pm")" ]] || echo >> "$pm"
    printf '%s\n' "# Boot animation (expressiveos-cheetah/bootanimation)" "$line" >> "$pm"
    echo "added to vendor/extra/product.mk: $line"
else
    printf '%s\n' \
        "# ExpressiveOS additions. vendor/lineage/config/common.mk inherits this file when it exists." \
        "# Not a repo project, so repo sync leaves it alone." \
        "" \
        "# Boot animation (expressiveos-cheetah/bootanimation)" \
        "$line" > "$pm"
    echo "created vendor/extra/product.mk: $line"
fi

if [[ "${TARGET_INCLUDE_BOOT_ANIMATIONS:-}" != false ]]; then
    echo "note: export TARGET_INCLUDE_BOOT_ANIMATIONS=false before building, or Evolution X's 12 other styles (about 190 MiB) ship in /product/media too"
fi
done=1
echo "BOOTANIM_APPLY=OK sha256=$sha holiday=$hsha"
