#!/usr/bin/env bash
# Offline test of tools/gms-drop.py: builds a small vendor_gms and a small stock root from
# made-up APKs (a zip with a binary AndroidManifest.xml written here), then checks compare and
# apply. Needs python3 only. Run it as a non-root user:
#   runuser -u ubuntu -- expressiveos-cheetah/tools/tests/gms-drop-test.sh
# Last line: PASSED <n> FAILED <n>; exit status 1 when anything failed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../gms-drop.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok: $1"; }
bad() { fail=$((fail + 1)); echo "FAILED: $1"; }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (no '$2' in $1)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then bad "$3 ('$2' in $1)"; else ok "$3"; fi; }

# mkapk <file> <package> <versionCode> <versionName> [utf8]
mkapk() {
    mkdir -p "$(dirname "$1")"
    python3 -I - "$@" <<'PY'
import struct, sys, zipfile
path, package, code, vname = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
utf8 = len(sys.argv) > 5
strings = ['versionCode', 'versionName', 'package', 'manifest', package, vname]
blobs = []
for s in strings:
    if utf8:
        b = s.encode('utf-8'); blobs.append(bytes([len(s), len(b)]) + b + b'\0')
    else:
        blobs.append(struct.pack('<H', len(s)) + s.encode('utf-16-le') + b'\0\0')
offs, body = [], b''
for b in blobs:
    offs.append(len(body)); body += b
body += b'\0' * (-len(body) % 4)
hdr = 28
pool = struct.pack('<HHI5I', 1, hdr, hdr + 4 * len(strings) + len(body), len(strings), 0,
                   0x100 if utf8 else 0, hdr + 4 * len(strings), 0)
pool += b''.join(struct.pack('<I', o) for o in offs) + body
resmap = struct.pack('<HHI2I', 0x0180, 8, 16, 0x0101021b, 0x0101021c)
NO = 0xffffffff
attrs = struct.pack('<IIIHBBI', NO, 0, NO, 8, 0, 0x10, code & 0xffffffff)
attrs += struct.pack('<IIIHBBI', NO, 1, 5, 8, 0, 3, 5)
attrs += struct.pack('<IIIHBBI', NO, 2, 4, 8, 0, 3, 4)
elem = struct.pack('<HHI', 0x0102, 16, 36 + len(attrs)) + struct.pack('<II', 1, NO)
elem += struct.pack('<IIHHHHHH', NO, 3, 20, 20, 3, 0, 0, 0) + attrs
doc = pool + resmap + elem
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('AndroidManifest.xml', struct.pack('<HHI', 3, 8, 8 + len(doc)) + doc)
    z.writestr('marker.txt', '%s %d' % (package, code))
PY
}

G=$T/gms; S=$T/stock
mkapk "$G/product/packages/privileged_apps/Launcher_100/Launcher_100.apk" com.example.launcher 100 1.0
mkapk "$G/product/packages/apps/Same/Same.apk" com.example.same 7 7.0 utf8
mkapk "$G/system_ext/packages/privileged_apps/Ahead/Ahead.apk" com.example.ahead 50 5.0
mkapk "$G/product/packages/apps/OursOnly/OursOnly.apk" com.example.oursonly 1 1
mkapk "$G/system/packages/apps/Sys/Sys.apk" com.example.sys 3 3.0
mkdir -p "$G/product/packages/apps/Big" "$G/product/blobs/etc/sysconfig" "$G/product/blobs/etc/permissions"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 5\n' 0 > "$G/product/packages/apps/Big/Big.apk"
echo '<config fixed="ours"/>' > "$G/product/blobs/etc/sysconfig/nowplaying.xml"
echo '<config/>' > "$G/product/blobs/etc/sysconfig/same.xml"
echo '<config/>' > "$G/product/blobs/etc/permissions/dropped.xml"
echo 'x' > "$G/product/blobs/etc/sysconfig/Android.bp"

# stock: the launcher's folder was renamed and is newer; system sits under system/system
mkapk "$S/product/priv-app/Launcher_200/Launcher_200.apk" com.example.launcher 200 2.0 utf8
mkapk "$S/product/app/Same/Same.apk" com.example.same 7 7.0
mkapk "$S/system_ext/priv-app/Ahead/Ahead.apk" com.example.ahead 40 4.0
mkapk "$S/product/app/NewDropApp/NewDropApp.apk" com.example.dropapp 1 1.0
mkapk "$S/system/system/app/Sys/Sys.apk" com.example.sys 4 4.0
mkdir -p "$S/product/etc/sysconfig" "$S/product/app/Broken"
echo '<config stock="1"/>' > "$S/product/etc/sysconfig/nowplaying.xml"
echo '<config/>' > "$S/product/etc/sysconfig/same.xml"
echo '<config/>' > "$S/product/etc/sysconfig/new_feature.xml"
echo 'not a zip' > "$S/product/app/Broken/Broken.apk"
mkapk "$S/system/system/priv-app/Platform/Platform.apk" com.android.platformthing 37 17
mkdir -p "$S/system/system/etc/sysconfig" "$G/system/blobs/etc/sysconfig"
echo '<config/>' > "$S/system/system/etc/sysconfig/platform.xml"
echo '<config a="1"/>' > "$S/system/system/etc/sysconfig/oursys.xml"
echo '<config a="2"/>' > "$G/system/blobs/etc/sysconfig/oursys.xml"

