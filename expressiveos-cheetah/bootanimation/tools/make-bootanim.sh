#!/usr/bin/env bash
# Render the boot animation again and pack it.
#
#   tools/make-bootanim.sh FONT.ttf [OUT.zip] [--preview OUT.mp4]
#   tools/make-bootanim.sh --holiday FONT.ttf [OUT.zip] [--preview OUT.mp4 [--palette COLOURS]]
#
# FONT.ttf is Google Sans Flex from ExpressiveLauncher (bootanim.conf has the path and
# sha256). OUT.zip defaults to ../bootanimation.zip. Prints the new sha256 and size for
# bootanim.conf. Needs python3 with numpy and Pillow (variable fonts, libraqm), and ffmpeg
# for --preview. Rendering takes a few minutes; the three parts render in parallel.
#
# --holiday renders the holiday copy instead (render.py --dynamic: colour masks the phone
# colours in), by default to ../bootanimation_holiday.zip, and prints its
# BOOTANIM_HOLIDAY_ZIP_SHA256 and _SIZE. Its preview is in desc.txt's start colours (Bloom's)
# or in --palette's, a holiday's four petal mids: RRGGBB,RRGGBB,RRGGBB,RRGGBB (README.md).
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
tools="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
kit="$(dirname -- "$tools")"
repo="$(cd "$kit/../.." && pwd)"
# shellcheck source=../bootanim.conf
source "$kit/bootanim.conf"
sha256() { if command -v sha256sum >/dev/null; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1; }

font='' out='' preview='' holiday=0 palette=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --preview) preview=${2:?--preview needs a path}; shift 2 ;;
        --holiday) holiday=1; shift ;;
        --palette) palette=(--palette "${2:?--palette needs RRGGBB,RRGGBB,RRGGBB,RRGGBB}"); shift 2 ;;
        *) if [[ -z "$font" ]]; then font=$1; else out=$1; fi; shift ;;
    esac
done
[[ -n "$font" ]] || fail "usage: make-bootanim.sh [--holiday] FONT.ttf [OUT.zip] [--preview OUT.mp4]"
[[ ${#palette[@]} = 0 || $holiday = 1 ]] || fail "--palette is for --holiday's preview"
if [[ $holiday = 1 ]]; then
    out=${out:-$kit/bootanimation_holiday.zip} dynamic=(--dynamic) var=BOOTANIM_HOLIDAY_ZIP
else
    out=${out:-$kit/bootanimation.zip} dynamic=() var=BOOTANIM_ZIP
fi
logo="$repo/$BOOTANIM_LOGO"
[[ "$(sha256 "$logo")" = "$BOOTANIM_LOGO_SHA256" ]] || fail "$logo isn't the pinned logo"
[[ "$(sha256 "$font")" = "$BOOTANIM_FONT_SHA256" ]] \
    || fail "$font isn't the pinned Google Sans Flex ($BOOTANIM_FONT in $BOOTANIM_FONT_REPO)"

work=$(mktemp -d "${TMPDIR:-/tmp}/bootanim.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
pids=()
for part in part0 part1 part2; do
    python3 -I "$tools/render.py" "$logo" "$font" "$work/src" --only "$part" ${dynamic[@]+"${dynamic[@]}"} > "$work/$part.log" 2>&1 &
    pids+=($!)
done
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { cat "$work"/part*.log >&2; fail "rendering part$i failed"; }
done
# Each part's frame count, and for --holiday how many pixels it kept out of the shader's grey
grep -h '^part[0-9]:' "$work"/part*.log
python3 -I "$tools/pack.py" "$work/src" "$out"
[[ -z "$preview" ]] || "$tools/preview.sh" "$work/src" "$preview" ${palette[@]+"${palette[@]}"}
echo "${var}_SHA256=$(sha256 "$out")"
echo "${var}_SIZE=$(wc -c < "$out" | tr -d ' ')"
