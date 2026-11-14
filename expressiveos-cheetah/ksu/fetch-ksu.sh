#!/usr/bin/env bash
# Download the SukiSU release pinned in ksu.conf (the manager APK, ksuinit and the release's
# android16-6.12 kernelsu.ko) into ~/android-dt/ksu/<version>/ and check each against
# ksu.conf's SHA-256, the manager's signer against manager_cert_sha256, and check out its
# source at src_commit (tools/ksu-module.sh builds cheetah's and husky's kernelsu.ko from it).
# Run it after changing ksu.conf; apply-ksu.sh and the tools/ scripts use the result.
# eos-images.sh runs it before every build: what's already here and matches ksu.conf is only
# checked, so a build needs GitHub only for something new in ksu.conf.
#
#   fetch-ksu.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
conf="$here/ksu.conf"
get() { sed -n "s/^$1=//p" "$conf" | head -1; }
version=$(get version)
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$ ]] || { echo "ksu.conf: version must look like v4.3.0 or v4.3.0-r2" >&2; exit 1; }
[[ "$(get release_url)" == "https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases/download/$version" ]] \
    || { echo "ksu.conf: release_url must be SukiSU-Ultra's $version release" >&2; exit 1; }
dir=~/android-dt/ksu/$version; mkdir -p "$dir"
fail=0
fetch() {   # fetch <key in ksu.conf>: download <key>_file from the release, check <key>_sha256
    local f sha have
    f=$(get "$1_file"); sha=$(get "$1_sha256")
    [[ -n "$f" && "$f" != */* ]] || { echo "ksu.conf: no $1_file" >&2; fail=1; return; }
    if [[ ! -s "$dir/$f" ]]; then
        curl -fL --retry 3 -o "$dir/$f.part" "$(get release_url)/$f"
        mv "$dir/$f.part" "$dir/$f"
    fi
    have=$(sha256sum "$dir/$f" | cut -d' ' -f1)
    if [[ -z "$sha" ]]; then
        echo "UNPINNED: $1 $f"
        echo "          sha256=$have  (check it against the release page, then set ${1}_sha256 in ksu.conf)"
        fail=1
    elif [[ "$have" != "$sha" ]]; then
        echo "FAIL: $f is $have, ksu.conf wants $sha; deleting it" >&2
        rm -f "$dir/$f"; fail=1
    else
        echo "OK: $f ($have)"
    fi
}
fetch manager
fetch ksuinit
fetch ko_android16-6.12
[[ $fail = 0 ]] || exit 1
# The kernel module trusts only SukiSU's own signer: check the APK's v2 signing cert
want_cert=$(get manager_cert_sha256)
have_cert=$(python3 -I "$here/tools/apk-cert.py" "$dir/$(get manager_file)") || true
[[ -n "$want_cert" && "$have_cert" == "$want_cert" ]] || { echo "FAIL: manager signer is ${have_cert:-unreadable}, ksu.conf wants ${want_cert:-nothing}" >&2; exit 1; }
echo "OK: manager signed by SukiSU ($have_cert)"
# Source for our own kernelsu.ko. Not shallow: SukiSU's Kbuild counts commits for its version.
src_url=$(get src_url); src_commit=$(get src_commit)
[[ "$src_url" == https://github.com/SukiSU-Ultra/SukiSU-Ultra.git && "$src_commit" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "ksu.conf: src_url must be SukiSU-Ultra's repo and src_commit a full commit hash" >&2; exit 1; }
[[ -d "$dir/src/.git" ]] || git clone -q --filter=blob:none "$src_url" "$dir/src"
# Fetched only while the tag isn't here: a tag upstream moves later can't fail a build
git -C "$dir/src" rev-parse -q --verify "refs/tags/$version^{commit}" > /dev/null || git -C "$dir/src" fetch -q --tags origin
tag=$(git -C "$dir/src" rev-parse "refs/tags/$version^{commit}")
[[ "$tag" == "$src_commit" ]] || { echo "FAIL: tag $version is $tag, ksu.conf wants $src_commit" >&2; exit 1; }
git -C "$dir/src" reset -q --hard
git -C "$dir/src" clean -qfdx
git -C "$dir/src" checkout -q --detach "$src_commit"
code=$((40000 + $(git -C "$dir/src" rev-list --count HEAD) - 2815))
[[ "$code" = "$(get version_code)" ]] || { echo "FAIL: $version's source counts to version $code, ksu.conf says $(get version_code)" >&2; exit 1; }
[[ -f "$dir/src/LICENSE" && -f "$dir/src/kernel/LICENSE" ]] || { echo "FAIL: no LICENSE or kernel/LICENSE in the source" >&2; exit 1; }
echo "OK: source $version ($src_commit, version $code)"
echo "$version" > ~/android-dt/ksu/CURRENT
echo "FETCH_KSU_OK SukiSU $version"
