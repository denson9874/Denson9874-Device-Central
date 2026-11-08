#!/usr/bin/env bash
# Offline test of eos-ota.sh: a fake home, tree, release folder, R2 and feed, with the AOSP
# tools (ota_from_target_files, check_ota_package_signature, payload*.py), rclone and curl
# stubbed. It checks the script's choices (base, names, feed entries and their order, what R2
# keeps, refusals), not the packages: those are checked on the server and on a phone.
#
#   tools/tests/eos-ota-test.sh        # about 10 seconds; needs openssl, python3, zip, unzip
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-ota-test.XXXXXX")
export HOME=$W/home
mkdir -p "$HOME/bin" "$W/stub" "$W/r2" "$W/feed"
top=$HOME/expressiveos
mkdir -p "$top/build" "$top/out/host/linux-x86/bin" "$top/vendor/expressiveos-priv/keys"
touch "$top/build/envsetup.sh"
mkdir -p "$top/prebuilts/jdk/jdk21/linux-x86/bin" "$top/prebuilts/jdk/jdk8/linux-x86/bin"; printf "#!/bin/sh\n" > "$top/prebuilts/jdk/jdk21/linux-x86/bin/java"; chmod +x "$top/prebuilts/jdk/jdk21/linux-x86/bin/java"
# The kit: a copy, with eos.conf's pin set to a test cert and the payload tools stubbed
kit=$HOME/expressiveos-cheetah
cp -a "$KITSRC" "$kit"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/k.pem" -out "$top/vendor/expressiveos-priv/keys/testkey.x509.pem" -subj /CN=t -days 3 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$W/k.pem" -outform DER -out "$top/vendor/expressiveos-priv/keys/testkey.pk8"
FP=$(openssl x509 -in "$top/vendor/expressiveos-priv/keys/testkey.x509.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')
sed -i "s/^EOS_OTA_CERT_SHA256=.*/EOS_OTA_CERT_SHA256=$FP/" "$kit/eos.conf"
cat > "$kit/tools/eos-keys-check.sh" <<'EOF'
#!/usr/bin/env bash
echo KEYS_CHECK=${FAKE_KEYS:-OK}
EOF
cat > "$kit/tools/payload-sig.py" <<EOF
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); z.getinfo('payload.bin')
print('PAYLOAD_SIG=OK $FP')
EOF
cat > "$kit/tools/payload.py" <<'EOF'
import sys, zipfile
print(zipfile.ZipFile(sys.argv[2]).read('payload.bin').decode().strip())
EOF
H=$top/out/host/linux-x86/bin
for t in check_ota_package_signature delta_generator; do printf '#!/bin/sh\necho "Payload signatures VERIFIED"\n' > "$H/$t"; chmod +x "$H/$t"; done
cat > "$H/ota_from_target_files" <<'EOF'
#!/usr/bin/env python3
import sys, zipfile, os
a = sys.argv[1:]; src = None; full = ''
pos = []
i = 0
while i < len(a):
    if a[i] == '-k': open(os.environ['HOME'] + '/otf-k.log', 'a').write(a[i+1] + '\n'); i += 2; continue
    if a[i] == '--path': i += 2; continue
    if a[i] == '-i': src = a[i+1]; i += 2; continue
    if a[i] == '--full_ota_partitions': full = a[i+1]; i += 2; continue
    pos.append(a[i]); i += 1
tgt, out = pos
assert not src or 'jdk21/linux-x86/bin' in os.environ['PATH'], os.environ['PATH']
assert not src or os.environ['TMPDIR'].startswith(os.environ['HOME']), os.environ.get('TMPDIR')
def props(p):
    d = {}
    for l in zipfile.ZipFile(p).read('SYSTEM/build.prop').decode().splitlines():
        if '=' in l: k, v = l.split('=', 1); d[k] = v
    return d
t = props(tgt)
md = ['ota-type=AB', 'pre-device=cheetah', 'post-timestamp=' + t['ro.build.date.utc'], 'post-build-incremental=' + t['ro.build.version.incremental']]
if src:
    s = props(src); md += ['pre-build=x', 'pre-build-incremental=' + s['ro.build.version.incremental']]
