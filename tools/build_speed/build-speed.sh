#!/usr/bin/env bash
# Read-only: what decides how long builds take on this server, and how long past
# builds took. The runner's build-speed action runs it; it runs by hand too:
#
#   build-speed.sh [tree...]    # default ~/evolution ~/derpfest ~/expressiveos
#
# Names, sizes, settings and timings only: no file contents beyond the build scripts'
# ccache, jobs and clean lines. Changes nothing (ccache -s only reads the counters).
set -uo pipefail
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
trees=("$@"); [[ ${#trees[@]} -gt 0 ]] || trees=(~/evolution ~/derpfest ~/expressiveos)

echo "== machine"
uptime; echo "cpus: $(nproc)"
lscpu 2>/dev/null | grep -E '^(Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|CPU\(s\)|CPU max MHz|NUMA node\(s\)|L3 cache|Hypervisor vendor|Virtualization type)' || true
echo "virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"; echo "kernel: $(uname -r)"
c=/sys/devices/system/cpu
r() { cat "$1" 2>/dev/null || echo n/a; }
echo "cpufreq governor: $(r $c/cpu0/cpufreq/scaling_governor), driver $(r $c/cpu0/cpufreq/scaling_driver), amd_pstate $(r $c/amd_pstate/status), energy preference $(r $c/cpu0/cpufreq/energy_performance_preference), boost $(r $c/cpufreq/boost)"
awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "cpu MHz now: %.0f on average over %d cpus\n", s / n, n }' /proc/cpuinfo
free -g; swapon --show 2>/dev/null || cat /proc/swaps
for f in cpu io memory; do echo "pressure $f: $(tr '\n' ' ' < /proc/pressure/$f 2>/dev/null || echo n/a)"; done
grep -E '^(pswpin|pswpout|pgmajfault|oom_kill) ' /proc/vmstat || true
awk '/^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i
    printf "cpu time since boot: user %.1f%%, system %.1f%%, idle %.1f%%, iowait %.1f%%, steal %.1f%%\n", 100*($2+$3)/t, 100*$4/t, 100*$5/t, 100*$6/t, 100*$9/t }' /proc/stat
echo "== busiest processes now"
ps -eo pid,user,pcpu,pmem,rss,etime,comm --sort=-pcpu | head -12

echo "== disks"
lsblk -d -o NAME,ROTA,SIZE,MODEL,TRAN,TYPE,SCHED 2>/dev/null || true
cat /proc/mdstat 2>/dev/null || true
for t in / /home /tmp "$HOME"; do findmnt -T "$t" -no TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null; done | sort -u
df -h ~ /tmp | sed 1d
# Since boot: data read and written, and the share of the uptime each device was busy
up=$(cut -d' ' -f1 /proc/uptime)
awk -v up="$up" '$3 ~ /^(md[0-9]+|nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)$/ {
    printf "%-10s read %7.0f GiB, written %7.0f GiB, busy %5.1f%% of the uptime\n", $3, $6*512/2^30, $10*512/2^30, 100*$13/1000/up }' /proc/diskstats

echo "== ccache"
command -v ccache >/dev/null || echo "(no ccache)"
ccache --version 2>/dev/null | head -1
echo "-- settings (and where each comes from)"
ccache -p 2>/dev/null || ccache --show-config 2>/dev/null || true
echo "-- statistics"
ccache -s -v 2>/dev/null || ccache -s 2>/dev/null || true
for c in ~/.ccache/ccache.conf ~/.config/ccache/ccache.conf; do [[ -f $c ]] && { echo "-- $c"; cat "$c"; }; done
ls -ld ~/.ccache ~/.cache/ccache 2>/dev/null || true

