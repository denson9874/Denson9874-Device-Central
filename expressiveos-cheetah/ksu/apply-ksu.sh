#!/usr/bin/env bash
# Put ExpressiveOS's KernelSU Next pieces into its cheetah tree (idempotent: a second
# run changes nothing):
#   1. patches/device_google_pantah/0101-0102 as local commits in device/google/pantah:
#      the manager in PRODUCT_PACKAGES with libksud.so executable (0101), and init_boot
#      from CHEETAH_KSU_INIT_BOOT (0102). They sit on the tree's own pantah patches
#      (../apply.sh, run by ../prepare.sh), which must be in first;
#   2. vendor/extra/ksu: the manager APK fetch-ksu.sh downloaded (its SHA-256 and signer
#      checked again here), the source's LICENSE, the APK's four arm64 libs, the first-boot
#      setup (tree/eos-ksu-firstboot.rc, tree/ksu-firstboot.sh), the Zygisk provider zip
#      fetch-ksu.sh downloaded (checked again too) with its licences in NOTICE-NeoZygisk, and
#      tree/Android.mk, which is removed first and written last, so make never sees it
#      without its files.
# Run it on every build (repo sync drops local commits). Never on the Evolution X or
# DerpFest tree: their users aren't rooted. Nothing is written through a symlink that
# leads out of the tree.
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
eos_top "${1:-}"
pantah="$top/device/google/pantah"
dest="$top/vendor/extra/ksu"
for p in vendor/extra vendor/extra/ksu vendor/extra/ksu/lib vendor/extra/ksu/lib/arm64; do in_top "$top/$p"; done
get() { sed -n "s/^$1=//p" "$here/ksu.conf" | head -1; }
version=$(get version)
echo "== KernelSU Next $version -> $top"

# 1. Tree patches
project_ok "$pantah"
! has_subject "$pantah" "cheetah: preinstall the KernelSU Next manager" \
    || fail "device/google/pantah has the old manager commit (no native libs); drop it with: (cd $top && repo sync -d device/google/pantah), then run prepare.sh and this again"
want=$(subject_of "$(echo "$kit"/patches/device_google_pantah/0002-*.patch)")
has_subject "$pantah" "$want" || fail "device/google/pantah lacks the tree's own patches ('$want'); run prepare.sh first"
am_patches "$pantah" device_google_pantah "$here"/patches/device_google_pantah/*.patch

# 2. The manager, checked again: the kernel trusts only this exact upstream signature
dl=~/android-dt/ksu/$version
apk=$dl/KernelSUNext.apk
[[ -s "$apk" ]] || fail "no $apk (run fetch-ksu.sh)"
[[ "$(sha256sum -- "$apk" | cut -d' ' -f1)" = "$(get manager_sha256)" ]] || fail "$apk isn't ksu.conf's manager_sha256 (run fetch-ksu.sh)"
cert=$(python3 -I "$here/tools/apk-cert.py" "$apk") || fail "can't read $apk's signature"
[[ "$cert" = "$(get manager_cert_sha256)" ]] || fail "$apk is signed by $cert, not ksu.conf's manager_cert_sha256"
[[ -d "$dl/src/.git" && "$(git -C "$dl/src" rev-parse HEAD)" = "$(get src_commit)" ]] || fail "$dl/src isn't at ksu.conf's src_commit (run fetch-ksu.sh)"
[[ -f "$dl/src/LICENSE" ]] || fail "no LICENSE in $dl/src"

work=$(mktemp -d "${TMPDIR:-/tmp}/ksu-apply.XXXXXX")
stage=$work/stage
mkdir -p "$stage/lib/arm64"
cp -- "$apk" "$stage/KernelSUNext.apk"
cp -- "$dl/src/LICENSE" "$stage/LICENSE"
cp -- "$here/tree/Android.mk" "$stage/Android.mk"
cp -- "$here/tree/eos-ksu-firstboot.rc" "$here/tree/ksu-firstboot.sh" "$stage/"
# The Zygisk provider, checked again: ksu.conf's zip byte for byte, and its source for the licences
zv=$(get zygisk_version)
zdir=~/android-dt/ksu/zygisk-$zv
zip=$zdir/zygisk-provider.zip
[[ -s "$zip" && "$(sha256sum -- "$zip" | cut -d' ' -f1)" = "$(get zygisk_sha256)" ]] \
    || fail "$zip isn't ksu.conf's zygisk_sha256 (run fetch-ksu.sh)"
python3 -I "$here/tools/zygisk-zip.py" "$zip" "$(get zygisk_module_id)" "$(get zygisk_version_code)" "$dl/src/risk/risk.json" \
    > "$work/zygisk.log" 2>&1 || { grep '^FAIL' "$work/zygisk.log" >&2; fail "$zip doesn't pass tools/zygisk-zip.py"; }
[[ -d "$zdir/src/.git" && "$(git -C "$zdir/src" rev-parse HEAD)" = "$(get zygisk_src_commit)" ]] \
    || fail "$zdir/src isn't at ksu.conf's zygisk_src_commit (run fetch-ksu.sh)"
lsplt=$zdir/src/loader/src/external/lsplt
[[ "$(git -C "$lsplt" rev-parse HEAD 2>/dev/null)" = "$(get zygisk_lsplt_commit)" && -s "$zdir/src/LICENSE" && -s "$lsplt/LICENSE" ]] \
    || fail "$lsplt isn't at ksu.conf's zygisk_lsplt_commit, or a LICENSE is missing (run fetch-ksu.sh)"
# ksu-firstboot.sh tells a half install of its own NeoZygisk from a Zygisk the user installed
# by this versionCode
[[ "$(sed -n 's/^ZYGISK_CODE=\([0-9]*\).*/\1/p' "$here/tree/ksu-firstboot.sh")" = "$(get zygisk_version_code)" ]] \
    || fail "tree/ksu-firstboot.sh's ZYGISK_CODE isn't ksu.conf's zygisk_version_code ($(get zygisk_version_code))"
