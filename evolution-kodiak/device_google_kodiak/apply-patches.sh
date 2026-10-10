#!/usr/bin/env bash
# Apply the kodiak patches to an Evolution X cnb checkout (idempotent).
#   apply-patches.sh [evolution-top]
# Same convention as ExpressiveOS evolution-husky/apply.sh:
# patches/<project_path_with_underscores>/*.patch
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
top="$(cd "${1:-$here/../../..}" && pwd)"
for dir in "$here"/patches/*/; do
    [[ -d "$dir" ]] || continue
    project="$(basename "$dir")"            # e.g. build_make
    path="$top/${project//_//}"             # -> build/make
    for patch in "$dir"*.patch; do
        # Subjects longer than ~70 chars are folded onto continuation lines.
        subject="$(awk '/^Subject: /{s=substr($0,10); while ((getline l) > 0 && l ~ /^ /) s = s l; print s; exit}' "$patch" | sed 's/^\[PATCH[^]]*\] //')"
        if git -C "$path" log --format=%s | grep -qxF "$subject"; then
            echo "already applied: $project: $subject"
        else
            git -C "$path" am -q --3way "$patch"
            echo "applied: $project: $subject"
        fi
    done
done
