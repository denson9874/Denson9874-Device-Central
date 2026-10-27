#!/usr/bin/env bash
# Download the KernelSU Next release pinned in ksu.conf (host ksud + manager APK)
# into ~/android-dt/ksu/<version>/ and check both against ksu.conf's SHA-256, and
# check out its source (for tools/ksu-module.sh) at ksu.conf's src_commit. Then the
# Zygisk provider (NeoZygisk) into ~/android-dt/ksu/zygisk-<version>/: its zip, checked
# against ksu.conf and by tools/zygisk-zip.py (never run), and its source at
# zygisk_src_commit with the LSPlt submodule, for the licences and the GPL source offer.
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

# The Zygisk provider: another project, so its own URL rule (fetch() takes KernelSU Next's only)
zv=$(get zygisk_version); zurl=$(get zygisk_url); zsha=$(get zygisk_sha256)
zid=$(get zygisk_module_id); zcode=$(get zygisk_version_code)
[[ "$zv" =~ ^v[0-9]+(\.[0-9]+)+$ && "$zurl" == https://github.com/JingMatrix/NeoZygisk/releases/download/$zv/*.zip ]] \
    || { echo "ksu.conf: zygisk_url must be a $zv release zip of JingMatrix/NeoZygisk" >&2; exit 1; }
zdir=~/android-dt/ksu/zygisk-$zv; mkdir -p "$zdir"
zip=$zdir/zygisk-provider.zip
if [[ ! -s "$zip" ]]; then
    curl -fL --retry 3 -o "$zip.part" "$zurl"
    mv "$zip.part" "$zip"
fi
have=$(sha256sum "$zip" | cut -d' ' -f1)
if [[ -z "$zsha" ]]; then
    echo "UNPINNED: zygisk $zurl"
    echo "          sha256=$have  (check it against the release, then set zygisk_sha256 in ksu.conf)"
    exit 1
elif [[ "$have" != "$zsha" ]]; then
    echo "FAIL: zygisk is $have, ksu.conf wants $zsha; deleting it" >&2
    rm -f "$zip"; exit 1
fi
echo "OK: zygisk $zv ($have)"
# The risk rules ksud scans module zips with: the ones built into it, and the ones a phone with
# a network fetches when it installs (a match stops the first-boot install)
python3 -I "$here/tools/zygisk-zip.py" "$zip" "$zid" "$zcode" "$dir/src/risk/risk.json" \
    || { echo "FAIL: $zip doesn't pass tools/zygisk-zip.py" >&2; exit 1; }
if curl -fsSL --retry 3 -o "$zdir/risk-remote.json" https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/risk/risk/risk.json; then
    python3 -I "$here/tools/zygisk-zip.py" "$zip" "$zid" "$zcode" "$zdir/risk-remote.json" | tail -2 | head -1
    python3 -I "$here/tools/zygisk-zip.py" "$zip" "$zid" "$zcode" "$zdir/risk-remote.json" > /dev/null \
        || { echo "FAIL: KernelSU Next's current risk rules flag $zip: a phone online at first boot won't install it" >&2; exit 1; }
else
    echo "note: couldn't fetch KernelSU Next's current risk rules; checked the built-in ones only"
fi
zsrc_url=$(get zygisk_src_url); zsrc=$(get zygisk_src_commit); zlsplt=$(get zygisk_lsplt_commit)
[[ "$zsrc_url" == https://github.com/JingMatrix/NeoZygisk.git && "$zsrc" =~ ^[0-9a-f]{40}$ && "$zlsplt" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "ksu.conf: zygisk_src_url must be NeoZygisk's repo, zygisk_src_commit and zygisk_lsplt_commit full commit hashes" >&2; exit 1; }
[[ -d "$zdir/src/.git" ]] || git clone -q --filter=blob:none "$zsrc_url" "$zdir/src"
git -C "$zdir/src" fetch -q --tags origin
tag=$(git -C "$zdir/src" rev-parse "refs/tags/$zv^{commit}")
[[ "$tag" == "$zsrc" ]] || { echo "FAIL: NeoZygisk's tag $zv is $tag, ksu.conf wants $zsrc" >&2; exit 1; }
git -C "$zdir/src" reset -q --hard
git -C "$zdir/src" clean -qfdx
git -C "$zdir/src" checkout -q --detach "$zsrc"
git -C "$zdir/src" submodule -q update --init --checkout
l=$(git -C "$zdir/src" ls-tree HEAD loader/src/external/lsplt | awk '{print $3}')
[[ "$l" == "$zlsplt" && "$(git -C "$zdir/src/loader/src/external/lsplt" rev-parse HEAD)" == "$zlsplt" ]] \
    || { echo "FAIL: NeoZygisk $zv's LSPlt is ${l:-missing}, ksu.conf wants $zlsplt" >&2; exit 1; }
for f in "$zdir/src/LICENSE" "$zdir/src/loader/src/external/lsplt/LICENSE"; do
    [[ -s "$f" ]] || { echo "FAIL: no ${f#"$zdir"/}" >&2; exit 1; }
done
echo "OK: NeoZygisk source $zv ($zsrc, LSPlt $zlsplt)"
echo "$version" > ~/android-dt/ksu/CURRENT
echo "FETCH_KSU_OK $version, NeoZygisk $zv"
