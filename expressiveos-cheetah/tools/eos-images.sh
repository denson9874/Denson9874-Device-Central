#!/usr/bin/env bash
# Build ExpressiveOS for a phone (EOS_DEVICE, cheetah unless set; devices/<device>.conf),
# start to finish, in its own tree (setup.sh made it; never ~/evolution or ~/derpfest):
#   1. prepare.sh: Git LFS files, the kit's tree patches, the phone's firmware;
#   2. eos-keys-check.sh tree and vars: ExpressiveOS's own keys are in
#      vendor/evolution-priv/keys and the build will sign with them, not with test keys
#      or Evolution X's;
#   3. the kits: ksu/fetch-ksu.sh (checks what it downloaded before, fetches only what's new
#      in ksu.conf, and KernelSU Next's current risk rules when GitHub answers) and
#      apply-ksu.sh on a phone with EOS_KSU=lkm, viper4android/apply-v4a.sh on one with
#      EOS_V4A=1, bootanimation/apply-bootanim.sh, wallpapers/apply-wallpapers.sh;
#   4. the name and version the build will carry (dumpvars), and a record of its sources
#      in EOS_STATE (out/eos/ for cheetah, out/eos-<device>/ for the others: the tree's repo
#      manifest -r, each patched project's upstream revision, the kit's commit, and the
#      Google files that aren't in the manifest; ksu-images.sh adds the kernel's);
#   5. ksu/tools/ksu-images.sh: lunch, build_kernel, kernelsu.ko, the two make passes (as
#      many of them as the phone's EOS_KERNEL and EOS_KSU need);
#   6. eos-verify.sh: the finished build, offline.
# Only a run that gets through all six writes build.ok and target-files.ok there (the
# sha256 of the OTA package and of the target-files zip kept with it), which eos-pack.sh needs.
# Holds ~/.evolution-tree.lock (the Evolution X routines' lock) and ~/.expressiveos.lock
# for the whole run, and first waits for any build already running. Everything also goes
# to EOS_BUILD_LOG (~/expressiveos-build.log for cheetah, ~/expressiveos-build-<device>.log
# for the others; the one before is kept as .1); the last line is BUILD_EXIT=0 or BUILD_EXIT=1.
#
#   eos-images.sh [top]                  # default ~/expressiveos
#   EOS_DEVICE=husky eos-images.sh       # another phone (devices/husky.conf)
#   KERNEL_ONLY=1 eos-images.sh [top]    # steps 1-4, then build_kernel and kernelsu.ko only
#   EOS_KERNEL_SYNC=1 eos-images.sh      # sync the kernel source to pins/kernel.xml again
#                                        # (otherwise only the first build syncs it)
#   EOS_INSTALLCLEAN=1 eos-images.sh     # start the make with m installclean (ksu-images.sh)
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
log=$EOS_BUILD_LOG
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
rm -f -- "$EOS_STATE/build.ok" "$EOS_STATE/target-files.ok"
# patches/device_google_pantah/0010 sets it too; apply-bootanim.sh checks for it here
export EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
echo "== ExpressiveOS $EOS_VERSION $EOS_BUILD_TYPE for $EOS_DEVICE in $top, $(date -u '+%F %T') UTC"
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
# KernelSU Next and ViPER4Android only where devices/<device>.conf turns them on: there's no
# android16-6.12 KernelSU Next module yet, and ViPER4Android needs gs201's HIDL effect HAL
if [[ $EOS_KSU = lkm ]]; then
    step "KernelSU Next downloads" 'FETCH_KSU_OK.*' "$kit/ksu/fetch-ksu.sh"
    step "KernelSU Next" 'APPLY_KSU_OK.*' "$kit/ksu/apply-ksu.sh" "$top"
else
    echo "== KernelSU Next: off for $EOS_DEVICE (EOS_KSU=$EOS_KSU, devices/$EOS_DEVICE.conf): the build's own init_boot, no root"
fi
if [[ $EOS_V4A = 1 ]]; then
    step "ViPER4Android" 'V4A_APPLY=OK.*' "$kit/viper4android/apply-v4a.sh" "$top"
else
    echo "== ViPER4Android: off for $EOS_DEVICE (EOS_V4A=$EOS_V4A, devices/$EOS_DEVICE.conf)"
    # It stages nothing then, but brings an older kit's viper4android.mk (every product's) up
    # to the one that adds ViPER4Android to the EOS_V4A=1 phones only
    step "ViPER4Android's makefile" 'V4A_APPLY=OK.*' "$kit/viper4android/apply-v4a.sh" "$top"
