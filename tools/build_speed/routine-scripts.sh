#!/bin/bash
# Read-only: what installing this checkout's routine scripts would change on the build
# server. Some copies in ~ were edited on the server after their last commit, so this
# comes before any install.
#
#   routine-scripts.sh <checkout> [<file in ~>...]
#
# Files named after the checkout (plain *.sh or *.py names in ~, such as scripts only the
# server has) are printed whole, with the same lines hidden.
# For every ~/*.sh and ~/*.py with a namesake in the checkout's tool folders, and for the
# ~/evolution-cheetah and ~/evolution-husky kits: same or differs, and for each copy that
# differs, its time and a unified diff (checkout -> server; lines that look like they
# could hold a secret are hidden). Then what the speed changes depend on: Evolution X's
# build_kernel and where lunch runs it, the kernel lines of the last cheetah and husky
# builds, ccache's settings and hit kinds, the shell startup files' ccache lines, the
# server's crontab, and what holds the tree lock now.
set -uo pipefail
repo=${1:?usage: routine-scripts.sh <checkout> [<file in ~>...]}; shift
[[ -d $repo/evolution-kodiak/tools ]] || { echo "no evolution-kodiak/tools in $repo"; exit 1; }
for n in "$@"; do
    [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(sh|py)$ ]] || { echo "not a plain *.sh or *.py name: $n"; exit 1; }
done
hide() { sed -E 's/^([-+ ]?).*(token|secret|passw|api[_-]?key|private key|authorization|bearer|cookie).*$/\1[line hidden: it may hold a secret]/I'; }
show_diff() { diff -u --label "checkout/$3" --label "server/$4" "$1" "$2" | hide | head -400; }

echo "== ~/*.sh and ~/*.py against the checkout (checkout -> server)"
folders=(evolution-kodiak/tools evolution-cheetah/tools evolution-husky/tools derpfest-husky/tools tools)
differ=()
for s in ~/*.sh ~/*.py; do
    [[ -f $s ]] || continue
    n=${s##*/}; r=
    for f in "${folders[@]}"; do [[ -f $repo/$f/$n ]] && { r=$f/$n; break; }; done
    if [[ -z $r ]]; then
        printf 'server only  %-34s %s\n' "~/$n" "$(date -r "$s" '+%F %T')"
    elif cmp -s "$repo/$r" "$s"; then
        printf 'same         %-34s %s\n' "~/$n" "$r"
    else
        printf 'DIFFERS      %-34s %s (server copy %s)\n' "~/$n" "$r" "$(date -r "$s" '+%F %T')"
        differ+=("$r|$n")
    fi