echo "== ccache, jobs and clean lines in the build scripts here"
scripts=(~/*.sh ~/expressiveos-cheetah/tools/*.sh ~/expressiveos-cheetah/ksu/tools/*.sh ~/evolution-cheetah/*.sh ~/evolution-cheetah/tools/*.sh ~/evolution-husky/*.sh ~/evolution-husky/tools/*.sh)
ls -l --time-style=+%F "${scripts[@]}" 2>/dev/null | awk '{ print $6, $7 }'
grep -HnE 'CCACHE|nproc|-j ?[0-9"$]|installclean|m clean|make clean|rm -rf[^#]*(\bout\b|/out)|SKIP_ABI_CHECKS|DISABLE_STUB_VALIDATION|WITH_DEXPREOPT|SOONG_|NINJA_|BUILD_DATETIME|build_kernel|SKIP_KERNEL_SYNC|KLEAF|bazel' "${scripts[@]}" 2>/dev/null \
    | sed "s|^$HOME/|~/|" | cut -c1-220 | head -220 || true

echo "== build_kernel (lunch and the build scripts run it)"
declare -A seen=()
for t in "${trees[@]}"; do
    for f in "$t"/vendor/*/build/envsetup.sh "$t"/vendor/*/vendorsetup.sh "$t"/vendor/*/build/tools/*.sh "$t"/device/google/*/vendorsetup.sh "$t"/build/envsetup.sh; do
        [[ -f $f ]] || continue
        grep -qE '^(function +)?build_kernel *\(\)' "$f" || continue
        body=$(awk '/^(function +)?build_kernel *\(\)/ { p = 1 } p { print; n++ } p && /^}/ { exit } n > 200 { exit }' "$f")
        sum=$(md5sum <<<"$body" | cut -c1-12)
        if [[ -n ${seen[$sum]:-} ]]; then echo "-- ${f#"$HOME"/}: same as ${seen[$sum]}"; continue; fi
        seen[$sum]=${f#"$HOME"/}
        echo "-- ${f#"$HOME"/}"; echo "$body"
    done
done

echo "== kernel build (Kleaf) output and caches"
for t in "${trees[@]}"; do
    k=$t/out-kernel
    [[ -d $k ]] || continue
    echo "-- ${k#"$HOME"/}"
    find "$k" -maxdepth 5 -type d \( -name output_user_root -o -name disk_cache -o -name 'cache' -o -name dist \) -printf '%TF %TH:%TM  %p\n' 2>/dev/null | sed "s|$HOME/|~/|" | head -12
done
ls -ld ~/.cache/bazel* ~/.bazelrc 2>/dev/null || true
[[ -f ~/.bazelrc ]] && grep -viE 'header|token|key|pass|cred|secret' ~/.bazelrc
echo "-- ~/.cache (GiB)"; timeout 120 nice -n 19 du -x -d1 -BG ~/.cache 2>/dev/null | sort -rn | head -8 || true

echo "== past builds: result lines in the build logs (newest logs first)"
logs=$(ls -t ~/routine-logs/* ~/expressiveos-jobs/*.log ~/*.log 2>/dev/null | head -250)
for f in $logs; do
    [[ -f $f ]] || continue
    r=$(grep -aoE '#### (build completed successfully|failed to build some targets) \([0-9:]+ \([hms:]+\)\) ####|INFO: Elapsed time: [0-9.]+s|== make pass [12][^,]*|== [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ [A-Z0-9+-]+ [a-z0-9]+ routine|ROUTINE_RESULT=[A-Z]+' "$f" 2>/dev/null | tr '\n' '|' || true)
    [[ -n $r ]] && echo "$(date -r "$f" '+%F %T') ${f#"$HOME"/}: $r" | cut -c1-700
done | head -160

# The routines publish while holding the tree lock: these times show how long that takes
echo "== releases: when each file was last written (pack zip and .sha256, OTA copy, .uploaded = SourceForge done)"
for d in ~/releases/*/; do
    [[ -d $d ]] || continue
    echo "-- ${d%/}"
    ls -lt --time-style='+%F %T' "$d" 2>/dev/null | awk 'NR > 1 { printf "  %s %s %12s %s\n", $6, $7, $5, $8 }' | head -14
done

echo "== where past builds' time went (soong_ui traces, ninja logs)"
timeout 1200 nice -n 10 python3 -I "$here/build-timings.py" "${trees[@]}" || echo "(build-timings.py stopped: $?)"
echo "BUILD_SPEED_DONE"
