#!/usr/bin/env bash
# Render the boot animation again and pack it.
#
#   tools/make-bootanim.sh FONT.ttf [OUT.zip] [--preview OUT.mp4]
#
# FONT.ttf is Google Sans Flex from ExpressiveLauncher (bootanim.conf has the path and
# sha256). OUT.zip defaults to ../bootanimation.zip. Prints the new sha256 and size for
# bootanim.conf. Needs python3 with numpy and Pillow (variable fonts, libraqm), and ffmpeg
# for --preview. Rendering takes a few minutes; the three parts render in parallel.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
tools="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
kit="$(dirname -- "$tools")"
repo="$(cd "$kit/../.." && pwd)"
# shellcheck source=../bootanim.conf
source "$kit/bootanim.conf"
sha256() { if command -v sha256sum >/dev/null; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1; }

font= out="$kit/bootanimation.zip" preview=
while [[ $# -gt 0 ]]; do
    case $1 in
        --preview) preview=${2:?--preview needs a path}; shift 2 ;;
        *) if [[ -z "$font" ]]; then font=$1; else out=$1; fi; shift ;;
    esac
done
[[ -n "$font" ]] || fail "usage: make-bootanim.sh FONT.ttf [OUT.zip] [--preview OUT.mp4]"
logo="$repo/$BOOTANIM_LOGO"
[[ "$(sha256 "$logo")" = "$BOOTANIM_LOGO_SHA256" ]] || fail "$logo isn't the pinned logo"
[[ "$(sha256 "$font")" = "$BOOTANIM_FONT_SHA256" ]] \
    || fail "$font isn't the pinned Google Sans Flex ($BOOTANIM_FONT in $BOOTANIM_FONT_REPO)"

work=$(mktemp -d "${TMPDIR:-/tmp}/bootanim.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
pids=()
for part in part0 part1 part2; do
    python3 -I "$tools/render.py" "$logo" "$font" "$work/src" --only "$part" > "$work/$part.log" 2>&1 &
    pids+=($!)
done
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { cat "$work"/part*.log >&2; fail "rendering part$i failed"; }
done
python3 -I "$tools/pack.py" "$work/src" "$out"
[[ -z "$preview" ]] || "$tools/preview.sh" "$work/src" "$preview"
echo "BOOTANIM_ZIP_SHA256=$(sha256 "$out")"
echo "BOOTANIM_ZIP_SIZE=$(wc -c < "$out" | tr -d ' ')"