with zipfile.ZipFile(out, 'w') as z:
    z.writestr('META-INF/com/android/metadata', '\n'.join(md) + '\n')
    z.writestr('payload.bin', zipfile.ZipFile(tgt).read('META/ab_partitions.txt'))
open(os.environ['HOME'] + '/otf.log', 'a').write('src=%s full=%s\n' % (src and os.path.basename(src), full))
EOF
chmod +x "$H/ota_from_target_files"
# rclone: r2:bucket/... is $W/r2/...
cat > "$HOME/bin/rclone" <<EOF
#!/usr/bin/env bash
R=$W/r2
p() { local x=\${1#*:}; [[ \$x == */* ]] && echo "\$R/\${x#*/}" || echo "\$R"; }
case \$1 in
  copyto) shift; [[ \$1 = --s3-no-check-bucket ]] && shift
          if [[ \$1 == r2:* ]]; then cp -- "\$(p "\$1")" "\$2"; else mkdir -p "\$(dirname "\$(p "\$2")")"; cp -- "\$1" "\$(p "\$2")"; fi ;;
  lsf) shift; [[ \$1 = --files-only ]] && shift; d=\$(p "\$1"); [[ -d \$d ]] || exit 3; find "\$d" -maxdepth 1 -type f -printf '%f\n' | sort ;;
  deletefile) rm -f -- "\$(p "\$2")" ;;
  cat) cat -- "\$(p "\$2")" ;;
  *) echo "rclone stub: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$HOME/bin/rclone"
