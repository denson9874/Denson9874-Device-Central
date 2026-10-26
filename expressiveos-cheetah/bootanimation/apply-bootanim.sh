#!/usr/bin/env bash
# Put the ExpressiveOS boot animation into an ExpressiveOS cheetah tree (idempotent: a
# second run changes nothing):
#   1. check bootanimation.zip against bootanim.conf;
#   2. stage it and bootanimation.mk into vendor/extra/bootanimation;
#   3. vendor/extra/product.mk inherits bootanimation.mk (Evolution X's vendor_evolution,
#      checked out at vendor/lineage, has config/common.mk inherit vendor/extra/product.mk),
#      which sets TARGET_BOOTANIMATION for lineage_cheetah.
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
not_evo() { [[ "${1%/}" != */evolution && "${1%/}" != evolution ]] || fail "$arg is the Evolution X tree ($1); the ExpressiveOS boot animation is for the ExpressiveOS tree only"; }
not_evo "$arg"
[[ -d "$arg" ]] || fail "no tree at $arg"
top="$(cd "$arg" && pwd -P)"
not_evo "$top"
evo=
if evo="$(cd "$HOME/evolution" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$evo" ]] || fail "$arg is the Evolution X tree (~/evolution); the ExpressiveOS boot animation is for the ExpressiveOS tree only"
fi
[[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
bmk="$top/vendor/lineage/bootanimation/Android.mk"
grep -q 'TARGET_BOOTANIMATION' "$bmk" 2>/dev/null \
    || fail "$bmk is missing or no longer reads TARGET_BOOTANIMATION; check how Evolution X installs its boot animation now"
grep -qE '^\s*\$\(call inherit-product-if-exists, *vendor/extra/product\.mk\)' "$top/vendor/lineage/config/common.mk" 2>/dev/null \
    || fail "vendor/lineage/config/common.mk no longer inherits vendor/extra/product.mk: the boot animation would silently not ship"
in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and not in ~/evolution
    local r
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    [[ -z "$evo" || ( "$r" != "$evo" && "$r" != "$evo"/* ) ]] || fail "${1#"$top"/} leads into the Evolution X tree ($r)"
}
for p in vendor/extra vendor/extra/bootanimation vendor/extra/product.mk; do in_top "$top/$p"; done
echo "== ExpressiveOS boot animation -> $top"

pm="$top/vendor/extra/product.mk"
line='$(call inherit-product, vendor/extra/bootanimation/bootanimation.mk)'
where=$([[ ! -f "$pm" ]] || want="$line" awk -f "$here/tools/mk-line.awk" -- "$pm") || fail "can't read $pm"
[[ $where != nested ]] \
    || fail "vendor/extra/product.mk has '$line' only inside an ifeq/ifdef/define block; move it out to the top level"

# 1. The zip is the one bootanim.conf names
zip="$here/bootanimation.zip"
[[ -f "$zip" ]] || fail "no $zip"
sha=$(sha256sum -- "$zip" | cut -d' ' -f1)
[[ "$sha" = "$BOOTANIM_ZIP_SHA256" ]] \
    || fail "bootanimation.zip is $sha, bootanim.conf says $BOOTANIM_ZIP_SHA256 (a partial checkout, or a re-render without updating bootanim.conf?)"

# 2. Stage. The folder belongs to this kit: anything else in it goes.
dest="$top/vendor/extra/bootanimation"
mkdir -p -- "$dest"
for f in "$zip" "$here/bootanimation.mk"; do
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
    [[ "$n" = bootanimation.zip || "$n" = bootanimation.mk ]] && continue
    [[ -f "$f" || -L "$f" ]] || fail "$f isn't a file this kit put there; move it out of the way"
    rm -f -- "$f"; echo "removed: vendor/extra/bootanimation/$n"
done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0)

# 3. vendor/extra/product.mk (ExpressiveOS's own; the tree builds only cheetah)
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
echo "BOOTANIM_APPLY=OK sha256=$sha"
