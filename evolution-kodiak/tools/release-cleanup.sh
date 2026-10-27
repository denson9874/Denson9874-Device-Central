#!/bin/bash
# Delete release zips from the build server once SourceForge hosts them: the downloads live there (the
# Updaters' OTAs on the R2 mirror), so the server keeps no builds. A zip is deleted only when its
# SourceForge folder (the folder's RSS feed) lists a file with the same MD5 and size, so a failed or
# partial upload keeps it. Covers the staged copies in ~/releases/<dev> and the OTA zips the build leaves
# in out/. The .sha256 and .uploaded files stay: the pack scripts and p11-ota.sh read them, so a released
# name is never reused.
# p11-routine.sh runs it for its device at the end; derp-ota.sh for derpfest-husky after a publish.
#
#   release-cleanup.sh [<kodiak|grizzly|cubs|yogi|cheetah|husky|derpfest-husky> ...] [--dry-run]
#
#   (no device)  every device
#   --dry-run    list what would be deleted, delete nothing
#
# The last line is CLEANUP=DONE|DRYRUN|FAILED deleted=<n> kept=<n> freed=<GB>. FAILED: SourceForge's
# listing couldn't be read for a device, and all of that device's zips were kept.
set -uo pipefail

SF=https://sourceforge.net/projects/denson9874-s-user-builds/rss
devs=(); DRY=0
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        kodiak|grizzly|cubs|yogi|cheetah|husky|derpfest-husky) devs+=("$a") ;;
        *) echo "usage: release-cleanup.sh [<kodiak|grizzly|cubs|yogi|cheetah|husky|derpfest-husky> ...] [--dry-run]" >&2; exit 2 ;;
    esac
done
[ ${#devs[@]} = 0 ] && devs=(kodiak grizzly cubs yogi cheetah husky derpfest-husky)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

deleted=0; kept=0; freed=0; result=DONE
for dev in "${devs[@]}"; do
    if [ "$dev" = derpfest-husky ]; then
        dirs=(~/releases/derpfest-husky ~/derpfest/out/target/product/husky); rom=DerpFest; sf=derpfest/husky
    else
        dirs=(~/releases/$dev ~/evolution/out/target/product/$dev); rom=EvolutionX; sf=$dev/17
    fi
    mapfile -t zips < <(find "${dirs[@]}" -maxdepth 1 -type f -name "$rom-*.zip" 2>/dev/null | sort)
    [ ${#zips[@]} = 0 ] && continue
    echo "== $dev: ${#zips[@]} zips; host: SourceForge $sf"
    # "<md5> <size>" of every file in the SourceForge folder
    curl -sf --max-time 120 "$SF?path=/$sf&limit=100" | grep -o 'filesize="[0-9]*"><media:hash algo="md5">[0-9a-f]*' \
        | sed 's/filesize="\([0-9]*\)"><media:hash algo="md5">\(.*\)/\2 \1/' > $T/sf
    if [ ! -s $T/sf ]; then
        echo "   couldn't read SourceForge's $sf listing; keeping all ${#zips[@]}"
        kept=$((kept + ${#zips[@]})); result=FAILED; continue
    fi
    for z in "${zips[@]}"; do
        size=$(stat -c %s "$z")
        if ! grep -qxF "$(md5sum < "$z" | cut -d' ' -f1) $size" $T/sf; then
            echo "   keep    $z (not on SourceForge)"; kept=$((kept + 1)); continue
        fi
        if [ $DRY = 1 ]; then echo "   would delete $z"; else rm -f "$z" && echo "   deleted $z"; fi
        deleted=$((deleted + 1)); freed=$((freed + size))
    done
done
[ $DRY = 1 ] && [ $result = DONE ] && result=DRYRUN
echo "CLEANUP=$result deleted=$deleted kept=$kept freed=$(awk -v b=$freed 'BEGIN {printf "%.1f", b / 1e9}')GB"
[ $result != FAILED ]
