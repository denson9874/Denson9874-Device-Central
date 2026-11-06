#!/usr/bin/env bash
# Build ExpressiveOS for a phone (EOS_DEVICE, cheetah unless set; devices/<device>.conf),
# start to finish, in its own tree (setup.sh made it):
#   1. prepare.sh: Git LFS files, the kit's tree patches, the phone's firmware;
#   2. eos-keys-check.sh tree and vars: ExpressiveOS's own keys are in the tree's key folder
#      (vendor/expressiveos-priv/keys; vendor/evolution-priv/keys before 1.1's move) and the
#      build will sign with them, not with test keys or Evolution X's;
#   3. the kits: viper4android/apply-v4a.sh on a phone with EOS_V4A=1,
#      bootanimation/apply-bootanim.sh, wallpapers/apply-wallpapers.sh,
#      launcher/apply-launcher.sh (Expressive Launcher as default Home and Recents app);
#   4. the name and version the build will carry (dumpvars), and a record of its sources
#      in EOS_STATE (out/eos/ for cheetah, out/eos-<device>/ for the others: the tree's repo
#      manifest -r, each patched project's upstream revision, the kit's commit, and the
#      Google files that aren't in the manifest; eos-make.sh adds the kernel's);
#   5. tools/eos-make.sh: lunch, build_kernel (on a phone with EOS_KERNEL=gs-6.1), the make;
#   6. eos-verify.sh: the finished build, offline.
# Only a run that gets through all six writes build.ok and target-files.ok there (the
# sha256 of the OTA package and of the target-files zip kept with it), which eos-pack.sh needs.
# A quick one (EOS_QUICK=1: the images only, m droid; lib.sh) writes quick.ok instead (the
# sha256 of every file the fastboot zip takes from out/),
# which eos-pack.sh packs as a quick candidate to test on a phone, never to release.
# Holds ~/.expressiveos.lock and the tree lock (~/.expressiveos-tree.lock, and through 1.1
# its old name ~/.evolution-tree.lock; lib.sh's eos_lock) for the whole run, and first waits
# for any build already running. Everything also goes
# to EOS_BUILD_LOG (~/expressiveos-build.log for cheetah, ~/expressiveos-build-<device>.log
# for the others; the one before is kept as .1); the last line is BUILD_EXIT=0 or BUILD_EXIT=1.
#
#   eos-images.sh [top]                  # default ~/expressiveos
#   EOS_DEVICE=husky eos-images.sh       # another phone (devices/husky.conf)
#   KERNEL_ONLY=1 eos-images.sh [top]    # steps 1-4, then build_kernel only
#   EOS_KERNEL_SYNC=1 eos-images.sh      # sync the kernel source to pins/kernel.xml again
#                                        # (otherwise only the first build syncs it)
#   EOS_INSTALLCLEAN=1 eos-images.sh     # start the make with m installclean (eos-make.sh)
#   EOS_QUICK=1 eos-images.sh            # a quick build: the images only (m droid), about 5
#                                        # minutes sooner; packed for testing, never released
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
rm -f -- "$EOS_STATE/build.ok" "$EOS_STATE/target-files.ok" "$EOS_STATE/quick.ok"
# The build type under its 1.1 name and its old one (a tree from before 1.1 reads that), as
# eos-make.sh exports them. patches/device_google_pantah/0010 sets TARGET_INCLUDE_BOOT_ANIMATIONS
# too; apply-bootanim.sh checks for it here
export EXPRESSIVE_BUILD_TYPE=$EOS_BUILD_TYPE EVO_BUILD_TYPE=$EOS_BUILD_TYPE TARGET_INCLUDE_BOOT_ANIMATIONS=false
kind="full build (m bacon: the images, the OTA package and its target-files)"
[[ $EOS_QUICK != 1 ]] || kind="quick build (EOS_QUICK=1: the images only, m droid; for testing, never released)"
# What the STEP and TIME lines (lib.sh's eos_step) say this build is; eos-make.sh's too
EOS_RUN_KIND=full EOS_RUN_FRESH=0
[[ $EOS_QUICK != 1 ]] || EOS_RUN_KIND=quick
[[ "${KERNEL_ONLY:-0}" != 1 ]] || EOS_RUN_KIND=kernel
[[ -d $EOS_PRODUCT_OUT ]] || EOS_RUN_FRESH=1
export EOS_RUN_KIND EOS_RUN_FRESH
echo "== ExpressiveOS $EOS_VERSION $EOS_BUILD_TYPE for $EOS_DEVICE in $top, $(date -u '+%F %T') UTC: a $kind"
[[ $EOS_RUN_FRESH = 0 ]] || echo "note: no $EOS_PRODUCT_OUT: this build makes all of it again, the longest kind of build"
wait_builds
eos_step prepare
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
# ViPER4Android only where devices/<device>.conf turns it on: it needs gs201's HIDL effect HAL
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
# Expressive Launcher as default Home and Recents app, on every phone (Pixel Launcher stays as a pick)
step "Expressive Launcher" 'LAUNCHER_APPLY=OK.*' "$kit/launcher/apply-launcher.sh" "$top"

