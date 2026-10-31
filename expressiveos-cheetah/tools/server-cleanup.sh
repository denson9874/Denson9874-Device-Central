#!/usr/bin/env bash
# Free disk on the build server. Second round (2026-10-31); the first round's seven groups
# (2026-10-26: release zips, test copies, factory zips, the emulator's product output) are
# all gone, and git history has them. The groups below come from the runner's server-usage
# listing of 2026-10-31 (sizes then):
#   1  scratch and an old cache: /tmp/kimg (Oct 10) and ~/.cache/ccache, unused since
#      Oct 9 (ccache's cache is ~/.ccache)                                         ~13 GB
#   2  Evolution X's emulator leftovers: lineage_sdk_phone_arm64's own files in
#      ~/evolution/out and out/soong (its product output went on 2026-10-26)       ~12 GB
#   3  DerpFest's kodiak build: its product output (last built Oct 19; DerpFest's feed is
#      husky only) and lineage_kodiak's own files in ~/derpfest/out and out/soong  ~26 GB
#   4  all of DerpFest's build output: ~/derpfest/out and ~/derpfest/out-kernel (its
#      source stays; the next DerpFest build starts from scratch)                 ~175 GB
#   5  ExpressiveOS's kodiak build output, ~/expressiveos/out/target/product/kodiak (its
#      root test build is packed in check/; the next kodiak build redoes it)       ~29 GB
#   6  ExpressiveOS's husky candidate in check/ (testers-only, Oct 30)             ~13 GB
#   7  the reeky LineageOS kodiak reference: ~/android-dt/ref/reeky, ~/android-dt/reeky
#                                                                                   ~22 GB
# Exact paths only, never a pattern, and deleting is permanent, so `delete` runs only the
# groups Daryl approved, and only while it holds the tree lock the routines and builds take
# (and ExpressiveOS's lock for groups 5 and 6), so nothing is removed from under a routine,
# a build or a pack. Groups 2-5 remove build output, so they also wait until no build runs
# at all (soong_ui or ninja, in any tree) and no ExpressiveOS tmux session (eos-build,
# eos-pack) is open. Nothing on the keep list goes, nor anything holding it: the firmware
# the pack scripts read, every product output a weekly routine or an open thread builds on
# (Evolution X's six phones, ExpressiveOS's cheetah), the ExpressiveOS records (out/eos*),
# the check/ candidates in use (cheetah's integrity test build, kodiak's root test build),
# the DDK, the stock dumps and ccache's cache. No folder holding an on-device gate's
# .device-ok record is removed either, nor the newest ExpressiveOS release's target-files
# (~/releases/expressiveos-*/target-files/LATEST).
#
#   server-cleanup.sh list [groups]       # what's there now, with sizes; changes nothing
#   server-cleanup.sh delete <groups>     # e.g. delete 1,2
#
# The last line is CLEANUP=LISTED, OK, PARTIAL (a group was skipped: a build was running)
# or FAIL.
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "CLEANUP=FAIL"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

