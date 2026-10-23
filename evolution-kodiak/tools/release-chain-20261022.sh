#!/bin/bash
# Release chain for all four Pixel 11 builds (kodiak, grizzly, cubs, yogi), hotfix from the 2026-10-21 01:42 sync
# (--no-sync): nowplaying.xml dropped (Now Playing, At a Glance), stale SystemUI.apk gone, release-checks.sh in the routine
set -uo pipefail

echo "=================================================="
echo "STARTING PIXEL 11 RELEASE CHAIN: $(date "+%F %T %Z")"
echo "=================================================="

for dev in kodiak grizzly cubs yogi; do
    echo "##################################################"
    echo "STARTING ROUTINE: $dev at $(date "+%F %T %Z")"
    echo "##################################################"
    ~/p11-routine.sh $dev --no-sync
    echo "FINISHED ROUTINE: $dev at $(date "+%F %T %Z")"
done

echo "=================================================="
echo "ALL PIXEL 11 RELEASES COMPLETED: $(date "+%F %T %Z")"
echo "=================================================="