before=$(cd "$G" && find . -type f -exec sha256sum {} + | sort | sha256sum)
python3 -I "$tool" compare "$S" "$G" > "$T/c.log" 2>&1 || bad "compare exits 0"
has "$T/c.log" 'com.example.launcher  1.0 (100) -> 2.0 (200)' "a renamed stock folder is matched by package and seen as newer"
has "$T/c.log" 'com.example.sys  3.0 (3) -> 4.0 (4)' "system/system is read"
has "$T/c.log" 'apps we carry that stock has newer (2)' "two newer apps"
has "$T/c.log" 'apps we carry at the same version: 1' "one app at the same version"
has "$T/c.log" 'com.example.ahead  ours 5.0 (50), stock 4.0 (40)' "an app ahead of stock is listed as newer than stock"
has "$T/c.log" 'com.example.oursonly  1 (1)' "an app stock lacks is listed"
has "$T/c.log" 'Big.apk: Git LFS pointer' "an LFS pointer is reported, not parsed"
has "$T/c.log" 'com.example.dropapp  1.0 (1)  product/app/NewDropApp/NewDropApp.apk' "a stock-only app is listed"
has "$T/c.log" 'differ from stock (2)' "two config files differ"
has "$T/c.log" 'product/etc/sysconfig/nowplaying.xml' "the differing config file is named"
has "$T/c.log" 'product/etc/permissions/dropped.xml' "a config file stock dropped is named"
has "$T/c.log" 'product/etc/sysconfig/new_feature.xml' "a stock config file we lack is named"
hasnt "$T/c.log" 'sysconfig/Android.bp' "build files are not compared"
has "$T/c.log" 'stock APK not read: product/app/Broken/Broken.apk' "an unreadable stock APK is a note, not a crash"
has "$T/c.log" 'GMS_DROP=CHANGES 5' "compare ends with the count of decisions (2 apps, 2 differing and 1 dropped config file)"
has "$T/c.log" 'platform apps (com.android.*, android.*) we do not carry: 1, not listed' "stock platform apps are counted, not listed"
hasnt "$T/c.log" 'com.android.platformthing' "a stock platform app is not listed"
has "$T/c.log" 'system-partition config files we do not carry: 1, not listed' "system config files are counted, not listed"
has "$T/c.log" 'system/system/etc/sysconfig/oursys.xml' "a system config path is printed as it is on disk"
after=$(cd "$G" && find . -type f -exec sha256sum {} + | sort | sha256sum)
[[ $before == "$after" ]] && ok "compare changes nothing" || bad "compare changes nothing"

ahead=$(sha256sum < "$G/system_ext/packages/privileged_apps/Ahead/Ahead.apk")
python3 -I "$tool" apply "$S" "$G" > "$T/a.log" 2>&1 || bad "apply exits 0"
has "$T/a.log" 'GMS_DROP=APPLIED 2' "apply copies the two newer apps"
cmp -s "$S/product/priv-app/Launcher_200/Launcher_200.apk" "$G/product/packages/privileged_apps/Launcher_100/Launcher_100.apk" \
    && ok "the newer APK lands at our path" || bad "the newer APK lands at our path"
cmp -s "$S/system/system/app/Sys/Sys.apk" "$G/system/packages/apps/Sys/Sys.apk" && ok "the system app is updated" || bad "the system app is updated"
[[ $ahead == "$(sha256sum < "$G/system_ext/packages/privileged_apps/Ahead/Ahead.apk")" ]] && ok "apply never downgrades" || bad "apply never downgrades"
grep -q 'fixed="ours"' "$G/product/blobs/etc/sysconfig/nowplaying.xml" && ok "apply leaves our config files alone" || bad "apply leaves our config files alone"
[[ ! -e "$G/product/packages/apps/NewDropApp" ]] && ok "apply adds no app" || bad "apply adds no app"
[[ -z "$(find "$G" -name '*.gms-drop')" ]] && ok "apply leaves no temporary file" || bad "apply leaves no temporary file"
python3 -I "$tool" compare "$S" "$G" > "$T/c2.log" 2>&1 || true
has "$T/c2.log" 'apps we carry that stock has newer (0)' "after apply nothing is newer"

mkdir -p "$T/empty"
if python3 -I "$tool" compare "$T/empty" "$G" > "$T/e.log" 2>&1; then bad "an empty stock root is refused"; else ok "an empty stock root is refused"; fi
if python3 -I "$tool" compare "$S" "$T/empty" > "$T/e2.log" 2>&1; then bad "a folder that is not vendor_gms is refused"; else ok "a folder that is not vendor_gms is refused"; fi

echo "PASSED $pass FAILED $fail"
[[ $fail -eq 0 ]]