fi
step "boot animation" 'BOOTANIM_APPLY=OK.*' "$kit/bootanimation/apply-bootanim.sh" "$top"
step "wallpapers" 'WALLPAPERS_APPLY=OK.*' "$kit/wallpapers/apply-wallpapers.sh" "$top"

echo "== identity"
# A phone with KernelSU Next or ViPER4Android off mustn't get them from the one tree all the
# phones share: what an earlier cheetah build put there (vendor/extra) is still in it
pk=()
[[ $EOS_KSU = lkm && $EOS_V4A = 1 ]] || pk=(PRODUCT_PACKAGES)
vars=$(dump_vars LINEAGE_VERSION EVO_VERSION EVO_BUILD_TYPE TARGET_DEVICE TARGET_BUILD_VARIANT "${pk[@]}") || fail "dumpvars failed"
name=$(var_of "$vars" LINEAGE_VERSION)
[[ "$name" =~ ^ExpressiveOS-17\.[0-9]+-[0-9]{8}-$EOS_DEVICE-${EOS_VERSION//./\\.}-$EOS_BUILD_TYPE$ ]] \
    || fail "the build would be named '$name', not ExpressiveOS-17.x-<date>-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE (patches/vendor_lineage/0001)"
for kv in "EVO_VERSION=$EOS_VERSION" "EVO_BUILD_TYPE=$EOS_BUILD_TYPE" "TARGET_DEVICE=$EOS_DEVICE" "TARGET_BUILD_VARIANT=${EOS_LUNCH##*-}"; do
    [[ "$(var_of "$vars" "${kv%%=*}")" = "${kv#*=}" ]] || fail "${kv%%=*} is '$(var_of "$vars" "${kv%%=*}")', want '${kv#*=}'"
done
if (( ${#pk[@]} )); then
    pkgs=" $(var_of "$vars" PRODUCT_PACKAGES) "
    [[ $EOS_KSU = lkm || $pkgs != *" KernelSUNext "* ]] \
        || fail "$EOS_LUNCH would install KernelSUNext, but devices/$EOS_DEVICE.conf has EOS_KSU=$EOS_KSU: its device tree mustn't add the KernelSU Next manager"
    for m in ViPER4Android libv4a_re; do
        [[ $EOS_V4A = 1 || $pkgs != *" $m "* ]] \
            || fail "$EOS_LUNCH would install $m, but devices/$EOS_DEVICE.conf has EOS_V4A=0: vendor/extra/product.mk (apply-v4a.sh, from a cheetah build) has every product inherit viper4android.mk, which must add it for the phones with EOS_V4A=1 only"
    done
    off=()
    [[ $EOS_KSU = lkm ]] || off+=("KernelSU Next")
    [[ $EOS_V4A = 1 ]] || off+=(ViPER4Android)
    echo "OK: $EOS_LUNCH installs no ${off[0]}${off[1]:+ or ${off[1]}}, as devices/$EOS_DEVICE.conf says"
fi
echo "OK: $name (the date is the build's own)"

echo "== sources"
# Only ExpressiveOS's manifest, as GitHub has it, is built (setup.sh syncs to it; the kit's
# commits for projects that aren't ExpressiveOS's own repos sit on top)
mf=$(tree_manifest) || fail "the tree isn't on ExpressiveOS's manifest (above)"
pins_check "$top" "$EOS_MANIFEST_BRANCH" "$mf" \
    || fail "the tree isn't on ExpressiveOS's manifest's commits (above): run setup.sh, which syncs it back to them"
mkdir -p -- "$EOS_STATE"
repo manifest -r -o "$EOS_STATE/manifest.xml" >/dev/null || fail "repo manifest -r failed"
# Collected first, outside any redirection: a fail here must end the build with its status line
projects=()
while IFS= read -r d; do
    p=$(patch_project "$d")
    [[ -d $p ]] || fail "${d#"$kit"/} patches $p, which this tree doesn't have"
    head=$(git -C "$p" rev-parse HEAD) || fail "can't read $p's HEAD"
    projects+=("  $p $(git -C "$p" rev-parse "m/$EOS_MANIFEST_BRANCH" 2>/dev/null || echo unknown) $head")
done < <(kit_patch_dirs)
# The Pixel 11s build with Google's own files, which the manifest doesn't name: their vendor
# blobs (prepare.sh copies the build server's repo of them) and vendor/google/<device>-images
# (prepare.sh has the device tree's extract-images.sh make it from the factory image zip)
google=()
if [[ $EOS_FIRMWARE_MODE = images ]]; then
    # kodiak's, grizzly's and cubs' BoardConfig.mk take Espada's kernel (and its
    # vendor_kernel_boot) whenever vendor/google/espada-kernel is in the tree: ExpressiveOS
    # ships Google's stock GKI, which only SHA256SUMS records
    [[ ! -e vendor/google/espada-kernel ]] \
        || fail "vendor/google/espada-kernel is in the tree: the Pixel 11 trees would build with its kernel, not Google's stock one. Move it out of $top"
    project_ok "$top/$EOS_VENDOR_DIR"
    head=$(git -C "$EOS_VENDOR_DIR" rev-parse HEAD) || fail "can't read $EOS_VENDOR_DIR's HEAD"
    imgs=vendor/google/$EOS_DEVICE-images
    from=$(sed -n 1p -- "$imgs/.eos-source" 2>/dev/null) || from=
    [[ -n $from ]] || fail "no $imgs/.eos-source: prepare.sh writes it once $imgs is made"
    [[ -f $imgs/SHA256SUMS ]] || fail "no $imgs/SHA256SUMS ($EOS_DEVICE_TREE/extract-images.sh writes it)"
    sums=$(sha256sum -- "$imgs/SHA256SUMS" | cut -d' ' -f1) || fail "can't read $imgs/SHA256SUMS"
    google+=("  $EOS_VENDOR_DIR $head (the build server's repo, not in the manifest)"
             "  $imgs from $from (factory image zip, bytes, mtime), SHA256SUMS sha256 $sums")
fi
{
    echo "ExpressiveOS $EOS_VERSION $EOS_BUILD_TYPE, $EOS_DEVICE, $(date -u '+%F %T') UTC"
    # A copy the runner installed (rsync, no .git) names the commit it came from
    echo "kit: $(git -C "$kit" rev-parse HEAD 2>/dev/null || sed -n '1s/^/installed from /p' "$kit/INSTALLED_FROM" 2>/dev/null || echo "not a git checkout")$([[ -z "$(git -C "$kit" status --porcelain -- . 2>/dev/null)" ]] || echo " (with local changes)")"
    if [[ $EOS_KSU = lkm ]]; then
        echo "KernelSU Next: $(sed -n 's/^version=//p' "$kit/ksu/ksu.conf") $(sed -n 's/^src_commit=//p' "$kit/ksu/ksu.conf")"
        echo "NeoZygisk (product/etc/eos/zygisk-provider.zip): $(sed -n 's/^zygisk_version=//p' "$kit/ksu/ksu.conf") $(sed -n 's/^zygisk_src_commit=//p' "$kit/ksu/ksu.conf"), LSPlt $(sed -n 's/^zygisk_lsplt_commit=//p' "$kit/ksu/ksu.conf")"
    else
        echo "KernelSU Next: none (EOS_KSU=$EOS_KSU)"
    fi
    echo "Patched projects: upstream revision (repo's m/$EOS_MANIFEST_BRANCH), then HEAD with the kit's commits"
    printf '%s\n' "${projects[@]}" | sort -u
    if (( ${#google[@]} )); then
        echo "Google's files, not in the manifest:"
        printf '%s\n' "${google[@]}"
    fi
} > "$EOS_STATE/sources.txt"
cat "$EOS_STATE/sources.txt"

# Kernel source (EOS_KERNEL=gs-6.1): ksu-images.sh syncs it to pins/kernel.xml when it's
# missing or EOS_KERNEL_SYNC=1, and checks it's on them otherwise
step "make (ksu-images.sh)" 'MAKE_EXIT=0' "$kit/ksu/tools/ksu-images.sh" "$top"
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    echo "OK: kernel only (KERNEL_ONLY=1): nothing to pack"
    done=1; echo "BUILD_EXIT=0"; exit 0
fi
step "verify (eos-verify.sh)" 'VERIFY=OK' "$kit/tools/eos-verify.sh" "$top"
zip=$(sed -n 's/^VERIFIED //p' "$work/step.log" | tail -1)
[[ -f $zip ]] || fail "eos-verify.sh named no package"
tf=$(tf_zip)
[[ -f $tf ]] || fail "no $tf (eos-verify.sh checked it)"
# The target-files eos-verify.sh checked against the package, for eos-pack.sh (written
# first: build.ok is what says the run finished)
echo "$(sha256sum -- "$tf" | cut -d' ' -f1)  ${tf##*/}" > "$EOS_STATE/target-files.ok"
echo "$(sha256sum -- "$zip" | cut -d' ' -f1)  ${zip##*/}" > "$EOS_STATE/build.ok"
echo "OK: $(cat "$EOS_STATE/build.ok")"
echo "OK: target-files $(cat "$EOS_STATE/target-files.ok") ($(stat -c %s -- "$tf") bytes)"
done=1
echo "BUILD_EXIT=0"
