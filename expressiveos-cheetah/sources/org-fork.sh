#!/usr/bin/env bash
# Copy ExpressiveOS's sources into its own GitHub organization (Daryl, 2026-10-28: fully
# independent of Evolution X, whose changes and rewrites must stop reaching ExpressiveOS):
#   - a fork of every Evolution X repo the pins name (pins/manifest.xml and
#     local_manifests/cheetah.xml: Evolution-X, Evolution-X-Devices and BtHelper's
#     TheParasiteProject), each with tag eos-1.0-base and branch expressiveos at its pinned
#     commit, the source of the 1.0 builds. expressiveos becomes the default branch; the
#     kit's commits go on top of it;
#   - blobs, an ordinary repo (a fork can't take Git LFS files) holding the Git LFS files of
#     the pinned vendor_gms and vendor_google_cheetah, which Evolution X keeps on gitea.com
#     and a personal gitlab.com account.
# GitHub makes the forks on its side, so only the LFS files (about 2 GiB) are downloaded and
# uploaded here. Runs where gh is logged in as an owner of the organization (Daryl's Mac), with
# git, git-lfs and python3; bash 3.2 is enough. Run it again any time: what's done is checked,
# not redone, and anything that doesn't match stops it.
#
#   org-fork.sh [org]     # default ExpressiveOS
#
# The last line is ORG_FORK=OK or ORG_FORK=FAIL.
set -uo pipefail
done=0
trap 'rc=$?; [[ $done = 1 ]] || { echo "ORG_FORK=FAIL"; exit $(( rc ? rc : 1 )); }' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
kit=$(cd -- "$(dirname -- "$0")/.." && pwd) || fail "can't find the kit"
org=${1:-ExpressiveOS}
[[ $org =~ ^[A-Za-z0-9-]+$ ]] || fail "not an organization name: $org"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

