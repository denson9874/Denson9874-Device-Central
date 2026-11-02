#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/name" in messages is meant literally
# Retire Evolution X and DerpFest on the build server (Daryl, 2026-11-02: the server now builds
# ExpressiveOS only). Reversible: nothing is deleted.
#
# `stop` moves the scripts in ~ that build or publish Evolution X or DerpFest into
# ~/retired/evo-derp-<UTC time>/ and leaves one stub in their place, ~/p11-routine.sh, whose
# only output is a ROUTINE_RESULT=RETIRED line. The Mac's weekly evox-parity-<device> tasks
# start `~/p11-routine.sh <device>` over SSH and wait for a ROUTINE_RESULT= line, so a task that
# still fires ends at its first check instead of syncing, building and publishing. It also
# writes the marker ~/retired/EVO_DERP_RETIRED, which makes the runner refuse its Evolution X
# build actions (and routine-install, which would put the scripts back).
# `undo` puts every moved script back, removes the stub and the marker. A script that
# mentions ExpressiveOS (a hand-made release chain that starts eos-images.sh, say) is never
# moved: stop lists it as kept.
#
# `keep` copies out of the Evolution X and DerpFest trees what outlives them, before any
# cleanup deletes those trees (nothing is moved or deleted):
#  - the Pixel 11 blob repos ExpressiveOS builds from: prepare.sh copies
#    ~/evolution/vendor/google/<phone> into ~/expressiveos the first time a Pixel 11 is built
#    there, so every one of kodiak, grizzly, cubs and yogi that ExpressiveOS doesn't have yet
#    is copied the same way now (git clone --no-hardlinks, checked out detached at the server
#    repo's HEAD, remote named server), and one it has gets the server repo's refs fetched;
#  - Evolution X's and DerpFest's private signing keys, copied (mode 600, folder 700) into
#    ~/retired/keys-<UTC time>/{evolution,derpfest}: the only way to sign an update that their
#    phones would install. It prints file counts and the platform certificate's SHA-256 only;
#  - work that exists only on this server, into ~/retired/saved-<UTC time>/<tree>/<project>/:
#    every git repo in the two trees (repo's projects, the kernel's, and hand-made repos under
#    device/, vendor/ and packages/) with commits no remote has gets a git bundle, uncommitted
#    changes a diff, untracked files a tarball (up to 50 MB each); INDEX.tsv lists them. A
#    repo with more than 300 such commits is listed, not bundled (a pinned revision, not hand
#    work). The Pixel 11 blob repos are skipped: the first step copied them whole;
#  - records, into ~/retired/records-<UTC time>/ (folder 700): repo's pinned manifests of both
#    trees and of the kernel trees (the source record for the published builds' kernels), the
#    DerpFest husky kernel manifest, every ~/releases folder that isn't ExpressiveOS's (the
#    last-release records and personal builds; refused over 2 GiB), the installed Evolution X
#    and DerpFest kits with their server-only notes, the feed clones, the backup folders, and
#    a copy of every ~/*.sh and ~/*.py.
# It writes ~/retired/KEPT, which delete reads. It holds ~/.expressiveos.lock, so it waits for
# no build: it refuses while one runs.
#
# `delete <part>...` (permanent; Daryl chose it on 2026-11-02) deletes, in this order whatever
# order they're named in:
#   out        ~/evolution/out and ~/evolution/out-kernel (Evolution X's build output)
#   evolution  the rest of ~/evolution
#   derpfest   ~/derpfest
#   research   ~/android-dt/ref/reeky, ~/android-dt/reeky, ~/android-dt/p11-diff{,-yogi}
#   leftovers  ~/espada, ~/fw-cp3a, ~/husky-audit, the old kits, feed clones and backup
#              folders keep copied, the ~/releases folders that aren't ExpressiveOS's (only
#              those keep copied), the Evolution X and DerpFest logs and state files by exact
#              name (never ~/.evolution-tree.lock, which ExpressiveOS's builds take), and their
#              zips in /tmp
# Every part needs stop and keep done, takes both build locks without waiting, and refuses
# while anything builds (soong_ui, ninja, repo sync, an ExpressiveOS script or eos-* session).
# evolution checks first that ExpressiveOS's copies of the Pixel 11 blob repos have the server
# repos' HEAD and branches, that the keys copy matches, and that nothing in ~/expressiveos
# borrows objects from or links into the tree; derpfest checks its keys and the same. It
# deletes exact paths only, never through a link, never across file systems.
#
# `check` (read-only; names, commits and counts only, never file contents or secrets) answers
# what has to be true before ~/evolution and ~/derpfest are deleted: tools in ~/bin and the
# runner's PATH that resolve into them, git alternates and symlinks in the ExpressiveOS tree
# that point into them, the global git config's keys, the Pixel 11 blob repos (ExpressiveOS's
# copy against the server's, and commits the server's has that no remote has), the two feed
# clones' unpushed commits, schedules, shell startup lines, the scripts in ~ that exist only
# on the server, ~/.ssh and rclone's remote names, and the private keys and their copies.
#
# ExpressiveOS runs none of these scripts (its kit is ~/expressiveos-cheetah). Only delete
# touches ~/evolution, ~/derpfest, ~/releases or ~/evolution_ota, and nothing touches the
# ExpressiveOS tree's own files, ~/.evolution-tree.lock, the SourceForge key, rclone or ccache.
#
#   evo-retire.sh list    # what stop would move, what runs, the marker; changes nothing
#   evo-retire.sh stop
#   evo-retire.sh undo
#   evo-retire.sh keep
#   evo-retire.sh check   # read-only: what ExpressiveOS still reaches in ~/evolution or ~/derpfest
#   evo-retire.sh delete out evolution derpfest research leftovers
#
# The last line is RETIRE=LISTED, CHECKED, STOPPED, ALREADY (stop when already retired),
# UNDONE, KEPT, DELETED or FAIL.
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "RETIRE=FAIL"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

