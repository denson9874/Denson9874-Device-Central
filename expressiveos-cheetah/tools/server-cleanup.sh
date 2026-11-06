#!/usr/bin/env bash
# Free disk on the build server. Third round (2026-11-06). Daryl's rule that day: the server
# keeps only what release builds, deltas and test builds need, and check/ and out/ files go
# once they're no longer needed. The groups below come from the runner's server-usage listing
# of 2026-11-06 (run 42285807240, sizes then; 877 GB free). Rounds 1 (2026-10-26) and 2
# (2026-10-31) are in git history.
#   1  the Nov 3 releases' zips in ~/releases, all six phones: each release's fastboot zip
#      (on R2 and Drive; its .sha256 stays, as eos-ota.sh expects) and its full OTA package
#      in ota/ (on R2, the live feed's; five of them are hard links of out/'s, so they free
#      their space with group 3)                                                   ~53 GB
#   2  the released Nov 3 candidates in check/ of husky, kodiak, grizzly, cubs and yogi: the
#      fastboot zip, its .pack-ok, its target-files (a hard link of target-files/'s, which
#      stays) and its text files. The .device-ok records stay                      ~26 GB
#   3  the build output of husky, kodiak, grizzly, cubs and yogi: out/target/product/<phone>
#      and each product's own files in out/ and out/soong (Kati's and Soong's ninja files,
#      raw-lineage_<phone>/ ...), plus the KernelSU leftovers out/ksu, out/ksu-husky and
#      out/ksu-kodiak (KernelSU left ExpressiveOS on 2026-11-03). Each phone's next build
#      starts its product over; the shared build output and ccache stay           ~200 GB
#   4  what no build reads: the stock firmware dumps ~/android-dt/dumps and the Pixel 11
#      kernel DDK ~/android-dt/ddk                                                  ~59 GB
# Kept, whatever the groups say: cheetah's build output and its check/ candidate (the test
# builds), out-kernel, the ExpressiveOS records (out/eos*), the firmware the pack scripts
# read, each phone's newest release target-files (the next delta's base), every .device-ok
# record, ccache's cache. Daryl approved groups 1, 2 and 3 on 2026-11-06; group 4 needs his OK.
# Exact paths only (built from the fixed phone and release names below, never a glob), and
# deleting is permanent, so `delete` runs only the groups named, only while it holds the tree
# lock and ExpressiveOS's lock, and only while no build runs (soong_ui or ninja, in any tree)
# and no ExpressiveOS tmux session (eos-build, eos-pack) is open.
#
#   server-cleanup.sh list [groups]       # what's there now, with sizes; changes nothing
#   server-cleanup.sh delete <groups>     # e.g. delete 1,2,3
#
# The last line is CLEANUP=LISTED, OK, PARTIAL (a group was skipped: a build was running)
# or FAIL.
set -euo pipefail
done=0
trap '[[ $done = 1 ]] || echo "CLEANUP=FAIL"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

