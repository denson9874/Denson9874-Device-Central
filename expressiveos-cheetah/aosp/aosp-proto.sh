#!/usr/bin/env bash
# ExpressiveOS on AOSP, cheetah only: the EXPERIMENT of branch eos/aosp (README.md here).
# Its own tree, ~/eos-aosp, never ~/expressiveos; its own tmux session, eos-aosp; its log in
# ~/expressiveos-jobs/aosp/. Nothing here builds, packs, signs, uploads or flashes a release.
#
#   aosp-proto.sh status   read-only: session, logs' last lines, the tree's size, free disk
#   aosp-proto.sh sync     repo init AOSP android-17.0.0_r1 (depth 1) + eos-aosp-cheetah.xml, repo sync
#   aosp-proto.sh build    lunch aosp_cheetah, then m -k droid: the log of what fails is the result
#   aosp-proto.sh round    sync, then build if it ended SYNC=OK (one round, one dispatch)
#   aosp-proto.sh clean    remove ~/eos-aosp and the copied scripts (nothing stays on the server)
#
# sync and build run in tmux and return at once; status shows how they go. They refuse while an
# ExpressiveOS build or pack (eos-build, eos-pack) or any soong/ninja runs, and build only after
# a sync that ended SYNC=OK.
set -euo pipefail
top=~/eos-aosp kitc=~/eos-aosp-kit jobs=~/expressiveos-jobs/aosp
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AOSP_TAG=android-17.0.0_r1
MIN_FREE_GB=300   # a depth-1 AOSP checkout plus one product's out/ (inferred: ~110 + ~180 GB)
fail() { echo "::error::$*"; exit 1; }
busy() {
    local s
    for s in eos-build eos-pack eos-setup eos-aosp; do
        if tmux has-session -t "=$s" 2>/dev/null; then echo "tmux session $s is running"; return 0; fi
    done
    if pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null; then echo "a soong/ninja build is running"; return 0; fi
    return 1
}
free_gb() { df -BG --output=avail ~ | tail -1 | tr -dc 0-9; }

start() {   # start <step>: run this script's <step>-run in the eos-aosp tmux session, from a copy
    local why
    if why=$(busy); then fail "not starting $1: $why"; fi
    mkdir -p "$kitc" "$jobs"
    cp "$here/aosp-proto.sh" "$kitc/" && cp "$here/local_manifests/eos-aosp-cheetah.xml" "$kitc/"
    local log=$jobs/$1-$(TZ=America/New_York date +%Y%m%d-%H%M).log
    # A fresh login's environment, as the kit's sessions get: the runner kills every process that
    # carries this job's RUNNER_TRACKING_ID when the job ends
    env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/bash LANG=C.UTF-8 TERM=screen \
        PATH="$HOME/bin:$PATH" tmux new-session -d -s eos-aosp "bash -l -c 'bash $kitc/aosp-proto.sh $1-run > $log 2>&1'"
    echo "started $1 in tmux session eos-aosp, log $log"
}

case ${1:-status} in
status)
    echo "== $(TZ=America/New_York date '+%Y-%m-%d %H:%M %Z')"
    tmux ls 2>/dev/null | grep -E '^eos-' || echo "no ExpressiveOS session running"
    echo "free: $(free_gb) GB"
    if [[ -d $top ]]; then echo "$top: $(du -sh --apparent-size "$top" 2>/dev/null | cut -f1)"; else echo "$top: not there"; fi
    for f in $(ls -t "$jobs"/*.log 2>/dev/null | head -2); do
        echo "== $f (last 60 lines)"; tail -n 60 "$f"
    done ;;
sync)  start sync ;;
build) start build ;;
round) start round ;;
clean)
    if why=$(busy); then fail "not cleaning: $why"; fi
    before=$(free_gb)
    rm -rf "$top" "$kitc"
    echo "removed $top and $kitc; free $before GB -> $(free_gb) GB (logs kept in $jobs)" ;;

sync-run)
    echo "SYNC start $(TZ=America/New_York date)"
    (( $(free_gb) >= MIN_FREE_GB )) || { echo "SYNC=FAIL only $(free_gb) GB free, need $MIN_FREE_GB"; exit 1; }
    command -v repo >/dev/null || { echo "SYNC=FAIL repo isn't installed"; exit 1; }
    mkdir -p "$top" && cd "$top"
    # This round's local manifest before repo init, which reads the one already there
    if [[ -d .repo ]]; then mkdir -p .repo/local_manifests && cp "$kitc/eos-aosp-cheetah.xml" .repo/local_manifests/; fi
    repo init -u https://android.googlesource.com/platform/manifest -b "$AOSP_TAG" --depth=1 </dev/null \
        || { echo "SYNC=FAIL repo init"; exit 1; }
    mkdir -p .repo/local_manifests
    cp "$kitc/eos-aosp-cheetah.xml" .repo/local_manifests/
    repo sync -c -j8 --no-tags --no-clone-bundle --fail-fast </dev/null || { echo "SYNC=FAIL repo sync"; exit 1; }
    echo "projects: $(repo list | wc -l); free $(free_gb) GB"
    echo "SYNC=OK $(TZ=America/New_York date)" ;;

build-run)
    echo "BUILD start $(TZ=America/New_York date)"
    grep -qs '^SYNC=OK' $(ls -t "$jobs"/sync-*.log "$jobs"/round-*.log 2>/dev/null | head -1) /dev/null \
        || { echo "BUILD=FAIL no sync ended SYNC=OK"; exit 1; }
    cd "$top"
    export USE_CCACHE=0   # its own tree: keep the release tree's ccache as it is
    source build/envsetup.sh
    echo "== lunch choices the cheetah trees offer"
    grep -hs -A8 COMMON_LUNCH_CHOICES device/google/pantah/AndroidProducts.mk || echo "(no AndroidProducts.mk lunch choices)"
    echo "== release configs AOSP $AOSP_TAG has"; ls build/release/release_configs 2>/dev/null | head -20 || true
    ok=
    for t in aosp_cheetah-trunk_staging-userdebug aosp_cheetah-userdebug; do
        echo "== lunch $t"
        # lunch can return 0 after a product-config error: check that it set the product
        if lunch "$t" && [[ -n ${TARGET_PRODUCT:-} ]] && get_build_var TARGET_DEVICE >/dev/null; then ok=$t; break; fi
    done
    if [[ -z $ok ]]; then
        # Each make error's own lines, so the next round's fix can be read off this log
        lunch aosp_cheetah-trunk_staging-userdebug 2>&1 | grep -oE '^[A-Za-z0-9_./-]+\.mk:[0-9]+: error' | sort -u |
        while IFS=: read -r f n _; do
            echo "== $f around line $n"; [[ -f $f ]] && sed -n "$(( n > 15 ? n - 15 : 1 )),$(( n + 5 ))p" "$f" | cat -n
        done
        echo "BUILD=FAIL lunch (the errors above are the device side's first list)"; exit 1
    fi
    echo "== m -k droid ($ok): keeps going past errors to list as many as it can"
    if m -k droid; then echo "BUILD=OK $(TZ=America/New_York date)"
    else echo "== errors"; grep -E '^(FAILED|error:)|error: ' out/error.log 2>/dev/null | head -100 || true
         echo "BUILD=FAIL m $(TZ=America/New_York date)"; exit 1; fi ;;
round-run)
    bash "$kitc/aosp-proto.sh" sync-run && bash "$kitc/aosp-proto.sh" build-run ;;
*) fail "usage: aosp-proto.sh status|sync|build|round|clean" ;;
esac
