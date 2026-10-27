#!/usr/bin/env bash
# Put the ExpressiveOS wallpapers into an ExpressiveOS cheetah tree (idempotent: a second
# run changes nothing):
#   1. check every PNG against wallpapers.conf;
#   2. stage wallpapers.mk, the theming_defaults overlay and Bloom into vendor/extra/wallpapers
#      (not ExpressiveWallpapers/'s picker APK: 1.0 keeps Pixel's wallpapers in the picker);
#   3. vendor/extra/product.mk inherits wallpapers.mk (Evolution X's vendor_evolution, checked
#      out at vendor/lineage, has config/common.mk inherit vendor/extra/product.mk), which sets
#      ro.config.wallpaper and the overlay for lineage_cheetah.
# Never on the Evolution X tree (~/evolution). Nothing is written through a symlink that
# leads out of the tree.
#
#   apply-wallpapers.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "WALLPAPERS_APPLY=FAIL"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=wallpapers.conf
source "$here/wallpapers.conf" || fail "can't read $here/wallpapers.conf"

arg=${1:-$HOME/expressiveos}
[[ $# -le 1 ]] || fail "usage: apply-wallpapers.sh [top]"
not_evo() {
    [[ "${1%/}" != */evolution && "${1%/}" != evolution && "${1%/}" != */derpfest && "${1%/}" != derpfest ]] \
        || fail "$arg is the Evolution X or DerpFest tree ($1); the ExpressiveOS wallpapers are for the ExpressiveOS tree only"
}
not_evo "$arg"
[[ -d "$arg" ]] || fail "no tree at $arg"
top="$(cd "$arg" && pwd -P)"
not_evo "$top"
evo='' derp=''
if evo="$(cd "$HOME/evolution" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$evo" ]] || fail "$arg is the Evolution X tree (~/evolution); the ExpressiveOS wallpapers are for the ExpressiveOS tree only"
fi
if derp="$(cd "$HOME/derpfest" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$derp" ]] || fail "$arg is the DerpFest tree (~/derpfest); the ExpressiveOS wallpapers are for the ExpressiveOS tree only"
fi
[[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
grep -qE '^\s*\$\(call inherit-product-if-exists, *vendor/extra/product\.mk\)' "$top/vendor/lineage/config/common.mk" 2>/dev/null \
    || fail "vendor/lineage/config/common.mk no longer inherits vendor/extra/product.mk: the wallpapers would silently not ship"
# What wallpapers.mk relies on, so an upstream change fails here and not on the phone
grep -q '"ro.config.wallpaper"' "$top/frameworks/base/core/java/android/app/WallpaperManager.java" 2>/dev/null \
    || fail "frameworks/base's WallpaperManager no longer reads ro.config.wallpaper; check how the default wallpaper is chosen now"
grep -q 'theming_defaults' "$top/frameworks/base/packages/SystemUI/src/com/android/systemui/theme/ThemeOverlayController.java" 2>/dev/null \
    || fail "SystemUI's ThemeOverlayController no longer reads theming_defaults; check how the first-boot theme is chosen now"
in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and not in ~/evolution or ~/derpfest
    local r
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    [[ -z "$evo" || ( "$r" != "$evo" && "$r" != "$evo"/* ) ]] || fail "${1#"$top"/} leads into the Evolution X tree ($r)"
    [[ -z "$derp" || ( "$r" != "$derp" && "$r" != "$derp"/* ) ]] || fail "${1#"$top"/} leads into the DerpFest tree ($r)"
}

# What goes into vendor/extra/wallpapers, relative to this folder: no Android.bp, so the
# picker APK isn't even a module in 1.0
d=ExpressiveWallpapers/res/drawable-nodpi
files=(
    wallpapers.mk
    overlay/frameworks/base/core/res/res/values/config.xml
    "$d/$WALLPAPER_DEFAULT.png"
)

dest="$top/vendor/extra/wallpapers"
for p in vendor/extra vendor/extra/wallpapers vendor/extra/product.mk; do in_top "$top/$p"; done
for f in "${files[@]}"; do in_top "$dest/$f"; done
echo "== ExpressiveOS wallpapers -> $top"

pm="$top/vendor/extra/product.mk"
line='$(call inherit-product, vendor/extra/wallpapers/wallpapers.mk)'
where=$([[ ! -f "$pm" ]] || want="$line" awk -f "$here/tools/mk-line.awk" -- "$pm") || fail "can't read $pm"
[[ $where != nested ]] \
    || fail "vendor/extra/product.mk has '$line' only inside an ifeq/ifdef/define block; move it out to the top level"

# 1. The PNGs are the ones wallpapers.conf names
for n in bloom dusk dawn mint; do
    for kind in "" _thumbnail; do
        f="$here/$d/expressiveos_$n$kind.png"
        var="WALLPAPER_${n^^}${kind:+_THUMB}_SHA256"
        [[ -f "$f" ]] || fail "no $f"
        sha=$(sha256sum -- "$f" | cut -d' ' -f1)
        [[ "$sha" = "${!var:-}" ]] \
            || fail "${f#"$here"/} is $sha, wallpapers.conf says ${!var:-nothing} (a partial checkout, or a re-render without updating wallpapers.conf?)"
    done
done
for f in "${files[@]}"; do [[ -f "$here/$f" ]] || fail "no $here/$f"; done

# 2. Stage. The folder belongs to this kit: anything else in it goes.
for f in "${files[@]}"; do
    t="$dest/$f"
    if cmp -s -- "$here/$f" "$t"; then
        echo "unchanged: vendor/extra/wallpapers/$f"
        continue
    fi
    mkdir -p -- "${t%/*}" || fail "can't make ${t%/*}"
    cp -- "$here/$f" "${t%/*}/.${t##*/}.tmp" && chmod 0644 "${t%/*}/.${t##*/}.tmp" \
        && mv -f -- "${t%/*}/.${t##*/}.tmp" "$t" || fail "can't stage $f in $dest"
    echo "staged: vendor/extra/wallpapers/$f"
done
while IFS= read -r -d '' t; do
    f=${t#"$dest"/}
    keep=0
    for k in "${files[@]}"; do [[ "$f" = "$k" ]] && { keep=1; break; }; done
    ((keep)) && continue
    [[ -f "$t" || -L "$t" ]] || fail "$t isn't a file this kit put there; move it out of the way"
    rm -f -- "$t"; echo "removed: vendor/extra/wallpapers/$f"
done < <(find "$dest" -mindepth 1 ! -type d -print0)
find "$dest" -mindepth 1 -type d -empty -delete

# 3. vendor/extra/product.mk (ExpressiveOS's own; the tree builds only cheetah)
if [[ $where = top ]]; then
    echo "unchanged: vendor/extra/product.mk"
elif [[ -f "$pm" ]]; then
    [[ -z "$(tail -c1 -- "$pm")" ]] || echo >> "$pm"
    printf '%s\n' "# Wallpapers (expressiveos-cheetah/wallpapers)" "$line" >> "$pm"
    echo "added to vendor/extra/product.mk: $line"
else
    printf '%s\n' \
        "# ExpressiveOS additions. vendor/lineage/config/common.mk inherits this file when it exists." \
        "# Not a repo project, so repo sync leaves it alone." \
        "" \
        "# Wallpapers (expressiveos-cheetah/wallpapers)" \
        "$line" > "$pm"
    echo "created vendor/extra/product.mk: $line"
fi

dvar="WALLPAPER_${WALLPAPER_DEFAULT#expressiveos_}"; dvar="${dvar^^}_SHA256"
done=1
echo "WALLPAPERS_APPLY=OK default=$WALLPAPER_DEFAULT sha256=${!dvar:-}"
