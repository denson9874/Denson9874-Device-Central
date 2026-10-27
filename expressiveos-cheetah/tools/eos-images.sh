#!/usr/bin/env bash
# Build ExpressiveOS for cheetah (Pixel 7 Pro), start to finish, in its own tree (setup.sh
# made it; never ~/evolution or ~/derpfest):
#   1. prepare.sh: Git LFS files, the kit's tree patches, the newest cached firmware;
#   2. eos-keys-check.sh tree and vars: ExpressiveOS's own keys are in
#      vendor/evolution-priv/keys and the build will sign with them, not with test keys
#      or Evolution X's;
#   3. the kits: ksu/apply-ksu.sh, viper4android/apply-v4a.sh, bootanimation/apply-bootanim.sh;
#   4. the name and version the build will carry (dumpvars), and a record of its sources
#      in out/eos/ (the tree's repo manifest -r, each patched project's upstream revision,
#      the kit's commit; ksu-images.sh adds the kernel's);
#   5. ksu/tools/ksu-images.sh: lunch, build_kernel, kernelsu.ko, the two make passes;
#   6. eos-verify.sh: the finished build, offline.
# Only a run that gets through all six writes out/eos/build.ok, which eos-pack.sh needs.
# Holds ~/.evolution-tree.lock (the Evolution X routines' lock) and ~/.expressiveos.lock
# for the whole run, and first waits for any build already running. Everything also goes
# to ~/expressiveos-build.log (the one before is kept as .1); the last line is
# BUILD_EXIT=0 or BUILD_EXIT=1.
#
#   eos-images.sh [top]                  # default ~/expressiveos
#   KERNEL_ONLY=1 eos-images.sh [top]    # steps 1-4, then build_kernel and kernelsu.ko only
#   EOS_KERNEL_SYNC=1 eos-images.sh      # sync the kernel source again (otherwise only the
#                                        # first build syncs it: it follows branch heads)
set -o pipefail
self=$(readlink -f -- "$0")
# Until the build's own trap below, a failure ends with the status line too, except while
# run_locked's marker is there: then the run waiting for the locks prints it
trap '[[ $? = 0 || -e "${EOS_STARTED:-}" ]] || echo "BUILD_EXIT=1"' EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$self")/../lib.sh"
[[ $# -le 1 ]] || fail "usage: eos-images.sh [top]"
eos_top "${1:-}"
# Run alone, this runs again under eos_lock and exits with it; that run carries on here
run_locked BUILD_EXIT=1 "$self" "$top"
log=$HOME/expressiveos-build.log
if [[ "${EOS_LOGGING:-}" != 1 ]]; then
    # Holding the locks now: no other run is writing the log
    [[ ! -f $log ]] || mv -f -- "$log" "$log.1"
    trap - EXIT     # the logged run prints the status line
    EOS_LOGGING=1 bash "$self" "$top" 2>&1 | tee -- "$log"
    exit "${PIPESTATUS[0]}"
fi

done=0
trap 'rc=$?; [[ $done = 1 ]] || { echo "BUILD_EXIT=1"; exit $(( rc ? rc : 1 )); }' EXIT
eos_top "${1:-}"
clean_env
cd "$top" || fail "can't cd to $top"
PATH=$HOME/bin:$PATH
rm -f -- out/eos/build.ok
# patches/device_google_pantah/0010 sets it too; apply-bootanim.sh checks for it here
export EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
echo "== ExpressiveOS $EOS_VERSION $EOS_BUILD_TYPE for cheetah in $top, $(date -u '+%F %T') UTC"
wait_builds
step() {   # step <title> <regex> <command>...: run it; its last line must match <regex>
    local title=$1 want=$2 rc=0
    shift 2
    echo "== $title"
    "$@" 2>&1 | tee -- "$work/step.log" || rc=$?
    ((rc == 0)) || fail "$title: ${1##*/} failed"
    tail -1 "$work/step.log" | grep -qxE -- "$want" || fail "$title: ${1##*/} didn't end with $want"
}
work=$(mktemp -d "${TMPDIR:-/tmp}/eos-images.XXXXXX")
trap 'rc=$?; rm -rf -- "$work"; [[ $done = 1 ]] || { echo "BUILD_EXIT=1"; exit $(( rc ? rc : 1 )); }' EXIT

step "prepare.sh" 'PREPARE_OK.*' "$kit/prepare.sh" "$top"
step "keys: tree" 'KEYS_CHECK=(OK|UNPINNED)' "$kit/tools/eos-keys-check.sh" tree "$top"
step "keys: build variables" 'KEYS_CHECK=(OK|UNPINNED)' "$kit/tools/eos-keys-check.sh" vars "$top"
step "KernelSU Next" 'APPLY_KSU_OK.*' "$kit/ksu/apply-ksu.sh" "$top"
step "ViPER4Android" 'V4A_APPLY=OK.*' "$kit/viper4android/apply-v4a.sh" "$top"
step "boot animation" 'BOOTANIM_APPLY=OK.*' "$kit/bootanimation/apply-bootanim.sh" "$top"

echo "== identity"
vars=$(dump_vars LINEAGE_VERSION EVO_VERSION EVO_BUILD_TYPE TARGET_DEVICE TARGET_BUILD_VARIANT) || fail "dumpvars failed"
name=$(var_of "$vars" LINEAGE_VERSION)
[[ "$name" =~ ^ExpressiveOS-17\.[0-9]+-[0-9]{8}-cheetah-${EOS_VERSION//./\\.}-$EOS_BUILD_TYPE$ ]] \
    || fail "the build would be named '$name', not ExpressiveOS-17.x-<date>-cheetah-$EOS_VERSION-$EOS_BUILD_TYPE (patches/vendor_lineage/0001)"
for kv in "EVO_VERSION=$EOS_VERSION" "EVO_BUILD_TYPE=$EOS_BUILD_TYPE" TARGET_DEVICE=cheetah "TARGET_BUILD_VARIANT=${EOS_LUNCH##*-}"; do
    [[ "$(var_of "$vars" "${kv%%=*}")" = "${kv#*=}" ]] || fail "${kv%%=*} is '$(var_of "$vars" "${kv%%=*}")', want '${kv#*=}'"
done
echo "OK: $name (the date is the build's own)"

echo "== sources"
mkdir -p -- out/eos
repo manifest -r -o out/eos/manifest.xml >/dev/null || fail "repo manifest -r failed"
# Collected first, outside any redirection: a fail here must end the build with its status line
projects=()
for d in "$kit"/patches/* "$kit"/ksu/patches/* "$kit"/viper4android/patches/*; do
    [[ -d $d ]] || continue
    p=$(patch_project "$d")
    [[ -d $p ]] || fail "${d#"$kit"/} patches $p, which this tree doesn't have"
    head=$(git -C "$p" rev-parse HEAD) || fail "can't read $p's HEAD"
    projects+=("  $p $(git -C "$p" rev-parse "m/$EOS_MANIFEST_BRANCH" 2>/dev/null || echo unknown) $head")
done
{
    echo "ExpressiveOS $EOS_VERSION $EOS_BUILD_TYPE, cheetah, $(date -u '+%F %T') UTC"
    # A copy the runner installed (rsync, no .git) names the commit it came from
    echo "kit: $(git -C "$kit" rev-parse HEAD 2>/dev/null || sed -n '1s/^/installed from /p' "$kit/INSTALLED_FROM" 2>/dev/null || echo "not a git checkout")$([[ -z "$(git -C "$kit" status --porcelain -- . 2>/dev/null)" ]] || echo " (with local changes)")"
    echo "KernelSU Next: $(sed -n 's/^version=//p' "$kit/ksu/ksu.conf") $(sed -n 's/^src_commit=//p' "$kit/ksu/ksu.conf")"
    echo "Patched projects: upstream revision (repo's m/$EOS_MANIFEST_BRANCH), then HEAD with the kit's commits"
    printf '%s\n' "${projects[@]}" | sort -u
} > out/eos/sources.txt
cat out/eos/sources.txt

# Kernel source: synced by the first build only, unless asked (it follows branch heads)
if [[ "${EOS_KERNEL_SYNC:-0}" != 1 && -d out-kernel/google/gs-6.1/.repo ]]; then
    export SKIP_KERNEL_SYNC=1
    echo "note: building the kernel source already in out-kernel/ (EOS_KERNEL_SYNC=1 syncs it)"
else
    unset SKIP_KERNEL_SYNC
fi
step "make (ksu-images.sh)" 'MAKE_EXIT=0' "$kit/ksu/tools/ksu-images.sh" "$top"
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    echo "OK: kernel only (KERNEL_ONLY=1): nothing to pack"
    done=1; echo "BUILD_EXIT=0"; exit 0
fi
step "verify (eos-verify.sh)" 'VERIFY=OK' "$kit/tools/eos-verify.sh" "$top"
zip=$(sed -n 's/^VERIFIED //p' "$work/step.log" | tail -1)
[[ -f $zip ]] || fail "eos-verify.sh named no package"
echo "$(sha256sum -- "$zip" | cut -d' ' -f1)  ${zip##*/}" > out/eos/build.ok
echo "OK: $(cat out/eos/build.ok)"
done=1
echo "BUILD_EXIT=0"
