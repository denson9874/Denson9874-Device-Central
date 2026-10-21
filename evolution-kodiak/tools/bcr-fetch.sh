#!/bin/bash
# Fetch Basic Call Recorder (BCR, https://github.com/chenxiaolong/BCR) for the DerpFest kodiak build, and check it
# before anything uses it: the release zip's pinned SHA-256, chenxiaolong's SSH signature, the build's rules for
# preprocessed APKs (alignment, uncompressed dex and JNI) and the APK's signing certificate. The privileged
# permissions in upstream's allowlist must also match ours (<dest-dir>/privapp-permissions-com.chiller3.bcr.xml):
# DerpFest only logs a missing allowlist entry, so a release that needs a new permission must not slip through.
# See DERP_BCR_PLAN.md, Task 1.
#
#   bcr-fetch.sh <dest-dir>        normally ~/derpfest/vendor/extra/bcr
#
# On success it writes BCR.apk, BCR.apk.sha256, VERSION and LICENSE into <dest-dir> and the last line is
# BCR_FETCH=OK version=<v>. On failure the last line is BCR_FETCH=FAIL <reason>, it exits 1 and <dest-dir> is left
# alone. To move to a new release, update the pins below from the release page (the zip's sha256) and the README
# (the certificate digest), then rebuild.
set -uo pipefail

: "${BCR_VERSION:=3.11}"
: "${BCR_ZIP_SHA256:=a5c8c2cf611891992c072d28cf85ec275da27a77b5dbf2408c6398d5bccee918}"
: "${BCR_CERT_SHA256:=d16f9b375df668c58ef4bb855eae959713d6d02e45f7f2c05ce2c27ae944f4f9}"
: "${BCR_TRUSTED_KEY:=chenxiaolong ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4}"
: "${APKSIGNER:=$HOME/derpfest/out/host/linux-x86/bin/apksigner}"
: "${ZIPALIGN:=$HOME/derpfest/out/host/linux-x86/bin/zipalign}"

PKG=com.chiller3.bcr
XML=privapp-permissions-$PKG.xml

fail() { echo "BCR_FETCH=FAIL $*"; exit 1; }

dest=${1:-}
[ -n "$dest" ] || { echo "usage: bcr-fetch.sh <dest-dir>" >&2; exit 2; }
[ -f "$dest/$XML" ] || fail "no $dest/$XML (our allowlist)"

work=$(mktemp -d) || fail "mktemp"
trap 'rm -rf "$work"' EXIT

zip=BCR-$BCR_VERSION-release.zip
url=https://github.com/chenxiaolong/BCR/releases/download/v$BCR_VERSION/$zip
curl -fsSL -o "$work/$zip" "$url" && curl -fsSL -o "$work/$zip.sig" "$url.sig" || fail "download of $url"

echo "$BCR_ZIP_SHA256  $work/$zip" | sha256sum -c --status || fail "zip checksum mismatch"

echo "$BCR_TRUSTED_KEY" > "$work/trusted_keys"
ssh-keygen -Y verify -f "$work/trusted_keys" -I chenxiaolong -n file -s "$work/$zip.sig" < "$work/$zip" >/dev/null 2>&1 \
    || fail "bad zip signature"

unzip -q -d "$work/x" "$work/$zip" "system/priv-app/$PKG/app-release.apk" "system/etc/permissions/$XML" LICENSE \
    || fail "the zip lacks the apk, the allowlist or LICENSE"
apk=$work/x/system/priv-app/$PKG/app-release.apk

# Same rules as build/soong/scripts/check_prebuilt_presigned_apk.py for a privileged, preprocessed app.
# zipinfo's 6th column is the compression method ("stor" = stored); there must be at least one classes.dex.
"$ZIPALIGN" -c -p 4 "$apk" >/dev/null 2>&1 || fail "bad zip alignment"
unzip -Z "$apk" | awk '
    $NF ~ /^classes[0-9]*\.dex$/ { dex++ }
    ($NF ~ /^classes[0-9]*\.dex$/ || $NF ~ /^lib\/.*\.so$/) && $6 != "stor" { bad++ }
    END { exit !(dex > 0 && bad == 0) }' || fail "dex or JNI compressed"

"$APKSIGNER" verify --print-certs "$apk" 2>/dev/null | grep -q "certificate SHA-256 digest: $BCR_CERT_SHA256\$" \
    || fail "apk certificate mismatch"

perms() { grep -o 'permission name="[^"]*"' "$1" | sort; }
[ "$(perms "$work/x/system/etc/permissions/$XML")" = "$(perms "$dest/$XML")" ] \
    || fail "privapp permissions changed upstream"

cp "$apk" "$work/BCR.apk" && (cd "$work" && sha256sum BCR.apk > BCR.apk.sha256) && echo "$BCR_VERSION" > "$work/VERSION" \
    || fail "staging the files"
cp "$work/BCR.apk" "$work/BCR.apk.sha256" "$work/VERSION" "$dest/" && cp "$work/x/LICENSE" "$dest/LICENSE" \
    || fail "copying to $dest"
echo "BCR $BCR_VERSION: checksum, signature, alignment, certificate and allowlist checked"
echo "BCR_FETCH=OK version=$BCR_VERSION"
