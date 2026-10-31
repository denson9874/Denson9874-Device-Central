#!/usr/bin/env bash
# Where the build server's disk goes, in more detail than expressiveos-host: every tree's
# source and build output per product, the release folders (zips, check/, testers/,
# staged-*, target-files/), firmware, the DDK, caches, logs, backups and big files that
# sit outside the trees. Read-only: names, sizes and dates only, never file contents.
# du runs at low priority, so it may run beside a build (its numbers then move).
#
#   server-usage.sh
set -uo pipefail
cd ~ || exit 1
lowdu() { nice -n 19 ionice -c2 -n7 du -x -s -h "$@" 2>/dev/null || true; }
lowdu1() { nice -n 19 ionice -c2 -n7 du -x -d1 -h "$@" 2>/dev/null | sort -rh || true; }
newest() { # newest() <dir>: the date of the newest file at most 2 levels down
    find "$1" -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -n 1
}

echo "== disk"; df -h ~ /tmp | sed 1d
echo "== locks and sessions"
for l in ~/.evolution-tree.lock ~/.expressiveos.lock; do
    if flock -n "$l" true 2>/dev/null; then echo "${l#"$HOME"/}: free"; else echo "${l#"$HOME"/}: held"; fi
done
tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' '; echo
pgrep -a -u "$(id -u)" -f 'soong_ui|bin/ninja|p11-routine|eos-(images|pack)' | cut -c1-160 | head -5 || true

echo "== ~, one level"
lowdu1 ~ | head -40

for t in ~/evolution ~/derpfest ~/expressiveos; do
    [[ -d $t ]] || continue
    echo "== $t: the tree's top folders, source, kernel out, and each out folder"
    lowdu1 "$t" | head -15
    lowdu "$t/.repo"
    for k in "$t"/out-kernel*; do [[ -d $k ]] && lowdu "$k"; done
    lowdu1 "$t/out" | head -25
    echo "-- $t/out/soong: one level, and its files over 500 MiB (date, size, name)"
    lowdu1 "$t/out/soong" | head -15
    find "$t/out/soong" -maxdepth 1 -type f -size +500M -printf '%TY-%Tm-%Td %s %f\n' 2>/dev/null | sort | numfmt --invalid=ignore --to=iec --field=2 | head -40 || true
    if [[ -d $t/out/target/product ]]; then
        echo "-- $t/out/target/product: size, newest file"
        for p in "$t"/out/target/product/*/; do
            p=${p%/}
            echo "$(lowdu "$p" | cut -f1)  ${p##*/}  newest $(newest "$p")"
        done
    fi
    # The ExpressiveOS records per phone (out/eos, out/eos-<device>)
    for e in "$t"/out/eos "$t"/out/eos-*; do
        [[ -d $e ]] || continue
        echo "-- ${e#"$HOME"/}: $(lowdu "$e" | cut -f1), build.ok $(cut -c1-120 "$e/build.ok" 2>/dev/null || echo none)"
    done
done

echo "== ~/releases, two levels"
nice -n 19 ionice -c2 -n7 du -x -d2 -h ~/releases 2>/dev/null | sort -rh | head -60 || true
echo "== files in ~/releases over 200 MiB (date, size, path)"
find ~/releases -type f -size +200M -printf '%TY-%Tm-%Td %TH:%TM %s %P\n' 2>/dev/null | sort | numfmt --invalid=ignore --to=iec --field=3 | head -150 || true
echo "== hard links: files in ~/releases over 200 MiB with more than one link (inode, links, path)"
find ~/releases -type f -size +200M -links +1 -printf '%i %n %P\n' 2>/dev/null | sort -n | head -60 || true
echo "== release folders' check/, testers/, staged-* and target-files/ (names, sizes)"
for d in ~/releases/*/check ~/releases/*/testers ~/releases/*/staged-* ~/releases/*/target-files ~/releases/*/personal; do
    [[ -d $d ]] || continue
    echo "-- ${d#"$HOME"/}"
    find "$d" -mindepth 1 -maxdepth 2 -printf '   %y %TY-%Tm-%Td %s %P\n' 2>/dev/null | sort -k4 | numfmt --invalid=ignore --to=iec --field=3 | head -40 || true
done
for f in ~/releases/*/target-files/LATEST; do [[ -f $f ]] && echo "${f#"$HOME"/}: $(head -n 1 "$f")"; done