# curl: the feed (raw.githubusercontent) from $W/feed, the mirror's HEAD from $W/r2
cat > "$W/stub/curl" <<EOF
#!/usr/bin/env bash
url=\${@: -1}; out=
for ((i=1;i<=\$#;i++)); do [[ \${!i} = -o ]] && { j=\$((i+1)); out=\${!j}; }; done
case \$url in
  https://raw.githubusercontent.com/*) f=$W/feed/\${url##*/}
     if [[ -f \$f ]]; then cp "\$f" "\$out"; printf 200; else printf 404; fi ;;
  https://ota-mirror.*) k=\${url#https://*/}; f=$W/r2/\$k
     [[ -f \$f ]] && printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "\$(stat -c %s "\$f")" || printf 'HTTP/1.1 404\r\n\r\n' ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$W/stub/curl"
export PATH=$W/stub:$PATH
D=$HOME/releases/expressiveos-cheetah
mkdir -p "$D/check" "$D/target-files" "$D/ota"
otacerts=$W/otacerts.zip
(cd "$top/vendor/expressiveos-priv/keys" && zip -q "$otacerts" testkey.x509.pem)
mktf() {   # mktf <out> <name> <ts> <incr> [<security patch>]
    local d; d=$(mktemp -d)
    mkdir -p "$d/META" "$d/SYSTEM/etc/security"
    printf 'ab_update=true\ndynamic_partition_list=system vendor product\n' > "$d/META/misc_info.txt"
    printf 'boot\ninit_boot\nproduct\nsystem\nvbmeta\nvendor\n' > "$d/META/ab_partitions.txt"
    printf 'ro.build.date.utc=%s\nro.build.version.incremental=%s\nro.build.version.security_patch=%s\nro.evolution.build.version=%s\n' "$3" "$4" "${5:-2026-11-05}" "$2" > "$d/SYSTEM/build.prop"
    cp "$otacerts" "$d/SYSTEM/etc/security/otacerts.zip"
    (cd "$d" && zip -q -r "$1" META SYSTEM); rm -rf "$d"
}
release() {   # release <name> <ts> <incr>: what eos-pack.sh --release leaves
    mktf "$D/target-files/$1-target_files.zip" "$1" "$2" "$3"
    (cd "$D/target-files" && sha256sum -- "$1-target_files.zip" > "$1-target_files.zip.sha256")
    echo "$1-target_files.zip" > "$D/target-files/LATEST"
    echo z > "$D/$1-fastboot.zip"; (cd "$D" && sha256sum -- "$1-fastboot.zip" > "$1-fastboot.zip.sha256")
    echo "notes for $1" > "$D/$1-changelog.txt"
    "$H/ota_from_target_files" -k x "$D/target-files/$1-target_files.zip" "$D/ota/$1.zip"
    (cd "$D/ota" && sha256sum -- "$1.zip" > "$1.zip.sha256")
}
ota() { local rc=0; "$kit/tools/eos-ota.sh" "$@" > "$W/out.log" 2>&1 || rc=$?; echo "$rc"; }
pass=0; failn=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1"; sed 's/^/     | /' "$W/out.log" | tail -25; fi; }
A=ExpressiveOS-17.0-20261103-cheetah-1.0-Unofficial
B=ExpressiveOS-17.0-20261203-cheetah-1.0-Unofficial
C=ExpressiveOS-17.0-20261210-cheetah-1.0-Unofficial

rc=$(ota); ok "no release yet: refuses" '[[ $rc = 1 ]] && grep -q "nothing released yet" "$W/out.log" && tail -1 "$W/out.log" | grep -qx OTA=FAIL'
release "$A" 1762100000 eng.a
rc=$(ota); ok "first release, no feed file: full only, preview" '[[ $rc = 0 ]] && grep -q "the full package only" "$W/out.log" && grep -q OTA_PREVIEW "$W/out.log" && [[ ! -d $W/r2/expressiveos ]]'
ok "  feed JSON: one full entry" 'python3 -c "import json,sys; r=json.load(open(sys.argv[1]))[\"response\"]; assert len(r)==1 and \"base_timestamp\" not in r[0] and r[0][\"timestamp\"]==1762100000 and r[0][\"version\"]==\"1.0\" and r[0][\"download\"].endswith(\"/expressiveos/cheetah/ota/$A.zip\")" "$D/ota/feed/builds/cheetah.json"'
ok "  changelog copied" 'grep -qx "notes for $A" "$D/ota/feed/changelogs/cheetah.txt"'
rc=$(ota --upload); ok "--upload: full on R2, feed printed" '[[ $rc = 0 ]] && [[ -f $W/r2/expressiveos/cheetah/ota/$A.zip ]] && grep -q "^OTA_FEED_READY" "$W/out.log" && grep -q "^===== OTA_FEED builds/cheetah.json" "$W/out.log"'
cp "$D/ota/feed/builds/cheetah.json" "$W/feed/cheetah.json"   # the feed PR merged
rc=$(ota --upload); ok "rerun of A once A is in the feed: still full only" '[[ $rc = 0 ]] && grep -q "the full package only" "$W/out.log"'

release "$B" 1764700000 eng.b
: > "$HOME/otf.log"
rc=$(ota --upload); ok "B: incremental from A" '[[ $rc = 0 ]] && [[ -f $D/ota/$B-incremental-from-20261103.zip ]] && grep -qx "src=$A-target_files.zip full=boot,init_boot,vbmeta" "$HOME/otf.log"'
ok "  signed with the key in vendor/expressiveos-priv (-k)" 'tail -1 "$HOME/otf-k.log" | grep -qx vendor/expressiveos-priv/keys/testkey'
ok "  feed: incremental first (base A, ts+1), then full" 'python3 -c "
import json,sys; r=json.load(open(sys.argv[1]))[\"response\"]
assert len(r)==2, r
assert r[0][\"filename\"]==\"$B-incremental-from-20261103.zip\" and r[0][\"base_timestamp\"]==1762100000 and r[0][\"timestamp\"]==1764700001
assert r[1][\"filename\"]==\"$B.zip\" and \"base_timestamp\" not in r[1] and r[1][\"timestamp\"]==1764700000
" "$D/ota/feed/builds/cheetah.json"'
ok "  R2 keeps A (the live feed's) and B" '[[ -f $W/r2/expressiveos/cheetah/ota/$A.zip && -f $W/r2/expressiveos/cheetah/ota/$B.zip && -f $W/r2/expressiveos/cheetah/ota/$B-incremental-from-20261103.zip ]]'
cp "$D/ota/feed/builds/cheetah.json" "$W/feed/cheetah.json"   # merged
: > "$HOME/otf.log"
rc=$(ota --upload); ok "rerun of B once B is in the feed: same base, not made again" '[[ $rc = 0 ]] && grep -q "made already" "$W/out.log" && [[ ! -s $HOME/otf.log ]] && grep -q "$B-incremental-from-20261103.zip" "$D/ota/feed/builds/cheetah.json"'
ok "  R2 drops A now that no feed names it" '[[ ! -f $W/r2/expressiveos/cheetah/ota/$A.zip && -f $W/r2/expressiveos/cheetah/ota/$B.zip ]]'

# The feed has B; LATEST pointing at A (older) must stop
echo "$A-target_files.zip" > "$D/target-files/LATEST"
rc=$(ota --upload); ok "older release than the feed's: OTA_SUPERSEDED, exit 3" '[[ $rc = 3 ]] && grep -q "^OTA_SUPERSEDED $B.zip" "$W/out.log"'
echo "$B-target_files.zip" > "$D/target-files/LATEST"

# A candidate C in check/, packed with keys and incremental base OK
mktf "$D/check/$C-target_files.zip" "$C" 1765300000 eng.c
(cd "$D/check" && sha256sum -- "$C-target_files.zip" > "$C-target_files.zip.sha256")
echo zz > "$D/check/$C-fastboot.zip"
printf 'sha256 %s\nkeys OK\nincremental-base OK\nbuild full\n' "$(sha256sum "$D/check/$C-fastboot.zip" | cut -d' ' -f1)" > "$D/check/$C-fastboot.zip.pack-ok"
echo old > "$D/check/ExpressiveOS-17.0-20261201-cheetah-1.0-Unofficial-incremental-from-20261103.zip"
: > "$HOME/otf.log"
rc=$(ota --candidate); ok "--candidate: incremental B->C to R2 test/ with a test feed" '[[ $rc = 0 ]] && [[ -f $D/check/$C-incremental-from-20261203.zip && -f $W/r2/expressiveos/cheetah/ota/test/$C-incremental-from-20261203.zip && -f $W/r2/expressiveos/cheetah/ota/test/cheetah.json ]] && grep -q "^OTA_TEST https://ota-mirror.daryldenson-apps.workers.dev/expressiveos/cheetah/ota/test/cheetah.json" "$W/out.log"'
ok "  older candidate incremental removed from check/" '[[ ! -e $D/check/ExpressiveOS-17.0-20261201-cheetah-1.0-Unofficial-incremental-from-20261103.zip ]]'
ok "  test feed: the incremental only, its download in test/" 'python3 -c "
import json,sys; r=json.load(open(sys.argv[1]))[\"response\"]
assert len(r)==1 and r[0][\"base_timestamp\"]==1764700000 and r[0][\"download\"].endswith(\"/ota/test/$C-incremental-from-20261203.zip\")
" "$W/r2/expressiveos/cheetah/ota/test/cheetah.json"'
ok "  the live feed's R2 files untouched" '[[ -f $W/r2/expressiveos/cheetah/ota/$B.zip ]]'
# C tested and released (eos-pack.sh --release: its target-files a hard link to check/'s): the
# release's incremental is check/'s, the one the phone test installed, not made again
ln "$D/check/$C-target_files.zip" "$D/target-files/$C-target_files.zip"
(cd "$D/target-files" && sha256sum -- "$C-target_files.zip" > "$C-target_files.zip.sha256")
echo "$C-target_files.zip" > "$D/target-files/LATEST"
cp "$D/check/$C-fastboot.zip" "$D/$C-fastboot.zip"; (cd "$D" && sha256sum -- "$C-fastboot.zip" > "$C-fastboot.zip.sha256")
echo "notes for $C" > "$D/$C-changelog.txt"
"$H/ota_from_target_files" -k x "$D/target-files/$C-target_files.zip" "$D/ota/$C.zip"
(cd "$D/ota" && sha256sum -- "$C.zip" > "$C.zip.sha256")
: > "$HOME/otf.log"
rc=$(ota); ok "release C: check/'s tested incremental, not made again" '[[ $rc = 0 ]] && grep -q "the candidate incremental the phone test installed" "$W/out.log" && [[ ! -s $HOME/otf.log ]] && cmp -s "$D/ota/$C-incremental-from-20261203.zip" "$D/check/$C-incremental-from-20261203.zip"'
ok "  its .sha256 names the release's file, its .base the same base and target-files" '(cd "$D/ota" && sha256sum -c --quiet "$C-incremental-from-20261203.zip.sha256") && cmp -s "$D/ota/$C-incremental-from-20261203.zip.base" "$D/check/$C-incremental-from-20261203.zip.base"'
ok "  feed: that incremental first" 'python3 -c "
import json,sys; r=json.load(open(sys.argv[1]))[\"response\"]
assert r[0][\"filename\"]==\"$C-incremental-from-20261203.zip\" and r[0][\"base_timestamp\"]==1764700000
" "$D/ota/feed/builds/cheetah.json"'
# A candidate incremental made to other target-files (an older build of the same name): made again
rm -f "$D/ota/$C-incremental-from-20261203.zip"*
sed -i 's/ [0-9a-f]*$/ 0000/' "$D/check/$C-incremental-from-20261203.zip.base"
: > "$HOME/otf.log"
rc=$(ota); ok "  a candidate incremental to other target-files isn't taken: made again" '[[ $rc = 0 ]] && ! grep -q "phone test installed" "$W/out.log" && grep -qx "src=$B-target_files.zip full=boot,init_boot,vbmeta" "$HOME/otf.log"'
rm -f "$D/target-files/$C-target_files.zip"* "$D/ota/$C"* "$D/$C-fastboot.zip"* "$D/$C-changelog.txt"
echo "$B-target_files.zip" > "$D/target-files/LATEST"
# A tree from before 1.1's key move (or after its revert): the key folder's old name
mv "$top/vendor/expressiveos-priv" "$top/vendor/evolution-priv"
rm -f "$D/check/$C-incremental-from-20261203.zip"*
: > "$HOME/otf-k.log"
rc=$(ota --candidate); ok "key folder still vendor/evolution-priv: -k takes it, with a note" '[[ $rc = 0 ]] && grep -q "^note: the release key is in vendor/evolution-priv" "$W/out.log" && tail -1 "$HOME/otf-k.log" | grep -qx vendor/evolution-priv/keys/testkey'
mv "$top/vendor/evolution-priv" "$top/vendor/expressiveos-priv"
sed -i 's/^build full/build quick/' "$D/check/$C-fastboot.zip.pack-ok"
rc=$(ota --candidate); ok "--candidate refuses a quick build" '[[ $rc = 1 ]] && grep -q "quick build" "$W/out.log"'
sed -i 's/^build quick/build full/' "$D/check/$C-fastboot.zip.pack-ok"

# Base target-files gone from the server: fetched from R2
mkdir -p "$W/r2/expressiveos/cheetah/target-files"
cp "$D/target-files/$B-target_files.zip"* "$W/r2/expressiveos/cheetah/target-files/"
rm "$D/target-files/$B-target_files.zip"
rc=$(ota --candidate); ok "base target-files fetched from R2" '[[ $rc = 0 ]] && grep -q "fetching it from" "$W/out.log"'
echo corrupt >> "$W/r2/expressiveos/cheetah/target-files/$B-target_files.zip"
rc=$(ota --candidate); ok "  a corrupt R2 copy is refused" '[[ $rc = 1 ]] && grep -q "isn.t the zip its .sha256 names" "$W/out.log"'

# A candidate with an older security patch than the feed's build (B has 2026-11-05)
mktf "$D/check/$C-target_files.zip" "$C" 1765300000 eng.c 2026-10-05
(cd "$D/check" && sha256sum -- "$C-target_files.zip" > "$C-target_files.zip.sha256")
rc=$(ota --candidate); ok "--candidate refuses an older security patch than the feed's" '[[ $rc = 1 ]] && grep -q "security patch 2026-10-05 is older than 2026-11-05" "$W/out.log"'

# Wrong key pin and a changed full package
rc=$(FAKE_KEYS=UNPINNED ota); ok "unpinned keys: refuses" '[[ $rc = 1 ]] && grep -q "pinned ones" "$W/out.log"'
echo x >> "$D/ota/$B.zip"
rc=$(ota); ok "a changed full package: refuses" '[[ $rc = 1 ]] && grep -q "isn.t the package its .sha256 names" "$W/out.log"'

echo "PASSED $pass FAILED $failn"
[[ $failn = 0 ]] && rm -rf "$W"