echo "== identity"
# The version and build type under their 1.1 names (vendor/lineage's version.mk:
# EXPRESSIVE_MODVERSION, EXPRESSIVE_BUILD_TYPE), else their old ones (EVO_VERSION,
# EVO_BUILD_TYPE): a tree from before 1.1, or a manifest rollback, has only those
vars=$(dump_vars LINEAGE_VERSION EXPRESSIVE_MODVERSION EXPRESSIVE_BUILD_TYPE EVO_VERSION EVO_BUILD_TYPE \
    TARGET_DEVICE TARGET_BUILD_VARIANT PRODUCT_PACKAGES) || fail "dumpvars failed"
name=$(var_of "$vars" LINEAGE_VERSION)
[[ "$name" =~ ^ExpressiveOS-17\.[0-9]+-[0-9]{8}-$EOS_DEVICE-${EOS_VERSION//./\\.}-$EOS_BUILD_TYPE$ ]] \
    || fail "the build would be named '$name', not ExpressiveOS-17.x-<date>-$EOS_DEVICE-$EOS_VERSION-$EOS_BUILD_TYPE (patches/vendor_lineage/0001)"
modver=$(var_new_or_old "$vars" EXPRESSIVE_MODVERSION EVO_VERSION)
btype=$(var_new_or_old "$vars" EXPRESSIVE_BUILD_TYPE EVO_BUILD_TYPE)
[[ -n $(var_of "$vars" EXPRESSIVE_MODVERSION) ]] \
    || echo "note: the tree has no EXPRESSIVE_MODVERSION (vendor/lineage from before 1.1): its version is EVO_VERSION"
[[ $modver = "$EOS_VERSION" ]] || fail "the build's version (EXPRESSIVE_MODVERSION, else EVO_VERSION) is '$modver', want '$EOS_VERSION'"
[[ $btype = "$EOS_BUILD_TYPE" ]] || fail "the build type (EXPRESSIVE_BUILD_TYPE, else EVO_BUILD_TYPE) is '$btype', want '$EOS_BUILD_TYPE'"
# The old names too, where the tree has them: through 1.1 they're the new ones' aliases
for v in EVO_VERSION:$EOS_VERSION EVO_BUILD_TYPE:$EOS_BUILD_TYPE; do
    x=$(var_of "$vars" "${v%%:*}")
    [[ -z $x || $x = "${v#*:}" ]] || fail "${v%%:*} is '$x', want '${v#*:}' (vendor/lineage's version.mk keeps it as an alias through 1.1)"
done
for kv in "TARGET_DEVICE=$EOS_DEVICE" "TARGET_BUILD_VARIANT=${EOS_LUNCH##*-}"; do
    [[ "$(var_of "$vars" "${kv%%=*}")" = "${kv#*=}" ]] || fail "${kv%%=*} is '$(var_of "$vars" "${kv%%=*}")', want '${kv#*=}'"
done
pkgs=" $(var_of "$vars" PRODUCT_PACKAGES) "
# Every phone gets Expressive Launcher (launcher/launcher.mk) next to Pixel Launcher
[[ $pkgs = *" ExpressiveLauncher "* ]] \
    || fail "$EOS_LUNCH doesn't install ExpressiveLauncher: launcher/launcher.mk's product list must name ${EOS_LUNCH%%-*}"
echo "OK: $EOS_LUNCH installs ExpressiveLauncher, the default Home and Recents app"
# No phone gets root, nor ViPER4Android where it's off, from what the one tree all the phones
# share still holds of earlier builds (vendor/extra, the pantah fork's KernelSU lines)
[[ $pkgs != *" KernelSUNext "* ]] \
    || fail "$EOS_LUNCH would install KernelSUNext: ExpressiveOS ships no root, and its device tree mustn't add the KernelSU Next manager"
if [[ $EOS_V4A != 1 ]]; then
    for m in ViPER4Android libv4a_re; do
        [[ $EOS_V4A = 1 || $pkgs != *" $m "* ]] \
            || fail "$EOS_LUNCH would install $m, but devices/$EOS_DEVICE.conf has EOS_V4A=0: vendor/extra/product.mk (apply-v4a.sh, from a cheetah build) has every product inherit viper4android.mk, which must add it for the phones with EOS_V4A=1 only"
    done
    echo "OK: $EOS_LUNCH installs no KernelSU Next or ViPER4Android, as devices/$EOS_DEVICE.conf says"
else
    echo "OK: $EOS_LUNCH installs no KernelSU Next"
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
    # GPL-3.0-or-later code ships in it (launcher/README.md, "Licence and credits")
    echo "Expressive Launcher: $(sed -n 's/^EL_VERSION=//p' "$kit/launcher/launcher.conf") ($(sed -n 's/^EL_VERSION_CODE=//p' "$kit/launcher/launcher.conf")), source $(sed -n 's/^EL_SRC=//p' "$kit/launcher/launcher.conf") $(sed -n 's/^EL_COMMIT=//p' "$kit/launcher/launcher.conf")"
    echo "Patched projects: upstream revision (repo's m/$EOS_MANIFEST_BRANCH), then HEAD with the kit's commits"
    printf '%s\n' "${projects[@]}" | sort -u
    if (( ${#google[@]} )); then
        echo "Google's files, not in the manifest:"
        printf '%s\n' "${google[@]}"
    fi
} > "$EOS_STATE/sources.txt"
cat "$EOS_STATE/sources.txt"

# Kernel source (EOS_KERNEL=gs-6.1): eos-make.sh syncs it to pins/kernel.xml when it's
# missing or EOS_KERNEL_SYNC=1, and checks it's on them otherwise. Its kernel and make steps
# are its own (eos_step)
eos_step end
step "make (eos-make.sh)" 'MAKE_EXIT=0' "$kit/tools/eos-make.sh" "$top"
if [[ "${KERNEL_ONLY:-0}" = 1 ]]; then
    echo "OK: kernel only (KERNEL_ONLY=1): nothing to pack"
    done=1; echo "BUILD_EXIT=0"; exit 0
fi
eos_step verify
step "verify (eos-verify.sh)" 'VERIFY=OK' "$kit/tools/eos-verify.sh" "$top"
eos_step end
if [[ $EOS_QUICK = 1 ]]; then
    ver=$(sed -n 's/^VERIFIED_QUICK //p' "$work/step.log" | tail -1)
    [[ -n $ver ]] || fail "eos-verify.sh didn't verify a quick build (no VERIFIED_QUICK line)"
    # What the quick candidate takes from out/, as eos-verify.sh checked it: eos-pack.sh
    # packs it only while every one of them is still this build's
    mapfile -t files < <(fastboot_files)
    # As eos-pack.sh checks the zip (fastboot_files always adds super_empty.img or vendor_kernel_boot.img)
    for need in init_boot.img vbmeta.img; do
        printf '%s\n' "${files[@]}" | grep -qxF -- "$need" || fail "$EOS_PRODUCT_OUT/fastboot-info.txt doesn't flash ${need%.img}"
    done
    files=("${files[@]/#/$EOS_PRODUCT_OUT/}")
    for f in "${files[@]}"; do [[ -f $f ]] || fail "no $f (eos-verify.sh checked it)"; done
    { sha256sum -- "${files[@]}" > "$EOS_STATE/.quick.ok.part" && mv -f -- "$EOS_STATE/.quick.ok.part" "$EOS_STATE/quick.ok"; } \
        || fail "can't write $EOS_STATE/quick.ok"
    echo "OK: quick build $ver: $EOS_STATE/quick.ok holds the sha256 of the ${#files[@]} files its fastboot zip takes from out/"
    echo "OK: no OTA package or target-files (quick): eos-pack.sh packs it to test on a phone, never to release or send to testers"
    done=1
    echo "BUILD_EXIT=0"
    exit 0
fi
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