echo "== ~/android-dt, two levels"
nice -n 19 ionice -c2 -n7 du -x -d2 -h ~/android-dt 2>/dev/null | sort -rh | head -40 || true
echo "== files in ~/android-dt over 1 GiB (date, size, path)"
find ~/android-dt -xdev -type f -size +1G -printf '%TY-%Tm-%Td %s %P\n' 2>/dev/null | sort | numfmt --invalid=ignore --to=iec --field=2 | head -80 || true

echo "== other folders in ~ (newest file)"
for d in ~/expressiveos-update ~/expressiveos-jobs ~/expressiveos-cheetah ~/expressiveos-cheetah.* ~/routine-backups ~/routine-logs \
         ~/actions-runner ~/actions-runner/_work ~/actions-runner/_diag ~/evolution-cheetah ~/evolution-husky \
         ~/.ccache ~/.cache ~/.cache/* ~/.gradle ~/.m2 ~/.npm ~/.local/share ~/.local/share/* ~/.android ~/bin ~/go ~/snap; do
    [[ -d $d ]] || continue
    echo "$(lowdu "$d" | cut -f1)  ${d#"$HOME"/}  newest $(newest "$d")"
done
echo "== ccache"
command -v ccache >/dev/null && { ccache -s 2>/dev/null | grep -iE 'cache directory|cache size|hits|misses' | head -8; ccache -p 2>/dev/null | grep -E 'max_size|cache_dir' | head -3; } || echo "(no ccache)"
for v in CCACHE_DIR CCACHE_MAXSIZE; do grep -h "$v" ~/.profile ~/.bashrc 2>/dev/null | head -2; done

echo "== files over 1 GiB in ~ outside the trees' .repo, out and out-kernel* and outside ~/releases and ~/android-dt (date, size, path)"
find ~ -xdev \( -path "$HOME/evolution" -o -path "$HOME/derpfest" -o -path "$HOME/expressiveos" -o -path "$HOME/releases" -o -path "$HOME/android-dt" \) -prune -o \
    -type f -size +1G -printf '%TY-%Tm-%Td %s %P\n' 2>/dev/null | sort | numfmt --invalid=ignore --to=iec --field=2 | head -60 || true
echo "== files over 1 GiB directly in the trees' top folders (not .repo or out)"
for t in ~/evolution ~/derpfest ~/expressiveos; do
    [[ -d $t ]] || continue
    find "$t" -maxdepth 1 -type f -size +1G -printf '%TY-%Tm-%Td %s %p\n' 2>/dev/null | numfmt --invalid=ignore --to=iec --field=2 || true
done
echo "== ~ top-level files over 100 MiB (logs, archives)"
find ~ -maxdepth 1 -type f -size +100M -printf '%TY-%Tm-%Td %s %f\n' 2>/dev/null | sort | numfmt --invalid=ignore --to=iec --field=2 || true
echo "== /tmp: entries of this user over 500 MiB (GiB)"
find /tmp -maxdepth 1 -user "$(id -u)" -printf '%p\n' 2>/dev/null | while read -r p; do
    s=$(nice -n 19 du -x -s -BM "$p" 2>/dev/null | cut -f1 | tr -d M)
    [[ ${s:-0} -ge 500 ]] && echo "$((s / 1024))G  $p  $(date -r "$p" '+%F %T' 2>/dev/null)"
done
echo "USAGE=LISTED"
