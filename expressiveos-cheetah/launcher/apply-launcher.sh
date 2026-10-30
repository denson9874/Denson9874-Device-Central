#!/usr/bin/env bash
# Put Expressive Launcher into the ExpressiveOS tree as every phone's Home and Recents app,
# in place of Pixel Launcher (idempotent: a second run changes nothing):
#   1. fetch-launcher.sh: the pinned release APK, its LICENSE and notices, verified;
#   2. stage them with tree/ into vendor/extra/launcher (Android.bp removed first and written
#      last, so Soong never sees it without its files; anything else there goes);
#   3. vendor/extra/product.mk inherits launcher.mk (Evolution X's vendor_evolution, checked
#      out at vendor/lineage, has config/common.mk inherit vendor/extra/product.mk);
#   4. tools/launcher-check.sh tree: the pre-build guards.
# Run it on every build (../tools/eos-images.sh does), for every phone: launcher.mk adds the
# launcher to all of ExpressiveOS's lineage_<device> products.
# Never on the Evolution X tree (~/evolution) or DerpFest's. Nothing is written through a
# symlink that leads out of the tree.
#
#   apply-launcher.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0 work=
cleanup() {
    local rc=$?
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "LAUNCHER_APPLY=FAIL"
    exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=launcher.conf
source "$here/launcher.conf" || fail "can't read $here/launcher.conf"
mkline="$here/tools/mk-line.awk"
[[ -f "$mkline" ]] || fail "no $mkline"

arg=${1:-$HOME/expressiveos}
[[ $# -le 1 ]] || fail "usage: apply-launcher.sh [top]"
not_evo() {
    [[ "${1%/}" != */evolution && "${1%/}" != evolution && "${1%/}" != */derpfest && "${1%/}" != derpfest ]] \
        || fail "$arg is the Evolution X or DerpFest tree ($1); Expressive Launcher is for the ExpressiveOS tree only"
}
not_evo "$arg"
[[ -d "$arg" ]] || fail "no tree at $arg"
top="$(cd "$arg" && pwd -P)"
not_evo "$top"
evo='' derp=''
if evo="$(cd "$HOME/evolution" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$evo" ]] || fail "$arg is the Evolution X tree (~/evolution); Expressive Launcher is for the ExpressiveOS tree only"
fi
if derp="$(cd "$HOME/derpfest" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$derp" ]] || fail "$arg is the DerpFest tree (~/derpfest); Expressive Launcher is for the ExpressiveOS tree only"
fi
[[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
# What this script writes must stay in this tree, even when a folder in it is a symlink
in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and not in ~/evolution or ~/derpfest
    local r
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    [[ -z "$evo" || ( "$r" != "$evo" && "$r" != "$evo"/* ) ]] || fail "${1#"$top"/} leads into the Evolution X tree ($r)"
    [[ -z "$derp" || ( "$r" != "$derp" && "$r" != "$derp"/* ) ]] || fail "${1#"$top"/} leads into the DerpFest tree ($r)"
}
dest="$top/vendor/extra/launcher"
for p in vendor/extra vendor/extra/launcher vendor/extra/product.mk; do in_top "$top/$p"; done
pm="$top/vendor/extra/product.mk"
line='$(call inherit-product, vendor/extra/launcher/launcher.mk)'
where=$([[ ! -f "$pm" ]] || want="$line" awk -f "$mkline" -- "$pm") || fail "can't read $pm"
[[ $where != nested ]] \
    || fail "vendor/extra/product.mk has '$line' only inside an ifeq/ifdef/define block, which may be false for a phone; move it out to the top level"
echo "== Expressive Launcher $EL_VERSION ($EL_VERSION_CODE) -> $top"

# 1. Fetch and verify into a fresh folder
work=$(mktemp -d "${TMPDIR:-/tmp}/launcher-apply.XXXXXX")
"$here/fetch-launcher.sh" --out "$work/files" || fail "fetch-launcher.sh failed"

# 2. Stage: the verified files at the top, tree/ as it is (its overlays keep their folders).
#    The folder belongs to this kit: anything in it that the kit doesn't ship goes.
mkdir "$work/stage"
cp -- "$work/files"/* "$work/stage/"
cp -R -- "$here/tree/." "$work/stage/"
find "$work/stage" -type d -exec chmod 0755 {} + && find "$work/stage" -type f -exec chmod 0644 {} +
files=()
while IFS= read -r -d '' f; do files+=("${f#"$work/stage"/}"); done \
    < <(find "$work/stage" -type f -print0 | LC_ALL=C sort -z)
for f in "${files[@]}"; do in_top "$dest/$f"; done
changed=0
for f in "${files[@]}"; do cmp -s -- "$work/stage/$f" "$dest/$f" || changed=1; done
stale=()
if [[ -d "$dest" ]]; then
    while IFS= read -r -d '' t; do
        f=${t#"$dest"/}
        [[ -f "$work/stage/$f" ]] && continue
        [[ -f "$t" || -L "$t" ]] || fail "$t isn't a file this kit put there; move it out of the way"
        stale+=("$f"); changed=1
    done < <(find "$dest" -mindepth 1 ! -type d -print0)
fi
if [[ $changed = 0 ]]; then
    echo "unchanged: vendor/extra/launcher"
else
    mkdir -p -- "$dest"
    rm -f -- "$dest/Android.bp"
    for f in ${stale[@]+"${stale[@]}"}; do
        rm -f -- "$dest/$f"; echo "removed: vendor/extra/launcher/$f"
    done
    find "$dest" -mindepth 1 -type d -empty -delete
    for f in "${files[@]}"; do
        [[ "$f" != Android.bp ]] || continue
        cmp -s -- "$work/stage/$f" "$dest/$f" && continue
        t="$dest/$f"
        mkdir -p -- "${t%/*}" || fail "can't make ${t%/*} (Android.bp stays out until a run succeeds)"
        cp -p -- "$work/stage/$f" "${t%/*}/.${t##*/}.tmp" && mv -f -- "${t%/*}/.${t##*/}.tmp" "$t" \
            || fail "can't stage $f in $dest (Android.bp stays out until a run succeeds)"
        echo "staged: vendor/extra/launcher/$f"
    done
    cp -p -- "$work/stage/Android.bp" "$dest/.Android.bp.tmp" || fail "can't stage Android.bp in $dest"
    mv -f -- "$dest/.Android.bp.tmp" "$dest/Android.bp" || fail "can't stage Android.bp in $dest"
    echo "staged: vendor/extra/launcher/Android.bp (last)"
fi

# 3. vendor/extra/product.mk (ExpressiveOS's own; read for every phone the tree builds)
if [[ $where = top ]]; then
    echo "unchanged: vendor/extra/product.mk"
elif [[ -f "$pm" ]]; then
    [[ -z "$(tail -c1 -- "$pm")" ]] || echo >> "$pm"
    printf '%s\n' "# Expressive Launcher (expressiveos-cheetah/launcher)" "$line" >> "$pm"
    echo "added to vendor/extra/product.mk: $line"
else
    printf '%s\n' \
        "# ExpressiveOS additions. vendor/lineage/config/common.mk inherits this file when it exists." \
        "# Not a repo project, so repo sync leaves it alone." \
        "" \
        "# Expressive Launcher (expressiveos-cheetah/launcher)" \
        "$line" > "$pm"
    echo "created vendor/extra/product.mk: $line"
fi

# 4. Pre-build guards
"$here/tools/launcher-check.sh" tree "$top" || fail "the tree checks above failed; don't build"
done=1
echo "LAUNCHER_APPLY=OK $EL_PACKAGE $EL_VERSION ($EL_VERSION_CODE)"
