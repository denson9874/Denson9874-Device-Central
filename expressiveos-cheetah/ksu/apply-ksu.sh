#!/usr/bin/env bash
# Put ExpressiveOS's SukiSU pieces into its tree for a phone (EOS_DEVICE, cheetah unless set;
# idempotent: a second run changes nothing):
#   1. the phone's SukiSU device tree patches as local commits: cheetah's
#      patches/device_google_pantah/0101-0102 in device/google/pantah, another phone's
#      ../devices/<device>/ksu-patches/<project>/. eos-sukisu in PRODUCT_PACKAGES (0101), and
#      init_boot from CHEETAH_KSU_INIT_BOOT, EOS_KSU_INIT_BOOT on the other phones (0102). They
#      sit on the tree's own device tree patches (../apply.sh, run by ../prepare.sh), which must
#      be in first;
#   2. vendor/extra/ksu: the manager APK fetch-ksu.sh downloaded (its SHA-256 and signer
#      checked again here), SukiSU's LICENSE, the first-boot setup (tree/eos-ksu-firstboot.rc,
#      tree/ksu-firstboot.sh), and tree/Android.mk, which is removed first and written last, so
#      make never sees it without its files.
# Run it on every build (repo sync drops local commits). Nothing is written through a symlink
# that leads out of the tree. A phone without SukiSU (EOS_KSU=none) has nothing here:
# eos-images.sh doesn't run it, and run anyway it says so and changes nothing.
#
#   apply-ksu.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0 work=
cleanup() {
    local rc=$?
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "APPLY_KSU=FAIL"
    exit $rc
}
trap cleanup EXIT
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
[[ $# -le 1 ]] || fail "usage: apply-ksu.sh [top]"
if [[ $EOS_KSU = none ]]; then
    echo "SukiSU is off for $EOS_DEVICE (EOS_KSU=none, devices/$EOS_DEVICE.conf): nothing to apply"
    done=1
    echo "APPLY_KSU_OK skipped for this device"
    exit 0
fi
eos_top "${1:-}"
dt="$top/$EOS_DEVICE_TREE"
# The phone's SukiSU device tree patches: cheetah's are in this folder (patches/), another
# phone's in devices/<device>/ksu-patches/, one folder per project, as ../patches/ is laid out
if [[ $EOS_DEVICE = cheetah ]]; then
    kdirs=("$here"/patches/device_google_pantah/)
else
    kdirs=("$kit/devices/$EOS_DEVICE"/ksu-patches/*/)
fi
dest="$top/vendor/extra/ksu"
for p in vendor/extra vendor/extra/ksu; do in_top "$top/$p"; done
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
version=$(get version)
echo "== SukiSU $version -> $top"

# 1. Tree patches
project_ok "$dt"
if [[ $EOS_DEVICE = cheetah ]]; then
    want=$(subject_of "$(echo "$kit"/patches/device_google_pantah/0002-*.patch)")
else
    # apply.sh checks the same feed commit in the device tree
    want="$EOS_DEVICE: get updates from denson9874/expressiveos_ota"
fi
has_subject "$dt" "$want" || fail "$EOS_DEVICE_TREE lacks the tree's own patches ('$want'); run prepare.sh first"
n=0
for dir in "${kdirs[@]}"; do
    [[ -d $dir ]] || continue
    patches=("$dir"*.patch)
    [[ -e "${patches[0]}" ]] || continue
    p=$(patch_project "$dir")              # e.g. device/google/pantah
    am_patches "$top/$p" "$(basename "$dir")" "${patches[@]}"
    n=$((n + ${#patches[@]}))
done
(( n > 0 )) || fail "devices/$EOS_DEVICE/ksu-patches/ has no patches: a phone with EOS_KSU=lkm needs its device tree to install eos-sukisu and ship the SukiSU init_boot (as cheetah's patches/device_google_pantah/0101-0102 do)"

# 2. The manager, checked again: the kernel trusts only this exact upstream signature
dl=~/android-dt/ksu/$version
apk=$dl/$(get manager_file)
[[ -s "$apk" ]] || fail "no $apk (run fetch-ksu.sh)"
[[ "$(sha256sum -- "$apk" | cut -d' ' -f1)" = "$(get manager_sha256)" ]] || fail "$apk isn't ksu.conf's manager_sha256 (run fetch-ksu.sh)"
cert=$(python3 -I "$here/tools/apk-cert.py" "$apk") || fail "can't read $apk's signature"
[[ "$cert" = "$(get manager_cert_sha256)" ]] || fail "$apk is signed by $cert, not ksu.conf's manager_cert_sha256"
[[ -d "$dl/src/.git" && "$(git -C "$dl/src" rev-parse HEAD)" = "$(get src_commit)" ]] || fail "$dl/src isn't at ksu.conf's src_commit (run fetch-ksu.sh)"
[[ -f "$dl/src/LICENSE" ]] || fail "no LICENSE in $dl/src"
# The first-boot script installs the manager by this package name
[[ "$(sed -n 's/^PKG=//p' "$here/tree/ksu-firstboot.sh")" = "$(get manager_package)" ]] \
    || fail "tree/ksu-firstboot.sh's PKG isn't ksu.conf's manager_package ($(get manager_package))"

work=$(mktemp -d "${TMPDIR:-/tmp}/ksu-apply.XXXXXX")
stage=$work/stage
mkdir -p "$stage"
cp -- "$apk" "$stage/sukisu-manager.apk"
cp -- "$dl/src/LICENSE" "$stage/LICENSE"
cp -- "$here/tree/Android.mk" "$stage/Android.mk"
cp -- "$here/tree/eos-ksu-firstboot.rc" "$here/tree/ksu-firstboot.sh" "$stage/"
find "$stage" -type f -exec chmod 0644 {} +

# Stage. The folder belongs to this kit: anything in it that the kit doesn't ship goes.
changed=0
while IFS= read -r -d '' f; do
    cmp -s -- "$f" "$dest/${f#"$stage"/}" || changed=1
done < <(find "$stage" -type f -print0)
stale=()
if [[ -d "$dest" ]]; then
    while IFS= read -r -d '' f; do
        rel=${f#"$dest"/}
        [[ -d "$f" && ! -L "$f" && -d "$stage/$rel" ]] && continue
        [[ -f "$stage/$rel" ]] && continue
        [[ -f "$f" || -L "$f" ]] || fail "$f isn't a file this kit put there; move it out of the way"
        stale+=("$rel"); changed=1
    done < <(find "$dest" -mindepth 1 -print0)
fi
if [[ $changed = 0 ]]; then
    echo "unchanged: vendor/extra/ksu"
else
    mkdir -p -- "$dest"
    rm -f -- "$dest/Android.mk"
    for rel in ${stale[@]+"${stale[@]}"}; do
        rm -f -- "${dest:?}/$rel"; echo "removed: vendor/extra/ksu/$rel"
    done
    while IFS= read -r -d '' f; do
        rel=${f#"$stage"/}
        [[ "$rel" != Android.mk ]] || continue
        cmp -s -- "$f" "$dest/$rel" && continue
        tmp="$(dirname -- "$dest/$rel")/.${rel##*/}.tmp"
        { cp -p -- "$f" "$tmp" && mv -f -- "$tmp" "$dest/$rel"; } \
            || fail "can't stage $rel in $dest (Android.mk stays out until a run succeeds)"
        echo "staged: vendor/extra/ksu/$rel"
    done < <(find "$stage" -type f -print0)
    { cp -p -- "$stage/Android.mk" "$dest/.Android.mk.tmp" && mv -f -- "$dest/.Android.mk.tmp" "$dest/Android.mk"; } \
        || fail "can't stage Android.mk in $dest"
    echo "staged: vendor/extra/ksu/Android.mk (last)"
fi
done=1
echo "APPLY_KSU_OK SukiSU $version"
