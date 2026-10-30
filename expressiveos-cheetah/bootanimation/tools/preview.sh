#!/usr/bin/env bash
# preview.sh SRC_DIR OUT.mp4 [loops] [--palette RRGGBB,RRGGBB,RRGGBB,RRGGBB]: what the phone
# shows on its 1080x2340 FHD+ boot screen, following desc.txt (pauses hold the part's last
# frame): the looping part plays N times (default 3), then a one-second hold at the end. 30 fps,
# scaled to 720 wide. Needs ffmpeg.
# The holiday zip's frames are colour masks: tint.py first draws them as the phone does, in
# --palette's colours (a holiday's four petal mids) or desc.txt's start colours (Bloom's).
set -euo pipefail
palette=() args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --palette) palette=("${2:?--palette needs RRGGBB,RRGGBB,RRGGBB,RRGGBB}"); shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
src=${args[0]:?usage: preview.sh SRC_DIR OUT.mp4 [loops] [--palette COLOURS]} out=${args[1]:?no OUT.mp4} loops=${args[2]:-3}
seq=$(mktemp -d "${TMPDIR:-/tmp}/bootanim-preview.XXXXXX")
trap 'rm -rf -- "$seq"' EXIT
if grep -q '^dynamic_colors ' "$src/desc.txt"; then
    python3 -I "$(dirname -- "$(readlink -f -- "$0")")/tint.py" "$src" "$seq/tinted" ${palette[@]+"${palette[@]}"}
    src=$seq/tinted
fi
n=0
put() { ln -s "$(cd "$(dirname -- "$1")" && pwd)/${1##*/}" "$seq/$(printf 'f%05d.png' $n)"; n=$((n + 1)); }
last='' bg=''
while read -r type plays pause part colour _; do
    [[ $type = [cp] ]] || continue
    # As BootAnimation.cpp: the colour is optional (' #rrggbb'), black when it's missing
    bg=${colour#\#}; [[ $colour = \#* && $bg =~ ^[0-9A-Fa-f]{6}$ ]] || bg=000000
    [[ $plays = 0 ]] && plays=$loops
    for ((r = 0; r < plays; r++)); do
        for f in "$src/$part"/img*.png; do put "$f"; last=$f; done
        for ((i = 0; i < pause; i++)); do put "$last"; done
    done
done < "$src/desc.txt"
for ((i = 0; i < 30; i++)); do put "$last"; done
ffmpeg -loglevel error -y -framerate 30 -i "$seq/f%05d.png" \
    -vf "pad=1080:2340:0:510:color=0x$bg,scale=720:1560:flags=lanczos" \
    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$out"
echo "$out: $n frames ($((n / 30)).$((n % 30 * 10 / 30)) s)"
