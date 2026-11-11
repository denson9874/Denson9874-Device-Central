#!/usr/bin/env bash
# Offline test of eos-progress-publish.sh (the live build page's sender): a fake home with a
# stub ~/bin/rclone that keeps what it is sent. It checks the key (made once, mode 600, never
# printed by the loop), what is sent where and with which headers, that the loop ends with the
# session and sends its result last, and that a missing or failing rclone stays silent.
#
#   tools/tests/eos-progress-publish-test.sh     # about 20 s; needs python3
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-progress-publish-test.XXXXXX")
trap 'rm -rf -- "$W"' EXIT
export HOME=$W/home
mkdir -p "$HOME/bin" "$HOME/expressiveos-cheetah" "$HOME/expressiveos-jobs/progress" "$W/r2"
cp -- "$KITSRC/eos.conf" "$HOME/expressiveos-cheetah/"
# As the runner's launch() lays it out
P=$HOME/expressiveos-jobs/progress
cp -- "$KITSRC/tools/eos-progress-publish.sh" "$KITSRC/tools/eos-progress.py" "$KITSRC/tools/progress-page/index.html" "$P/"
pass=0 failed=0
ok() { if eval "$2"; then echo "ok   $1"; pass=$((pass + 1)); else echo "FAIL $1"; failed=$((failed + 1)); fi; }

cat > "$HOME/bin/rclone" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$W/calls"
[[ ! -e "$W/rclone-fails" ]] || { echo "boom" >&2; exit 1; }
src=\${*: -2:1} dst=\${*: -1}
mkdir -p "$W/r2/\$(dirname "\${dst#*:}")"
cp -- "\$src" "$W/r2/\${dst#*:}"
n=\$(cat "$W/r2/\${dst#*:}.n" 2> /dev/null || echo 0)
echo \$((n + 1)) > "$W/r2/\${dst#*:}.n"
EOF
chmod +x "$HOME/bin/rclone"

# A session of 5 s, sent every 2 s
sleep 5 & pid=$!
t0=$(date +%s)
bash "$P/eos-progress-publish.sh" "$pid" 2 > "$W/out" 2>&1; rc=$?
t1=$(date +%s)
key=$(cat "$HOME/.expressiveos-progress-key" 2> /dev/null || true)
D=$W/r2/denson9874-ota/expressiveos/progress/$key
ok "exit 0" '[[ $rc = 0 ]]'
ok "it ended within 6 s of the session" '(( t1 - t0 <= 11 ))'
ok "the key: 32 hex digits, mode 600" '[[ $key =~ ^[0-9a-f]{32}$ && $(stat -c %a "$HOME/.expressiveos-progress-key") = 600 ]]'
ok "the loop prints nothing (no key, no address)" '[[ ! -s $W/out ]]'
ok "the page is sent once, as html" '[[ $(cat "$D/index.html.n") = 1 ]] && cmp -s "$D/index.html" "$P/index.html" && grep -q -- "Content-Type: text/html; charset=utf-8 .*index.html$" "$W/calls"'
ok "status.txt is sent while it runs and once after" '(( $(cat "$D/status.txt.n") >= 3 ))'
ok "status.txt: never cached, plain text" '[[ $(grep -c -- "--header-upload Content-Type: text/plain; charset=utf-8 --header-upload Cache-Control: no-store .*/status.txt$" "$W/calls") = $(cat "$D/status.txt.n") ]]'
ok "status.txt: a PUBLISHED line, then eos-progress.py's output" '[[ $(head -n 1 "$D/status.txt") =~ ^PUBLISHED\ at=20[0-9-]+T[0-9:]+Z\ every=2$ ]] && grep -qx "PROGRESS_OK" "$D/status.txt" && grep -q "^SESSION name=" "$D/status.txt"'
ok "every send goes to the bucket of eos.conf, under the key" '! grep -v -- " r2:denson9874-ota/expressiveos/progress/$key/\(index.html\|status.txt\)$" "$W/calls" | grep -q .'
ok "nothing is left in the temp folder" '! ls "${TMPDIR:-/tmp}"/eos-progress-publish.?????? > /dev/null 2>&1'

# The key is kept, and --where names the page
sleep 1 & pid=$!
bash "$P/eos-progress-publish.sh" "$pid" 2 > /dev/null 2>&1
ok "a second session keeps the key" '[[ $(cat "$HOME/.expressiveos-progress-key") = "$key" ]]'
ok "--where prints the page's address" '[[ $(bash "$P/eos-progress-publish.sh" --where) = "https://ota-mirror.daryldenson-apps.workers.dev/expressiveos/progress/$key/index.html" ]]'

# eos-progress.py failing is said on the page, not hidden
mv "$P/eos-progress.py" "$P/eos-progress.py.real"; echo 'import sys; sys.exit(7)' > "$P/eos-progress.py"
sleep 1 & pid=$!
bash "$P/eos-progress-publish.sh" "$pid" 2 > /dev/null 2>&1
ok "a failing eos-progress.py is reported in status.txt" 'grep -qx "PUBLISH_ERROR eos-progress.py ended 7" "$D/status.txt"'
mv -f "$P/eos-progress.py.real" "$P/eos-progress.py"

# A hangup (the session's terminal closing) doesn't stop the last send
: > "$W/calls"
sleep 3 & pid=$!
bash "$P/eos-progress-publish.sh" "$pid" 60 > /dev/null 2>&1 & pub=$!
sleep 1; kill -HUP "$pub"; wait "$pub"; rc=$?
ok "it survives a hangup and sends the result" '[[ $rc = 0 && $(grep -c "status.txt$" "$W/calls") = 2 ]]'

# rclone failing, or not there, or a bad key: silent, exit 0, nothing sent
touch "$W/rclone-fails"
sleep 1 & pid=$!
bash "$P/eos-progress-publish.sh" "$pid" 2 > "$W/out" 2>&1; rc=$?
ok "a failing rclone: exit 0 and silent" '[[ $rc = 0 && ! -s $W/out ]]'
rm -f "$W/rclone-fails"; : > "$W/calls"
echo "not a key" > "$HOME/.expressiveos-progress-key"
sleep 1 & pid=$!
bash "$P/eos-progress-publish.sh" "$pid" 2 > "$W/out" 2>&1; rc=$?
ok "a damaged key file: exit 0, nothing sent, the file is left alone" '[[ $rc = 0 && ! -s $W/calls && $(cat "$HOME/.expressiveos-progress-key") = "not a key" ]]'
echo "$key" > "$HOME/.expressiveos-progress-key"
mv "$HOME/bin/rclone" "$HOME/bin/rclone.off"
bash "$P/eos-progress-publish.sh" $$ 2 > "$W/out" 2>&1; rc=$?
ok "no rclone: exit 0 at once and silent" '[[ $rc = 0 && ! -s $W/out ]]'
bash "$P/eos-progress-publish.sh" 2> /dev/null && rc=0 || rc=$?
ok "no pid: usage, exit 2" '[[ $rc = 2 ]]'

# The page names every phone the kit builds, with its conf's model
for c in "$KITSRC"/devices/*.conf; do
    d=$(basename "$c" .conf) m=$(sed -n 's/^EOS_MODEL=//p' "$c")
    ok "the page knows $d ($m)" 'grep -q -- "$d: \"$m\"" "$P/index.html"'
done
ok "the page loads nothing from elsewhere" '! grep -qE "(src|href)=\"https?:|@import|url\(" "$P/index.html"'

echo "$pass passed, $failed failed"
(( failed == 0 ))
