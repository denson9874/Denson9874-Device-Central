#!/usr/bin/env bash
# Free disk on the build server for the ExpressiveOS tree (about 450 GB with full history).
# Removes only the leftovers in the six groups below, which come from the runner's listing
# of 2026-10-26 (sizes then: 67, 56, 36, 68, 47 and 15 GB):
#   1  test, check and scratch copies          4  factory zips already unpacked
#   2  older releases the feeds have replaced  5  the emulator's build output
#   3  same-day fastboot rebuilds              6  older personal kodiak builds
# Exact paths only, never a pattern. Deleting is permanent, so `delete` runs only the
# groups Daryl approved. The builds the OTA feeds serve, the newest fastboot zip of each
# device, the newest personal builds and the image-*.zip files the pack scripts read are
# on the keep list: nothing on it, or holding it, is ever removed.
#
#   server-cleanup.sh list [groups]       # what's there now, with sizes; changes nothing
#   server-cleanup.sh delete <groups>     # e.g. delete 1,2,3,4,5,6
#
# The last line is CLEANUP=LISTED, OK, PARTIAL (group 5 waited for a build) or FAIL.
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "CLEANUP=FAIL"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

mode=${1:-}
groups=${2:-1,2,3,4,5,6}
[[ "$mode" = list || "$mode" = delete ]] && [[ $# -le 2 ]] || fail "usage: server-cleanup.sh list [groups] | delete <groups>"
[[ "$mode" = list || $# -eq 2 ]] || fail "delete needs the groups, e.g. delete 1,2"
[[ "$groups" =~ ^[1-6](,[1-6])*$ ]] || fail "groups are numbers 1-6 separated by commas, not '$groups'"

# The groups are read through a nameref (g$n)
R=releases
# shellcheck disable=SC2034
g1=(
    /tmp/kodiak-evox-img.zip
    /tmp/kodiak-evox-img-4021403-personal.zip
    /tmp/EvolutionX-17.0-20261011-kodiak-12.3-Unofficial-fastboot.zip
    "$R/derpfest-husky.evolution-keys-20261021-DO-NOT-RELEASE/"
    "$R/kodiak/test/"
    "$R/grizzly/test/"
    "$R/cubs/test/"
    "$R/yogi/test/"
    "$R/kodiak/check/"
    # check/ is the on-device gate's staging folder: its .device-ok records stay
    "$R/husky/check/EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip"
    "$R/husky/check/boot-20261024.img"
    "$R/husky/check/vendor_boot-20261024.img"
    "$R/husky/check/recovery-20261024.sha256"
    "$R/cheetah/check/EvolutionX-17.0-20261024-cheetah-12.3-Unofficial-fastboot.zip"
    "$R/cheetah/EvolutionX-17.0-20261018-cheetah-12.3-Unofficial-UNTESTED-fastboot.zip"
    "$R/cheetah/EvolutionX-17.0-20261018-cheetah-12.3-Unofficial-UNTESTED-r2-fastboot.zip"
)
# shellcheck disable=SC2034
g2=(
    "$R/kodiak/EvolutionX-17.0-20261023-kodiak-12.3-Unofficial.zip"
    "$R/kodiak/EvolutionX-17.0-20261023-kodiak-12.3-Unofficial-fastboot.zip"
    "$R/kodiak/EvolutionX-17.0-20261023-kodiak-12.3-Unofficial-r2-fastboot.zip"
    "$R/yogi/EvolutionX-17.0-20261023-yogi-12.3-Unofficial-fastboot.zip"
    "$R/yogi/EvolutionX-17.0-20261024-yogi-12.3-Unofficial.zip"
    "$R/grizzly/EvolutionX-17.0-20261023-grizzly-12.3-Unofficial-fastboot.zip"
    "$R/grizzly/EvolutionX-17.0-20261024-grizzly-12.3-Unofficial.zip"
    "$R/cubs/EvolutionX-17.0-20261023-cubs-12.3-Unofficial-fastboot.zip"
    "$R/cubs/EvolutionX-17.0-20261024-cubs-12.3-Unofficial.zip"
    "$R/husky/EvolutionX-17.0-20261016-husky-12.3-Unofficial.zip"
    "$R/husky/EvolutionX-17.0-20261021-husky-12.3-Unofficial.zip"
    "$R/husky/EvolutionX-17.0-20261023-husky-12.3-Unofficial.zip"
    "$R/derpfest-husky/DerpFest-v17-20261021-husky-Unofficial-Stable.zip"
    "$R/derpfest-husky/DerpFest-v17-20261023-husky-Unofficial-Stable.zip"
    "$R/emulator/EvolutionX-emulator-emu64a-20261023-2111.zip"
)
# shellcheck disable=SC2034
g3=(
    "$R/yogi/EvolutionX-17.0-20261024-yogi-12.3-Unofficial-fastboot.zip"
    "$R/yogi/EvolutionX-17.0-20261024-yogi-12.3-Unofficial-r2-fastboot.zip"
    "$R/grizzly/EvolutionX-17.0-20261024-grizzly-12.3-Unofficial-fastboot.zip"
    "$R/grizzly/EvolutionX-17.0-20261024-grizzly-12.3-Unofficial-r2-fastboot.zip"
    "$R/cubs/EvolutionX-17.0-20261024-cubs-12.3-Unofficial-fastboot.zip"
    "$R/cubs/EvolutionX-17.0-20261024-cubs-12.3-Unofficial-r2-fastboot.zip"
    "$R/kodiak/EvolutionX-17.0-20261024-kodiak-12.3-Unofficial-fastboot.zip"
)
F=android-dt/firmware
# shellcheck disable=SC2034
g4=(
    "$F/kodiak-cd1a.261005.003-factory-006d44d7.zip"
    "$F/yogi-cd1a.261005.003-factory-0f9fd538.zip"
    "$F/grizzly-cd1a.261005.003-factory-7c6dad8a.zip"
    "$F/cubs-cd1a.261005.003-factory-38087b24.zip"
    "$F/cheetah-cp3a.261005.002.a1-factory-5b5b06ad.zip"
    "$F/husky-cp3a.261005.005-factory-4b94ad0e.zip"
)
# shellcheck disable=SC2034
g5=(evolution/out/target/product/emu64a/)
# shellcheck disable=SC2034
g6=(
    "$R/kodiak-personal/EvolutionX-17.0-20261012-kodiak-12.3-Unofficial-personal-keep-initboot.zip"
    "$R/kodiak-personal/EvolutionX-17.0-20261013-kodiak-12.3-Unofficial-personal-keep-initboot.zip"
    "$R/kodiak-personal/EvolutionX-17.0-20261014-kodiak-12.3-Unofficial-personal-keep-initboot.zip"
)
keep=(
    # What evolution_ota and derpfest_ota serve (2026-10-26)
    "$R/cheetah/EvolutionX-17.0-20261024-cheetah-12.3-Unofficial.zip"
    "$R/cubs/EvolutionX-17.0-20261024-cubs-12.3-Unofficial-r2.zip"
    "$R/grizzly/EvolutionX-17.0-20261024-grizzly-12.3-Unofficial-r2.zip"
    "$R/husky/EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip"
    "$R/kodiak/EvolutionX-17.0-20261024-kodiak-12.3-Unofficial.zip"
    "$R/yogi/EvolutionX-17.0-20261024-yogi-12.3-Unofficial-r2.zip"
    "$R/derpfest-husky/DerpFest-v17-20261024-husky-Unofficial-Stable.zip"
    # The newest fastboot zip of each device
    "$R/cheetah/EvolutionX-17.0-20261024-cheetah-12.3-Unofficial-fastboot.zip"
    "$R/cubs/EvolutionX-17.0-20261024-cubs-12.3-Unofficial-r3-fastboot.zip"
    "$R/grizzly/EvolutionX-17.0-20261024-grizzly-12.3-Unofficial-r3-fastboot.zip"
    "$R/yogi/EvolutionX-17.0-20261024-yogi-12.3-Unofficial-r3-fastboot.zip"
    "$R/kodiak/EvolutionX-17.0-20261024-kodiak-12.3-Unofficial-r2-fastboot.zip"
    # The newest personal and emulator builds
    "$R/cheetah/personal/EvolutionX-17.0-20261019-cheetah-12.3-Unofficial-personal-magisk-fastboot.zip"
    "$R/kodiak-personal/EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot.zip"
    "$R/emulator/EvolutionX-emulator-POWERFIX-20261024-0353.zip"
    # Firmware the pack scripts and fetch-firmware.sh use
    "$F/image-kodiak-cd1a.261005.003.zip"
    "$F/image-yogi-cd1a.261005.003.zip"
    "$F/image-grizzly-cd1a.261005.003.zip"
    "$F/image-cubs-cd1a.261005.003.zip"
    "$F/image-cheetah-cp3a.261005.002.a1.zip"
    "$F/image-husky-cp3a.261005.005.zip"
    "$F/cheetah/"
    "$R/husky/check/EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip.device-ok"
    "$R/cheetah/check/EvolutionX-17.0-20261024-cheetah-12.3-Unofficial.zip.device-ok"
)

home=$(cd ~ && pwd -P)
# Absolute path of an entry: /tmp entries as they are, the rest under ~
abs() { local p=${1%/}; [[ "$p" = /* ]] && echo "$p" || echo "$home/$p"; }
# Only things inside these folders may go (the emulator's output folder itself too)
allowed() {
    local p=$1 r
    [[ "$p" = "$home/evolution/out/target/product/emu64a" ]] && return 0
    for r in "$home/releases" "$home/android-dt/firmware" /tmp; do
        [[ "$p" = "$r"/* ]] && return 0
    done
    return 1
}
# Checksum files the pack scripts and the release step write next to a zip
sidecars() { local f; for f in "$1.sha256" "$1.sha256sum" "$1.md5sum" "${1%.zip}.sha256"; do [[ -f "$f" && ! -L "$f" ]] && echo "$f"; done; return 0; }
size_of() { nice -n 19 ionice -c2 -n7 du -s -B1 --apparent-size -- "$@" 2>/dev/null | awk '{s += $1} END {print s + 0}'; }
human() { numfmt --to=iec --suffix=B "$1"; }

# Nothing on the keep list may be a target, or inside one
for k in "${keep[@]}"; do
    K=$(abs "$k")
    for n in 1 2 3 4 5 6; do
        declare -n list="g$n"
        for t in "${list[@]}"; do
            T=$(abs "$t")
            [[ "$K" != "$T" && "$K" != "$T"/* && "$T" != "$K"/* ]] || fail "group $n's $t would remove $k, or part of it, which is kept"
        done
        unset -n list
    done
done

build_running() { pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null; }
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
        if [[ "$t" = */ ]]; then
            [[ -d "$T" ]] || fail "$T should be a folder (nothing was removed)"
        else
            [[ -f "$T" ]] || fail "$T should be a file (nothing was removed)"
        fi
    done
    unset -n list
done

echo "== $mode, groups $groups ($(df -h --output=avail ~ | tail -1 | tr -d ' ') free)"
total=0 skipped=0
for n in "${chosen[@]}"; do
    declare -n list="g$n"
    echo "== group $n"
    gsum=0
    for t in "${list[@]}"; do
        T=$(abs "$t")
        if [[ ! -e "$T" ]]; then echo "gone     $t"; continue; fi
        side=()
        if [[ -d "$T" ]]; then
            s=$(size_of "$T")
            echo "folder   $(human "$s")  $t"
            if [[ "$mode" = list && $n != 5 ]]; then
                find "$T" -mindepth 1 -printf '           %y %s %P\n' | sort -k3 | numfmt --to=iec --field=2 | head -40 || true
            fi
        else
            mapfile -t side < <(sidecars "$T")
            s=$(size_of "$T" ${side[@]+"${side[@]}"})
            echo "file     $(human "$s")  $t${side[*]:+ (+ ${#side[@]} checksum file)}"
        fi
        if [[ "$mode" = delete ]]; then
            if [[ $n = 5 ]]; then
                # The emulator's output only while nothing builds in ~/evolution
                if build_running; then echo "SKIPPED  $t: a build is running; run group 5 again when the server is idle"; skipped=1; continue; fi
                exec 9>"$home/.evolution-tree.lock"
                flock -n 9 || { echo "SKIPPED  $t: the tree lock is held; run group 5 again later"; exec 9>&-; skipped=1; continue; }
                rm -rf --one-file-system -- "$T"
                exec 9>&-
            elif [[ -d "$T" ]]; then
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
    echo "== freed $(human "$total"); $free_now free now; group 5 was skipped"
    echo "CLEANUP=PARTIAL"
else
    echo "== freed $(human "$total"); $free_now free now"
    echo "CLEANUP=OK"
fi
