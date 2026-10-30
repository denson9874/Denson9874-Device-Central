#!/usr/bin/env bash
# Put ViPER4Android RE into an ExpressiveOS cheetah tree (idempotent: a second run
# changes nothing):
#   1. fetch-v4a.sh: the pinned app APK and driver library, verified;
#   2. stage them with tree/ into vendor/extra/viper4android (Android.bp removed
#      first and written last, so Soong never sees it without its files);
#   3. vendor/extra/product.mk inherits viper4android.mk (Evolution X's vendor_evolution,
#      checked out at vendor/lineage, has config/common.mk inherit vendor/extra/product.mk);
#   4. patches/frameworks_av/*.patch in frameworks/av (lib.sh's am_patches: commits of
#      ExpressiveOS's frameworks_av fork already, else local commits by git am --3way);
#   5. tools/v4a-check.sh tree: the pre-build guards.
# Run it on every build, after the tree's own patches (repo sync drops local commits).
# A phone with EOS_V4A=0 in its devices/<device>.conf (all but cheetah) gets none of this:
# the run touches nothing and ends with V4A_APPLY=OK skipped.
# Never on the Evolution X tree (~/evolution): its vendor/extra and frameworks/av are
# shared by every Evolution X build there. Nothing is written through a symlink that
# leads out of the tree.
#
#   apply-v4a.sh [top]      # default ~/expressiveos
set -euo pipefail
done=0 work=
cleanup() {
    local rc=$?
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "V4A_APPLY=FAIL"
    exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
# shellcheck source=v4a.conf
source "$here/v4a.conf" || fail "can't read $here/v4a.conf"

arg=${1:-$HOME/expressiveos}
[[ $# -le 1 ]] || fail "usage: apply-v4a.sh [top]"
# Only for a phone whose devices/<device>.conf has EOS_V4A=1 (EOS_DEVICE, cheetah unless set;
# lib.sh reads it). For the others this leaves the tree alone: what a cheetah run staged in
# vendor/extra stays, and tree/viper4android.mk adds nothing to their products
read -r v4a_dev v4a_on <<<"$(source "$here/../lib.sh" && printf '%s %s' "$EOS_DEVICE" "$EOS_V4A")"
[[ -n ${v4a_dev:-} && ${v4a_on:-} =~ ^[01]$ ]] || fail "can't read this phone's EOS_V4A (lib.sh, devices/<device>.conf)"
if [[ $v4a_on = 0 ]]; then
    done=1
    echo "V4A_APPLY=OK skipped (ViPER4Android is off for $v4a_dev)"
    exit 0
fi
not_evo() {
    [[ "${1%/}" != */evolution && "${1%/}" != evolution && "${1%/}" != */derpfest && "${1%/}" != derpfest ]] \
        || fail "$arg is the Evolution X or DerpFest tree ($1); ViPER4Android RE is for the ExpressiveOS tree only"
}
not_evo "$arg"
[[ -d "$arg" ]] || fail "no tree at $arg"
top="$(cd "$arg" && pwd -P)"
not_evo "$top"
evo='' derp=''
if evo="$(cd "$HOME/evolution" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$evo" ]] || fail "$arg is the Evolution X tree (~/evolution); ViPER4Android RE is for the ExpressiveOS tree only"
fi
if derp="$(cd "$HOME/derpfest" 2>/dev/null && pwd -P)"; then
    [[ "$top" != "$derp" ]] || fail "$arg is the DerpFest tree (~/derpfest); ViPER4Android RE is for the ExpressiveOS tree only"
fi
[[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
av="$top/frameworks/av"
[[ -d "$av" && "$(cd "$av" && git rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$av" && pwd -P)" ]] \
    || fail "$top isn't an Android tree (frameworks/av isn't a git project)"
# What this script writes must stay in this tree, even when a folder in it is a symlink
# (vendor/extra or frameworks/av linked from ~/evolution would change the Evolution X tree).
in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and not in ~/evolution or ~/derpfest
    local r
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    [[ -z "$evo" || ( "$r" != "$evo" && "$r" != "$evo"/* ) ]] || fail "${1#"$top"/} leads into the Evolution X tree ($r)"
    [[ -z "$derp" || ( "$r" != "$derp" && "$r" != "$derp"/* ) ]] || fail "${1#"$top"/} leads into the DerpFest tree ($r)"
}
for p in vendor/extra vendor/extra/viper4android vendor/extra/product.mk frameworks/av; do in_top "$top/$p"; done
gd=$(git -C "$av" rev-parse --absolute-git-dir) && gd=$(realpath -- "$gd") || fail "can't find frameworks/av's git folder"
[[ -z "$evo" || ( "$gd" != "$evo" && "$gd" != "$evo"/* ) ]] || fail "frameworks/av's git folder is in the Evolution X tree ($gd)"
[[ -z "$derp" || ( "$gd" != "$derp" && "$gd" != "$derp"/* ) ]] || fail "frameworks/av's git folder is in the DerpFest tree ($gd)"
# An am or rebase someone else left running in frameworks/av is theirs to finish: step 4's
# cleanup (am --abort) would drop the commits it already made
[[ ! -e "$gd/rebase-apply" && ! -e "$gd/rebase-merge" ]] \
    || fail "frameworks/av has a git am or rebase in progress ($gd/rebase-apply or rebase-merge); finish it or abort it yourself, then run this again"
echo "== ViPER4Android RE -> $top"

# 1. Fetch and verify into a fresh folder
work=$(mktemp -d "${TMPDIR:-/tmp}/v4a-apply.XXXXXX")
"$here/fetch-v4a.sh" --out "$work/files" || fail "fetch-v4a.sh failed"

# 2. Stage. The folder belongs to this kit: anything in it that the kit doesn't ship goes.
dest="$top/vendor/extra/viper4android"
mkdir "$work/stage"
cp -- "$work/files"/* "$here/tree"/* "$work/stage/"
chmod 0644 "$work/stage"/*
changed=0
for f in "$work/stage"/*; do
    cmp -s -- "$f" "$dest/${f##*/}" || changed=1
done
stale=()
if [[ -d "$dest" ]]; then
    while IFS= read -r -d '' f; do
        n=${f##*/}
        [[ -e "$work/stage/$n" ]] && continue
        [[ -f "$f" || -L "$f" ]] || fail "$dest/$n isn't a file this kit put there; move it out of the way"
        stale+=("$n"); changed=1
    done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0)
fi
if [[ $changed = 0 ]]; then
    echo "unchanged: vendor/extra/viper4android"
else
    mkdir -p -- "$dest"
    rm -f -- "$dest/Android.bp"
    for n in ${stale[@]+"${stale[@]}"}; do
        rm -f -- "$dest/$n"; echo "removed: vendor/extra/viper4android/$n"
    done
    for f in "$work/stage"/*; do
        n=${f##*/}
        [[ "$n" != Android.bp ]] || continue
        cmp -s -- "$f" "$dest/$n" && continue
        cp -p -- "$f" "$dest/.$n.tmp" || fail "can't stage $n in $dest (Android.bp stays out until a run succeeds)"
        mv -f -- "$dest/.$n.tmp" "$dest/$n" || fail "can't stage $n in $dest (Android.bp stays out until a run succeeds)"
        echo "staged: vendor/extra/viper4android/$n"
    done
    cp -p -- "$work/stage/Android.bp" "$dest/.Android.bp.tmp" || fail "can't stage Android.bp in $dest"
    mv -f -- "$dest/.Android.bp.tmp" "$dest/Android.bp" || fail "can't stage Android.bp in $dest"
    echo "staged: vendor/extra/viper4android/Android.bp (last)"
fi

# 3. vendor/extra/product.mk (ExpressiveOS's own; read for every phone the tree builds, so
#    viper4android.mk itself adds ViPER4Android only for the EOS_V4A=1 products)
pm="$top/vendor/extra/product.mk"
line='$(call inherit-product, vendor/extra/viper4android/viper4android.mk)'
where=$([[ ! -f "$pm" ]] || want="$line" awk -f "$here/tools/mk-line.awk" -- "$pm") || fail "can't read $pm"
if [[ $where = top ]]; then
    echo "unchanged: vendor/extra/product.mk"
elif [[ $where = nested ]]; then
    fail "vendor/extra/product.mk has '$line' only inside an ifeq/ifdef/define block, which may be false for $v4a_dev; move it out to the top level"
elif [[ -f "$pm" ]]; then
    [[ -z "$(tail -c1 -- "$pm")" ]] || echo >> "$pm"
    printf '%s\n' "# ViPER4Android RE (expressiveos-cheetah/viper4android)" "$line" >> "$pm"
    echo "added to vendor/extra/product.mk: $line"
else
    printf '%s\n' \
        "# ExpressiveOS additions. vendor/lineage/config/common.mk inherits this file when it exists." \
        "# Not a repo project, so repo sync leaves it alone." \
        "" \
        "# ViPER4Android RE (expressiveos-cheetah/viper4android)" \
        "$line" > "$pm"
    echo "created vendor/extra/product.mk: $line"
fi

# 4. frameworks/av patches: lib.sh's am_patches, as apply.sh puts the tree's own. On
# ExpressiveOS's manifest frameworks/av is ExpressiveOS's frameworks_av fork, which has them as
# commits already: they're only checked there, and a missing or edited one fails (README.md)
( source "$here/../lib.sh" && am_patches "$av" frameworks_av "$here"/patches/frameworks_av/*.patch )

# 5. Pre-build guards
"$here/tools/v4a-check.sh" tree "$top" || fail "the tree checks above failed; don't build"
done=1
echo "V4A_APPLY=OK app=$V4A_APP_VERSION fx=$V4A_FX_VERSION"