for t in gh git git-lfs python3; do command -v "$t" >/dev/null || fail "$t isn't installed"; done
gh auth status >/dev/null 2>&1 || fail "gh isn't logged in (gh auth login)"
me=$(gh api user --jq .login) || fail "gh api user failed"
role=$(gh api "orgs/$org/memberships/$me" --jq .role 2>/dev/null) || role=
[[ $role = admin ]] || fail "$me isn't an owner of $org (role: ${role:-none})"
# git and git-lfs talk to GitHub with gh's login, whatever git's own config says
gitgh() { git -c credential.https://github.com.helper= -c 'credential.https://github.com.helper=!gh auth git-credential' "$@"; }

# "<owner/repo> <pinned commit> <suffix>" for each project hosted on GitHub outside LineageOS.
# A repo pinned twice (evolution/OTA on cnb, evolution/OTA-VANILLA on cnb-vanilla) gets a
# tag and a branch for each: <suffix> is - for its first pin, else the other's branch less
# the first's ("vanilla")
list=$(python3 -I - "$kit/pins/manifest.xml" "$kit/local_manifests/cheetah.xml" <<'EOF'
import re, sys, xml.etree.ElementTree as ET
seen, pins = {}, {}
for f in sys.argv[1:]:
    r = ET.parse(f).getroot()
    fetch = {e.get("name"): e.get("fetch") for e in r.iter("remote")}
    d = r.find("default")
    for p in r.iter("project"):
        url = (fetch[p.get("remote") or d.get("remote")] or "").rstrip("/") + "/" + p.get("name")
        m = re.fullmatch(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)", url)
        if not m or m.group(1) == "LineageOS":
            continue
        rev = p.get("revision") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            sys.exit(f"{url} isn't pinned to a commit: {rev!r}")
        name = m.group(2)
        if seen.get(name, url) != url:
            sys.exit(f"two repos named {name}: {seen[name]} and {url}")
        seen[name] = url
        up = re.sub(r"^refs/heads/", "", p.get("upstream") or "")
        pins.setdefault(f"{m.group(1)}/{name}", []).append((up, rev, p.get("path")))
for key, pl in pins.items():
    first = pl[0][0]
    sfxs = {"-": pl[0][1]}
    for up, rev, path in pl[1:]:
        sfx = up[len(first) + 1:] if up.startswith(first + "-") else up
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", sfx) or sfxs.get(sfx, rev) != rev:
            sys.exit(f"{key}: no tag or branch name for its pin of {path} ({up!r})")
        sfxs[sfx] = rev
    for sfx, rev in sfxs.items():
        print(f"{key} {rev} {sfx}")
EOF
) || fail "can't read the pins"
n=$(printf '%s\n' "$list" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
echo "== $n repos to fork into $org ($(printf '%s\n' "$list" | wc -l | tr -d ' ') pinned commits)"

api_retry() {   # api_retry <what> <gh api args>...: a new fork answers 404/409/422 until GitHub has copied it
    local what=$1 i out
    shift
    for i in $(seq 1 20); do
        out=$(gh api "$@" 2>&1) && return 0
        [[ $out == *"HTTP 404"* || $out == *"HTTP 409"* || $out == *"HTTP 422"* ]] || break
        sleep 15
    done
    fail "$what: $out"
}

ensure_fork() {   # ensure_fork <owner/repo>: $org/<repo> is a fork of it
    local src=$1 name=${1#*/} out
    if out=$(gh api "repos/$org/$name" --jq '.parent.full_name // "-"' 2>&1); then
        [[ "$(lower "$out")" = "$(lower "$src")" ]] || fail "$org/$name is there, but forked from $out, not $src"
        echo "fork there: $org/$name"
        return
    fi
    [[ $out == *"HTTP 404"* ]] || fail "gh api repos/$org/$name: $out"
    out=$(cd / && gh repo fork "$src" --org "$org" --clone=false --remote=false 2>&1) \
        || fail "gh repo fork $src --org $org: $out"
    sleep 2   # GitHub's limits on creating content
    # GitHub answers with an existing fork of the same network instead, under its own name
    api_retry "$org/$name after gh repo fork ($out)" "repos/$org/$name" --silent
    out=$(gh api "repos/$org/$name" --jq '.parent.full_name // "-"') || fail "gh api repos/$org/$name failed"
    [[ "$(lower "$out")" = "$(lower "$src")" ]] || fail "$org/$name was forked from $out, not $src"
    echo "forked: $src -> $org/$name"
}

ensure_ref() {   # ensure_ref <repo> <tags/x|heads/x> <commit>: the ref is there at the commit (a branch may have commits on top)
    local repo=$1 ref=$2 pin=$3 cur st
    if cur=$(gh api "repos/$repo/git/ref/$ref" --jq .object.sha 2>/dev/null) && [[ -n $cur ]]; then
        [[ $cur = "$pin" ]] && { echo "  $ref: ${pin:0:12}"; return; }
        [[ $ref = heads/* ]] || fail "$repo's $ref is $cur, not $pin"
        st=$(gh api "repos/$repo/compare/$pin...$cur" --jq .status 2>/dev/null) || st=
        [[ $st = ahead ]] || fail "$repo's $ref ($cur) isn't $pin or a commit on top of it (${st:-no comparison})"
        echo "  $ref: ${cur:0:12}, on top of ${pin:0:12}"
        return
    fi
    api_retry "$repo: create $ref at $pin" -X POST "repos/$repo/git/refs" -f "ref=refs/$ref" -f "sha=$pin" --silent
    echo "  $ref: ${pin:0:12} (made)"
}

while read -r src pin sfx; do
    name=${src#*/}
    s=${sfx#-}; s=${s:+-$s}
    ensure_fork "$src"
    # The commit itself, which GitHub may hold for the fork only by way of Evolution X's network
    api_retry "$org/$name: commit $pin" "repos/$org/$name/git/commits/$pin" --silent
    ensure_ref "$org/$name" "tags/eos-1.0-base$s" "$pin"
    ensure_ref "$org/$name" "heads/expressiveos$s" "$pin"
    [[ -z $s ]] || continue
    if [[ "$(gh api "repos/$org/$name" --jq .default_branch)" != expressiveos ]]; then
        gh api -X PATCH "repos/$org/$name" -f default_branch=expressiveos --silent || fail "$org/$name: can't make expressiveos the default branch"
        echo "  default branch: expressiveos"
    fi
done <<<"$list"

echo "== Git LFS files into $org/blobs"
work=$(mktemp -d "${TMPDIR:-/tmp}/org-fork.XXXXXX") || fail "mktemp failed"
trap 'rc=$?; rm -rf -- "$work"; [[ $done = 1 ]] || { echo "ORG_FORK=FAIL"; exit $(( rc ? rc : 1 )); }' EXIT
if ! gh api "repos/$org/blobs" --silent 2>/dev/null; then
    gh repo create "$org/blobs" --public \
        --description "Git LFS files of ExpressiveOS's vendor_gms and vendor_google_cheetah" >/dev/null \
        || fail "gh repo create $org/blobs failed"
    echo "made: $org/blobs"
fi
blobs=https://github.com/$org/blobs.git
lfs=()
while read -r src pin sfx; do
    name=${src#*/}
    [[ $sfx = - ]] || fail "$src has more than one pin; only one pin's LFS files are copied"
    d=$work/$name
    git init -q "$d" || fail "git init failed"
    git -C "$d" fetch -q --depth=1 --no-tags "https://github.com/$src" "$pin" || fail "can't fetch $src $pin"
    git -C "$d" cat-file -e "$pin:.lfsconfig" 2>/dev/null || fail "$src has no .lfsconfig at $pin"
    # Pointers only, then the files themselves from where Evolution X keeps them (.lfsconfig)
    GIT_LFS_SKIP_SMUDGE=1 git -C "$d" -c advice.detachedHead=false checkout -q "$pin" || fail "$src: checkout failed"
    git -C "$d" remote add origin "https://github.com/$src" || fail "git remote add failed"
    echo "-- $src at ${pin:0:12} (from $(git -C "$d" config -f .lfsconfig --get lfs.url))"
    git -C "$d" lfs fetch origin "$pin" || fail "$src: git lfs fetch failed"
    oids=$(git -C "$d" lfs ls-files -l "$pin" | awk '{print $1}')
    [[ -n $oids ]] || fail "$src: no Git LFS files at $pin"
    for o in $oids; do
        f=$d/.git/lfs/objects/${o:0:2}/${o:2:2}/$o
        [[ -f $f && "$(shasum -a 256 "$f" 2>/dev/null || sha256sum "$f")" == "$o "* ]] || fail "$src: LFS object $o missing or damaged after the fetch"
    done
    # lfs.url and lfs.pushurl from git -c outrank the project's .lfsconfig
    gitgh -C "$d" -c "lfs.url=$blobs/info/lfs" -c "lfs.pushurl=$blobs/info/lfs" \
        lfs push --object-id "$blobs" $oids || fail "$src: git lfs push to $org/blobs failed"
    echo "uploaded (or already there): $(printf '%s\n' $oids | wc -l | tr -d ' ') files"
    lfs+=("$name $pin")
done <<<"$(printf '%s\n' "$list" | grep -E '/(vendor_gms|vendor_google_cheetah) ')"
((${#lfs[@]} == 2)) || fail "expected the LFS files of vendor_gms and vendor_google_cheetah, got ${#lfs[@]} repos"

# A record in blobs/main of what it holds: each project's LFS pointer files at its pin, so
# GitHub keeps the files referenced
if [[ -z "$(gitgh ls-remote "$blobs" refs/heads/main)" ]]; then
    b=$work/blobs
    git init -q "$b" || fail "git init failed"
    export GIT_INDEX_FILE=$b/.git/record-index
    msg="ExpressiveOS's Git LFS files"$'\n'
    for e in "${lfs[@]}"; do
        set -- $e
        # "<mode> blob <id>\t<path>" of each pointer file, copied under <project>/
        git -C "$work/$1" lfs ls-files -n "$2" > "$work/paths" || fail "$1: git lfs ls-files failed"
        while IFS= read -r f; do
            git -C "$work/$1" ls-tree "$2" -- "$f"
        done < "$work/paths" > "$work/entries"
        [[ "$(wc -l < "$work/entries")" -eq "$(wc -l < "$work/paths")" ]] || fail "$1: can't list its pointer files"
        while IFS=$'\t' read -r meta f; do
            set -- $e $meta
            git -C "$work/$1" cat-file blob "$5" | git -C "$b" hash-object -w --stdin >/dev/null \
                && git -C "$b" update-index --add --cacheinfo "$3,$5,$1/$f" || fail "$1: can't record $f"
        done < "$work/entries"
        set -- $e
        msg+=$'\n'"$1: $(wc -l < "$work/paths" | tr -d ' ') files, from https://github.com/$org/$1 at $2 (tag eos-1.0-base)"
    done
    a=$(printf '* filter=lfs diff=lfs merge=lfs -text\n.gitattributes !filter !diff !merge text\n' | git -C "$b" hash-object -w --stdin) \
        && git -C "$b" update-index --add --cacheinfo "100644,$a,.gitattributes" || fail "can't write .gitattributes"
    tree=$(git -C "$b" write-tree) || fail "write-tree failed"
    email=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"') || fail "gh api user failed"
    c=$(git -C "$b" -c user.name="$me" -c user.email="$email" commit-tree "$tree" -m "$msg") || fail "commit-tree failed"
    unset GIT_INDEX_FILE
    # The files are uploaded already; git-lfs's pre-push hook isn't installed in this clone
    gitgh -C "$b" push -q "$blobs" "$c:refs/heads/main" || fail "can't push $org/blobs main"
    echo "blobs main: $c"
else
    echo "blobs main: there"
fi

echo "OK: $n forks in $org, each with tag eos-1.0-base and default branch expressiveos at its pin (a second pin: eos-1.0-base-<suffix> and expressiveos-<suffix>); Git LFS files in $org/blobs"
done=1
echo "ORG_FORK=OK"