mode=${1:-list}
shift || true
usage="usage: evo-retire.sh list|check|stop|undo|keep, or delete out|evolution|derpfest|research|leftovers..."
[[ $mode =~ ^(list|check|stop|undo|keep|delete)$ ]] || fail "$usage"
parts=()
if [[ $mode = delete ]]; then
    [[ $# -ge 1 ]] || fail "$usage"
    for p in "$@"; do [[ $p =~ ^(out|evolution|derpfest|research|leftovers)$ ]] || fail "unknown part $p; $usage"; parts+=("$p"); done
else
    [[ $# -eq 0 ]] || fail "$usage"
fi
cd ~ || fail "no home folder"
home=$(pwd -P)
ret=$home/retired
marker=$ret/EVO_DERP_RETIRED
kept=$ret/KEPT
stubtag='# EVO-RETIRE STUB'
p11=(kodiak grizzly cubs yogi)

# What builds or publishes Evolution X (the weekly routine and everything it runs, the hand-run
# build and pack scripts) and DerpFest. Exact names; the dated release chains are listed by
# name too, from ~ itself, below.
evo=(
    p11-routine.sh p11-ota.sh p11-upload.sh release-chain.sh release-cleanup.sh release-checks.sh
    kodiak-build.sh kodiak-test-build.sh kodiak-images.sh kodiak-release-images.sh kodiak-imgzip.sh
    kodiak-release-pack.sh kodiak-personal-pack.sh kodiak-ota-personal.sh kodiak-magisk-patch.sh
    kodiak-vbmeta.sh grizzly-images.sh grizzly-pack.sh cubs-images.sh cubs-pack.sh yogi-images.sh
    yogi-pack.sh cheetah-images.sh cheetah-pack.sh husky-images.sh husky-release-pack.sh
    husky-sync-rebuild.sh audit-test-chain.sh
)
derp=(derp-build.sh derp-husky-build.sh derp-sync.sh derp-ota.sh)
for f in release-chain-[0-9]*.sh; do [[ -f $f ]] && evo+=("$f"); done
names=("${evo[@]}" "${derp[@]}")

mentions_eos() { grep -qiE 'expressiveos|eos-(images|pack|verify)' -- "$1" 2>/dev/null; }
running() {   # the routines, release chains and Evo/DerpFest builds running now (pid and command)
    pgrep -a -u "$(id -u)" -f '(^|/)(p11-routine|p11-ota|p11-upload|release-chain[-0-9]*|release-cleanup|derp-(husky-)?build|derp-sync|derp-ota|kodiak-(test-)?build|husky-sync-rebuild|[a-z]+-(images|pack|release-pack|release-images))\.sh' \
        | grep -v -e 'evo-retire\.sh' -e expressiveos | cut -c1-160 || true
}
busy_locks() {   # Evolution X's publish locks held now: a routine still uploading after its build
    local l
    for l in "$home"/.evolution-publish-*.lock "$home"/.evolution-ota.lock; do
        [[ -e $l ]] || continue
        flock -n "$l" true 2>/dev/null || echo "${l#"$home"/}"
    done
}
staged() {   # Evolution X releases staged but never published (p11-routine.sh --publish-staged)
    find "$home/releases" -mindepth 2 -maxdepth 2 -type d -name 'staged-*' -not -path '*/expressiveos-*' 2>/dev/null | sed "s#^$home/##" || true
}
report() {
    echo "== marker"
    if [[ -f $marker ]]; then cat "$marker"; else echo "none: Evolution X and DerpFest are not retired"; fi
    echo "== the scripts, in ~"
    local n
    for n in "${names[@]}"; do
        if [[ -L $n ]]; then echo "symlink   ~/$n -> $(readlink "$n")"
        elif [[ -f $n ]] && grep -q "^$stubtag" "$n" 2>/dev/null; then echo "stub      ~/$n"
        elif [[ -f $n ]] && mentions_eos "$n"; then echo "keep      ~/$n  $(date -r "$n" '+%F %T') (mentions ExpressiveOS: stop leaves it)"
        elif [[ -f $n ]]; then echo "present   ~/$n  $(date -r "$n" '+%F %T')"
        fi
    done
    echo "== running now"; local r; r=$(running); echo "${r:-nothing}"
    echo "== Evolution X publish locks held"; r=$(busy_locks); echo "${r:-none}"
    echo "== Evolution X releases staged, never published"; r=$(staged); echo "${r:-none}"
    echo "== the Mac tasks' last routine logs (~/routine-logs/*-latest.out)"
    ls -l --time-style='+%F %T' "$home"/routine-logs/*-latest.out 2>/dev/null | awk '{print $6, $7, $8}' || true
    echo "== crontab"; crontab -l 2>/dev/null | grep -v '^#' | grep . || echo none
    echo "== keep (what's been copied out of the old trees)"
    if [[ -f $kept ]]; then cat "$kept"; else echo "not run"; fi
}
kv() { sed -n "s/^$1=//p" "$kept" 2>/dev/null | tail -n 1; }

mask() { sed -E 's#(://)[^/@ ]*@#\1***@#g'; }   # credentials in a URL
into_old() {   # into_old <path>: does it resolve into ~/evolution or ~/derpfest?
    local r; r=$(readlink -f -- "$1" 2>/dev/null) || return 1
    [[ $r == "$home/evolution" || $r == "$home/evolution/"* || $r == "$home/derpfest" || $r == "$home/derpfest/"* ]]
}
check() {
    local f l d x n eos=$home/expressiveos
    echo "== ~/bin and ~/android-dt/bin: links that resolve into ~/evolution or ~/derpfest (BAD) or elsewhere"
    for f in "$home"/bin/* "$home"/android-dt/bin/*; do
        [[ -L $f ]] || continue
        if into_old "$f"; then echo "BAD   ${f#"$home"/} -> $(readlink "$f")"; else echo "ok    ${f#"$home"/} -> $(readlink "$f")"; fi
    done
    echo "== the tools ExpressiveOS's scripts run, as PATH=~/bin:\$PATH finds them"
    for x in repo git git-lfs lz4 cpio rclone python3 openssl zip unzip simg2img img2simg lpmake avbtool tmux flock ccache; do
        f=$(PATH=$home/bin:$PATH command -v "$x" 2>/dev/null) || { echo "none  $x"; continue; }
        if into_old "$f"; then echo "BAD   $x: $f -> $(readlink -f "$f")"; else echo "ok    $x: $f"; fi
    done
    echo "== the runner's PATH and .env: entries in ~/evolution, ~/derpfest or ~/android-dt (names only)"
    if [[ -f $home/actions-runner/.path ]]; then
        tr ':' '\n' < "$home/actions-runner/.path" | grep -nE "/(evolution|derpfest|android-dt)(/|$)" || echo "PATH: none"
    else echo "no ~/actions-runner/.path"; fi
    [[ -f $home/actions-runner/.env ]] && { grep -E "(evolution|derpfest|android-dt)" "$home/actions-runner/.env" | cut -d= -f1 | sed 's/^/.env variable: /' || echo ".env: none"; }
    echo "== git alternates in the ExpressiveOS tree (its .repo, kernel .repo, standalone repos)"
    n=0
    while IFS= read -r f; do
        n=$((n + 1))
        while IFS= read -r l; do
            if into_old "$l"; then echo "BAD   ${f#"$home"/}: $l"; else echo "ok    ${f#"$home"/}: $l"; fi
        done < "$f"
    done < <(find "$eos/.repo" "$eos"/out-kernel/*/*/.repo "$eos"/vendor/google/*/.git -xdev -path '*/objects/info/alternates' -size +0 2>/dev/null)
    echo "($n alternates files)"
    echo "-- repo's reference setting"
    for f in "$eos/.repo/manifests.git/config" "$eos"/out-kernel/*/*/.repo/manifests.git/config; do
        [[ -f $f ]] && { grep -nE 'reference|dissociate' "$f" | mask | sed "s#^#${f#"$home"/}: #" || echo "${f#"$home"/}: none"; }
    done
    echo "== symlinks in the ExpressiveOS tree (not out/) that resolve into ~/evolution or ~/derpfest"
    n=0
    while IFS= read -r f; do
        into_old "$f" || continue
        n=$((n + 1)); [[ $n -le 40 ]] && echo "BAD   ${f#"$home"/} -> $(readlink "$f")"
    done < <(nice -n 19 find "$eos" -xdev -path "$eos/out" -prune -o -type l \( -lname '*evolution*' -o -lname '*derpfest*' \) -print 2>/dev/null)
    echo "($n found)"
    echo "== the global git config: key names (URL credentials masked)"
    git config --global --name-only --list 2>/dev/null | mask | sort | uniq -c | sed 's/^ *//' || echo "none"
    git config --global --get-regexp '^(include|includeif)\..*' 2>/dev/null | mask || true
    ls -l "$home/.git-credentials" 2>/dev/null | awk '{print "present: ~/.git-credentials,", $5, "bytes"}' || true
    echo "== the Pixel 11 blob repos: ExpressiveOS's copy against the server's (~/evolution)"
    for d in kodiak grizzly cubs yogi; do
        local src=$home/evolution/vendor/google/$d dst=$eos/vendor/google/$d sh=none eh=none
        [[ -d $src/.git ]] && sh=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo "no commit")
        [[ -d $dst/.git ]] && eh=$(git -C "$dst" rev-parse --short HEAD 2>/dev/null || echo "no commit")
        echo "$d: ExpressiveOS $eh, server $sh"
        if [[ -d $src/.git ]]; then
            echo "   server remotes: $(git -C "$src" remote -v 2>/dev/null | awk '$3=="(fetch)"{print $1"="$2}' | mask | tr '\n' ' ')"
            echo "   server branches: $(git -C "$src" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | tr '\n' ' ')"
            echo "   commits on the server's branches that no remote-tracking ref has: $(git -C "$src" rev-list --branches --not --remotes 2>/dev/null | wc -l)"
            [[ -d $dst/.git && $sh != none ]] && { git -C "$dst" cat-file -e "$(git -C "$src" rev-parse HEAD)^{commit}" 2>/dev/null && echo "   ExpressiveOS's copy has the server's HEAD" || echo "   ExpressiveOS's copy LACKS the server's HEAD"; }
        fi
    done
    echo "== the feed clones: unpushed commits, uncommitted files"
    for d in "$home/evolution_ota" "$home/derpfest_ota" "$home/expressiveos_ota"; do
        [[ -d $d/.git ]] || continue
        echo "${d#"$home"/}: branch $(git -C "$d" rev-parse --abbrev-ref HEAD), remote $(git -C "$d" remote get-url origin 2>/dev/null | mask), ahead $(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?'), changed $(git -C "$d" status --porcelain 2>/dev/null | wc -l)"
    done
    echo "== schedules"
    crontab -l 2>/dev/null | grep -v '^#' | grep . || echo "crontab: none"
    systemctl --user list-timers --all --no-pager 2>/dev/null | head -12 || echo "systemd user timers: unavailable"
    echo "== shell startup files: lines naming ~/evolution, ~/derpfest or ~/android-dt (line numbers and the path only)"
    for f in .profile .bashrc .bash_aliases .bash_profile; do
        [[ -f $f ]] && grep -noE "(~|\\\$HOME|$home)/(evolution|derpfest|android-dt)[A-Za-z0-9_./-]*" "$f" | sed "s#^#~/$f:#" || true
    done
    echo "== scripts in ~ (date, then what they mention: E ExpressiveOS, V ~/evolution, D ~/derpfest)"
    for f in *.sh *.py; do
        [[ -f $f ]] || continue
        l=""
        mentions_eos "$f" && l+=E
        grep -qE '(~|HOME|/home/build)/evolution(/|\b)' "$f" 2>/dev/null && l+=V
        grep -qiE 'derpfest' "$f" 2>/dev/null && l+=D
        printf '%-4s %s  ~/%s\n' "${l:--}" "$(date -r "$f" '+%F %T')" "$f"
    done
    echo "== ~/.ssh (names only)"; { ls -1 "$home/.ssh" 2>/dev/null || true; } | tr '\n' ' '; echo
    echo "== rclone's remotes (names only)"
    if [[ -x $home/bin/rclone ]]; then "$home/bin/rclone" listremotes 2>/dev/null | tr '\n' ' '; echo; else echo "no ~/bin/rclone"; fi
    echo "== private keys and their copies (file counts only)"
    for d in evolution/vendor/evolution-priv/keys derpfest/vendor/lineage-priv/keys expressiveos/vendor/evolution-priv/keys; do
        [[ -e $home/$d ]] && echo "~/$d: $(find -L "$home/$d" -type f 2>/dev/null | wc -l) files$([[ -L $home/$d ]] && echo " (a link to $(readlink "$home/$d"))")"
    done
    for d in "$home"/keys-retired "$ret"/keys-*; do [[ -d $d ]] && echo "${d#"$home"/}: $(find "$d" -type f | wc -l) files"; done
    ls -l "$home"/expressiveos-keys-*.tar.gz 2>/dev/null | awk '{print $9, $5, "bytes"}' | sed "s#$home/#~/#" || true
    echo "== ExpressiveOS check/ target-files, the only incremental-OTA base for phones on a testers build"
    n=0
    for f in "$home"/releases/expressiveos-*/testers/*.zip; do
        [[ -f $f ]] || continue
        n=$((n + 1)); x=${f##*/}; x=${x%-fastboot.zip}
        l=no; for d in "$home"/releases/expressiveos-*/check/"$x"-target_files.zip "$home"/releases/expressiveos-*/target-files/"$x"*; do [[ -f $d ]] && l="yes, ${d#"$home"/}"; done
        echo "${f#"$home"/}: its target-files on the server: $l"
    done
    [[ $n -gt 0 ]] || echo "no testers builds"
}

# ---- keep's saves and records, delete's checks ----------------------------------------------
save_tree() {   # save_tree <name>: what exists only in ~/<name>'s git repos, into $sd/<name>/
    local name=$1 tree=$home/$1 out=$sd/$1 list p rel d n c u kind sz k nsaved=0 nrepos=0
    [[ -d $tree ]] || { echo "$name: no ~/$name; nothing to save"; return 0; }
    mkdir -p "$out"
    list=$(mktemp)
    {
        [[ ! -f $tree/.repo/project.list ]] || sed "s#^#$tree/#" "$tree/.repo/project.list"
        for k in "$tree"/out-kernel/*/*; do
            [[ ! -f $k/.repo/project.list ]] || sed "s#^#$k/#" "$k/.repo/project.list"
        done
        find "$tree/device" "$tree/vendor" "$tree/packages" -mindepth 1 -maxdepth 4 -name .git -prune -printf '%h\n' 2>/dev/null || true
    } | sort -u > "$list"
    printf 'project\tcommits only here\tchanged files\tuntracked files\tsaved\n' > "$out/INDEX.tsv"
    while IFS= read -r p; do
        [[ -e $p/.git ]] || continue
        rel=${p#"$tree"/}
        case $rel in
            vendor/google/kodiak|vendor/google/grizzly|vendor/google/cubs|vendor/google/yogi) continue ;;   # copied whole above
            vendor/google/*-images) continue ;;   # extracted from the factory image zips, which stay
        esac
        nrepos=$((nrepos + 1))
        n=$(git -C "$p" rev-list --count HEAD --branches --not --remotes 2>/dev/null) || n=0
        c=$(git -C "$p" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null | wc -l)
        u=$(git -C "$p" ls-files --others --exclude-standard 2>/dev/null | wc -l)
        (( n + c + u > 0 )) || continue
        d=$out/${rel//\//__}
        mkdir -p "$d"
        kind=""
        if (( n > 300 )); then
            kind+="not bundled ($n commits: a pinned revision, not hand work) "
        elif (( n > 0 )); then
            sz=$(git -C "$p" count-objects -v 2>/dev/null | awk '/^size-pack:/ {print $2}')
            if [[ -z $(git -C "$p" for-each-ref --count=1 refs/remotes) ]] || (( ${sz:-0} < 524288 )); then
                git -C "$p" bundle create -q "$d/repo.bundle" --all || fail "$name: $rel: git bundle failed"
                kind+="bundle (whole repo) "
            else
                git -C "$p" bundle create -q "$d/repo.bundle" HEAD --branches --not --remotes || fail "$name: $rel: git bundle failed"
                kind+="bundle (the $n commits only) "
            fi
            git -C "$p" bundle verify -q "$d/repo.bundle" >/dev/null 2>&1 || fail "$name: $rel: its bundle doesn't verify"
            git -C "$p" log --oneline HEAD --branches --not --remotes > "$d/commits.txt" 2>/dev/null || true
        fi
        if (( c > 0 )); then
            git -C "$p" --no-optional-locks status --porcelain --untracked-files=no > "$d/status.txt"
            git -C "$p" diff HEAD --binary > "$d/changes.diff" || fail "$name: $rel: git diff failed"
            kind+="changes.diff "
        fi
        if (( u > 0 )); then
            sz=$(cd "$p" && git ls-files -z --others --exclude-standard | du -cb --files0-from=- 2>/dev/null | tail -n 1 | cut -f1)
            if (( ${sz:-0} <= 52428800 )); then
                (cd "$p" && git ls-files -z --others --exclude-standard | tar --null -T - -czf "$d/untracked.tar.gz") || fail "$name: $rel: tar failed"
                kind+="untracked.tar.gz"
            else
                git -C "$p" ls-files --others --exclude-standard > "$d/untracked-NOT-SAVED.txt"
                kind+="untracked list only ($((sz / 1048576)) MB)"
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$n" "$c" "$u" "$kind" >> "$out/INDEX.tsv"
        nsaved=$((nsaved + 1))
        echo "saved     $name/$rel: $n commits only here, $c changed, $u untracked: $kind"
    done < "$list"
    rm -f "$list"
    echo "$name: $nsaved of $nrepos repos had work only here ($(du -sh "$out" | cut -f1) in ${out#"$home"/})"
}

old_releases() {   # the ~/releases entries that aren't ExpressiveOS's
    local d
    for d in "$home"/releases/*; do
        [[ -e $d && ! -L $d ]] || continue
        [[ ${d##*/} = expressiveos-* ]] && continue
        echo "${d##*/}"
    done
}
records() {   # records: repo manifests, release records and the old kits into $rd
    local t k kn f n sz nm
    mkdir -p "$rd"; chmod 700 "$rd"
    for t in evolution derpfest; do
        for k in "$home/$t" "$home/$t"/out-kernel/*/*; do
            [[ -d $k/.repo ]] || continue
            kn=${k#"$home"/}; kn=${kn//\//_}
            if (cd "$k" && PATH=$home/bin:$PATH repo manifest -r -o "$rd/$kn-manifest-pinned.xml" >/dev/null 2>&1); then
                echo "record    ~/${k#"$home"/}: repo's pinned manifest -> ${rd#"$home"/}/$kn-manifest-pinned.xml"
            else
                echo "WARNING: repo manifest -r failed in ~/${k#"$home"/}"
            fi
        done
    done
    for f in derpfest-husky-kernel-manifest.xml evolution-cheetah evolution-husky derpfest-husky derpfest-backups yogi-overlays routine-backups bp-repair-backups evolution_ota derpfest_ota; do
        [[ -e $home/$f && ! -L $home/$f ]] || continue
        cp -a -- "$home/$f" "$rd/$f" || fail "can't copy ~/$f"
        echo "record    ~/$f"
    done
    mapfile -t nm < <(old_releases)
    if (( ${#nm[@]} > 0 )); then
        sz=$(cd "$home/releases" && du -scb -- "${nm[@]}" | tail -n 1 | cut -f1)
        (( sz <= 2147483648 )) || fail "the ~/releases folders that aren't ExpressiveOS's hold $((sz / 1048576)) MB, more than keep copies; look at them first: ${nm[*]}"
        mkdir -p "$rd/releases"
        for f in "${nm[@]}"; do cp -a -- "$home/releases/$f" "$rd/releases/$f" || fail "can't copy ~/releases/$f"; done
        echo "record    ~/releases/{$(IFS=,; echo "${nm[*]}")} ($((sz / 1048576)) MB)"
    fi
    mkdir -p "$rd/home-scripts"
    n=0
    for f in "$home"/*.sh "$home"/*.py; do [[ -f $f && ! -L $f ]] && cp -a -- "$f" "$rd/home-scripts/" && n=$((n + 1)); done
    echo "record    $n scripts from ~ (*.sh, *.py) -> ${rd#"$home"/}/home-scripts"
    chmod -R go-rwx "$rd"
}

busy() {   # what builds now: soong_ui, ninja, repo sync, an ExpressiveOS script, an eos-* session
    pgrep -a -u "$(id -u)" -f '(soong_ui|/ninja( |$)|repo sync|expressiveos-cheetah/[^ ]*\.sh)' \
        | grep -v -e 'evo-retire\.sh' | cut -c1-160 || true
    tmux ls -F '#S' 2>/dev/null | grep -E '^eos-' | sed 's/^/tmux session /' || true
}
verify_p11() {   # ExpressiveOS's copies of the Pixel 11 blob repos have the server repos' HEAD and branches
    local d src dst sh b
    for d in "${p11[@]}"; do
        src=$home/evolution/vendor/google/$d dst=$home/expressiveos/vendor/google/$d
        [[ -d $src/.git ]] || continue
        sh=$(git -C "$src" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || continue
        [[ -d $dst/.git ]] || fail "$d: ExpressiveOS has no copy of ~/evolution/vendor/google/$d; run keep again"
        [[ ! -s $dst/.git/objects/info/alternates ]] || fail "$d: ExpressiveOS's copy borrows objects (objects/info/alternates)"
        git -C "$dst" cat-file -e "$sh^{commit}" 2>/dev/null || fail "$d: ExpressiveOS's copy lacks the server repo's ${sh:0:12}; run keep again"
        while IFS= read -r b; do
            git -C "$dst" cat-file -e "$b^{commit}" 2>/dev/null || fail "$d: ExpressiveOS's copy lacks a server branch's ${b:0:12}; run keep again"
        done < <(git -C "$src" for-each-ref --format='%(objectname)' refs/heads)
        echo "ok        vendor/google/$d: ExpressiveOS's copy has the server repo's HEAD ${sh:0:12} and every branch"
    done
}
verify_keys() {   # verify_keys <name>: keep's copy matches the tree's key folder
    local name=$1 src kd n m
    case $name in evolution) src=$home/evolution/vendor/evolution-priv/keys ;; derpfest) src=$home/derpfest/vendor/lineage-priv/keys ;; esac
    [[ -d $src ]] || { echo "ok        no ~/${src#"$home"/}: no keys to keep"; return 0; }
    kd=$(kv keys)
    [[ -n $kd && -d $home/$kd/$name ]] || fail "keep made no copy of $name's keys; run keep again"
    n=$(find -L "$src" -type f | wc -l); m=$(find "$home/$kd/$name" -type f | wc -l)
    [[ $n -eq $m ]] || fail "$name: the tree has $n key files, keep's copy $m; run keep again"
    diff -rq "$(readlink -f "$src")" "$home/$kd/$name" >/dev/null 2>&1 || fail "$name's keys differ from keep's copy; run keep again"
    echo "ok        $name's keys: all $m files match the copy in $kd"
}
verify_saved() {   # verify_saved <name>: keep scanned the tree's repos
    local sd; sd=$(kv saved)
    [[ -n $sd && -f $home/$sd/$1/INDEX.tsv ]] || fail "keep didn't save ~/$1's server-only work; run keep again"
    echo "ok        ~/$1's server-only work saved in $sd/$1 ($(($(wc -l < "$home/$sd/$1/INDEX.tsv") - 1)) repos)"
}
no_borrow() {   # nothing in ~/expressiveos borrows objects from, or links into, the old trees
    local f l x eos=$home/expressiveos
    while IFS= read -r f; do
        while IFS= read -r l; do into_old "$l" && fail "${f#"$home"/} borrows objects from $l"; done < "$f"
    done < <(find "$eos/.repo" "$eos"/out-kernel/*/*/.repo "$eos"/vendor -xdev -path '*/objects/info/alternates' -size +0 2>/dev/null)
    x=$(nice -n 19 find "$eos" -xdev -path "$eos/out" -prune -o -type l \( -lname '*evolution*' -o -lname '*derpfest*' \) -print 2>/dev/null \
        | while IFS= read -r f; do into_old "$f" && echo "${f#"$home"/}"; done | head -n 5)
    [[ -z $x ]] || fail "links in ~/expressiveos point into the old trees: $x"
    echo "ok        nothing in ~/expressiveos borrows objects from or links into ~/evolution or ~/derpfest"
}
zap() {   # zap <path>: delete it for good; never a link, never through one, never across file systems
    local p=$1 r
    [[ -e $p || -L $p ]] || { echo "absent    ${p/#"$home"\//\~/}"; return 0; }
    [[ ! -L $p ]] || fail "$p is a link; not following it"
    r=$(readlink -f -- "$p")
    [[ $r = "$p" ]] || fail "$p resolves to $r (a link on the way); not deleting"
    rm -rf --one-file-system -- "$p"
    [[ ! -e $p ]] || fail "$p is still there"
    echo "deleted   ${p/#"$home"\//\~/}"
}
old_links() {   # ~/android-dt/bin's links to Evolution X's host tools: nothing ExpressiveOS runs uses them, and they'd dangle
    local f t
    for f in "$home"/android-dt/bin/*; do
        [[ -L $f ]] || continue
        t=$(readlink -- "$f")
        if into_old "$f" || [[ $t == "$home"/evolution/* || $t == "$home"/derpfest/* ]]; then
            rm -f -- "$f"; echo "deleted   link ~/${f#"$home"/} -> $t"
        fi
    done
}
free_gb() { df -BG --output=avail "$home" | tail -n 1 | tr -dc '0-9'; }

case $mode in
check)
    check
    done=1; echo "RETIRE=CHECKED"; exit 0 ;;

list)
    report
    done=1; echo "RETIRE=LISTED"; exit 0 ;;

stop)
    if [[ -f $marker ]]; then
        report
        done=1; echo "RETIRE=ALREADY"; exit 0
    fi
    r=$(running); [[ -z $r ]] || fail "an Evolution X or DerpFest script is running; stop it or let it finish first:
$r"
    r=$(busy_locks); [[ -z $r ]] || fail "a routine is still publishing (lock held: $r)"
    r=$(staged)
    [[ -z $r ]] || echo "NOTE: Evolution X releases staged and never published stay where they are (undo can still publish them): $r"
    dir=$ret/evo-derp-$(date -u +%Y%m%d-%H%M%S)
    mkdir -p "$dir"
    : > "$dir/MOVED"
    for n in "${names[@]}"; do
        [[ -f $n && ! -L $n ]] || continue
        if mentions_eos "$n"; then echo "kept      ~/$n (it mentions ExpressiveOS)"; continue; fi
        mv -n -- "$n" "$dir/$n"
        [[ -e $n ]] && fail "~/$n is still there after moving it"
        echo "$n" >> "$dir/MOVED"
        echo "moved     ~/$n -> ${dir#"$home"/}/$n"
    done
    when=$(date -u '+%F %H:%M UTC')
    # The stub, written beside ~/p11-routine.sh and renamed over its name
    cat > .p11-routine.sh.stub <<EOF
#!/bin/bash
$stubtag (evo-retire.sh stop, $when). Evolution X builds on this server were retired
# (Daryl, 2026-11-02: the server builds ExpressiveOS only). The real script is in
# ${dir#"$home"/}/; the runner's evo-retire action with query undo puts it back.
echo "Evolution X builds on this server were retired on $when: nothing was synced, built or published."
echo "ROUTINE_RESULT=RETIRED device=\${1:-none} log=none"
EOF
    chmod 755 .p11-routine.sh.stub
    mv -f .p11-routine.sh.stub p11-routine.sh
    echo "stub      ~/p11-routine.sh (prints ROUTINE_RESULT=RETIRED)"
    printf 'retired %s by evo-retire.sh stop; scripts in %s\n' "$when" "${dir#"$home"/}" > "$marker"
    # A routine that started while the scripts moved keeps running from its open file: say so
    r=$(running | grep -v -F "$home/p11-routine.sh" || true)
    [[ -z $r ]] || echo "WARNING: started during the move, still running: $r"
    echo "--"; report
    done=1; echo "RETIRE=STOPPED"; exit 0 ;;

undo)
    [[ -f $marker ]] || fail "not retired: no $marker"
    rel=$(sed -n 's/^retired .* scripts in \(retired\/evo-derp-[0-9-]*\)$/\1/p' "$marker" | head -n 1)
    [[ -n $rel && -f $home/$rel/MOVED ]] || fail "the marker doesn't name a folder with a MOVED list: $(cat "$marker")"
    dir=$home/$rel
    # Nothing new may stand where a moved script goes back, except the stub
    while read -r n; do
        [[ -n $n && -f $dir/$n ]] || fail "$rel/$n is missing"
        [[ ! -e $n ]] && continue
        [[ $n = p11-routine.sh ]] && grep -q "^$stubtag" "$n" && continue
        fail "~/$n exists and isn't the stub; move it aside before undo"
    done < "$dir/MOVED"
    [[ -z $(running) ]] || fail "something is running a retired script name: $(running)"
    while read -r n; do
        [[ -n $n ]] || continue
        if [[ $n = p11-routine.sh ]]; then mv -f -- "$dir/$n" "$n"; else mv -n -- "$dir/$n" "$n"; fi
        echo "restored  ~/$n"
    done < "$dir/MOVED"
    # p11-routine.sh may not have been there to move: drop a stub left alone
    if [[ -f p11-routine.sh ]] && grep -q "^$stubtag" p11-routine.sh; then rm -f p11-routine.sh; echo "removed   the stub ~/p11-routine.sh"; fi
    mv "$dir/MOVED" "$dir/UNDONE-$(date -u +%Y%m%d-%H%M%S)"
    rm -f "$marker"
    echo "--"; report
    done=1; echo "RETIRE=UNDONE"; exit 0 ;;

keep)
    exec 8>"$home/.expressiveos.lock"
    flock -n 8 || fail "~/.expressiveos.lock is held: an ExpressiveOS build, pack or setup is running; try again when it ends"
    eos=$home/expressiveos
    [[ -d $eos/.repo ]] || fail "no ExpressiveOS tree at ~/expressiveos"
    echo "== the Pixel 11 blob repos ExpressiveOS builds from"
    for d in kodiak grizzly cubs yogi; do
        src=$home/evolution/vendor/google/$d dst=$eos/vendor/google/$d
        if [[ ! -d $src/.git ]]; then echo "$d: no ~/evolution/vendor/google/$d repo; nothing to copy"; continue; fi
        sh=$(git -C "$src" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || { echo "$d: ~/evolution/vendor/google/$d has no commit; nothing to copy"; continue; }
        if [[ ! -e $dst ]]; then
            git clone -q --no-hardlinks --no-checkout -- "$src" "$dst" || fail "can't copy ~/evolution/vendor/google/$d"
            git -C "$dst" remote rename origin server || fail "can't name vendor/google/$d's remote"
            git -C "$dst" checkout -q --detach "$sh" || fail "can't check out vendor/google/$d"
            echo "$d: copied into ~/expressiveos/vendor/google/$d at ${sh:0:12} ($(du -sh "$dst" | cut -f1))"
        elif [[ -d $dst/.git ]]; then
            [[ ! -s $dst/.git/objects/info/alternates ]] || fail "~/expressiveos/vendor/google/$d borrows objects from another repo (objects/info/alternates)"
            git -C "$dst" remote get-url server >/dev/null 2>&1 || git -C "$dst" remote add server "$src"
            git -C "$dst" fetch -q server '+refs/heads/*:refs/remotes/server/*' '+HEAD:refs/remotes/server/evolution-HEAD' || fail "can't fetch ~/evolution/vendor/google/$d"
            # What prepare.sh would do on the phone's next build: move forward to the server repo's HEAD
            if [[ $(git -C "$dst" rev-parse HEAD) = "$sh" ]]; then
                echo "$d: ~/expressiveos/vendor/google/$d already at the server repo's ${sh:0:12}; its refs fetched"
            elif [[ -z "$(git -C "$dst" status --porcelain)" ]] && git -C "$dst" merge-base --is-ancestor HEAD "$sh"; then
                old=$(git -C "$dst" rev-parse --short HEAD)
                git -C "$dst" checkout -q --detach "$sh" || fail "can't move vendor/google/$d to ${sh:0:12}"
                echo "$d: ~/expressiveos/vendor/google/$d moved from $old to the server repo's ${sh:0:12}, as its next build would"
            else
                echo "WARNING: $d: ~/expressiveos/vendor/google/$d is at $(git -C "$dst" rev-parse --short HEAD), which the server repo's ${sh:0:12} doesn't build on (or it has changes): kept as it is, the server repo's refs fetched"
            fi
        else
            fail "~/expressiveos/vendor/google/$d exists but isn't a git repo"
        fi
        git -C "$dst" cat-file -e "$sh^{commit}" || fail "vendor/google/$d: ${sh:0:12} didn't arrive"
    done
    echo "== Evolution X's and DerpFest's private signing keys"
    kd=$ret/keys-$(date -u +%Y%m%d-%H%M%S)
    for pair in "evolution:$home/evolution/vendor/evolution-priv/keys" "derpfest:$home/derpfest/vendor/lineage-priv/keys"; do
        name=${pair%%:*} src=${pair#*:}
        if [[ ! -d $src ]]; then echo "$name: no ${src#"$home"/}; nothing to copy"; continue; fi
        src=$(readlink -f "$src")
        case $src in "$home"/evolution/*|"$home"/derpfest/*) ;; *) fail "$name's keys resolve outside its tree: ${src#"$home"/}";; esac
        mkdir -p "$kd"; chmod 700 "$ret" "$kd"
        # Links inside the key folder are copied as the files they point to: the copy has to
        # outlive the tree
        (umask 077; cp -RL --preserve=timestamps -- "$src" "$kd/$name")
        find "$kd/$name" -type d -exec chmod 700 {} + ; find "$kd/$name" -type f -exec chmod 600 {} +
        n=$(find "$kd/$name" -type f | wc -l)
        [[ $n -eq $(find -L "$src" -type f | wc -l) ]] || fail "$name: copied $n files, the tree has $(find -L "$src" -type f | wc -l)"
        diff -rq "$src" "$kd/$name" >/dev/null 2>&1 || fail "$name: the copy differs from the tree's keys"
        fp=none
        [[ -f $kd/$name/platform.x509.pem ]] && fp=$(openssl x509 -in "$kd/$name/platform.x509.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')
        echo "$name: $n files copied to ${kd#"$home"/}/$name (platform certificate SHA-256 $fp)"
    done
    stamp=${kd##*/keys-}
    sd=$ret/saved-$stamp rd=$ret/records-$stamp
    echo "== work that exists only in the old trees' git repos"
    mkdir -p "$sd"; chmod 700 "$sd"
    save_tree evolution
    save_tree derpfest
    chmod -R go-rwx "$sd"
    echo "== records: manifests, release records, the old kits and notes, the scripts in ~"
    records
    heads=""
    for d in "${p11[@]}"; do
        [[ -d $eos/vendor/google/$d/.git ]] && heads+="$d:$(git -C "$eos/vendor/google/$d" rev-parse --short HEAD) "
    done
    {
        echo "when=$(date -u '+%F %H:%M UTC')"
        echo "keys=$([[ -d $kd ]] && echo "${kd#"$home"/}" || echo none)"
        echo "saved=${sd#"$home"/}"
        echo "records=${rd#"$home"/}"
        echo "p11=${heads% }"
    } > "$kept.new"
    mv -f "$kept.new" "$kept"
    echo "--"; cat "$kept"
    done=1; echo "RETIRE=KEPT"; exit 0 ;;

delete)
    [[ -f $marker ]] || fail "Evolution X and DerpFest aren't retired: run stop first"
    [[ -f $kept ]] || fail "keep hasn't run: nothing has been copied out of the old trees yet"
    [[ $(( $(date +%s) - $(date -r "$kept" +%s) )) -lt 172800 ]] || fail "keep ran more than 2 days ago ($(kv when)); run it again first"
    exec 8>>"$home/.expressiveos.lock"
    flock -n 8 || fail "~/.expressiveos.lock is held: an ExpressiveOS build, pack or setup is running"
    exec 9>>"$home/.evolution-tree.lock"
    flock -n 9 || fail "~/.evolution-tree.lock is held: a build is running"
    r=$(busy); [[ -z $r ]] || fail "something is building; delete waits for nothing:
$r"
    r=$(running); [[ -z $r ]] || fail "an Evolution X or DerpFest script is running: $r"
    r=$(busy_locks); [[ -z $r ]] || fail "a publish lock is held: $r"
    eos=$home/expressiveos
    before=$(free_gb)
    echo "== $before GB free before"
    for part in out evolution derpfest research leftovers; do
        [[ " ${parts[*]} " = *" $part "* ]] || continue
        echo "== $part"
        case $part in
        out)
            old_links
            zap "$home/evolution/out"
            zap "$home/evolution/out-kernel" ;;
        evolution)
            [[ -d $home/evolution ]] || { echo "absent    ~/evolution"; continue; }
            verify_p11
            verify_keys evolution
            verify_saved evolution
            no_borrow
            old_links
            zap "$home/evolution" ;;
        derpfest)
            [[ -d $home/derpfest ]] || { echo "absent    ~/derpfest"; continue; }
            verify_keys derpfest
            verify_saved derpfest
            no_borrow
            zap "$home/derpfest" ;;
        research)
            for f in android-dt/ref/reeky android-dt/reeky android-dt/p11-diff android-dt/p11-diff-yogi; do zap "$home/$f"; done ;;
        leftovers)
            rd=$home/$(kv records)
            [[ -d $rd ]] || fail "keep's records folder ($(kv records)) is missing; run keep again"
            for f in espada fw-cp3a husky-audit; do zap "$home/$f"; done
            for f in evolution-husky derpfest-husky derpfest-backups yogi-overlays routine-backups bp-repair-backups evolution_ota derpfest_ota derpfest-husky-kernel-manifest.xml; do
                if [[ -e $home/$f && ! -e $rd/$f ]]; then echo "kept      ~/$f (keep didn't copy it)"; continue; fi
                zap "$home/$f"
            done
            while IFS= read -r f; do
                if [[ ! -e $rd/releases/$f ]]; then echo "kept      ~/releases/$f (keep didn't copy it)"; continue; fi
                zap "$home/releases/$f"
            done < <(old_releases)
            for f in cheetah-build.log husky-build.log kodiak-build.log grizzly-build.log cubs-build.log yogi-build.log \
                     kodiak-release-build.log kodiak-personal-build.log derp-build.log derp-husky-build.log dl-p11.log \
                     .evolution-ota.lock .evolution-queue .evolution-last-build .evolution-last-sync .kodiak-root; do
                zap "$home/$f"
            done
            for f in "$home"/husky-build-*.out "$home"/.evolution-publish-*.lock /tmp/kodiak-evox-img*.zip /tmp/EvolutionX-*.zip /tmp/magiskpatch.*; do
                [[ -e $f && -O $f ]] && zap "$f"
            done ;;
        esac
    done
    after=$(free_gb)
    echo "== $after GB free now ($((after - before)) GB freed)"
    done=1; echo "RETIRE=DELETED"; exit 0 ;;
esac
