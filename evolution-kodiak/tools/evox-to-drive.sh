#!/bin/bash
# Copy an Evolution X build's release files to Google Drive, gdrive:EvolutionX/<dev>, the way
# derp-build.sh copies DerpFest builds to gdrive:DerpFest/kodiak (both through ~/upload-to-drive.sh).
# p11-routine.sh runs it after every successful build; by hand it copies a device's newest build.
#
#   evox-to-drive.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--newer <file>] [--dry-run]
#
#   --newer <file>  the files in ~/releases/<dev> written after <file> (the routine's start marker)
#   (default)       the newest fastboot zip and the newest OTA zip, each with its .sha256, and the
#                   newest changelog. Picked by time, not name: the two zips' -rN revisions differ.
#   --dry-run       list what would be copied
#
# The last line is DRIVE_UPLOAD=DONE|FAILED|NOTHING|DRYRUN. The rclone output goes to
# ~/routine-logs/drive-<dev>-<time>.log.
set -uo pipefail

dev=${1:-}; [ $# -gt 0 ] && shift
NEWER=""; DRY=0
while [ $# -gt 0 ]; do
    case $1 in
        --newer) NEWER=${2:?--newer needs a file}; shift ;;
        --dry-run) DRY=1 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case $dev in
    kodiak|grizzly|cubs|yogi|cheetah|husky) ;;
    *) echo "usage: evox-to-drive.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> [--newer <file>] [--dry-run]" >&2; exit 2 ;;
esac
dir=~/releases/$dev
[ -d "$dir" ] || { echo "no $dir"; echo "DRIVE_UPLOAD=NOTHING"; exit 0; }

files=()
if [ -n "$NEWER" ]; then
    [ -e "$NEWER" ] || { echo "no $NEWER"; exit 2; }
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -newer "$NEWER" \
        \( -name 'EvolutionX-*.zip' -o -name 'EvolutionX-*.zip.sha256' -o -name 'CHANGES-*.txt' \) | sort)
else
    fastboot=$(ls -t "$dir"/EvolutionX-*-fastboot.zip 2>/dev/null | head -1)
    ota=$(ls -t "$dir"/EvolutionX-*.zip 2>/dev/null | grep -v -- '-fastboot\.zip$' | head -1)
    changes=$(ls -t "$dir"/CHANGES-*.txt 2>/dev/null | head -1)
    for f in "$fastboot" "$ota"; do
        [ -n "$f" ] || continue
        files+=("$f"); [ -f "$f.sha256" ] && files+=("$f.sha256")
    done
    [ -n "$changes" ] && files+=("$changes")
fi

if [ ${#files[@]} = 0 ]; then
    echo "== Google Drive: no $dev release files to copy"
    echo "DRIVE_UPLOAD=NOTHING"; exit 0
fi
echo "== Google Drive: ${#files[@]} files to gdrive:EvolutionX/$dev"
for f in "${files[@]}"; do echo "   $(basename "$f") ($(du -h "$f" | cut -f1))"; done
[ $DRY = 1 ] && { echo "DRIVE_UPLOAD=DRYRUN"; exit 0; }

mkdir -p ~/routine-logs
log=~/routine-logs/drive-$dev-$(date +%Y%m%d-%H%M%S).log
if ~/upload-to-drive.sh EvolutionX "$dev" "${files[@]}" > "$log" 2>&1; then
    echo "DRIVE_UPLOAD=DONE log=$log"
else
    tail -5 "$log" | tr '\r' '\n' | grep -v '^\s*$' | tail -3
    echo "DRIVE_UPLOAD=FAILED log=$log"; exit 1
fi
