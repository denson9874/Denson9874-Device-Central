#!/bin/bash
# Sandbox tests for derp-build.sh --check-only, in a fake $HOME (runs on the Mac or the server).
#   evolution-kodiak/tools/tests/derp-build-check-test.sh evolution-kodiak/tools/derp-build.sh
S=${1:?script}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; failn=0
expect() {  # expect <name> <rc> <output prefix>
    local out rc
    out=$(HOME="$T" bash "$S" --check-only); rc=$?
    if [ "$rc" = "$2" ] && [[ "$out" == "$3"* ]]; then pass=$((pass + 1)); echo "ok   $1"
    else failn=$((failn + 1)); echo "FAIL $1: rc=$rc out=$out (want rc=$2, '$3…')"; fi
}
E=$T/derpfest/vendor/extra; B=$E/bcr; O=$T/derpfest/out/target/product/kodiak/system_ext

expect "no vendor/extra" 3 "BCR_CHECK=MISSING"
mkdir -p "$B" "$O/priv-app/BCR" "$O/etc/permissions"
echo apk > "$B/BCR.apk"; (cd "$B" && sha256sum BCR.apk > BCR.apk.sha256); echo 3.11 > "$B/VERSION"
expect "no product.mk" 3 "BCR_CHECK=MISSING"
printf '# Basic Call Recorder (chenxiaolong/BCR)\nPRODUCT_PACKAGES += \\\n    BCR\n' > "$E/product.mk"
expect "not installed" 3 "BCR_CHECK=MISSING"
cp "$B/BCR.apk" "$O/priv-app/BCR/BCR.apk"
expect "no allowlist xml" 3 "BCR_CHECK=MISSING"
touch "$O/etc/permissions/privapp-permissions-com.chiller3.bcr.xml"
expect "all present" 0 "BCR_CHECK=OK version=3.11"
echo changed > "$O/priv-app/BCR/BCR.apk"
expect "apk modified" 3 "BCR_CHECK=MISSING"
printf '# Basic Call Recorder (chenxiaolong/BCR), removed for this release\n' > "$E/product.mk"
expect "BCR taken out of product.mk (rollback)" 0 "BCR_CHECK=SKIPPED"
echo "passed=$pass failed=$failn"
[ "$failn" = 0 ]
