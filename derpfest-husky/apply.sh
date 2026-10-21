#!/usr/bin/env bash
# Apply the husky patches to a DerpFest 17 checkout (idempotent).
#   apply.sh [derpfest-top]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
top="$(cd "${1:-$PWD}" && pwd)"
for dir in "$here"/patches/*/; do
    [[ -d "$dir" ]] || continue
    project="$(basename "$dir")"            # e.g. device_google_shusky
    path="$top/${project//_//}"             # -> device/google/shusky
    for patch in "$dir"*.patch; do
        # Subjects longer than ~70 chars are folded onto continuation lines.
        subject="$(awk '/^Subject: /{s=substr($0,10); while ((getline l) > 0 && l ~ /^ /) s = s l; print s; exit}' "$patch" | sed 's/^\[PATCH[^]]*\] //')"
        if git -C "$path" log --format=%s | grep -xF "$subject" >/dev/null; then   # not -q: an early exit SIGPIPEs git log under pipefail
            echo "already applied: $project: $subject"
        else
            git -C "$path" am -q --3way "$patch"
            echo "applied: $project: $subject"
        fi
    done
done
