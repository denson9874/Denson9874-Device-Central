#!/usr/bin/env bash
# Get the Expressive Launcher release pinned in launcher.conf (the APK, the LICENSE at its
# source revision and the two notices) into a cache, and check them against launcher.conf:
# SHA-256 (and the APK's size), then the APK's package, version, signing certificate,
# permissions and uses-library tags.
# A download lands under a temporary name and is renamed only once it matches, so the cache
# never holds a half-written or unverified file under a pinned name.
#
#   fetch-launcher.sh [--out <dir>]
#       --out: also put the verified files there (<dir> must not exist yet; it appears only
#       once everything passed): ExpressiveLauncher.apk, LICENSE, NOTICE.calculator and
#       NOTICE.font. apply-launcher.sh uses it.
#   EL_CACHE=<dir>    cache folder (default ~/android-dt/launcher)
#   EL_OFFLINE=1      never download: fail when a file isn't in the cache
set -euo pipefail
done=0 work= part=
cleanup() {
    local rc=$?
    [[ -z "$part" ]] || rm -f -- "$part"
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "LAUNCHER_FETCH=FAIL"
    exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=launcher.conf
source "$here/launcher.conf" || fail "can't read $here/launcher.conf"
# The APK reader is ViPER4Android's (no build tools needed)
apkinfo="$here/tools/apk-info.py"
[[ -f "$apkinfo" ]] || fail "no $apkinfo"

out=
case "${1:-}" in
    "") ;;
    --out) out=${2:-}; [[ -n "$out" && $# = 2 ]] || fail "usage: fetch-launcher.sh [--out <dir>]" ;;
    *) fail "usage: fetch-launcher.sh [--out <dir>]" ;;
esac

# launcher.conf sanity: a typo there must not turn into a download from somewhere else
for v in EL_SHA256 EL_CERT_SHA256 EL_LICENSE_SHA256 EL_NOTICE_MIT_SHA256 EL_NOTICE_OFL_SHA256; do
    [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || fail "launcher.conf: $v must be a 64-hex SHA-256"
done
[[ "${EL_SIZE:-}" =~ ^[1-9][0-9]*$ ]] || fail "launcher.conf: EL_SIZE must be a size in bytes"
[[ "${EL_VERSION_CODE:-}" =~ ^[1-9][0-9]*$ ]] || fail "launcher.conf: EL_VERSION_CODE must be a number"
[[ "${EL_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || fail "launcher.conf: EL_COMMIT must be a full commit id"
for v in EL_FILE EL_LICENSE_FILE EL_NOTICE_MIT_FILE EL_NOTICE_OFL_FILE; do
    [[ "${!v:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "launcher.conf: $v must be a plain file name"
done
[[ "$EL_PACKAGE" = dev.launcher.expressive.l3 ]] \
    || fail "launcher.conf: EL_PACKAGE must be dev.launcher.expressive.l3 (tree/ and the overlays name it)"
[[ "$EL_URL" == "https://github.com/denson9874/ExpressiveLauncher/releases/download/$EL_TAG/$EL_FILE" ]] \
    || fail "launcher.conf: EL_URL must be the $EL_TAG release asset $EL_FILE of denson9874/ExpressiveLauncher"
[[ "$EL_LICENSE_URL" == "https://raw.githubusercontent.com/denson9874/ExpressiveLauncher/$EL_COMMIT/LICENSE.txt" ]] \
    || fail "launcher.conf: EL_LICENSE_URL must be LICENSE.txt at EL_COMMIT"
[[ "$EL_NOTICE_MIT_URL" == "https://raw.githubusercontent.com/denson9874/ExpressiveLauncher/$EL_COMMIT/lawnchair/src/app/lawnchair/search/algorithms/data/calculator/LICENSE" ]] \
    || fail "launcher.conf: EL_NOTICE_MIT_URL must be the calculator's LICENSE at EL_COMMIT"
[[ "$EL_NOTICE_OFL_URL" =~ ^https://raw\.githubusercontent\.com/googlefonts/googlesans-flex/[0-9a-f]{40}/OFL\.txt$ ]] \
    || fail "launcher.conf: EL_NOTICE_OFL_URL must be OFL.txt at a googlefonts/googlesans-flex commit"
for tool in sha256sum python3; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
done

cache=${EL_CACHE:-$HOME/android-dt/launcher}
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
            fail "$what: the cached $dst is $have, launcher.conf wants $want; deleted it (run again to download it)"
        fi
        echo "OK: $what (cached, $have)"
        return
    fi
    [[ "${EL_OFFLINE:-0}" != 1 ]] || fail "$what: $dst isn't cached and EL_OFFLINE=1"
    command -v curl >/dev/null || fail "curl is not installed"
    part=$(mktemp "$cache/.$3.XXXXXX.part")
    echo "Downloading $what: $url"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-filesize 134217728 -o "$part" "$url" \
        || fail "$what: download failed: $url"
    have=$(size "$part")
    [[ -z "$wsize" || "$have" = "$wsize" ]] || fail "$what: $url is $have bytes, launcher.conf wants $wsize"
    have=$(sha "$part")
    [[ "$have" = "$want" ]] || fail "$what: $url is $have, launcher.conf wants $want"
    chmod 0644 -- "$part"
    mv -f -- "$part" "$dst"; part=
    echo "OK: $what (downloaded, $have)"
}

get "Expressive Launcher $EL_VERSION" "$EL_URL" "$EL_FILE" "$EL_SHA256" "$EL_SIZE"
get "LICENSE" "$EL_LICENSE_URL" "$EL_LICENSE_FILE" "$EL_LICENSE_SHA256"
get "the calculator's MIT licence" "$EL_NOTICE_MIT_URL" "$EL_NOTICE_MIT_FILE" "$EL_NOTICE_MIT_SHA256"
get "Google Sans Flex's OFL" "$EL_NOTICE_OFL_URL" "$EL_NOTICE_OFL_FILE" "$EL_NOTICE_OFL_SHA256"
apk="$cache/$EL_FILE"
[[ "$(size "$apk")" = "$EL_SIZE" ]] || fail "cached $apk is $(size "$apk") bytes, launcher.conf wants $EL_SIZE"

# What the pins say it is, asking for nothing more. apk-info.py reads the APK's binary
# manifest and APK Signature Scheme block itself.
info=$(python3 -I "$apkinfo" "$apk") || fail "can't read $apk"
field() { sed -n "s/^$1 //p" <<<"$info"; }
[[ "$(field package)" = "$EL_PACKAGE" ]] || fail "package is $(field package), launcher.conf wants $EL_PACKAGE"
[[ "$(field versionName)" = "$EL_VERSION" ]] || fail "versionName is $(field versionName), launcher.conf wants $EL_VERSION"
[[ "$(field versionCode)" = "$EL_VERSION_CODE" ]] || fail "versionCode is $(field versionCode), launcher.conf wants $EL_VERSION_CODE"
[[ "$(field cert)" = "$EL_CERT_SHA256" ]] || fail "signed by $(field cert), launcher.conf wants $EL_CERT_SHA256"
echo "OK: $(field package) $(field versionName) ($(field versionCode)), signer $(field cert)"
perms=$(field uses-permission | paste -sd' ') perms23=$(field uses-permission-sdk-23 | paste -sd' ')
[[ -z "$perms23" && "$perms" = "$EL_PERMS" ]] \
    || fail "permissions changed: has [$perms${perms23:+ (sdk-23) $perms23}], launcher.conf wants [$EL_PERMS]. A new privileged one must go into tree/privapp-permissions-$EL_PACKAGE.xml and EL_PRIVAPP_PERMS on purpose, then update EL_PERMS (README.md, Pins)"
echo "OK: asks for the $(wc -w <<<"$perms") permissions launcher.conf pins"
libs=$(field uses-library | paste -sd' ')
want_libs=""; for l in $EL_OPTIONAL_USES_LIBS; do want_libs+="${want_libs:+ }$l required=false"; done
[[ "$libs" = "$want_libs" ]] || fail "uses-library tags are [$libs], launcher.conf and tree/Android.bp want [$want_libs]"
echo "OK: uses-library tags: $EL_OPTIONAL_USES_LIBS (optional)"

if [[ -n "$out" ]]; then
    [[ ! -e "$out" ]] || fail "--out $out already exists"
    mkdir -p -- "$(dirname -- "$out")"
    work=$(mktemp -d "$(dirname -- "$out")/.launcher-fetch.XXXXXX")
    cp -- "$apk" "$work/ExpressiveLauncher.apk"
    cp -- "$cache/$EL_LICENSE_FILE" "$work/LICENSE"
    cp -- "$cache/$EL_NOTICE_MIT_FILE" "$work/NOTICE.calculator"
    cp -- "$cache/$EL_NOTICE_OFL_FILE" "$work/NOTICE.font"
    chmod 0644 "$work"/* && chmod 0755 "$work"
    # Check the copies too: they are what gets staged
    [[ "$(sha "$work/ExpressiveLauncher.apk")" = "$EL_SHA256" && "$(sha "$work/LICENSE")" = "$EL_LICENSE_SHA256" \
        && "$(sha "$work/NOTICE.calculator")" = "$EL_NOTICE_MIT_SHA256" && "$(sha "$work/NOTICE.font")" = "$EL_NOTICE_OFL_SHA256" ]] \
        || fail "the copies don't match launcher.conf"
    mv -- "$work" "$out"; work=
    echo "OK: verified files in $out"
fi
done=1
echo "LAUNCHER_FETCH=OK $EL_PACKAGE $EL_VERSION ($EL_VERSION_CODE)"
