#!/usr/bin/env bash
# Read-only: why builds redo the big framework steps (the API stubs, SystemUI,
# Settings, services). Where siso runs the builds, from what siso wrote about each
# recent build (out/siso_explain*); elsewhere, from ninja's own dry run of the
# product's graph against the out/ the last build left (`ninja -n -d explain` runs no
# command and writes no log). With other products, it also compares their commands for
# the same steps with the first product's (word by word: what only one side has).
#
#   build-explain.sh <evolution|derpfest|expressiveos> <product> [<other product>...]
#
# Takes a few minutes and some GB of memory (ninja loads the product's whole graph),
# so it refuses while a build is running.
set -uo pipefail
fail() { echo "FAIL: $*"; exit 1; }
[[ $# -ge 2 && $# -le 4 ]] || fail "usage: build-explain.sh <evolution|derpfest|expressiveos> <product> [<other product>...]"
[[ $1 =~ ^(evolution|derpfest|expressiveos)$ ]] || fail "tree must be evolution, derpfest or expressiveos"
for p in "${@:2}"; do [[ $p =~ ^[a-z0-9_]+$ ]] || fail "bad product name: $p"; done
top=$HOME/$1 p1=$2 others=("${@:3}")
cd "$top" || fail "no $top"
ninja=prebuilts/build-tools/linux-x86/bin/ninja
[[ -x $ninja ]] || fail "no $top/$ninja"
for p in "${@:2}"; do [[ -f out/combined-$p.ninja ]] || fail "no out/combined-$p.ninja (that product hasn't been built in $top)"; done
pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja|linux-x86/siso' >/dev/null && fail "a build is running; try again when it's done"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# The steps to look at, as the last build recorded them
pats=(
    frameworks/base/api/system-api-stubs-docs-non-updatable/android_common/exportable/system-api-stubs-docs-non-updatable-stubs.srcjar
    frameworks/base/api/api-stubs-docs-non-updatable/android_common/everything/api_lint.timestamp
    frameworks/base/packages/SystemUI/SystemUI-core/android_common/ksp/ksp-java-sources.srcjar
    frameworks/base/packages/SystemUI/SystemUI-core/android_common/kotlin/SystemUI-core.jar
    packages/apps/Settings/Settings-core/android_common/kapt/stubs.jar
    frameworks/base/services/services/android_common/dex/services.jar
    packages/apps/Updater/app/Updater/android_common/dex/Updater.jar
    /all_aconfig_declarations.pb
)
targets=()
for pat in "${pats[@]}"; do
    t=$(grep -F -- "$pat" out/.ninja_log | cut -f4 | grep -F -- "$pat" | tail -1)
    [[ -n $t ]] && targets+=("$t") || echo "(not in out/.ninja_log: $pat)"
done
[[ ${#targets[@]} -gt 0 ]] || fail "none of the steps is in out/.ninja_log"
printf 'step: %s\n' "${targets[@]}"
echo "== the last build in $top: $(ls -t out/build.trace* 2>/dev/null | head -1 | xargs -r date '+%F %T' -r)"
for f in out/target/product/*/; do echo "  $(date -r "$f" '+%F %T') ${f%/}"; done | sort | tail -3

echo "== the build log ninja reads (out/.ninja_log) and the other executors' files"
ls -la --time-style='+%F %T' out/.ninja_log out/.ninja_deps out/.n2_db* out/.siso* out/siso* 2>/dev/null | awk '{ print $5, $6, $7, $8 }'
echo "log: $(head -1 out/.ninja_log), $(wc -l < out/.ninja_log) lines, $(cut -f4 out/.ninja_log | sort -u | wc -l) outputs, $(grep -c 'out/host/linux-x86/bin/go/' out/.ninja_log) of them host tools' Go packages"
grep -m8 -aiE 'n2|siso|ninja_log|partial.?compile' out/soong.log 2>/dev/null | cut -c1-250
echo "== partial compile (its wrapper script is named after the product)"
ls -la --time-style='+%F %T' out/soong/use_partial_compile* 2>/dev/null | awk '{ print $5, $6, $7, $8 }' | head -12
for f in out/soong/use_partial_compile-"${p1#lineage_}".sh out/soong/use_partial_compile.sh; do [[ -f $f ]] && { echo "-- $f"; head -30 "$f"; }; done
grep -h -iE 'PARTIAL' "out/soong/soong.environment.used.$p1" out/soong/soong.environment.used* 2>/dev/null | sort -u | head -10
echo "-- rules in $p1's Soong graph whose command runs that wrapper"
for f in "out/soong/build.$p1.ninja" out/soong/build."$p1".[0-9]*.ninja; do [[ -f $f ]] && cat "$f"; done 2>/dev/null \
    | awk '/^rule /{ r = $2 } /use_partial_compile/ && r != "" { print r; r = "" }' | sed -E 's/[0-9]+$//' | sort | uniq -c | sort -rn | head -25
# Siso keeps its own logs and deps, so ninja's dry run would only see stale ones. Siso
# writes why it ran each step into out/siso_explain (rotated: .0 is the build before).
if [[ -e out/.siso_deps ]]; then
    echo "== siso runs the builds here: what it wrote about why it ran each step (newest first)"
    ex=$(ls -t out/siso_explain* 2>/dev/null | head -6)
    for f in $ex; do echo "  $(date -r "$f" '+%F %T') $f: $(wc -l < "$f") lines"; done
    for f in $ex; do
        echo "-- $f: kinds of line (paths shown as P), most frequent first"
        sed -E 's#[^ ]*/[^ ]*#P#g; s/[0-9]+/N/g' "$f" | cut -c1-160 | sort | uniq -c | sort -rn | head -12
        echo "-- $f: lines about the framework steps"
        for pat in "${pats[@]}"; do grep -F -- "$pat" "$f" | head -2 | cut -c1-600; done
        echo "-- $f: folders named most often (first 5 parts of the first path on a line)"
        grep -oE '(out|frameworks|packages|vendor|device|system|external|build|prebuilts|hardware|libcore|art)/[^ :,]*' "$f" \
            | awk -F/ '{ d = $1; for (i = 2; i <= (NF < 5 ? NF - 1 : 5); i++) d = d "/" $i; print d }' | sort | uniq -c | sort -rn | head -12
    done
else
    echo "== $p1: ninja -n -d explain (nothing runs, no log is written)"
    tm=(); [[ -x /usr/bin/time ]] && tm=(/usr/bin/time -f "(ninja: %e s, %M KB peak)")
    start=$SECONDS
    "${tm[@]}" timeout 1500 nice -n 10 "$ninja" -f "out/combined-$p1.ninja" -n -d explain "${targets[@]}" > "$T/explain" 2>&1
    echo "exit $?, $((SECONDS - start)) s; $(grep -c 'ninja explain:' "$T/explain") explain lines, $(grep -cE '^\[[0-9]+/[0-9]+\]' "$T/explain") steps would run"
    grep -E '^\(ninja:|^ninja: (error|warning|no work)' "$T/explain" | head -5
    # Root causes are the lines that don't just pass dirtiness up ("X is dirty because Y are dirty")
    awk '/^ninja explain: / && !/ is dirty because / && !/ is dirty$/ { sub(/^ninja explain: /, ""); print }' "$T/explain" > "$T/roots"
    echo "-- root causes ($(wc -l < "$T/roots") lines), by kind and by folder"
    awk '{
        k = "other"; p = ""
        if ($0 ~ /^command line changed for /)            { k = "command line changed";         p = $5 }
        else if ($0 ~ /^command line not found in log for /) { k = "command line not in the log"; p = $8 }
        else if ($0 ~ /^output .* older than most recent input /) { k = "older than an input"; p = $2 }
        else if ($0 ~ /^recorded mtime of .* older than most recent input /) { k = "recorded mtime older than an input"; p = $4 }
        else if ($0 ~ /^deps for .* are missing/)          { k = "deps missing";                 p = $3 }
        else if ($0 ~ / doesn.t exist$/)                   { k = "output missing";               p = $2 }
        gsub(/\x27/, "", p); n = split(p, a, "/"); d = a[1]; for (i = 2; i <= (n < 5 ? n - 1 : 5); i++) d = d "/" a[i]
        print k " | " d
    }' "$T/roots" | sort | uniq -c | sort -rn | head -30
    echo "-- inputs newer than what was built from them, most often named"
    grep -oE 'older than most recent input [^ ]+' "$T/roots" | awk '{ print $6 }' | sort | uniq -c | sort -rn | head -20
    echo "-- command line changed: the first 25 (deepest first)"
    grep '^command line changed' "$T/roots" | head -25 | cut -c1-300
    echo "-- other root causes: the first 25 that aren't about host tools' Go packages"
    grep -v '^command line changed' "$T/roots" | grep -v '/bin/go/' | head -25 | cut -c1-300
    echo "-- what it says about the steps themselves"
    for t in "${targets[@]}"; do grep -F -- "$t" "$T/explain" | grep -v ' is dirty$' | head -2 | cut -c1-400; done

fi

# One load of each product's graph: the final command of every step, one line each
commands() { timeout 900 nice -n 10 "$ninja" -f "out/combined-$1.ninja" -t commands -s "${targets[@]}" 2>/dev/null; }
if [[ ${#others[@]} -gt 0 ]]; then
    commands "$p1" > "$T/c-$p1"
    for p2 in "${others[@]}"; do
        echo "== the same steps' commands: $p1 against $p2 (words only one side has)"
        commands "$p2" > "$T/c-$p2"
        n1=$(wc -l < "$T/c-$p1") n2=$(wc -l < "$T/c-$p2")
        [[ $n1 = "${#targets[@]}" && $n2 = "${#targets[@]}" ]] || echo "(got $n1 and $n2 commands for ${#targets[@]} steps; the lines may not pair up)"
        for i in "${!targets[@]}"; do
            t=${targets[$i]}
            sed -n "$((i + 1))p" "$T/c-$p1" | tr ' ' '\n' | sort -u > "$T/a"
            sed -n "$((i + 1))p" "$T/c-$p2" | tr ' ' '\n' | sort -u > "$T/b"
            if cmp -s "$T/a" "$T/b"; then
                echo "-- ${t##*/}: same command"
            else
                echo "-- ${t##*/}: $p1 only: $(comm -23 "$T/a" "$T/b" | head -15 | cut -c1-200 | tr '\n' ' ')"
                echo "   ${t##*/}: $p2 only: $(comm -13 "$T/a" "$T/b" | head -15 | cut -c1-200 | tr '\n' ' ')"
            fi
        done
    done
fi
echo "BUILD_EXPLAIN_DONE"
