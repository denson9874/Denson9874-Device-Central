#!/usr/bin/env bash
# Download the KernelSU Next release pinned in ksu.conf (host ksud + manager APK)
# into ~/android-dt/ksu/<version>/ and check both against ksu.conf's SHA-256, and
# check out its source (for tools/ksu-module.sh) at ksu.conf's src_commit.
# Run it after changing ksu.conf; apply-ksu.sh and the tools/ scripts use the result.
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
# The kernel module trusts only KernelSU Next's own signer: check the APK's v2 signing cert
want_cert=$(get manager_cert_sha256)
have_cert=$(python3 -I "$here/tools/apk-cert.py" "$dir/KernelSUNext.apk") || true
[[ -n "$want_cert" && "$have_cert" == "$want_cert" ]] || { echo "FAIL: manager signer is ${have_cert:-unreadable}, ksu.conf wants ${want_cert:-nothing}" >&2; exit 1; }
echo "OK: manager signed by KernelSU Next ($have_cert)"
# Source for our own kernelsu.ko. Not shallow: the module's version counts the commits.
src_url=$(get src_url); src_commit=$(get src_commit)
[[ "$src_url" == https://github.com/KernelSU-Next/KernelSU-Next.git && "$src_commit" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "ksu.conf: src_url must be KernelSU-Next's repo and src_commit a full commit hash" >&2; exit 1; }
[[ -d "$dir/src/.git" ]] || git clone -q --filter=blob:none "$src_url" "$dir/src"
git -C "$dir/src" fetch -q --tags origin
tag=$(git -C "$dir/src" rev-parse "refs/tags/$version^{commit}")
[[ "$tag" == "$src_commit" ]] || { echo "FAIL: tag $version is $tag, ksu.conf wants $src_commit" >&2; exit 1; }
git -C "$dir/src" reset -q --hard
git -C "$dir/src" clean -qfdx
git -C "$dir/src" checkout -q --detach "$src_commit"
echo "OK: source $version ($src_commit)"
chmod +x "$dir/ksud"
"$dir/ksud" --version
echo "$version" > ~/android-dt/ksu/CURRENT
echo "FETCH_KSU_OK $version"