done
for d in "${differ[@]}"; do
    r=${d%%|*}; n=${d#*|}
    echo "-- ~/$n"
    show_diff "$repo/$r" ~/"$n" "$r" "~/$n"
done

for n in "$@"; do
    echo "== ~/$n (whole file)"
    if [[ -f ~/$n ]]; then
        echo "$(date -r ~/"$n" '+%F %T'), $(wc -l < ~/"$n") lines"
        hide < ~/"$n" | head -500
    else
        echo "absent"
    fi
done

for kit in evolution-cheetah evolution-husky; do
    echo "== ~/$kit against the checkout's $kit/"
    [[ -d ~/$kit ]] || { echo "absent"; continue; }
    echo "installed from: $(cat ~/$kit/INSTALLED_FROM 2>/dev/null || echo 'not recorded')"
    out=$(diff -rq -x .git -x INSTALLED_FROM -x __pycache__ "$repo/$kit" ~/"$kit" 2>&1)
    [[ -z $out ]] && { echo "same"; continue; }
    sed "s#$repo/#checkout/#g; s#$HOME/#~/#g" <<<"$out" | head -60
    while read -r a b; do
        [[ -f $a && -f $b ]] || continue
        grep -Iq . "$a" 2>/dev/null && grep -Iq . "$b" 2>/dev/null || { echo "-- ${b#$HOME/}: binary, not shown"; continue; }
        echo "-- ~/${b#$HOME/}"
        show_diff "$a" "$b" "${a#$repo/}" "~/${b#$HOME/}"
    done < <(sed -n 's/^Files \(.*\) and \(.*\) differ$/\1 \2/p' <<<"$out")
done

top=~/evolution
echo "== Evolution X's build_kernel ($top/vendor/lineage/build/envsetup.sh)"
awk '/^function build_kernel\(\)/ { p = 1 } p { print } p && /^}/ { exit }' $top/vendor/lineage/build/envsetup.sh 2>/dev/null | hide
echo "== where build_kernel and SKIP_KERNEL_* are used in the envsetup files"
grep -n -B4 -A2 -E 'build_kernel|SKIP_KERNEL' $top/build/envsetup.sh $top/vendor/lineage/build/envsetup.sh $top/vendor/*/build/envsetup.sh 2>/dev/null \
    | grep -v -E '^[^:]*-[0-9]+-\s*$' | sed "s#$top/##" | awk '!seen[$0]++' | hide | head -80
echo "== kernel lines in the last cheetah and husky builds"
for l in ~/cheetah-build.log ~/husky-build.log; do
    [[ -f $l ]] || continue
    echo "-- $l ($(date -r "$l" '+%F %T'))"
    grep -n -E 'Syncing .*out-kernel|Kernel source|Kernel build output copied|Skipping kernel|build_kernel|^Fetching:|repo sync has finished|INFO: Build completed|INFO: Elapsed time' "$l" | cut -c1-200 | head -30
done

echo "== ccache"
ccache --version 2>/dev/null | head -1
ccache -p 2>/dev/null | grep -E '\) (direct_mode|max_size|compression|compression_level|sloppiness|compiler_check|base_dir|cache_dir|hash_dir|depend_mode|file_clone|inode_cache) = ' || echo "(ccache -p printed nothing)"
ccache -s -v 2>/dev/null | grep -iE 'hits|misses|direct|preprocessed|cache size|cleanups' | head -20
echo "== shell startup files: ccache lines"
for f in ~/.profile ~/.bash_profile ~/.bash_login ~/.bashrc; do
    if [[ -f $f ]]; then
        echo "-- $f ($(wc -l < "$f") lines)"
        grep -n -iE 'ccache|DIRECT_MODE|case \$- in|PS1' "$f" | hide | head -10
    else
        echo "-- $f: absent"
    fi
done
echo "== crontab (comments left out)"
crontab -l 2>/dev/null | grep -v -E '^\s*(#|$)' | sed 's/^/ /' | hide || echo "none"

echo "== now"
echo "tree lock: $(flock -n ~/.evolution-tree.lock true 2>/dev/null && echo free || echo held)"
for l in ~/.evolution-publish-*.lock; do
    [ -e "$l" ] || continue
    d=${l##*/.evolution-publish-}; echo "publish lock ${d%.lock}: $(flock -n "$l" true 2>/dev/null && echo free || echo held)"
done
echo "waiting for the tree: $(ls ~/.evolution-queue 2>/dev/null | paste -sd' ' | sed 's/^$/none/')"
echo "last build in out/: $(cat ~/.evolution-last-build 2>/dev/null || echo "not recorded")"
ls -d ~/releases/*/staged-* 2>/dev/null | sed 's/^/staged, not published: /'
pgrep -a -u "$(id -u)" -f 'p11-routine|release-chain|eos-images|eos-pack|soong_ui|derp-build' 2>/dev/null \
    | grep -v -E "^$$ |routine-scripts" | cut -c1-160 || echo "no routine or build running"
tmux ls 2>/dev/null | cut -d: -f1 | sed 's/^/tmux: /'
echo "== newest routine logs"
ls -t ~/routine-logs 2>/dev/null | head -14
