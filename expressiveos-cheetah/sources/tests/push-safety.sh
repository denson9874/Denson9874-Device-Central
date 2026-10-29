#!/usr/bin/env bash
# Regression test: push safety of update.py (plan/push/token).
#  a. the push token only ever goes to https://github.com/ (receive_pack, token mode, plan, push)
#  b. plan.json's "pins": a fork the new manifest moves to its branch tip without a merge is
#     checked by push's preflight ("plan again" when its branch isn't at that tip any more)
#  c. a resolution for a fork whose planning failed isn't also "not one of ExpressiveOS's forks"
#  d. plan doesn't crash when a project LineageOS moved to another repo fails its own check, and
#     any unexpected exception still ends with UPDATE_PLAN=NOT_READY
#   push-safety.sh <kit src>
# Builds its worlds (harness.sh, one at a time) in push-safety under $EOS_TEST_WORK, starts small
# logging HTTP servers on 127.0.0.1 (random ports), and deletes it all at the end.
set -uo pipefail
KSRC=$(cd "${1:?usage: push-safety.sh <kit src>}" && pwd) || exit 2
R=$(cd "$(dirname "$0")" && pwd)
H=$R/harness.sh
TRES=$R/t-resolve.sh
WD=${EOS_TEST_WORK:-${TMPDIR:-/tmp}/eos-update-tests}/push-safety
rm -rf "$WD"
mkdir -p "$WD/aux"
A=$WD/aux
SRVPIDS=()
stop_servers() { local p; for p in "${SRVPIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; SRVPIDS=(); }
trap 'stop_servers; rm -rf "$WD"' EXIT
pass=0 failn=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
show() { sed 's/^/    | /' | tail -"${2:-15}"; }   # indented tail of some output, after a FAIL
UPY=$KSRC/sources/update.py
TOKEN=github_pat_TEST
TOKEN64=$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)

# A logging HTTP server: every request (any method, CONNECT too) logged with its Authorization
# header; GETs served from a folder (dumb git over http); receive-pack probes answered 401 without
# a login, 200 with one; CONNECT refused (so nothing ever leaves the machine through it)
cat > "$A/srv.py" <<'EOF'
import http.server, os, sys
root, log, portfile = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def note(self):
        with open(log, "a") as f:
            f.write(f"{self.command} {self.path} Authorization={self.headers.get('Authorization')}\n")
    def empty(self, code, ctype=None, extra=()):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_GET(self):
        self.note()
        if "service=git-receive-pack" in self.path:
            if not self.headers.get("Authorization"):
                return self.empty(401, extra=[("WWW-Authenticate", 'Basic realm="x"')])
            return self.empty(200, "application/x-git-receive-pack-advertisement")
        self.path = self.path.split("?")[0]
        return super().do_GET()
    def do_HEAD(self):
        self.note(); self.empty(404)
    def do_POST(self):
        self.note(); self.empty(403)
    def do_PUT(self):
        self.note(); self.empty(403)
    def do_CONNECT(self):
        self.note(); self.empty(403); self.close_connection = True
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(portfile + ".tmp", portfile)
s.serve_forever()
EOF
# start_server <name> <root dir>: sets PORT_<name>, logs to $A/<name>.log
start_server() {
    local name=$1 root=$2 i
    mkdir -p "$root"; : > "$A/$name.log"; rm -f "$A/$name.port"
    python3 -I "$A/srv.py" "$root" "$A/$name.log" "$A/$name.port" & SRVPIDS+=($!)
    for i in $(seq 100); do [[ -s $A/$name.port ]] && break; sleep 0.1; done
    [[ -s $A/$name.port ]] || { bad "logging server $name didn't start"; return 1; }
    printf -v "PORT_$name" '%s' "$(cat "$A/$name.port")"
}
# no request in the log carries a login (or the token in any form)
no_token_in() { ! grep -v 'Authorization=None$' "$1" | grep -q . && ! grep -qE "$TOKEN|$TOKEN64" "$1"; }

