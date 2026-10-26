#!/usr/bin/env bash
# preview.sh SRC_DIR OUT.mp4 [loops]: what the phone shows on its 1080x2340 FHD+ boot screen,
# following desc.txt (pauses hold the part's last frame): the looping part plays N times
# (default 3), then a one-second hold at the end. 30 fps, scaled to 720 wide. Needs ffmpeg.
set -euo pipefail
src=$1 out=$2 loops=${3:-3}
seq=$(mktemp -d "${TMPDIR:-/tmp}/bootanim-preview.XXXXXX")
trap 'rm -rf -- "$seq"' EXIT
n=0
put() { ln -s "$(cd "$(dirname -- "$1")" && pwd)/${1##*/}" "$seq/$(printf 'f%05d.png' $n)"; n=$((n + 1)); }
last='' bg=''
while read -r type plays pause part colour _; do
    [[ $type = [cp] ]] || continue
    bg=${colour#\#}
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
