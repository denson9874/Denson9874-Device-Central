#!/usr/bin/env bash
# Download the KernelSU Next release pinned in ksu.conf (host ksud + manager APK)
# into ~/android-dt/ksu/<version>/ and check both against ksu.conf's SHA-256.
# Run it after changing ksu.conf; prepare.sh and cheetah-ksu.sh use the result.
#
#   fetch-ksu.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
conf="$here/ksu.conf"
get() { sed -n "s/^$1=//p" "$conf" | head -1; }
version=$(get version)
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ksu.conf: version must look like v3.4.2" >&2; exit 1; }
dir=~/android-dt/ksu/$version; mkdir -p "$dir"
fail=0
fetch() {   # fetch <name in ksu.conf> <file name in $dir>
    local url sha have
    url=$(get "$1_url"); sha=$(get "$1_sha256")
    [[ "$url" == https://github.com/KernelSU-Next/KernelSU-Next/releases/download/$version/* ]] \
        || { echo "ksu.conf: $1_url must be a $version release asset of KernelSU-Next/KernelSU-Next" >&2; fail=1; return; }
    if [[ ! -s "$dir/$2" ]]; then
        curl -fL --retry 3 -o "$dir/$2.part" "$url"
        mv "$dir/$2.part" "$dir/$2"
    fi
    have=$(sha256sum "$dir/$2" | cut -d' ' -f1)
    if [[ -z "$sha" ]]; then
        echo "UNPINNED: $1 $url"
        echo "          sha256=$have  (check it against the release, then set ${1}_sha256 in ksu.conf)"
        fail=1
    elif [[ "$have" != "$sha" ]]; then
        echo "FAIL: $1 is $have, ksu.conf wants $sha; deleting it" >&2
        rm -f "$dir/$2"; fail=1
    else
        echo "OK: $1 $version ($have)"
    fi
}
fetch ksud ksud
fetch manager KernelSUNext.apk
[[ $fail = 0 ]] || exit 1
chmod +x "$dir/ksud"
"$dir/ksud" --version
echo "$version" > ~/android-dt/ksu/CURRENT
echo "FETCH_KSU_OK $version"
