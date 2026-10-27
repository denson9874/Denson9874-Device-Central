#!/usr/bin/env bash
# Apply the ExpressiveOS cheetah tree patches (idempotent): patches/<project path with
# underscores>/*.patch as local commits (git am --3way, skipping a patch whose subject
# is already in the project's log), the same convention as evolution-cheetah. The set:
#   device_google_pantah 0001, 0002, 0010   ExpressiveOS's own: maintainer, update feed,
#                                           only ExpressiveOS's boot animation
#   device_google_pantah 0003-0009,         evolution-cheetah's, copied unchanged
#   device_google_gs201, vendor_google_cheetah
#   frameworks_base                         the fixes the Evolution X tree carries for
#                                           every build there (evolution-kodiak's copies)
#   vendor_lineage 0001                     ExpressiveOS 1.0 names and the build's own date
#   vendor_lineage 0002                     evolution-kodiak's: stock's 60 fps game default
#   frameworks_base 0021-0024, Settings,    ExpressiveOS's branding: no screen names Evolution X
#   Evolver, Updater and the rest
# Never evolution-cheetah's apply.sh, or its pantah 0001/0002: they point the Updater
# at Evolution X's feed. prepare.sh runs this; repo sync drops the commits again.
#
#   apply.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "APPLY=FAIL"' EXIT
# shellcheck source=lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/lib.sh"
[[ $# -le 1 ]] || fail "usage: apply.sh [top]"
eos_top "${1:-}"

# The kit itself never points at Evolution X's feed
bad=$(grep -l -- evolution_ota "$kit"/patches/*/*.patch || true)
[[ -z "$bad" ]] || fail "kit patches mention evolution_ota, Evolution X's feed: $bad"

for dir in "$kit"/patches/*/; do
    project=$(basename "$dir")             # e.g. device_google_pantah
    patches=("$dir"*.patch)
    [[ -e "${patches[0]}" ]] || continue
    am_patches "$top/$(patch_project "$dir")" "$project" "${patches[@]}"
done

# Evolution X's own identity patches must not be in this tree (evolution-cheetah's
# apply.sh run here by mistake), and ExpressiveOS's must be
pantah="$top/device/google/pantah"
if git -C "$pantah" log --format=%s | grep -E -- 'evolution_ota|^cheetah: set unofficial maintainer$' >&2; then
    fail "device/google/pantah has Evolution X's identity commits (above); drop them with: (cd $top && repo sync -d device/google/pantah), then run this again"
fi
for p in "$kit"/patches/device_google_pantah/000[12]-*.patch; do
    s=$(subject_of "$p")
    has_subject "$pantah" "$s" || fail "device/google/pantah lacks '$s'"
done
done=1
echo "APPLY_OK"
