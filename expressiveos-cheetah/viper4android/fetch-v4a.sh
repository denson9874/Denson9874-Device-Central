#!/usr/bin/env bash
# Get the ViPER4Android RE release files pinned in v4a.conf (the app APK, the app's
# LICENSE, the non-AIDL driver's module zip and the AIDL driver's) into a cache, and check
# each against v4a.conf: size and SHA-256 of every file, then the APK's package, v2 signer,
# permissions and uses-library tags, then the non-AIDL zip's arm64 library and LICENSE and the
# AIDL zip's arm64 library and effects config, extracted (unzip -j, nothing else) into fresh
# temporary folders. Both drivers are fetched for every phone: the staged folder is one for the
# whole tree, and viper4android.mk picks each product's.
# A download lands under a temporary name and is renamed only once it matches, so
# the cache never holds a half-written or unverified file under a pinned name.
#
#   fetch-v4a.sh [--out <dir>]
#       --out: also put the verified files there (<dir> must not exist yet; it
#       appears only once everything passed): ViPER4Android.apk,
#       libv4a_re_arm64-v8a.so, LICENSE.app, LICENSE.driver, libv4a_aidl_arm64-v8a.so,
#       audio_effects_config.aidl.xml. apply-v4a.sh uses it.
#   V4A_CACHE=<dir>   cache folder (default ~/android-dt/v4a)
#   V4A_OFFLINE=1     never download: fail when a file isn't in the cache
set -euo pipefail
done=0 work= part=
cleanup() {
    local rc=$?
    [[ -z "$part" ]] || rm -f -- "$part"
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "V4A_FETCH=FAIL"
    exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=v4a.conf
source "$here/v4a.conf" || fail "can't read $here/v4a.conf"

out=
case "${1:-}" in
    "") ;;
    --out) out=${2:-}; [[ -n "$out" && $# = 2 ]] || fail "usage: fetch-v4a.sh [--out <dir>]" ;;
    *) fail "usage: fetch-v4a.sh [--out <dir>]" ;;
esac

# v4a.conf sanity: a typo there must not turn into a download from somewhere else
for v in V4A_APP_SHA256 V4A_APP_CERT_SHA256 V4A_APP_LICENSE_SHA256 V4A_FX_ZIP_SHA256 V4A_FX_LIB_SHA256 V4A_FX_LICENSE_SHA256 \
    V4A_AIDL_ZIP_SHA256 V4A_AIDL_LIB_SHA256 V4A_AIDL_CONFIG_SHA256; do
    [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || fail "v4a.conf: $v must be a 64-hex SHA-256"
done
for v in V4A_APP_SIZE V4A_FX_ZIP_SIZE V4A_FX_LIB_SIZE V4A_AIDL_ZIP_SIZE V4A_AIDL_LIB_SIZE; do
    [[ "${!v:-}" =~ ^[1-9][0-9]*$ ]] || fail "v4a.conf: $v must be a size in bytes"
done
for v in V4A_APP_FILE V4A_APP_LICENSE_FILE V4A_FX_FILE V4A_AIDL_FILE; do
    [[ "${!v:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "v4a.conf: $v must be a plain file name"
done
[[ "$V4A_APP_URL" == "https://github.com/likelikeslike/ViPER4Android/releases/download/$V4A_APP_TAG/"* ]] \
    || fail "v4a.conf: V4A_APP_URL must be a $V4A_APP_TAG release asset of likelikeslike/ViPER4Android"
[[ "$V4A_APP_LICENSE_URL" == "https://raw.githubusercontent.com/likelikeslike/ViPER4Android/$V4A_APP_TAG/LICENSE" ]] \
    || fail "v4a.conf: V4A_APP_LICENSE_URL must be the LICENSE at tag $V4A_APP_TAG"
[[ "$V4A_FX_URL" == "https://github.com/likelikeslike/ViPERFX_RE/releases/download/$V4A_FX_TAG/"* ]] \
    || fail "v4a.conf: V4A_FX_URL must be a $V4A_FX_TAG release asset of likelikeslike/ViPERFX_RE"
[[ "$V4A_FX_LIB_MEMBER" == common/files/libv4a_re_arm64-v8a.so && "$V4A_FX_LICENSE_MEMBER" == LICENSE ]] \
    || fail "v4a.conf: the zip members must be common/files/libv4a_re_arm64-v8a.so and LICENSE"
[[ "$V4A_AIDL_URL" == "https://github.com/likelikeslike/ViPERFX_RE/releases/download/$V4A_FX_TAG/"* ]] \
    || fail "v4a.conf: V4A_AIDL_URL must be a $V4A_FX_TAG release asset of likelikeslike/ViPERFX_RE (the non-AIDL driver's release)"
[[ "$V4A_AIDL_LIB_MEMBER" == common/files/libv4a_aidl_arm64-v8a.so && "$V4A_AIDL_CONFIG_MEMBER" == common/audio_effects_config.xml ]] \
    || fail "v4a.conf: the AIDL zip members must be common/files/libv4a_aidl_arm64-v8a.so and common/audio_effects_config.xml"
for tool in sha256sum unzip python3; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
done

cache=${V4A_CACHE:-$HOME/android-dt/v4a}
mkdir -p -- "$cache"
cache="$(cd "$cache" && pwd)"
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
size() { stat -c %s -- "$1"; }

get() {   # get <what> <url> <file in the cache> <sha256> [<size>]
    local what=$1 url=$2 dst="$cache/$3" want=$4 wsize=${5:-} have
    if [[ -e "$dst" ]]; then
        have=$(sha "$dst")
        if [[ "$have" != "$want" ]]; then
            rm -f -- "$dst"
            fail "$what: the cached $dst is $have, v4a.conf wants $want; deleted it (run again to download it)"
        fi
        echo "OK: $what (cached, $have)"
        return
    fi
    [[ "${V4A_OFFLINE:-0}" != 1 ]] || fail "$what: $dst isn't cached and V4A_OFFLINE=1"
    command -v curl >/dev/null || fail "curl is not installed"
    part=$(mktemp "$cache/.$3.XXXXXX.part")
    echo "Downloading $what: $url"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-filesize 67108864 -o "$part" "$url" \
        || fail "$what: download failed: $url"
    have=$(size "$part")
    [[ -z "$wsize" || "$have" = "$wsize" ]] || fail "$what: $url is $have bytes, v4a.conf wants $wsize"
    have=$(sha "$part")
    [[ "$have" = "$want" ]] || fail "$what: $url is $have, v4a.conf wants $want"
    chmod 0644 -- "$part"
    mv -f -- "$part" "$dst"; part=
    echo "OK: $what (downloaded, $have)"
}

get "app $V4A_APP_VERSION" "$V4A_APP_URL" "$V4A_APP_FILE" "$V4A_APP_SHA256" "$V4A_APP_SIZE"
get "app LICENSE" "$V4A_APP_LICENSE_URL" "$V4A_APP_LICENSE_FILE" "$V4A_APP_LICENSE_SHA256"
get "driver zip $V4A_FX_VERSION" "$V4A_FX_URL" "$V4A_FX_FILE" "$V4A_FX_ZIP_SHA256" "$V4A_FX_ZIP_SIZE"
get "AIDL driver zip $V4A_FX_VERSION" "$V4A_AIDL_URL" "$V4A_AIDL_FILE" "$V4A_AIDL_ZIP_SHA256" "$V4A_AIDL_ZIP_SIZE"
apk="$cache/$V4A_APP_FILE" zip="$cache/$V4A_FX_FILE" azip="$cache/$V4A_AIDL_FILE"
[[ "$(size "$apk")" = "$V4A_APP_SIZE" && "$(size "$zip")" = "$V4A_FX_ZIP_SIZE" && "$(size "$azip")" = "$V4A_AIDL_ZIP_SIZE" ]] \
    || fail "cached file sizes don't match v4a.conf"

# Work folder next to --out, so the finished set appears there with one rename
if [[ -n "$out" ]]; then
    [[ ! -e "$out" ]] || fail "--out $out already exists"
    mkdir -p -- "$(dirname -- "$out")"
    work=$(mktemp -d "$(dirname -- "$out")/.v4a-fetch.XXXXXX")
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/v4a-fetch.XXXXXX")
fi

# The app: what the pins say it is, asking for nothing more. apk-info.py reads the
# APK's binary manifest and v2 signing block itself (no build tools needed).
info=$(python3 -I "$here/tools/apk-info.py" "$apk") || fail "can't read $apk"
field() { sed -n "s/^$1 //p" <<<"$info"; }
[[ "$(field package)" = "$V4A_APP_PACKAGE" ]] || fail "app: package is $(field package), v4a.conf wants $V4A_APP_PACKAGE"
[[ "$(field versionName)" = "$V4A_APP_VERSION" ]] || fail "app: versionName is $(field versionName), v4a.conf wants $V4A_APP_VERSION"
[[ "$(field cert)" = "$V4A_APP_CERT_SHA256" ]] || fail "app: signed by $(field cert), v4a.conf wants $V4A_APP_CERT_SHA256"
echo "OK: app $(field package) $(field versionName), v2 signer $(field cert)"
perms=$(field uses-permission | paste -sd' ') perms23=$(field uses-permission-sdk-23 | paste -sd' ')
[[ -z "$perms23" && "$perms" = "$V4A_APP_PERMS" ]] \
    || fail "app: permissions changed upstream: has [$perms${perms23:+ (sdk-23) $perms23}], v4a.conf wants [$V4A_APP_PERMS]. Add a new privileged one to tree/privapp-permissions-com.llsl.viper4android.xml deliberately, then update V4A_APP_PERMS"
echo "OK: app asks for the $(wc -w <<<"$perms") permissions v4a.conf pins"
libs=$(field uses-library | paste -sd' ')
want_libs=""; for l in $V4A_APP_OPTIONAL_USES_LIBS; do want_libs+="${want_libs:+ }$l required=false"; done
[[ "$libs" = "$want_libs" ]] || fail "app: uses-library tags are [$libs], v4a.conf and tree/Android.bp want [$want_libs]"
echo "OK: app uses-library tags: $V4A_APP_OPTIONAL_USES_LIBS (optional)"

# The driver: only the arm64 library and the LICENSE come out of the zip
members=$(unzip -Z1 "$zip") || fail "$zip isn't a readable zip"
grep -qxF -- "$V4A_FX_LIB_MEMBER" <<<"$members" || fail "driver zip has no $V4A_FX_LIB_MEMBER"
grep -qxF -- "$V4A_FX_LICENSE_MEMBER" <<<"$members" || fail "driver zip has no $V4A_FX_LICENSE_MEMBER"
mkdir "$work/zip"
unzip -qq -j "$zip" "$V4A_FX_LIB_MEMBER" "$V4A_FX_LICENSE_MEMBER" -d "$work/zip" || fail "can't extract from $zip"
lib="$work/zip/${V4A_FX_LIB_MEMBER##*/}"
[[ "$(find "$work/zip" -mindepth 1 | wc -l)" = 2 && -f "$lib" && -f "$work/zip/LICENSE" ]] \
    || fail "unzip didn't give exactly ${V4A_FX_LIB_MEMBER##*/} and LICENSE"
have=$(sha "$lib")
[[ "$have" = "$V4A_FX_LIB_SHA256" && "$(size "$lib")" = "$V4A_FX_LIB_SIZE" ]] \
    || fail "driver: ${V4A_FX_LIB_MEMBER##*/} is $have ($(size "$lib") bytes), v4a.conf wants $V4A_FX_LIB_SHA256 ($V4A_FX_LIB_SIZE bytes)"
echo "OK: driver ${V4A_FX_LIB_MEMBER##*/} ($have)"
have=$(sha "$work/zip/LICENSE")
[[ "$have" = "$V4A_FX_LICENSE_SHA256" ]] || fail "driver: LICENSE is $have, v4a.conf wants $V4A_FX_LICENSE_SHA256"
echo "OK: driver LICENSE ($have)"

# The AIDL driver: only the arm64 library and the effects config come out of its zip
members=$(unzip -Z1 "$azip") || fail "$azip isn't a readable zip"
grep -qxF -- "$V4A_AIDL_LIB_MEMBER" <<<"$members" || fail "AIDL driver zip has no $V4A_AIDL_LIB_MEMBER"
grep -qxF -- "$V4A_AIDL_CONFIG_MEMBER" <<<"$members" || fail "AIDL driver zip has no $V4A_AIDL_CONFIG_MEMBER"
mkdir "$work/azip"
unzip -qq -j "$azip" "$V4A_AIDL_LIB_MEMBER" "$V4A_AIDL_CONFIG_MEMBER" -d "$work/azip" || fail "can't extract from $azip"
alib="$work/azip/${V4A_AIDL_LIB_MEMBER##*/}" acfg="$work/azip/${V4A_AIDL_CONFIG_MEMBER##*/}"
[[ "$(find "$work/azip" -mindepth 1 | wc -l)" = 2 && -f "$alib" && -f "$acfg" ]] \
    || fail "unzip didn't give exactly ${V4A_AIDL_LIB_MEMBER##*/} and ${V4A_AIDL_CONFIG_MEMBER##*/}"
have=$(sha "$alib")
[[ "$have" = "$V4A_AIDL_LIB_SHA256" && "$(size "$alib")" = "$V4A_AIDL_LIB_SIZE" ]] \
    || fail "AIDL driver: ${V4A_AIDL_LIB_MEMBER##*/} is $have ($(size "$alib") bytes), v4a.conf wants $V4A_AIDL_LIB_SHA256 ($V4A_AIDL_LIB_SIZE bytes)"
echo "OK: AIDL driver ${V4A_AIDL_LIB_MEMBER##*/} ($have)"
have=$(sha "$acfg")
[[ "$have" = "$V4A_AIDL_CONFIG_SHA256" ]] || fail "AIDL driver: ${V4A_AIDL_CONFIG_MEMBER##*/} is $have, v4a.conf wants $V4A_AIDL_CONFIG_SHA256"
echo "OK: AIDL driver effects config ${V4A_AIDL_CONFIG_MEMBER##*/} ($have)"

if [[ -n "$out" ]]; then
    mkdir "$work/out"
    cp -- "$apk" "$work/out/ViPER4Android.apk"
    cp -- "$cache/$V4A_APP_LICENSE_FILE" "$work/out/LICENSE.app"
    cp -- "$lib" "$work/out/libv4a_re_arm64-v8a.so"
    cp -- "$work/zip/LICENSE" "$work/out/LICENSE.driver"
    cp -- "$alib" "$work/out/libv4a_aidl_arm64-v8a.so"
    cp -- "$acfg" "$work/out/audio_effects_config.aidl.xml"
    chmod 0644 "$work/out"/*
    # Check the copies too: they are what gets staged
    while read -r want f; do
        [[ "$(sha "$work/out/$f")" = "$want" ]] || fail "copy of $f doesn't match v4a.conf"
    done <<EOF
$V4A_APP_SHA256 ViPER4Android.apk
$V4A_APP_LICENSE_SHA256 LICENSE.app
$V4A_FX_LIB_SHA256 libv4a_re_arm64-v8a.so
$V4A_FX_LICENSE_SHA256 LICENSE.driver
$V4A_AIDL_LIB_SHA256 libv4a_aidl_arm64-v8a.so
$V4A_AIDL_CONFIG_SHA256 audio_effects_config.aidl.xml
EOF
    mv -- "$work/out" "$out"
    echo "OK: verified files in $out"
fi
done=1
echo "V4A_FETCH=OK app=$V4A_APP_VERSION fx=$V4A_FX_VERSION aidl=$V4A_FX_VERSION"
