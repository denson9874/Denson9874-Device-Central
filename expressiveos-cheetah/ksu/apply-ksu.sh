#!/usr/bin/env bash
# Put ExpressiveOS's KernelSU Next pieces into a cheetah tree (idempotent): this
# kit's device/google/pantah patches as local commits (preinstalled manager, and
# init_boot from CHEETAH_KSU_INIT_BOOT), and the manager APK fetch-ksu.sh
# downloaded. Run it after the tree's own patches, on every build (repo sync
# drops local commits). Never on the Evolution X cheetah tree: its users aren't
# meant to be rooted.
#
#   apply-ksu.sh [top]      # default ~/expressiveos
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
top="$(cd "${1:-$HOME/expressiveos}" && pwd)"
[[ "$top" != "$HOME/evolution" ]] || { echo "FAIL: $top is the Evolution X tree; KernelSU Next is for ExpressiveOS only" >&2; exit 1; }
for dir in "$here"/patches/*/; do
    project="$(basename "$dir")"            # device_google_pantah
    path="$top/${project//_//}"             # device/google/pantah
    for patch in "$dir"*.patch; do
        # Subjects longer than ~70 chars are folded onto continuation lines
        subject="$(awk '/^Subject: /{s=substr($0,10); while ((getline l) > 0 && l ~ /^ /) s = s l; print s; exit}' "$patch" | sed 's/^\[PATCH[^]]*\] //')"
        # Not grep -q: exiting at the first match would kill git log with SIGPIPE under pipefail
        if git -C "$path" log --format=%s | grep -xF "$subject" >/dev/null; then
            echo "already applied: $project: $subject"
        else
            git -C "$path" am -q --3way "$patch"
            echo "applied: $project: $subject"
        fi
    done
done
version=$(sed -n 's/^version=//p' "$here/ksu.conf")
apk=~/android-dt/ksu/$version/KernelSUNext.apk
[[ -s "$apk" ]] || { echo "FAIL: no $apk (run fetch-ksu.sh)" >&2; exit 1; }
cp "$apk" "$top/device/google/pantah/ksu/KernelSUNext.apk"
echo "APPLY_KSU_OK KernelSU Next $version"