world() {   # a fresh world (the old one deleted)
    bash "$H" "$KSRC" "$WD/world" >/dev/null 2>&1 || { bad "harness.sh failed to build a world"; echo "== $pass passed, $failn failed"; exit 1; }
    # shellcheck disable=SC1091
    source "$WD/world/env.sh"
    export GIT_CEILING_DIRECTORIES=$T
    W=$HOME/expressiveos-update
    U=$kit/sources/updates/2026-11
}
plan() { (cd "$T" && bash "$kit/sources/update.sh" plan "${1:-2026-11}" "$top"); }
push() { (cd "$T" && bash "$kit/sources/update.sh" push "${1:-2026-11}" "$top"); }
resolve() { bash "$TRES" "$WD/world" true >/dev/null 2>&1; }
tipof() { git --git-dir="$T/gh/$1.git" rev-parse -q --verify "refs/heads/${2:-expressiveos}" 2>/dev/null; }
commit_on() {   # commit_on <bare> <branch> <file> <content> <msg>: one more commit; prints it
    local w; w=$(mktemp -d "$T/w/x.XXXX")
    git clone -q -b "$2" "$1" "$w" && printf '%s\n' "$4" > "$w/$3" && git -C "$w" add -A && git -C "$w" commit -qm "$5" \
        && git -C "$w" push -q origin "$2" && git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
report_of() { sed -n 's/^report: //p' <<<"$1" | tail -1; }

# ======================================================================================
# 1. receive_pack(): with a token, only https://github.com/ is asked
start_server rp "$A/empty" || exit 1
cat > "$A/rp.py" <<'EOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("eos_update_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
token = None if sys.argv[2] == "-" else sys.argv[2]
print(json.dumps({u: m.receive_pack(u, token) for u in sys.argv[3:]}))
EOF
# http and https go to the logging server as a proxy (127.0.0.1 is in no_proxy), so a request to
# example.com or github.com shows up there (a CONNECT, or a GET of a full URL), and nothing leaves the machine
rp() { https_proxy=http://127.0.0.1:$PORT_rp HTTPS_PROXY=http://127.0.0.1:$PORT_rp http_proxy=http://127.0.0.1:$PORT_rp HTTP_PROXY=http://127.0.0.1:$PORT_rp python3 -I "$A/rp.py" "$UPY" "$@"; }
off=("http://127.0.0.1:$PORT_rp/x" "https://example.com/x" "http://github.com/ExpressiveOS/manifest"
     "https://github.com.evil.example/ExpressiveOS/manifest" "https://evil.example/https://github.com/x")
out=$(rp "$TOKEN" "${off[@]}" 2>&1); rc=$?
if [[ $rc = 0 ]] && python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == set(sys.argv[2:]), d
assert all(v[0] is None and "not on GitHub" in v[1] for v in d.values()), d' "$out" "${off[@]}" 2>/dev/null; then
    ok "1a receive_pack with a token answers 'not on GitHub' for local http, example.com, plain-http and look-alike GitHub URLs"
else
    bad "1a receive_pack with a token for non-GitHub URLs: rc $rc, answered: $out"
fi
if [[ ! -s $A/rp.log ]]; then
    ok "1b no request at all (no GET, no CONNECT) reached the logging server for those token calls"
else
    bad "1b requests reached the logging server with a token in hand:"; show < "$A/rp.log"
fi
: > "$A/rp.log"
out=$(rp - "http://127.0.0.1:$PORT_rp/x" 2>&1)
if grep -qx "GET /x.git/info/refs?service=git-receive-pack Authorization=None" "$A/rp.log" && grep -q '401' <<<"$out"; then
    ok "1c control: without a token the local URL is asked (GET logged, no Authorization, 401 back)"
else
    bad "1c control: token None for the local URL didn't reach the server (answer $out)"; show < "$A/rp.log"
fi
: > "$A/rp.log"
out=$(rp "$TOKEN" "https://github.com/ExpressiveOS/manifest" 2>&1)
if grep -q '^CONNECT github.com:443 ' "$A/rp.log" && no_token_in "$A/rp.log" && ! grep -q 'not on GitHub' <<<"$out"; then
    ok "1d control: with a token, https://github.com/ is still asked (a CONNECT to github.com, no login in clear)"
else
    bad "1d control: a token call for https://github.com/ wasn't attempted ($out)"; show < "$A/rp.log"
fi
stop_servers

# ======================================================================================
# 3. push_urls_problem() and on_github(): which push URLs plan and push accept
out=$(python3 -I - "$UPY" <<'EOF' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("eos_update_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
gh = ["https://github.com/ExpressiveOS/manifest", "https://github.com/ExpressiveOS/frameworks_base"]
fl = ["file:///srv/gh/ExpressiveOS/manifest", "file:///srv/gh/ExpressiveOS/vendor_lineage"]
bad = ["http://127.0.0.1:8080/ExpressiveOS/x", "https://example.com/ExpressiveOS/x", "http://github.com/ExpressiveOS/x",
       "https://github.com.evil.example/ExpressiveOS/x", "ssh://git@github.com/ExpressiveOS/x",
       "git@github.com:ExpressiveOS/x", "https://gitlab.com/ExpressiveOS/x", "/srv/gh/ExpressiveOS/x"]
fails = []
def want(name, cond):
    if not cond:
        fails.append(name)
want("empty list: no problem", m.push_urls_problem([]) is None)
want("GitHub only: no problem", m.push_urls_problem(gh) is None)
want("file:// only: no problem", m.push_urls_problem(fl) is None)
want("GitHub and file://: no problem", m.push_urls_problem(gh + fl) is None)
for u in bad:
    p = m.push_urls_problem(gh + [u] + fl)
    want(f"{u}: a problem naming it, and only it",
         p is not None and "not on GitHub" in p and u in p and not any(g in p for g in gh + fl))
    want(f"{u}: not on_github", not m.on_github(u))
p = m.push_urls_problem(bad)
want("all the bad ones named", p is not None and all(u in p for u in bad))
want("on_github(https://github.com/...)", all(m.on_github(u) for u in gh))
want("file:// isn't on_github (no token for it)", not any(m.on_github(u) for u in fl))
print("ALLOK" if not fails else "FAILED: " + " | ".join(fails))
EOF
)
if [[ $out = ALLOK ]]; then
    ok "3a push_urls_problem: GitHub and file:// accepted; local http, example.com, plain http, look-alikes, ssh, scp-style, a bare path refused and named"
else
    bad "3a push_urls_problem: $out"
fi

# ======================================================================================
# 2. token mode: never sends the token anywhere but https://github.com/
world
resolve
out=$(cd "$T" && EOS_PUSH_TOKEN=$TOKEN bash "$kit/sources/update.sh" token 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "EOS_MANIFEST_URL file://.* isn't on GitHub" <<<"$out" && ! grep -q 'TOKEN_CHECK=OK' <<<"$out"; then
    ok "2a token mode with the harness's file:// manifest: refused, EOS_MANIFEST_URL isn't on GitHub"
else
    bad "2a token mode with a file:// manifest: rc $rc"; show <<<"$out"
fi
# Servers: "evil" (a host that isn't GitHub), "gh" (every ExpressiveOS repo over dumb http) and
# "px" (the https/http proxy for update.py's urllib, so nothing leaves the machine)
mkdir -p "$A/gh-root/ExpressiveOS"
for r in "$T"/gh/ExpressiveOS/*.git; do
    git --git-dir="$r" update-server-info; ln -sfn "$r" "$A/gh-root/ExpressiveOS/$(basename "$r" .git)"
done
start_server evil "$A/evil-root" || exit 1
start_server gh "$A/gh-root" || exit 1
start_server px "$A/px-root" || exit 1
proxied() { https_proxy=http://127.0.0.1:$PORT_px HTTPS_PROXY=http://127.0.0.1:$PORT_px http_proxy=http://127.0.0.1:$PORT_px HTTP_PROXY=http://127.0.0.1:$PORT_px "$@"; }
# set_remote <fetch>: GitHub's manifest (and, with "tree", the tree's) takes its expressiveos remote from <fetch>
set_remote() {
    local w; w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$T/gh/ExpressiveOS/manifest.git" "$w"
    sed -i "s#<remote name=\"expressiveos\" fetch=\"[^\"]*\"#<remote name=\"expressiveos\" fetch=\"$1\"#" "$w/default.xml"
    git -C "$w" commit -qam "expressiveos remote: $1" && git -C "$w" push -q origin expressiveos
    moved=$(grep -c "<remote name=\"expressiveos\" fetch=\"$1\"" "$w/default.xml"); rm -rf "$w"
    git --git-dir="$T/gh/ExpressiveOS/manifest.git" update-server-info
    if [[ ${2:-} = tree ]]; then
        git -C "$top/.repo/manifests" fetch -q origin && git -C "$top/.repo/manifests" reset -q --hard origin/expressiveos
    fi
}
# 2b. the manifest's expressiveos remote pointed at "evil", EOS_MANIFEST_URL file://
set_remote "http://127.0.0.1:$PORT_evil/ExpressiveOS"
out=$(cd "$T" && proxied env EOS_PUSH_TOKEN=$TOKEN bash "$kit/sources/update.sh" token 2>&1); rc=$?
if [[ $moved = 1 && $rc != 0 && ! -s $A/evil.log && ! -s $A/px.log ]] && grep -q "EOS_MANIFEST_URL file://.* isn't on GitHub" <<<"$out" \
        && ! grep -q 'TOKEN_CHECK=OK' <<<"$out"; then
    ok "2b token mode, file:// manifest whose expressiveos remote is http://127.0.0.1:<port>: refused (not on GitHub), the server got nothing"
else
    bad "2b token mode with the expressiveos remote at the logging server: rc $rc, remote moved $moved"; show <<<"$out"; show < "$A/evil.log"
fi
# 2d. as it is for real: EOS_MANIFEST_URL is https://github.com/ExpressiveOS/manifest (read here
#     from the file:// one, and its no-login probe answered 401 as GitHub does), and a manifest
#     commit points the expressiveos remote at "evil": those repos are refused without a request;
#     the GitHub one is still asked (a CONNECT to github.com through px, refused there)
sed -i "s#^EOS_MANIFEST_URL=.*#EOS_MANIFEST_URL=https://github.com/ExpressiveOS/manifest#" "$kit/eos.conf"
: > "$A/evil.log"; : > "$A/px.log"
out=$(cd "$T" && proxied env EOS_PUSH_TOKEN=$TOKEN python3 -I - "$kit/sources/update.py" "$G/ExpressiveOS/manifest" "$W" <<'EOF' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("eos_update_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
GH = "https://github.com/ExpressiveOS/manifest"
real_fetch, real_rp = m.fetch_manifest, m.receive_pack
m.fetch_manifest = lambda work, sub, url, branch: real_fetch(work, sub, sys.argv[2] if url.rstrip("/") == GH else url, branch)
def rp(url, token):
    if url == GH and token is None:
        return 401, ""     # GitHub, asked without a login
    return real_rp(url, token)
m.receive_pack = rp
class A: work = sys.argv[3]
try:
    m.token_check(A)
    print("RC=0")
except SystemExit as e:
    print(f"RC={e.code!r}")
EOF
); rc=$?
nevil=$(grep -c "^http://127.0.0.1:$PORT_evil/ExpressiveOS/[A-Za-z_]*: not on GitHub" <<<"$out")
if grep -q '^TOKEN_CHECK=FAIL' <<<"$out" && grep -q '^RC=1$' <<<"$out" && [[ $nevil -ge 4 ]] \
        && grep -q "^http://127.0.0.1:$PORT_evil/ExpressiveOS/frameworks_base: not on GitHub" <<<"$out" \
        && [[ ! -s $A/evil.log ]] && grep -q '^CONNECT github.com:443 ' "$A/px.log" && ! grep -qv '^CONNECT github.com:443 ' "$A/px.log" \
        && no_token_in "$A/px.log"; then
    ok "2d token mode, GitHub EOS_MANIFEST_URL, expressiveos remote at http://127.0.0.1:<port>: TOKEN_CHECK=FAIL, $nevil repos 'not on GitHub', nothing sent there"
else
    bad "2d token mode with a GitHub manifest and the remote elsewhere ($nevil repos refused)"; show <<<"$out"; echo "    evil.log:"; show < "$A/evil.log"; echo "    px.log:"; show < "$A/px.log"
fi
# 2c. the reviewer's case: EOS_MANIFEST_URL over (dumb) http from "gh", the remote at "evil"
: > "$A/evil.log"; : > "$A/gh.log"; : > "$A/px.log"
sed -i "s#^EOS_MANIFEST_URL=.*#EOS_MANIFEST_URL=http://127.0.0.1:$PORT_gh/ExpressiveOS/manifest#" "$kit/eos.conf"
out=$(cd "$T" && proxied env EOS_PUSH_TOKEN=$TOKEN bash "$kit/sources/update.sh" token 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "EOS_MANIFEST_URL http://127.0.0.1:$PORT_gh/ExpressiveOS/manifest isn't on GitHub" <<<"$out" \
        && grep -q 'GET /ExpressiveOS/manifest/' "$A/gh.log" && [[ ! -s $A/evil.log && ! -s $A/px.log ]] \
        && no_token_in "$A/gh.log" && ! grep -q 'receive-pack' "$A/gh.log"; then
    ok "2c token mode, http:// EOS_MANIFEST_URL and remote elsewhere: manifest read, refused before any receive-pack request, no token anywhere"
else
    bad "2c token mode with an http manifest: rc $rc"; show <<<"$out"; echo "    gh.log:"; show < "$A/gh.log"; echo "    evil.log:"; show < "$A/evil.log"
fi
# 3c. plan, the token in its environment, with the forks at http://127.0.0.1:<port> ("gh" serves
#     them) and EOS_MANIFEST_URL back on file://: NOT_READY naming the forks' URLs, no plan.json,
#     and no login sent
sed -i "s#^EOS_MANIFEST_URL=.*#EOS_MANIFEST_URL=$G/ExpressiveOS/manifest#" "$kit/eos.conf"
set_remote "http://127.0.0.1:$PORT_gh/ExpressiveOS" tree
: > "$A/evil.log"; : > "$A/gh.log"; : > "$A/px.log"
out=$(proxied env EOS_PUSH_TOKEN=$TOKEN bash -c 'cd "$1" && bash "$2/sources/update.sh" plan 2026-11 "$3"' _ "$T" "$kit" "$top" 2>&1); rc=$?
rep=$(report_of "$out")
offline=$(grep "^not on GitHub (https://github.com/), the only place the push token goes: " <<<"$out")
if [[ $moved = 1 && $rc != 0 ]] && grep -q 'UPDATE_PLAN=NOT_READY (2 forks merged, 0 need a resolution, 1 problems)' <<<"$out" \
        && grep -q "http://127.0.0.1:$PORT_gh/ExpressiveOS/frameworks_base" <<<"$offline" \
        && grep -q "http://127.0.0.1:$PORT_gh/ExpressiveOS/vendor_lineage" <<<"$offline" && ! grep -q 'file://' <<<"$offline" \
        && [[ -n $rep && -f $rep && ! -e $W/updates/2026-11/plan.json ]] && grep -qF "$offline" "$rep" \
        && grep -q 'GET /ExpressiveOS/frameworks_base/' "$A/gh.log" && no_token_in "$A/gh.log" && ! grep -q 'receive-pack' "$A/gh.log" \
        && [[ ! -s $A/px.log ]]; then
    ok "3c plan with the forks at http://127.0.0.1:<port>: NOT_READY 'not on GitHub' naming both forks, no plan.json, no login sent"
else
    bad "3c plan with non-GitHub fork URLs: rc $rc"; show <<<"$out"; echo "    gh.log:"; show < "$A/gh.log" 5
fi
stop_servers

# ======================================================================================
# 4. plan.json's pins: a fork ahead of its pin (no LineageOS commits) moves to its tip without a
#    merge; push refuses ("plan again") when that branch isn't at the planned tip any more
world
resolve
S=$T/gh/ExpressiveOS/packages_apps_Settings.git
old=$(git --git-dir="$S" rev-parse expressiveos)
T1=$(commit_on "$S" expressiveos y "y" "Settings: a later fix")
out=$(plan 2>&1); rc=$?
pj=$W/updates/2026-11/plan.json
if [[ $rc = 0 ]] && grep -q 'UPDATE_PLAN=READY' <<<"$out" && [[ -f $pj ]] && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
pins = d["pins"]
assert len(pins) == 1, pins
p = pins[0]
assert p == {"path": "packages/apps/Settings", "url": p["url"], "branch": "expressiveos", "tip": sys.argv[2]}, p
assert p["url"].endswith("/ExpressiveOS/packages_apps_Settings"), p
assert "packages/apps/Settings" not in [f["path"] for f in d["forks"]]
assert sorted(f["path"] for f in d["forks"]) == ["frameworks/base", "vendor/lineage"], d["forks"]' "$pj" "$T1" 2>/dev/null; then
    ok "4a plan READY; plan.json pins packages/apps/Settings at its new tip (and only it; the merged forks aren't pins)"
else
    bad "4a plan with Settings ahead of its pin: rc $rc"; show <<<"$out"; [[ -f $pj ]] && python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pins"))' "$pj"
fi
fb0=$(tipof ExpressiveOS/frameworks_base) vl0=$(tipof ExpressiveOS/vendor_lineage) man0=$(tipof ExpressiveOS/manifest)
nothing_pushed() {
    [[ $(tipof ExpressiveOS/frameworks_base) = "$fb0" && $(tipof ExpressiveOS/vendor_lineage) = "$vl0" \
        && $(tipof ExpressiveOS/manifest) = "$man0" && -z $(tipof ExpressiveOS/manifest update/2026-11) ]] \
        && ! grep -q '"pushed"' "$pj"
}

# 3b. push refuses a plan whose fork URL isn't on GitHub (or file://), before asking it anything
start_server off "$A/off-root" || exit 1
cp "$pj" "$A/plan.json.saved"
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["forks"][0]["url"] = f"http://127.0.0.1:{sys.argv[2]}/ExpressiveOS/frameworks_base"
json.dump(d, open(sys.argv[1], "w"), indent=1)' "$pj" "$PORT_off"
out=$(cd "$T" && EOS_PUSH_TOKEN=$TOKEN bash "$kit/sources/update.sh" push 2026-11 "$top" 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "not on GitHub.*http://127.0.0.1:$PORT_off/ExpressiveOS/frameworks_base" <<<"$out" \
        && [[ ! -s $A/off.log ]] && nothing_pushed; then
    ok "3b push refuses a plan with a fork at http://127.0.0.1:<port>: 'not on GitHub', the server got nothing, nothing pushed"
else
    bad "3b push with a non-GitHub fork URL: rc $rc"; show <<<"$out"; show < "$A/off.log"
fi
cp "$A/plan.json.saved" "$pj"
stop_servers

# 4b. the pinned fork rewound to its old pin (a force-push after the plan)
git --git-dir="$S" update-ref refs/heads/expressiveos "$old"
out=$(push 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "packages/apps/Settings: .* expressiveos is at ${old:0:12}, the plan pins ${T1:0:12}: plan again" <<<"$out" \
        && nothing_pushed && [[ $(tipof ExpressiveOS/packages_apps_Settings) = "$old" ]]; then
    ok "4b pinned fork rewound to its old pin: push fails 'plan again', no fork pushed, no manifest branch"
else
    bad "4b push with the pinned fork rewound: rc $rc"; show <<<"$out"
    echo "    fb $(tipof ExpressiveOS/frameworks_base) (was $fb0), vl $(tipof ExpressiveOS/vendor_lineage) (was $vl0), update/2026-11: $(tipof ExpressiveOS/manifest update/2026-11)"
fi
# 4c. the pinned fork moved on past the planned tip: not the tip the manifest would pin either
git --git-dir="$S" update-ref refs/heads/expressiveos "$T1"
T2=$(commit_on "$S" expressiveos z "z" "Settings: after the plan")
out=$(push 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "packages/apps/Settings: .* is at ${T2:0:12}, the plan pins ${T1:0:12}: plan again" <<<"$out" && nothing_pushed; then
    ok "4c pinned fork moved on after the plan: push fails 'plan again', nothing pushed"
else
    bad "4c push with the pinned fork moved on: rc $rc"; show <<<"$out"
fi
# 4d. control: back at the planned tip, the same plan pushes, and the manifest pins Settings there
git --git-dir="$S" update-ref refs/heads/expressiveos "$T1"
out=$(push 2>&1); rc=$?
mb=$(tipof ExpressiveOS/manifest update/2026-11)
if [[ $rc = 0 ]] && grep -q 'UPDATE_PUSH=OK (2 forks pushed now' <<<"$out" && [[ -n $mb ]] \
        && git --git-dir="$T/gh/ExpressiveOS/manifest.git" show "$mb:default.xml" | grep 'name="packages_apps_Settings"' | grep -q "revision=\"$T1\"" \
        && [[ $(tipof ExpressiveOS/packages_apps_Settings) = "$T1" ]]; then
    ok "4d control: pinned fork back at the planned tip: push OK, the manifest's update/2026-11 pins Settings at it"
else
    bad "4d control push: rc $rc, update/2026-11 '${mb}'"; show <<<"$out"
fi

# ======================================================================================
# 5. a resolution kept for frameworks/base while frameworks/base's branch doesn't descend from
#    its pin: the real error only, no "isn't one of ExpressiveOS's forks" for it
world
resolve
FB=$T/gh/ExpressiveOS/frameworks_base.git
pinfb=$(tipof ExpressiveOS/frameworks_base)
w=$(mktemp -d "$T/w/x.XXXX"); git clone -q -b expressiveos "$FB" "$w"
git -C "$w" reset -q --hard HEAD~1 && printf 'rewritten\n' > "$w/R" && git -C "$w" add -A && git -C "$w" commit -qm "rewritten history" \
    && git -C "$w" push -q -f origin expressiveos; rm -rf "$w"
newfb=$(tipof ExpressiveOS/frameworks_base)
# control in the same plan: a resolution for a project that isn't a fork (external/foo follows LineageOS)
mkdir -p "$U/resolutions/external"; cp "$U/resolutions/frameworks/base.patch" "$U/resolutions/external/foo.patch"
out=$(plan 2>&1); rc=$?
rep=$(report_of "$out")
git --git-dir="$FB" merge-base --is-ancestor "$pinfb" "$newfb"; anc=$?
if [[ $anc = 1 && $rc != 0 && -f $U/resolutions/frameworks/base.patch ]] && grep -q 'UPDATE_PLAN=NOT_READY' <<<"$out" && [[ -n $rep && -f $rep ]] \
        && grep -q "^frameworks/base: its expressiveos branch (${newfb:0:12}) doesn't descend from the manifest's ${pinfb:0:12}" "$rep" \
        && ! grep -q "frameworks/base isn't one of ExpressiveOS's forks" "$rep" && ! grep -q "frameworks/base isn't one of" <<<"$out"; then
    ok "5a frameworks/base's branch rewritten, its resolution kept: the report has the real error, no 'isn't one of ExpressiveOS's forks' for it"
else
    bad "5a resolution for a fork that failed planning: rc $rc, ancestor rc $anc, report '$rep'"; show <<<"$out" 25
fi
if [[ -n $rep && -f $rep ]] && grep -q "^resolutions/external/foo.patch: external/foo isn't one of ExpressiveOS's forks" "$rep"; then
    ok "5b control: a resolution for external/foo (not a fork) is still reported as not one of ExpressiveOS's forks"
else
    bad "5b control: no 'isn't one of ExpressiveOS's forks' for resolutions/external/foo.patch"; [[ -f $rep ]] && grep -i "fork\|not ready" "$rep" | show
fi

# ======================================================================================
# 6. LineageOS moves development to another repo whose history doesn't contain our pin
world
resolve
git init -q --bare "$T/gh/LineageOS/android_development_new.git"
w=$(mktemp -d "$T/w/n.XXXX"); git -C "$w" init -q -b lineage-24.0; echo other > "$w/dev.txt"; git -C "$w" add -A; git -C "$w" commit -qm "fresh"
git -C "$w" push -q "$T/gh/LineageOS/android_development_new.git" lineage-24.0; rm -rf "$w"
w=$(mktemp -d "$T/w/l.XXXX"); git clone -q -b lineage-24.0 "$T/gh/LineageOS/android.git" "$w"
sed -i 's#name="LineageOS/android_development"#name="LineageOS/android_development_new"#' "$w/snippets/lineage.xml"
git -C "$w" commit -qam "development: new repo"; git -C "$w" push -q origin lineage-24.0
C1b=$(git -C "$w" rev-parse HEAD); rm -rf "$w"
echo "LINEAGE_MANIFEST=$C1b" > "$U/update.conf"
devpin=$(git -C "$top/.repo/manifests" show HEAD:default.xml | grep 'path="development"' | grep -o 'revision="[0-9a-f]*"' | grep -o '[0-9a-f]\{40\}')
mkdir -p "$W/reports"; ls "$W/reports" > "$A/reports.before" 2>/dev/null
out=$(plan 2>&1); rc=$?
rep=$(report_of "$out")
deverr="^development: LineageOS/android_development_new lineage-24.0 doesn't contain our commit ${devpin:0:12}"
if [[ $rc != 0 && -n $devpin ]] && ! grep -qE 'Traceback|KeyError' <<<"$out" && grep -q "UPDATE_PLAN=NOT_READY" <<<"$out" \
        && grep -q "$deverr" <<<"$out" && ! grep -q "doesn't handle" <<<"$out"; then
    ok "6a development moved to an unrelated repo: no traceback/KeyError, NOT_READY with development's own error"
else
    bad "6a plan with development moved to an unrelated repo: rc $rc, pin '$devpin'"; show <<<"$out" 25
fi
if [[ -n $rep && -f $rep ]] && ! grep -qxF "$(basename "$rep")" "$A/reports.before" && grep -q "$deverr" "$rep" \
        && grep -q "UPDATE_PLAN=NOT_READY" "$rep" && [[ ! -e $W/updates/2026-11/plan.json ]]; then
    ok "6b report file written with development's error and UPDATE_PLAN=NOT_READY; no plan.json"
else
    bad "6b report after development's move: '$rep'"; ls "$W/reports" "$W/updates/2026-11" 2>&1 | show
fi

# 6c. any unexpected exception in plan still ends with UPDATE_PLAN=NOT_READY (and a nonzero exit)
out=$(python3 -I - "$UPY" "$top" "$W" <<'EOF' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("eos_update_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def boom(a):
    raise KeyError("an-unexpected-key")
m.plan = boom
sys.argv = ["update.py", "plan", "2026-11", "--top", sys.argv[2], "--manifest", sys.argv[2] + "/.repo/manifests/default.xml",
            "--work", sys.argv[3]]
try:
    m.main()
    print("RC=0")
except SystemExit as e:
    print(f"RC={e.code!r}")
EOF
)
if grep -q '^UPDATE_PLAN=NOT_READY' <<<"$out" && grep -q "KeyError: 'an-unexpected-key'" <<<"$out" && ! grep -qE '^RC=(0|None)$' <<<"$out"; then
    ok "6c an unexpected exception in plan prints the traceback, UPDATE_PLAN=NOT_READY and exits nonzero"
else
    bad "6c unexpected exception in plan"; show <<<"$out"
fi

stop_servers
rm -rf "$WD"
echo "== $pass passed, $failn failed"
[[ $failn = 0 ]]
