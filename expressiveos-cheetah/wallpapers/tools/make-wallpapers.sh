#!/usr/bin/env bash
# Render the four wallpapers and their thumbnails again.
#
#   tools/make-wallpapers.sh [OUTDIR] [--preview SHEET.png]
#
# OUTDIR defaults to ../ExpressiveWallpapers/res/drawable-nodpi. Prints the new sha256 lines
# for wallpapers.conf. Needs python3 with numpy, scipy, Pillow and cairocffi (libcairo).
# --preview also draws every wallpaper on a mock lock and home screen and puts them on one
# sheet; it needs Google Sans Flex and its clock cut in $EOS_FONTS (default
# vendor/extras/prebuilt/product/fonts, run from the tree). The four render in parallel:
# about 20 s on 4 cores and 1.2 GB of memory in all. The same sources give the same bytes
# (seeded noise, numpy 2.5.4, scipy 1.18.1, Pillow 13.0.0, cairocffi 1.17.2).
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
tools="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
kit="$(dirname -- "$tools")"
# shellcheck source=../wallpapers.conf
source "$kit/wallpapers.conf"
sha256() { if command -v sha256sum >/dev/null; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1; }

out="$kit/ExpressiveWallpapers/res/drawable-nodpi" preview=
while [[ $# -gt 0 ]]; do
    case $1 in
        --preview) preview=${2:?--preview needs a path}; shift 2 ;;
        *) out=$1; shift ;;
    esac
done
mark="${EOS_MARK:-$tools/mark-108.txt}"
[[ "$(sha256 "$mark")" = "$WALLPAPER_MARK_SHA256" ]] \
    || fail "$mark isn't the pinned mark (../branding/tools/make-brand.py draws it from $WALLPAPER_LOGO)"
# --preview's fonts, checked before anything in OUTDIR is replaced (mock.py's paths)
if [[ -n "$preview" ]]; then
    fonts=${EOS_FONTS:-vendor/extras/prebuilt/product/fonts}
    for f in GoogleSansFlexClock-Regular.ttf GoogleSansFlex-Regular.ttf; do
        [[ -f "$fonts/$f" ]] || fail "no $fonts/$f for --preview: run from the tree or set EOS_FONTS (e.g. ~/expressiveos/vendor/extras/prebuilt/product/fonts)"
    done
    export EOS_FONTS=$fonts
fi
mkdir -p -- "$out"

work=$(mktemp -d "${TMPDIR:-/tmp}/wallpapers.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
pids=()
for n in bloom dusk dawn mint; do
    EOS_MARK="$mark" python3 -I "$tools/final.py" "$n" "$work/expressiveos_$n.png" > "$work/$n.log" 2>&1 &
    pids+=($!)
done
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { cat "$work"/*.log >&2; fail "rendering wallpaper $i failed"; }
done
python3 -I "$tools/thumbs.py" "$work"
for n in bloom dusk dawn mint; do
    for f in "expressiveos_$n.png" "expressiveos_${n}_thumbnail.png"; do
        cp -- "$work/$f" "$out/.$f.tmp" && mv -f -- "$out/.$f.tmp" "$out/$f"
    done
done
if [[ -n "$preview" ]]; then
    mkdir -- "$work/mock"
    for n in bloom dusk dawn mint; do python3 -I "$tools/mock.py" "$out/expressiveos_$n.png" "$work/mock"; done
    python3 -I "$tools/sheet.py" "$work/mock" "$out" "$preview"
fi
for n in bloom dusk dawn mint; do
    echo "WALLPAPER_${n^^}_SHA256=$(sha256 "$out/expressiveos_$n.png")"
done
for n in bloom dusk dawn mint; do
    echo "WALLPAPER_${n^^}_THUMB_SHA256=$(sha256 "$out/expressiveos_${n}_thumbnail.png")"
done
