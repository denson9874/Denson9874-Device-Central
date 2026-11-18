#!/usr/bin/env bash
# ExpressiveOS on AOSP, cheetah only: the EXPERIMENT of branch eos/aosp (README.md here).
# Its own tree, ~/eos-aosp, never ~/expressiveos; its own tmux session, eos-aosp; its log in
# ~/expressiveos-jobs/aosp/. Nothing here builds, packs, signs, uploads or flashes a release.
#
#   aosp-proto.sh status   read-only: session, logs' last lines, the tree's size, free disk
#   aosp-proto.sh sync     repo init AOSP android-17.0.0_r1 (depth 1) + eos-aosp-cheetah.xml, repo sync
#   aosp-proto.sh build    lunch aosp_cheetah, then m -k nothing (analysis only): what fails is the result
#   aosp-proto.sh full     the same with m -k droid: the whole image, hours, holds the server
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
    for f in $(ls -t "$jobs"/*.log 2>/dev/null | head -1); do
        echo "== $f (last 150 lines)"; tail -n 150 "$f"
    done ;;
sync)  start sync ;;
build) start build ;;
full)  start full ;;
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
    # build-run's stand-in edit of the blobs' Android.bp: put it back so repo sync updates cleanly
    if [[ -e vendor/google/cheetah/.git ]]; then git -C vendor/google/cheetah checkout -- Android.bp 2>/dev/null || true; fi
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
    # Round 3: the cheetah trees set these only in lineage_cheetah.mk:11-13, and BoardConfig.mk:22
    # includes $(DEVICE_PATH)/BoardConfigCommon.mk; aosp_cheetah.mk leaves them empty
    export DEVICE_CODENAME=cheetah DEVICE_PATH=device/google/pantah VENDOR_PATH=vendor/google/cheetah
    # Round 5: the blobs declare dump_modem and gpuflag as rust_prebuilt_binary, a module type
    # only Lineage's build/soong has. STAND-IN, in this throwaway tree only (sync-run puts the
    # file back): declare them as plain prebuilt binaries without the Rust library links
    python3 - vendor/google/cheetah/Android.bp <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
n = s.count("rust_prebuilt_binary {") + s.count("rust_prebuilt_dylib {")
s = s.replace("rust_prebuilt_binary {", "cc_prebuilt_binary {\n    check_elf_files: false,")
# Round 6: AOSP's Soong refuses Rust prebuilts outside the system image (libgpuflag_aconfig_rust)
s = s.replace("rust_prebuilt_dylib {", "cc_prebuilt_library_shared {\n    check_elf_files: false,")
s = re.sub(r"\n\s*rustlibs: \[[^\]]*\],", "", s)
open(p, "w").write(s); print(f"== stand-in: {n} Rust prebuilt blobs declared as plain cc prebuilts")
PY
    # Round 7: Soong stops at the first module that depends on a Lineage-only module
    # (gs201/parts' GoogleParts needs org.lineageos.settings.resources). Let it go on, so one
    # round lists every such dependency; m -k then fails each of those modules on its own
    export ALLOW_MISSING_DEPENDENCIES=true
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
            echo "== $f, lines 1-$(( n + 5 ))"; if [[ -f $f ]]; then sed -n "1,$(( n + 5 ))p" "$f" | cat -n; fi
        done || true   # lunch's own failure ends this pipeline non-zero (pipefail)
        # Where the device trees set the folder variables a Lineage-style tree uses
        echo "== DEVICE_PATH / DEVICE_CODENAME / VENDOR_PATH set in device/google and vendor/google"
        grep -rnE '^\s*(DEVICE_PATH|DEVICE_CODENAME|VENDOR_PATH|COMMON_PATH)\s*[:?]?=' device/google vendor/google 2>/dev/null | head -30 || true
        echo "== products the cheetah trees define"
        { grep -rlE 'PRODUCT_NAME\s*:?=' device/google/pantah 2>/dev/null | head || true; }; grep -rhE 'PRODUCT_MAKEFILES|COMMON_LUNCH' device/google/pantah/AndroidProducts.mk 2>/dev/null || true
        echo "BUILD=FAIL lunch (the errors above are the device side's first list)"; exit 1
    fi
    # build: analysis only (Soong and Kati, minutes, no compiling), so a missing-module list
    # doesn't hold the server for hours. full: m -k droid, the whole image, hours
    goal=nothing; if [[ ${2:-} == full ]]; then goal=droid; fi
    echo "== m -k $goal ($ok): keeps going past errors to list as many as it can"
    if m -k "$goal"; then echo "BUILD=OK ($goal) $(TZ=America/New_York date)"
    else echo "== errors"; grep -E '^(FAILED|error:)|error: ' out/error.log 2>/dev/null | head -100 || true
         echo "== missing modules (count, what)"
         grep -ohE 'missing dependencies: .*|depends on undefined module "[^"]+"' out/error.log out/soong/*.log 2>/dev/null |
             sed -E 's/^missing dependencies: //' | tr ',' '\n' | sed 's/^ *//' | sort | uniq -c | sort -rn | head -80 || true
         echo "BUILD=FAIL m $(TZ=America/New_York date)"; exit 1; fi ;;
full-run)
    bash "$kitc/aosp-proto.sh" build-run full ;;
round-run)
    bash "$kitc/aosp-proto.sh" sync-run && bash "$kitc/aosp-proto.sh" build-run ;;
*) fail "usage: aosp-proto.sh status|sync|build|full|round|clean" ;;
esac