mode=${1:-}
groups=${2:-1,2,3,4}
[[ "$mode" = list || "$mode" = delete ]] && [[ $# -le 2 ]] || fail "usage: server-cleanup.sh list [groups] | delete <groups>"
[[ "$mode" = list || $# -eq 2 ]] || fail "delete needs the groups, e.g. delete 1,2"
[[ "$groups" =~ ^[1-4](,[1-4])*$ ]] || fail "groups are numbers 1-4 separated by commas, not '$groups'"

# The groups are read through a nameref (g$n). Entries ending in / are folders
X=expressiveos/out R=releases A=android-dt
ALL=(cheetah husky kodiak grizzly cubs yogi)
DONE=(husky kodiak grizzly cubs yogi)  # released Nov 3, no test build planned before 1.1
rel() { echo "ExpressiveOS-17.0-20261103-$1-1.0-Official"; }
g1=() g2=() g3=() g4=()
for d in "${ALL[@]}"; do
    g1+=("$R/expressiveos-$d/$(rel "$d")-fastboot.zip" "$R/expressiveos-$d/ota/$(rel "$d").zip")
done
for d in "${DONE[@]}"; do
    c=$R/expressiveos-$d/check/$(rel "$d")
    g2+=("$c-fastboot.zip" "$c-fastboot.zip.pack-ok" "$c-target_files.zip"
         "$c-manifest.xml" "$c-kernel-manifest.xml" "$c-sources.txt" "$c-changelog.txt")
    [[ $d = husky ]] || g2+=("$c-announcement.md")
    P=lineage_$d
    g3+=("$X/target/product/$d/")
    for f in "build-$P-cleanspec.ninja" "build-$P.ninja" "build-$P-package.ninja" "combined-$P.ninja" \
             "env-$P-cleanspec.sh" "env-$P-package.sh" "env-$P.sh" \
             ".kati_stamp-$P" ".kati_stamp-$P-cleanspec" ".kati_stamp-$P-package" \
             "ninja-$P-cleanspec.sh" "ninja-$P-package.sh" "ninja-$P.sh"; do
        g3+=("$X/$f")
    done
    for f in "Android-$P.mk" "build.$P.0.ninja" "build.$P.1.ninja" "build.$P.2.ninja" "build.$P.3.ninja" \
             "build.$P.4.ninja" "build.$P.5.ninja" "build.$P.6.ninja" "build.$P.7.ninja" "build.$P.8.ninja" \
             "build.$P.9.ninja" "build.$P.ninja" "build.$P.ninja.d" "build_uuid-$P.txt" "dexpreopt-$P.config" \
             "installs-$P.mk" "kati_packaging-$P/" "late-$P.mk" "make_vars-$P.mk" "module-info-$P.json" \
             "raw-$P/" "soong.environment.used.$P.build" "soong.$P.extra.variables" "soong.$P.variables"; do
        g3+=("$X/soong/$f")
    done
done
g3+=("$X/ksu/" "$X/ksu-husky/" "$X/ksu-kodiak/")
g4=("$A/dumps/" "$A/ddk/")
keep=(
    # The firmware the pack scripts and fetch-firmware.sh read
    "$A/firmware/"
    # The test builds: cheetah's build output and its check/ candidate; the kernel build
    "$X/target/product/cheetah/"
    "$R/expressiveos-cheetah/check/"
    expressiveos/out-kernel/
    # The ExpressiveOS records, and ccache's cache
    "$X/eos/"
    .ccache/
)
for d in "${ALL[@]}"; do
    # Each release's fastboot zip checksum stays (eos-ota.sh's sign of a release of this folder),
    # and so do the phones' build records
    keep+=("$R/expressiveos-$d/$(rel "$d")-fastboot.zip.sha256")
    [[ $d = cheetah ]] || keep+=("$X/eos-$d/")
done

home=$(cd ~ && pwd -P)
# Absolute path of an entry: /tmp entries as they are, the rest under ~
abs() { local p=${1%/}; [[ "$p" = /* ]] && echo "$p" || echo "$home/$p"; }
# Only things inside these folders may go
allowed() {
    local p=$1 r
    for r in "$home/releases" "$home/android-dt" "$home/expressiveos/out"; do
        [[ "$p" = "$r"/* ]] && return 0
    done
    return 1
}
# The newest ExpressiveOS release's target-files (target-files/LATEST), and the newest by
# date in each such folder too, should LATEST be missing or stale: kept, with their .sha256
for d in "$home/$R"/expressiveos-*/target-files; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    rel=${d#"$home"/}
    n=$(head -n 1 -- "$d/LATEST" 2>/dev/null || true)
    [[ -z "$n" || "$n" =~ ^ExpressiveOS-[A-Za-z0-9._-]+-target_files\.zip$ ]] || fail "$d/LATEST names '$n', not an ExpressiveOS target-files zip"
    newest=$(find "$d" -maxdepth 1 -type f -name 'ExpressiveOS-*-target_files.zip' -printf '%T@ %f\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
    [[ "$newest" != "$n" ]] || newest=''
    keep+=("$rel/LATEST")
    for z in "$n" "$newest"; do [[ -z "$z" ]] || keep+=("$rel/$z" "$rel/$z.sha256"); done
done
kept() { # kept <absolute path>: on the keep list, or inside a kept folder
    local k K
    for k in "${keep[@]}"; do K=$(abs "$k"); [[ "$1" = "$K" || "$1" = "$K"/* ]] && return 0; done
    return 1
}
# Checksum files the pack scripts and the release step write next to a zip or image
sidecars() { # each checksum file beside $1, once (name.sha256 for a .zip too), unless it's kept
    local f; local -a c=("$1.sha256" "$1.sha256sum" "$1.md5sum")
    [[ $1 == *.zip ]] && c+=("${1%.zip}.sha256")
    for f in "${c[@]}"; do [[ -f "$f" && ! -L "$f" ]] && ! kept "$f" && echo "$f"; done; return 0
}
# du's total even if it can't read part of a folder (that stops nothing; the sum is then low)
size_of() { { nice -n 19 ionice -c2 -n7 du -s -B1 --apparent-size -- "$@" 2>/dev/null || true; } | awk '{s += $1} END {print s + 0}'; }
human() { numfmt --to=iec --suffix=B "$1"; }

# Nothing on the keep list may be a target, or inside one, or hold one
for k in "${keep[@]}"; do
    K=$(abs "$k")
    for n in 1 2 3 4; do
        declare -n list="g$n"
        for t in "${list[@]}"; do
            T=$(abs "$t")
            [[ "$K" != "$T" && "$K" != "$T"/* && "$T" != "$K"/* ]] || fail "group $n's $t would remove $k, or part of it, which is kept"
        done
        unset -n list
    done
done

build_running() { pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null; }
eos_session() { local s; for s in eos-build eos-pack; do tmux has-session -t "=$s" 2>/dev/null && return 0; done; return 1; }
IFS=, read -r -a chosen <<<"$groups"

# Check every target first, so a bad one stops the run before anything is removed
for n in "${chosen[@]}"; do
    declare -n list="g$n"
    for t in "${list[@]}"; do
        T=$(abs "$t")
        [[ ! -L "$T" ]] || fail "$T is a symlink; not touching it (nothing was removed)"
        [[ -e "$T" ]] || continue
        r=$(realpath -e -- "$T")
        if [[ "$r" != "$T" ]] || ! allowed "$r"; then fail "$T resolves to $r, outside the folders this may clean (nothing was removed)"; fi
        [[ "$(stat -c %u -- "$T")" = "$(id -u)" ]] || fail "$T isn't this account's (nothing was removed)"
        if [[ "$t" = */ ]]; then
            [[ -d "$T" ]] || fail "$T should be a folder (nothing was removed)"
            [[ -z "$(find "$T" -name '*.device-ok' -print -quit)" ]] \
                || fail "$T holds an on-device gate's .device-ok record; not removing it (nothing was removed)"
        else
            [[ -f "$T" ]] || fail "$T should be a file (nothing was removed)"
        fi
    done
    unset -n list
done

if [[ "$mode" = delete ]]; then
    # Held to the end: no routine or build starts while files go
    exec 9>"$home/.evolution-tree.lock"
    flock -n 9 || fail "the tree lock is held (a routine or build is running); run delete again later (nothing was removed)"
    exec 8>"$home/.expressiveos.lock"
    flock -n 8 || fail "ExpressiveOS's lock is held (a build, pack or kit script is running); run delete again later (nothing was removed)"
fi
echo "== $mode, groups $groups ($(df -h --output=avail ~ | tail -1 | tr -d ' ') free)"
total=0 skipped=0
for n in "${chosen[@]}"; do
    declare -n list="g$n"
    echo "== group $n"
    gsum=0 skip=''
    if [[ "$mode" = delete ]]; then
        # Only while nothing builds, in any tree, even by hand
        if build_running; then skip="a build is running"; elif eos_session; then skip="an ExpressiveOS build or pack session is open"; fi
    fi
    if [[ -n $skip ]]; then
        echo "SKIPPED  group $n: $skip; run it again when the server is idle"
        skipped=1; unset -n list; continue
    fi
    for t in "${list[@]}"; do
        T=$(abs "$t")
        if [[ ! -e "$T" ]]; then echo "gone     $t"; continue; fi
        side=()
        if [[ -d "$T" ]]; then
            s=$(size_of "$T")
            echo "folder   $(human "$s")  $t"
            if [[ "$mode" = list && $n = 4 ]]; then
                find "$T" -mindepth 1 -maxdepth 1 -printf '           %y %s %P\n' | sort -k3 | numfmt --invalid=ignore --to=iec --field=2 | head -20 || true
            fi
            if [[ "$mode" = list ]]; then
                # A build's zips (a release, an OTA, images) left in it: is each one uploaded?
                find "$T" -xdev -maxdepth 4 -type f -name '*.zip' -size +100M -printf '           zip %TY-%Tm-%Td %TH:%TM %s %P\n' 2>/dev/null \
                    | sort -k5 | numfmt --invalid=ignore --to=iec --field=4 | head -30 || true
            fi
        else
            mapfile -t side < <(sidecars "$T")
            s=$(size_of "$T" ${side[@]+"${side[@]}"})
            echo "file     $(human "$s")  $t${side[*]:+ (+ ${#side[@]} checksum file(s))}"
        fi
        if [[ "$mode" = delete ]]; then
            if [[ -d "$T" ]]; then
                rm -rf --one-file-system -- "$T"
            else
                rm -f -- "$T" ${side[@]+"${side[@]}"}
            fi
            [[ ! -e "$T" ]] || fail "couldn't remove $T"
            echo "removed  $t"
        fi
        gsum=$((gsum + s))
    done
    unset -n list
    echo "   group $n: $(human "$gsum")"
    total=$((total + gsum))
done

echo "== kept, never touched"
for k in "${keep[@]}"; do
    K=$(abs "$k")
    if [[ -e "$K" ]]; then echo "ok       $k"; else echo "absent   $k"; fi
done
done=1
free_now=$(df -h --output=avail ~ | tail -1 | tr -d ' ')
if [[ "$mode" = list ]]; then
    echo "== would free $(human "$total") ($free_now free now)"
    echo "CLEANUP=LISTED"
elif [[ $skipped = 1 ]]; then
    echo "== freed $(human "$total"); $free_now free now; a group was skipped"
    echo "CLEANUP=PARTIAL"
else
    echo "== freed $(human "$total"); $free_now free now"
    echo "CLEANUP=OK"
fi