[[ "$(get zygisk_module_id)" = zygisksu ]] || fail "tree/ksu-firstboot.sh looks for NeoZygisk as zygisksu, ksu.conf says $(get zygisk_module_id)"
cp -- "$zip" "$stage/zygisk-provider.zip"
{
    printf '%s\n' \
        "NeoZygisk $zv (versionCode $(get zygisk_version_code)), by JingMatrix, GNU GPL v3: https://github.com/JingMatrix/NeoZygisk" \
        "Shipped unmodified as /product/etc/eos/zygisk-provider.zip, upstream's $zv release zip. Its source:" \
        "https://github.com/JingMatrix/NeoZygisk/tree/$(get zygisk_src_commit)" \
        "It includes LSPlt, GNU LGPL v3: https://github.com/JingMatrix/LSPlt/tree/$(get zygisk_lsplt_commit)" \
        "" "NeoZygisk's licence:" ""
    cat -- "$zdir/src/LICENSE"
    printf '\n%s\n\n' "LSPlt's licence:"
    cat -- "$lsplt/LICENSE"
} > "$stage/NOTICE-NeoZygisk"
# The libs Android.mk installs must be exactly the APK's arm64 ones
libs=$(sed -n 's|^ *lib/arm64/\(lib[^ ]*\.so\).*|\1|p' "$here/tree/Android.mk" | sort)
have=$(unzip -Z1 -- "$apk" 'lib/arm64-v8a/*' | sed 's|^lib/arm64-v8a/||' | sort)
[[ -n "$libs" && "$libs" = "$have" ]] \
    || fail "the APK's arm64 libs ($(tr '\n' ' ' <<<"$have")) aren't the ones tree/Android.mk installs ($(tr '\n' ' ' <<<"$libs")); update tree/Android.mk and tools/ksu-check.sh together"
for l in $libs; do
    unzip -p -- "$apk" "lib/arm64-v8a/$l" > "$stage/lib/arm64/$l"
    [[ -s "$stage/lib/arm64/$l" ]] || fail "can't extract lib/arm64-v8a/$l from $apk"
done
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
    mkdir -p -- "$dest/lib/arm64"
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
grep -qxF 'TARGET_FS_CONFIG_GEN += device/google/pantah/ksu/config.fs' "$pantah/cheetah/BoardConfig.mk" \
    || fail "cheetah/BoardConfig.mk doesn't use ksu/config.fs: libksud.so would ship without its exec bit"
done=1
echo "APPLY_KSU_OK KernelSU Next $version"
