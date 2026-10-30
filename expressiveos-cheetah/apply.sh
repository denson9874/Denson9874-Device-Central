#!/usr/bin/env bash
# Apply the ExpressiveOS cheetah tree patches (idempotent): patches/<project path with
# underscores>/*.patch as local commits (git am --3way, skipping a patch whose subject
# is already in the project's log), the same convention as evolution-cheetah; a folder
# whose project has a _ of its own names it in a PROJECT file. A project that's one of
# ExpressiveOS's own repos (README.md, "Sources") has them as commits already: there each is
# only checked, and a patch it lacks stops this (change such a repo with a commit). The set:
#   device_google_pantah 0001, 0002, 0010   ExpressiveOS's own: maintainer, update feed,
#                                           only ExpressiveOS's boot animation
#   device_google_pantah 0003-0009,         evolution-cheetah's, copied unchanged
#   device_google_gs201 0001-0005,
#   vendor_google_cheetah
#   device_google_gs201 0006                ExpressiveOS's own: target-files takes the built
#                                           system, vendor, product... images (incrementals)
#   frameworks_base                         the fixes the Evolution X tree carries for
#                                           every build there (evolution-kodiak's copies)
#   vendor_lineage 0001                     ExpressiveOS 1.0 names and the build's own date
#   vendor_lineage 0002                     evolution-kodiak's: stock's 60 fps game default
#   vendor_lineage 0003                     ExpressiveOS's own: m evolution keeps target-files
#   frameworks_base 0021-0024, Settings,    ExpressiveOS's branding: no screen names Evolution X
#   Evolver, Updater and the rest
#   packages_apps_Updater 0005              ExpressiveOS's own: an incremental is offered
#                                           only to its base build
#   packages_apps_Settings 0005,            the Bloom colours: the glowing wordmark and the
#   packages_apps_Updater 0006,             egg's stars take the logo's petals, not neon
#   packages_apps_EvoEgg 0003
#   system_update_engine 0001-0003          OTA payloads must be signed again (ExpressiveOS's
#                                           key; recovery's sideload also takes LineageOS's
#                                           release key, in its otacerts), never older
# Never evolution-cheetah's apply.sh, or its pantah 0001/0002: they point the Updater
# at Evolution X's feed. prepare.sh runs this; repo sync drops the local commits again.
# For another phone (EOS_DEVICE, devices/<device>.conf), its own devices/<device>/patches/
# come after the shared ones, and its device tree (EOS_DEVICE_TREE) must carry
# ExpressiveOS's maintainer and feed commits, "<device>: set ExpressiveOS's maintainer" and
# "<device>: get updates from denson9874/expressiveos_ota", as pantah's 0001 and 0002 do.
#
#   apply.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "APPLY=FAIL"' EXIT
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"
[[ $# -le 1 ]] || fail "usage: apply.sh [top]"
eos_top "${1:-}"

# The kit itself never points at Evolution X's feed. The other phones' patches may name it on
# the lines they take out (a tree that read it), never on a line they add
bad=$( { grep -l -- evolution_ota "$kit"/patches/*/*.patch
         grep -lE -- '^\+.*evolution_ota' "$kit"/ksu/patches/*/*.patch "$kit"/devices/*/patches/*/*.patch \
             "$kit"/devices/*/ksu-patches/*/*.patch 2>/dev/null; } || true)
[[ -z "$bad" ]] || fail "kit patches mention evolution_ota, Evolution X's feed: $bad"

# The shared patches/ (cheetah's among them), then this phone's own. ksu/ and viper4android/
# patches are apply-ksu.sh's and apply-v4a.sh's
dirs=("$kit"/patches/*/ "$kit/devices/$EOS_DEVICE"/patches/*/)
for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    project=$(basename "$dir")             # e.g. device_google_pantah
    patches=("$dir"*.patch)
    [[ -e "${patches[0]}" ]] || continue
    p=$(patch_project "$dir")
    am_patches "$top/$p" "$project" "${patches[@]}"
done

# Evolution X's own identity commits must not be in this phone's tree (evolution-cheetah's or
# evolution-husky's apply.sh run here by mistake), and ExpressiveOS's must be
dt="$top/$EOS_DEVICE_TREE"
project_ok "$dt"
if git -C "$dt" log --format=%s | grep -E -- "evolution_ota|^$EOS_DEVICE: set unofficial maintainer( overlay)?\$" >&2; then
    fail "$EOS_DEVICE_TREE has Evolution X's identity commits (above); drop them with: (cd $top && repo sync -d $EOS_DEVICE_TREE), then run this again"
fi
for s in "$EOS_DEVICE: set ExpressiveOS's maintainer" "$EOS_DEVICE: get updates from denson9874/expressiveos_ota"; do
    has_subject "$dt" "$s" || fail "$EOS_DEVICE_TREE lacks '$s'"
done
# ...and its Updater overlay's feed is ExpressiveOS's in the files too (a tree can carry Evolution
# X's feed from its first commit, under no subject); eos-verify.sh checks the built overlay again
# This phone's overlay only: the tree can hold its siblings' too (pantah's panther, shusky's shiba)
mapfile -t ovl < <(find "$dt" -path "$dt/.git" -prune -o -type d -name "$EOS_UPDATER_OVERLAY" -print)
(( ${#ovl[@]} )) || fail "$EOS_DEVICE_TREE has no $EOS_UPDATER_OVERLAY (devices/$EOS_DEVICE.conf's EOS_UPDATER_OVERLAY)"
bad=$(grep -rlE --include='*.xml' '<string name="updater_server_url"[^<]*>[^<]*evolution_ota' -- "${ovl[@]}" 2>/dev/null || true)
[[ -z "$bad" ]] || fail "$EOS_DEVICE_TREE's Updater still reads Evolution X's feed: ${bad//"$top"\//}"
done=1
echo "APPLY_OK"
