#!/usr/bin/env bash
# Read-only: why a product's next build would redo the big framework steps (the API
# stubs, SystemUI, Settings, services), from ninja's own dry run of that product's
# build graph against the out/ the last build left: `ninja -n -d explain` runs no
# command and writes no log. With other products, it also compares their commands for
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
pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null && fail "a build is running; try again when it's done"
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

echo "== $p1: ninja -n -d explain (nothing runs, no log is written)"
tm=(); [[ -x /usr/bin/time ]] && tm=(/usr/bin/time -f "(ninja: %e s, %M KB peak)")
start=$SECONDS
"${tm[@]}" timeout 1500 nice -n 10 "$ninja" -f "out/combined-$p1.ninja" -n -d explain "${targets[@]}" > "$T/explain" 2>&1
echo "exit $?, $((SECONDS - start)) s; $(grep -c 'ninja explain:' "$T/explain") explain lines, $(grep -cE '^\[[0-9]+/[0-9]+\]' "$T/explain") steps would run"
grep -E '^\(ninja:|^ninja: (error|warning|no work)' "$T/explain" | head -5
echo "-- reasons, counted"
grep -oE 'ninja explain: (command line changed|output .* older than most recent input|.* is dirty|.* has no in-edge and is missing|.* doesn.t exist|recorded mtime of .* older than most recent input|.*)' "$T/explain" \
    | sed -E 's/^ninja explain: //; s/^(output|recorded mtime of) .* older than most recent input.*/\1 ... older than most recent input/; s/^command line changed for .*/command line changed/; s/^.* is dirty$/(dirty because of an input)/; s/^.* has no in-edge and is missing$/missing source file/' \
    | sort | uniq -c | sort -rn | head -12
echo "-- the first 60 explain lines (ninja explains the deepest inputs first: these are the causes)"
grep 'ninja explain:' "$T/explain" | grep -v ' is dirty$' | head -60 | cut -c1-400
echo "-- inputs that are newer than what was built from them, most often named"
grep -oE 'older than most recent input [^ ]+' "$T/explain" | awk '{ print $6 }' | sort | uniq -c | sort -rn | head -25
echo "-- what it says about the steps themselves"
for t in "${targets[@]}"; do grep -F -- "$t" "$T/explain" | grep -v ' is dirty$' | head -2 | cut -c1-400; done

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