mode=${1:-}
groups=${2:-1,2,3,4,5,6,7}
[[ "$mode" = list || "$mode" = delete ]] && [[ $# -le 2 ]] || fail "usage: server-cleanup.sh list [groups] | delete <groups>"
[[ "$mode" = list || $# -eq 2 ]] || fail "delete needs the groups, e.g. delete 1,2"
[[ "$groups" =~ ^[1-7](,[1-7])*$ ]] || fail "groups are numbers 1-7 separated by commas, not '$groups'"

# The groups are read through a nameref (g$n). Entries ending in / are folders
E=evolution/out D=derpfest/out X=expressiveos/out R=releases A=android-dt
# shellcheck disable=SC2034
g1=(
    /tmp/kimg/
    .cache/ccache/
)
# shellcheck disable=SC2034
g2=(
    "$E/build-lineage_sdk_phone_arm64-cleanspec.ninja"
    "$E/build-lineage_sdk_phone_arm64.ninja"
    "$E/build-lineage_sdk_phone_arm64-package.ninja"
    "$E/combined-lineage_sdk_phone_arm64.ninja"
    "$E/env-lineage_sdk_phone_arm64-cleanspec.sh"
    "$E/env-lineage_sdk_phone_arm64-package.sh"
    "$E/env-lineage_sdk_phone_arm64.sh"
    "$E/.kati_stamp-lineage_sdk_phone_arm64"
    "$E/.kati_stamp-lineage_sdk_phone_arm64-cleanspec"
    "$E/.kati_stamp-lineage_sdk_phone_arm64-package"
    "$E/ninja-lineage_sdk_phone_arm64-cleanspec.sh"
    "$E/ninja-lineage_sdk_phone_arm64-package.sh"
    "$E/ninja-lineage_sdk_phone_arm64.sh"
    "$E/soong/Android-lineage_sdk_phone_arm64.mk"
    "$E/soong/build.lineage_sdk_phone_arm64.0.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.1.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.2.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.3.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.4.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.5.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.6.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.7.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.8.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.9.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.ninja"
    "$E/soong/build.lineage_sdk_phone_arm64.ninja.d"
    "$E/soong/build.lineage_sdk_phone_arm64.ninja.glob_results"
    "$E/soong/build.lineage_sdk_phone_arm64.ninja.globs"
    "$E/soong/build.lineage_sdk_phone_arm64.ninja.globs_time"
    "$E/soong/build_uuid-lineage_sdk_phone_arm64.txt"
    "$E/soong/dexpreopt-lineage_sdk_phone_arm64.config"
    "$E/soong/installs-lineage_sdk_phone_arm64.mk"
    "$E/soong/kati_packaging-lineage_sdk_phone_arm64/"
    "$E/soong/late-lineage_sdk_phone_arm64.mk"
    "$E/soong/make_vars-lineage_sdk_phone_arm64.mk"
    "$E/soong/module-info-lineage_sdk_phone_arm64.json"
    "$E/soong/raw-lineage_sdk_phone_arm64/"
    "$E/soong/soong.environment.used.lineage_sdk_phone_arm64.build"
    "$E/soong/soong.lineage_sdk_phone_arm64.extra.variables"
    "$E/soong/soong.lineage_sdk_phone_arm64.variables"
)
# shellcheck disable=SC2034
g3=(
    "$D/target/product/kodiak/"
    "$D/build-lineage_kodiak-cleanspec.ninja"
    "$D/build-lineage_kodiak.ninja"
    "$D/build-lineage_kodiak-package.ninja"
    "$D/combined-lineage_kodiak.ninja"
    "$D/env-lineage_kodiak-cleanspec.sh"
    "$D/env-lineage_kodiak-package.sh"
    "$D/env-lineage_kodiak.sh"
    "$D/.kati_stamp-lineage_kodiak"
    "$D/.kati_stamp-lineage_kodiak-cleanspec"
    "$D/.kati_stamp-lineage_kodiak-package"
    "$D/ninja-lineage_kodiak-cleanspec.sh"
    "$D/ninja-lineage_kodiak-package.sh"
    "$D/ninja-lineage_kodiak.sh"
    "$D/soong/Android-lineage_kodiak.mk"
    "$D/soong/build.lineage_kodiak.0.ninja"
    "$D/soong/build.lineage_kodiak.1.ninja"
    "$D/soong/build.lineage_kodiak.2.ninja"
    "$D/soong/build.lineage_kodiak.3.ninja"
    "$D/soong/build.lineage_kodiak.4.ninja"
    "$D/soong/build.lineage_kodiak.5.ninja"
    "$D/soong/build.lineage_kodiak.6.ninja"
    "$D/soong/build.lineage_kodiak.7.ninja"
    "$D/soong/build.lineage_kodiak.8.ninja"
    "$D/soong/build.lineage_kodiak.9.ninja"
    "$D/soong/build.lineage_kodiak.ninja"
    "$D/soong/build.lineage_kodiak.ninja.d"
    "$D/soong/build.lineage_kodiak.ninja.glob_results"
    "$D/soong/build.lineage_kodiak.ninja.globs"
    "$D/soong/build.lineage_kodiak.ninja.globs_time"
    "$D/soong/build_uuid-lineage_kodiak.txt"
    "$D/soong/dexpreopt-lineage_kodiak.config"
    "$D/soong/installs-lineage_kodiak.mk"
    "$D/soong/kati_packaging-lineage_kodiak/"
    "$D/soong/late-lineage_kodiak.mk"
    "$D/soong/make_vars-lineage_kodiak.mk"
    "$D/soong/module-info-lineage_kodiak.json"
    "$D/soong/raw-lineage_kodiak/"
    "$D/soong/soong.environment.used.lineage_kodiak.build"
    "$D/soong/soong.lineage_kodiak.extra.variables"
    "$D/soong/soong.lineage_kodiak.variables"
)
# shellcheck disable=SC2034
g4=(
    "$D/"
    derpfest/out-kernel/
)
# shellcheck disable=SC2034
g5=("$X/target/product/kodiak/")
H=$R/expressiveos-husky/check/ExpressiveOS-17.0-20261030-husky-1.0-Unofficial
# shellcheck disable=SC2034
g6=(
    "$H-fastboot.zip"
    "$H-fastboot.zip.pack-ok"
    "$H-init_boot-stock.img"
    "$H-kernel-manifest.xml"
    "$H-manifest.xml"
    "$H-sources.txt"
    "$H-target_files.zip"
)
# shellcheck disable=SC2034
g7=(
    "$A/ref/reeky/"
    "$A/reeky/"
)
F=$A/firmware
keep=(
    # Firmware the pack scripts and fetch-firmware.sh read
    "$F/image-kodiak-cd1a.261005.003.zip"
    "$F/image-yogi-cd1a.261005.003.zip"
    "$F/image-grizzly-cd1a.261005.003.zip"
    "$F/image-cubs-cd1a.261005.003.zip"
    "$F/image-cheetah-cp3a.261005.002.a1.zip"
    "$F/image-husky-cp3a.261005.005.zip"
    "$F/cheetah/"
    # What the next builds start from: the weekly routines' six phones, ExpressiveOS's cheetah
    "$E/target/product/cheetah/"
    "$E/target/product/husky/"
    "$E/target/product/kodiak/"
    "$E/target/product/grizzly/"
    "$E/target/product/cubs/"
    "$E/target/product/yogi/"
    "$X/target/product/cheetah/"
    "$X/eos/"
    "$X/eos-husky/"
    "$X/eos-kodiak/"
    # Candidates in use: cheetah's integrity test build (on the 7 Pro), kodiak's root test build
    "$R/expressiveos-cheetah/check/"
    "$R/expressiveos-kodiak/check/"
    # Gate records, the KernelSU Next DDK, the stock dumps, ccache's cache
    "$R/husky/check/EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip.device-ok"
    "$R/cheetah/check/EvolutionX-17.0-20261024-cheetah-12.3-Unofficial.zip.device-ok"
    "$A/ddk/"
    "$A/dumps/"
    .ccache/
)

home=$(cd ~ && pwd -P)
# Absolute path of an entry: /tmp entries as they are, the rest under ~
abs() { local p=${1%/}; [[ "$p" = /* ]] && echo "$p" || echo "$home/$p"; }
# Only things inside these folders may go, and these two folders themselves
allowed() {
    local p=$1 r
    [[ "$p" = "$home/derpfest/out" || "$p" = "$home/derpfest/out-kernel" ]] && return 0
    for r in "$home/releases" "$home/android-dt/ref" "$home/android-dt" "$home/.cache" /tmp \
             "$home/evolution/out" "$home/derpfest/out" "$home/expressiveos/out"; do
        [[ "$p" = "$r"/* ]] && return 0
    done
    return 1
}
# The newest ExpressiveOS release's target-files (target-files/LATEST), and the newest by
# date in each such folder too, should LATEST be missing or stale: kept, with their .sha256
for d in "$home/$R"/expressiveos-*/target-files; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    rel=${d#"$home"/}
    n=$(head -n 1 -- "$d/LATEST" 2>/dev/null || true)
    [[ -z "$n" || "$n" =~ ^ExpressiveOS-[A-Za-z0-9._-]+-target_files\.zip$ ]] || fail "$d/LATEST names '$n', not an ExpressiveOS target-files zip"
    newest=$(find "$d" -maxdepth 1 -type f -name 'ExpressiveOS-*-target_files.zip' -printf '%T@ %f\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
    [[ "$newest" != "$n" ]] || newest=''
    keep+=("$rel/LATEST")
    for z in "$n" "$newest"; do [[ -z "$z" ]] || keep+=("$rel/$z" "$rel/$z.sha256"); done
done
# Checksum files the pack scripts and the release step write next to a zip or image
sidecars() { # each checksum file beside $1, once (name.sha256 for a .zip too)
    local f; local -a c=("$1.sha256" "$1.sha256sum" "$1.md5sum")
    [[ $1 == *.zip ]] && c+=("${1%.zip}.sha256")
    for f in "${c[@]}"; do [[ -f "$f" && ! -L "$f" ]] && echo "$f"; done; return 0
}
size_of() { nice -n 19 ionice -c2 -n7 du -s -B1 --apparent-size -- "$@" 2>/dev/null | awk '{s += $1} END {print s + 0}'; }
human() { numfmt --to=iec --suffix=B "$1"; }

# Nothing on the keep list may be a target, or inside one, or hold one
for k in "${keep[@]}"; do
    K=$(abs "$k")
    for n in 1 2 3 4 5 6 7; do
        declare -n list="g$n"
        for t in "${list[@]}"; do
            T=$(abs "$t")
            [[ "$K" != "$T" && "$K" != "$T"/* && "$T" != "$K"/* ]] || fail "group $n's $t would remove $k, or part of it, which is kept"
        done
        unset -n list
    done
done

# Group 1's old cache must not be the one ccache uses now
if [[ ",$groups," == *,1,* ]] && command -v ccache >/dev/null; then
    ccdir=$(ccache --get-config cache_dir 2>/dev/null || ccache -k cache_dir 2>/dev/null || true)
    [[ -n $ccdir ]] || fail "can't read ccache's cache_dir; not touching ~/.cache/ccache (nothing was removed)"
    [[ "$(realpath -m -- "$ccdir")" != "$home/.cache/ccache" ]] || fail "ccache's cache_dir is ~/.cache/ccache, in use (nothing was removed)"
fi

build_running() { pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null; }
eos_session() { local s; for s in eos-build eos-pack; do tmux has-session -t "=$s" 2>/dev/null && return 0; done; return 1; }
IFS=, read -r -a chosen <<<"$groups"

# Check every target first, so a bad one stops the run before anything is removed
for n in "${chosen[@]}"; do
    declare -n list="g$n"
    for t in "${list[@]}"; do
        T=$(abs "$t")
        [[ ! -L "$T" ]] || fail "$T is a symlink; not touching it (nothing was removed)"
        [[ -e "$T" ]] || continue
        r=$(realpath -e -- "$T")
        if [[ "$r" != "$T" ]] || ! allowed "$r"; then fail "$T resolves to $r, outside the folders this may clean (nothing was removed)"; fi
        [[ "$(stat -c %u -- "$T")" = "$(id -u)" ]] || fail "$T isn't this account's (nothing was removed)"
        if [[ "$t" = */ ]]; then
            [[ -d "$T" ]] || fail "$T should be a folder (nothing was removed)"
            [[ -z "$(find "$T" -name '*.device-ok' -print -quit)" ]] \
                || fail "$T holds an on-device gate's .device-ok record; not removing it (nothing was removed)"
        else
            [[ -f "$T" ]] || fail "$T should be a file (nothing was removed)"
        fi
    done
    unset -n list
done

if [[ "$mode" = delete ]]; then
    # Held to the end: no routine or build starts while files go
    exec 9>"$home/.evolution-tree.lock"
    flock -n 9 || fail "the tree lock is held (a routine or build is running); run delete again later (nothing was removed)"
    if [[ ",$groups," =~ ,[56], ]]; then
        exec 8>"$home/.expressiveos.lock"
        flock -n 8 || fail "ExpressiveOS's lock is held (a build, pack or kit script is running); run delete again later (nothing was removed)"
    fi
fi
echo "== $mode, groups $groups ($(df -h --output=avail ~ | tail -1 | tr -d ' ') free)"
total=0 skipped=0
for n in "${chosen[@]}"; do
    declare -n list="g$n"
    echo "== group $n"
    gsum=0 skip=''
    if [[ "$mode" = delete && $n =~ ^[2345]$ ]]; then
        # Build output only while nothing builds, in any tree, even by hand
        if build_running; then skip="a build is running"; elif eos_session; then skip="an ExpressiveOS build or pack session is open"; fi
    fi
    if [[ -n $skip ]]; then
        echo "SKIPPED  group $n: $skip; run it again when the server is idle"
        skipped=1; unset -n list; continue
    fi
    for t in "${list[@]}"; do
        T=$(abs "$t")
        if [[ ! -e "$T" ]]; then echo "gone     $t"; continue; fi
        side=()
        if [[ -d "$T" ]]; then
            s=$(size_of "$T")
            echo "folder   $(human "$s")  $t"
            if [[ "$mode" = list && $n =~ ^[167]$ ]]; then
                find "$T" -mindepth 1 -maxdepth 1 -printf '           %y %s %P\n' | sort -k3 | numfmt --invalid=ignore --to=iec --field=2 | head -20 || true
            fi
        else
            mapfile -t side < <(sidecars "$T")
            s=$(size_of "$T" ${side[@]+"${side[@]}"})
            echo "file     $(human "$s")  $t${side[*]:+ (+ ${#side[@]} checksum file(s))}"
        fi
        if [[ "$mode" = delete ]]; then
            if [[ -d "$T" ]]; then
                rm -rf --one-file-system -- "$T"
            else
                rm -f -- "$T" ${side[@]+"${side[@]}"}
            fi
            [[ ! -e "$T" ]] || fail "couldn't remove $T"
            echo "removed  $t"
        fi
        gsum=$((gsum + s))
    done
    unset -n list
    echo "   group $n: $(human "$gsum")"
    total=$((total + gsum))
done

echo "== kept, never touched"
for k in "${keep[@]}"; do
    K=$(abs "$k")
    if [[ -e "$K" ]]; then echo "ok       $k"; else echo "absent   $k"; fi
done
done=1
free_now=$(df -h --output=avail ~ | tail -1 | tr -d ' ')
if [[ "$mode" = list ]]; then
    echo "== would free $(human "$total") ($free_now free now)"
    echo "CLEANUP=LISTED"
elif [[ $skipped = 1 ]]; then
    echo "== freed $(human "$total"); $free_now free now; a group was skipped"
    echo "CLEANUP=PARTIAL"
else
    echo "== freed $(human "$total"); $free_now free now"
    echo "CLEANUP=OK"
fi
