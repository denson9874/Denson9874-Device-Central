#!/usr/bin/env bash
# Download the Wild Kernels release pinned in ksu.conf (the BakaSU AnyKernel3 zip for each KMI)
# into ~/android-dt/wild/<version>/, check each against ksu.conf's SHA-256, and unpack its kernel
# Image to ~/android-dt/wild/<version>/<kmi>/Image (tools/wild-boot.sh builds boot.img with it).
# eos-images.sh runs it before every build: what's already here and matches ksu.conf is only
# checked, so a build needs GitHub only for something new in ksu.conf.
#
#   fetch-ksu.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
conf="$here/ksu.conf"
get() { sed -n "s/^$1=//p" "$conf" | head -1; }
version=$(get version)
[[ "$version" =~ ^r[0-9]+$ ]] || { echo "ksu.conf: version must look like r22" >&2; exit 1; }
[[ "$(get release_url)" == "https://github.com/WildKernels/GKI_KernelSU_SUSFS/releases/download/$version" ]] \
    || { echo "ksu.conf: release_url must be Wild Kernels' $version release" >&2; exit 1; }
dir=~/android-dt/wild/$version; mkdir -p "$dir"
for kmi in android14-6.1 android16-6.12; do
    f=$(get "zip_$kmi"); sha=$(get "zip_${kmi}_sha256"); u=$(get "uname_$kmi")
    [[ -n "$f" && "$f" != */* && "$sha" =~ ^[0-9a-f]{64}$ && -n "$u" ]] || { echo "ksu.conf: zip_$kmi, its sha256 or uname_$kmi is missing" >&2; exit 1; }
    if [[ ! -s "$dir/$f" ]]; then
        curl -fL --retry 3 -o "$dir/$f.part" "$(get release_url)/$f"
        mv "$dir/$f.part" "$dir/$f"
    fi
    have=$(sha256sum "$dir/$f" | cut -d' ' -f1)
    [[ "$have" == "$sha" ]] || { echo "FAIL: $f is $have, ksu.conf wants $sha; deleting it" >&2; rm -f "$dir/$f"; exit 1; }
    mkdir -p "$dir/$kmi"
    if [[ ! -s "$dir/$kmi/Image" || "$dir/$f" -nt "$dir/$kmi/Image" ]]; then
        unzip -p "$dir/$f" Image > "$dir/$kmi/Image.part" && mv "$dir/$kmi/Image.part" "$dir/$kmi/Image"
    fi
    # awk, not grep -m1: an early exit would kill strings with SIGPIPE under pipefail
    v=$(strings "$dir/$kmi/Image" | awk '/^Linux version / && !f { print $3; f = 1 }')
    [[ "$v" == "$u" ]] || { echo "FAIL: $f's Image is Linux $v, ksu.conf says $u" >&2; exit 1; }
    echo "OK: $f ($have), Linux $v"
done
echo "$version" > ~/android-dt/wild/CURRENT
echo "FETCH_KSU_OK Wild $version"
