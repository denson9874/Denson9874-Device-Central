#!/usr/bin/env bash
# ExpressiveOS on AOSP, cheetah only: the EXPERIMENT of branch eos/aosp (README.md here).
# Its own tree, ~/eos-aosp, never ~/expressiveos; its own tmux session, eos-aosp; its log in
# ~/expressiveos-jobs/aosp/. Nothing here builds, packs, signs, uploads or flashes a release.
#
#   aosp-proto.sh status   read-only: session, logs' last lines, the tree's size, free disk
#   aosp-proto.sh sync     repo init AOSP android-17.0.0_r1 (depth 1) + eos-aosp-cheetah.xml, repo sync
#   aosp-proto.sh build    lunch aosp_cheetah, then m -k nothing (analysis only): what fails is the result
#   aosp-proto.sh full     the same with m -k droid: the whole image, hours, holds the server
#   aosp-proto.sh kernel   Google's stock cheetah kernel, DTB and modules from the factory image
#                          into device/google/pantah-kernels/6.1 (stand-in for Lineage's build_kernel)
#   aosp-proto.sh round    sync, then build if it ended SYNC=OK (one round, one dispatch)
#   aosp-proto.sh clean    remove ~/eos-aosp and the copied scripts (nothing stays on the server)
#
# sync and build run in tmux and return at once; status shows how they go. They refuse while an
# ExpressiveOS build or pack (eos-build, eos-pack) or any soong/ninja runs, and build only after
# a sync that ended SYNC=OK.
set -euo pipefail
top=~/eos-aosp kitc=~/eos-aosp-kit jobs=~/expressiveos-jobs/aosp
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AOSP_TAG=android-17.0.0_r1
MIN_FREE_GB=300   # a depth-1 AOSP checkout plus one product's out/ (inferred: ~110 + ~180 GB)
fail() { echo "::error::$*"; exit 1; }
busy() {
    local s
    for s in eos-build eos-pack eos-setup eos-aosp; do
        if tmux has-session -t "=$s" 2>/dev/null; then echo "tmux session $s is running"; return 0; fi
    done
    if pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null; then echo "a soong/ninja build is running"; return 0; fi
    return 1
}
free_gb() { df -BG --output=avail ~ | tail -1 | tr -dc 0-9; }
standins() {   # the stand-in edits, in this throwaway tree only, from $top (sync-run puts the files back)
    # Round 5: the blobs declare dump_modem and gpuflag as rust_prebuilt_binary, a module type
    # only Lineage's build/soong has. STAND-IN, in this throwaway tree only (sync-run puts the
    # file back): declare them as plain prebuilt binaries without the Rust library links
    python3 - vendor/google/cheetah/Android.bp <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
n = s.count("rust_prebuilt_binary {") + s.count("rust_prebuilt_dylib {")
s = s.replace("rust_prebuilt_binary {", "cc_prebuilt_binary {\n    check_elf_files: false,")
# Round 6: AOSP's Soong refuses Rust prebuilts outside the system image (libgpuflag_aconfig_rust)
s = s.replace("rust_prebuilt_dylib {", "cc_prebuilt_library_shared {\n    check_elf_files: false,")
s = re.sub(r"\n\s*rustlibs: \[[^\]]*\],", "", s)
open(p, "w").write(s); print(f"== stand-in: {n} Rust prebuilt blobs declared as plain cc prebuilts")
PY
    # Round 11: the full compile's last Lineage-only pieces in gs201's common.mk. STAND-IN, in this
    # throwaway tree only (sync-run puts the file back): leave out Lineage's touch HAL
    # (vendor.lineage.touch-service.pixel needs vendor.lineage.touch-V1-ndk) and GoogleParts
    # (needs org.lineageos.settings.resources)
    python3 - device/google/gs201/common.mk device/google/pantah/device-cheetah.mk <<'PY'
import re, sys
# Rounds 11-13: gs201's common.mk and pantah's device-cheetah.mk include Lineage-only HALs from
# our hardware_google_pixel fork: touch (needs vendor.lineage.touch-V1-ndk), lineage_health
# (charge limit) and powershare (battery share); their pixel-sepolicy dirs name types only
# Lineage's device/lineage/sepolicy declares (hal_lineage_*_default). And GoogleParts (needs
# org.lineageos.settings.resources). Leave all of them out.
for p in sys.argv[1:]:
    s = open(p).read()
    s, a = re.subn(r"(?m)^-?include hardware/google/pixel/(touch|lineage_health|powershare)/device\.mk\n", "", s)
    s, b = re.subn(r"(?m)^[ \t]+GoogleParts[ \t]*\n", "", s)
    open(p, "w").write(s); print(f"== stand-in: {p} without {a} Lineage HAL include(s) and {b} GoogleParts line(s)")
    for n, line in enumerate(s.splitlines(), 1):
        if re.search(r"lineage", line, re.I): print(f"   still names Lineage: {p}:{n}: {line.strip()}")
PY
}

start() {   # start <step>: run this script's <step>-run in the eos-aosp tmux session, from a copy
    local why
    if why=$(busy); then fail "not starting $1: $why"; fi
    mkdir -p "$kitc" "$jobs"
    cp "$here/aosp-proto.sh" "$kitc/" && cp "$here/local_manifests/eos-aosp-cheetah.xml" "$kitc/"
    local log=$jobs/$1-$(TZ=America/New_York date +%Y%m%d-%H%M).log
    # A fresh login's environment, as the kit's sessions get: the runner kills every process that
    # carries this job's RUNNER_TRACKING_ID when the job ends
    env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/bash LANG=C.UTF-8 TERM=screen \
        PATH="$HOME/bin:$PATH" tmux new-session -d -s eos-aosp "bash -l -c 'bash $kitc/aosp-proto.sh $1-run > $log 2>&1'"
    echo "started $1 in tmux session eos-aosp, log $log"
}

case ${1:-status} in
status)
    echo "== $(TZ=America/New_York date '+%Y-%m-%d %H:%M %Z')"
    tmux ls 2>/dev/null | grep -E '^eos-' || echo "no ExpressiveOS session running"
    echo "free: $(free_gb) GB"
    if [[ -d $top ]]; then echo "$top: $(du -sh --apparent-size "$top" 2>/dev/null | cut -f1)"; else echo "$top: not there"; fi
    for f in $(ls -t "$jobs"/*.log 2>/dev/null | head -1); do
        echo "== $f (last 150 lines)"; tail -n 150 "$f"
    done
    # Round 11: each failed step's own error lines (sepolicy's reasons aren't on FAILED lines)
    if [[ -s $top/out/error.log ]]; then
        echo "== out/error.log: each FAILED step and the lines after it"
        grep -E -A14 '^FAILED: ' "$top/out/error.log" | grep -vE '^\s*$' | head -260 || true
    fi ;;
sync)  start sync ;;
build) start build ;;
full)  start full ;;
kernel) start kernel ;;
round) start round ;;
clean)
    if why=$(busy); then fail "not cleaning: $why"; fi
    before=$(free_gb)
    rm -rf "$top" "$kitc"
    echo "removed $top and $kitc; free $before GB -> $(free_gb) GB (logs kept in $jobs)" ;;

sync-run)
    echo "SYNC start $(TZ=America/New_York date)"
    (( $(free_gb) >= MIN_FREE_GB )) || { echo "SYNC=FAIL only $(free_gb) GB free, need $MIN_FREE_GB"; exit 1; }
    command -v repo >/dev/null || { echo "SYNC=FAIL repo isn't installed"; exit 1; }
    mkdir -p "$top" && cd "$top"
    # This round's local manifest before repo init, which reads the one already there
    if [[ -d .repo ]]; then mkdir -p .repo/local_manifests && cp "$kitc/eos-aosp-cheetah.xml" .repo/local_manifests/; fi
    # build-run's stand-in edit of the blobs' Android.bp: put it back so repo sync updates cleanly
    if [[ -e vendor/google/cheetah/.git ]]; then git -C vendor/google/cheetah checkout -- Android.bp 2>/dev/null || true; fi
    # and build-run's round-11 stand-in edit of gs201's common.mk
    if [[ -e device/google/gs201/.git ]]; then git -C device/google/gs201 checkout -- common.mk 2>/dev/null || true; fi
    if [[ -e device/google/pantah/.git ]]; then git -C device/google/pantah checkout -- device-cheetah.mk 2>/dev/null || true; fi
    # and kernel-run's stock kernel files in Lineage's module-list project
    if [[ -e device/google/pantah-kernels/.git ]]; then git -C device/google/pantah-kernels checkout -- . 2>/dev/null || true; git -C device/google/pantah-kernels clean -fdq 2>/dev/null || true; fi
    repo init -u https://android.googlesource.com/platform/manifest -b "$AOSP_TAG" --depth=1 </dev/null \
        || { echo "SYNC=FAIL repo init"; exit 1; }
    mkdir -p .repo/local_manifests
    cp "$kitc/eos-aosp-cheetah.xml" .repo/local_manifests/
    # --force-sync: a stand-in swaps the project at an existing path (round 9: frameworks/hardware/interfaces)
    repo sync -c -j8 --no-tags --no-clone-bundle --fail-fast --force-sync </dev/null || { echo "SYNC=FAIL repo sync"; exit 1; }
    echo "projects: $(repo list | wc -l); free $(free_gb) GB"
    echo "SYNC=OK $(TZ=America/New_York date)" ;;

build-run)
    echo "BUILD start $(TZ=America/New_York date)"
    grep -qs '^SYNC=OK' $(ls -t "$jobs"/sync-*.log "$jobs"/round-*.log 2>/dev/null | head -1) /dev/null \
        || { echo "BUILD=FAIL no sync ended SYNC=OK"; exit 1; }
    cd "$top"
    export USE_CCACHE=0   # its own tree: keep the release tree's ccache as it is
    # Round 3: the cheetah trees set these only in lineage_cheetah.mk:11-13, and BoardConfig.mk:22
    # includes $(DEVICE_PATH)/BoardConfigCommon.mk; aosp_cheetah.mk leaves them empty
    export DEVICE_CODENAME=cheetah DEVICE_PATH=device/google/pantah VENDOR_PATH=vendor/google/cheetah
    standins
    # Round 7: Soong stops at the first module that depends on a Lineage-only module
    # (gs201/parts' GoogleParts needs org.lineageos.settings.resources). Let it go on, so one
    # round lists every such dependency; m -k then fails each of those modules on its own
    export ALLOW_MISSING_DEPENDENCIES=true
    source build/envsetup.sh
    echo "== lunch choices the cheetah trees offer"
    grep -hs -A8 COMMON_LUNCH_CHOICES device/google/pantah/AndroidProducts.mk || echo "(no AndroidProducts.mk lunch choices)"
    echo "== release configs AOSP $AOSP_TAG has"; ls build/release/release_configs 2>/dev/null | head -20 || true
    ok=
    for t in aosp_cheetah-trunk_staging-userdebug aosp_cheetah-userdebug; do
        echo "== lunch $t"
        # lunch can return 0 after a product-config error: check that it set the product
        if lunch "$t" && [[ -n ${TARGET_PRODUCT:-} ]] && get_build_var TARGET_DEVICE >/dev/null; then ok=$t; break; fi
    done
    if [[ -z $ok ]]; then
        # Each make error's own lines, so the next round's fix can be read off this log
        lunch aosp_cheetah-trunk_staging-userdebug 2>&1 | grep -oE '^[A-Za-z0-9_./-]+\.mk:[0-9]+: error' | sort -u |
        while IFS=: read -r f n _; do
            echo "== $f, lines 1-$(( n + 5 ))"; if [[ -f $f ]]; then sed -n "1,$(( n + 5 ))p" "$f" | cat -n; fi
        done || true   # lunch's own failure ends this pipeline non-zero (pipefail)
        # Where the device trees set the folder variables a Lineage-style tree uses
        echo "== DEVICE_PATH / DEVICE_CODENAME / VENDOR_PATH set in device/google and vendor/google"
        grep -rnE '^\s*(DEVICE_PATH|DEVICE_CODENAME|VENDOR_PATH|COMMON_PATH)\s*[:?]?=' device/google vendor/google 2>/dev/null | head -30 || true
        echo "== products the cheetah trees define"
        { grep -rlE 'PRODUCT_NAME\s*:?=' device/google/pantah 2>/dev/null | head || true; }; grep -rhE 'PRODUCT_MAKEFILES|COMMON_LUNCH' device/google/pantah/AndroidProducts.mk 2>/dev/null || true
        echo "BUILD=FAIL lunch (the errors above are the device side's first list)"; exit 1
    fi
    # build: analysis only (Soong and Kati, minutes, no compiling), so a missing-module list
    # doesn't hold the server for hours. full: m -k droid, the whole image, hours
    goal=nothing; if [[ ${2:-} == full ]]; then goal=droid; fi
    echo "== m -k $goal ($ok): keeps going past errors to list as many as it can"
    if m -k "$goal"; then echo "BUILD=OK ($goal) $(TZ=America/New_York date)"
    else echo "== errors"; grep -E '^(FAILED|error:)|error: ' out/error.log 2>/dev/null | head -100 || true
         echo "== missing modules (count, what)"
         grep -ohE 'missing dependencies: .*|depends on undefined module "[^"]+"' out/error.log out/soong/*.log 2>/dev/null |
             sed -E 's/^missing dependencies: //' | tr ',' '\n' | sed 's/^ *//' | sort | uniq -c | sort -rn | head -80 || true
         echo "BUILD=FAIL m $(TZ=America/New_York date)"; exit 1; fi ;;
full-run)
    bash "$kitc/aosp-proto.sh" build-run full ;;
kernel-run)
    # Daryl's go 11-18 4:48 PM ET ("Build it"). Google's own kernel for the prototype: boot.img as
    # BOARD_PREBUILT_BOOTIMAGE, the DTB from vendor_kernel_boot, and every module with its load list
    # from vendor_kernel_boot, vendor_dlkm and system_dlkm (gs201/BoardConfig-common.mk:55,206,235-272)
    echo "KERNEL start $(TZ=America/New_York date)"
    url=https://dl.google.com/dl/android/aosp/cheetah-cp4a.261105.040.a1-factory-b255f8dd.zip   # firmware/cheetah.conf
    sha=b255f8dd30041fad74cb4985f26770b37643914f9fa5eea5a18b1f92e0b45e91
    cd "$top"; w=$top/stock-kernel; kd=$top/device/google/pantah-kernels/6.1
    [[ -d $kd ]] || { echo "KERNEL=FAIL $kd isn't there (sync first)"; exit 1; }
    mkdir -p "$w" && cd "$w"
    if [[ ! -f factory.zip ]] || ! echo "$sha  factory.zip" | sha256sum -c --quiet; then
        curl -fL --retry 3 -o factory.zip "$url" && echo "$sha  factory.zip" | sha256sum -c \
            || { echo "KERNEL=FAIL download or SHA-256"; exit 1; }
    fi
    rm -rf img && mkdir img
    unzip -q -o -j factory.zip '*/image-*.zip' -d . || { echo "KERNEL=FAIL unzip"; exit 1; }
    # CP4A's image zip has no super.img (measured 11-18): the dlkm partitions come as their own
    # images; take super.img only if they don't
    names=$(unzip -Z1 image-*.zip); echo "== image zip: $(echo $names)"
    want="boot.img vendor_kernel_boot.img dtbo.img"
    for n in vendor_dlkm.img system_dlkm.img; do grep -qx "$n" <<<"$names" && want+=" $n"; done
    if ! grep -qx vendor_dlkm.img <<<"$names"; then want+=" super.img"; fi
    unzip -q -o image-*.zip $want -d img || { echo "KERNEL=FAIL unzip $want"; exit 1; }
    cd "$top"
    export USE_CCACHE=0 DEVICE_CODENAME=cheetah DEVICE_PATH=device/google/pantah VENDOR_PATH=vendor/google/cheetah ALLOW_MISSING_DEPENDENCIES=true
    standins   # round 11: a sync puts back the blobs' Android.bp, and Soong reads it for host tools too
    source build/envsetup.sh && lunch aosp_cheetah-trunk_staging-userdebug >/dev/null
    m simg2img lpunpack fsck.erofs || { echo "KERNEL=FAIL host tools"; exit 1; }
    hb=$top/out/host/linux-x86/bin; lz4=$top/prebuilts/build-tools/linux-x86/bin/lz4
    cd "$w"
    if [[ -f img/super.img ]]; then
        "$hb/simg2img" img/super.img img/super.raw && rm img/super.img
        "$hb/lpunpack" -p vendor_dlkm_a -p system_dlkm_a img/super.raw img/ 2>/dev/null \
            || "$hb/lpunpack" -p vendor_dlkm -p system_dlkm img/super.raw img/ || { echo "KERNEL=FAIL lpunpack"; exit 1; }
        rm img/super.raw
    fi
    # The server has no file(1) (measured 11-18): tell image types by their magic numbers
    fstype() { local m; m=$(od -An -tx1 -N4 "$1" | tr -d ' \n'); [[ $m == 3aff26ed ]] && { echo sparse; return; }
        m=$(od -An -tx1 -j1080 -N2 "$1" | tr -d ' \n'); [[ $m == 53ef ]] && { echo ext4; return; }
        m=$(od -An -tx1 -j1024 -N4 "$1" | tr -d ' \n'); [[ $m == e2e1f5e0 ]] && { echo erofs; return; }
        echo unknown; }
    # A dlkm image may be sparse: make it raw before reading it
    for f in img/*dlkm*.img; do if [[ $(fstype "$f") == sparse ]]; then "$hb/simg2img" "$f" "$f.raw" && mv "$f.raw" "$f"; fi; done
    ls -la img
    python3 "$top/system/tools/mkbootimg/unpack_bootimg.py" --boot_img img/vendor_kernel_boot.img --out vkb >/dev/null \
        || { echo "KERNEL=FAIL unpack vendor_kernel_boot"; exit 1; }
    rm -rf ex && mkdir -p ex/vkb ex/vendor_dlkm ex/system_dlkm
    # Each ramdisk by its own compression (measured 11-18: piping blind gave "cpio: premature end")
    [[ -x $lz4 ]] || lz4=$(command -v lz4 || echo "$hb/lz4")
    ls -la vkb
    for r in vkb/vendor_ramdisk* vkb/ramdisk*; do
        [[ -f $r ]] || continue
        m=$(od -An -tx1 -N4 "$r" | tr -d ' \n')
        case $m in
        02214c18|04224d18) "$lz4" -dc "$r" > "$r.cpio" ;;
        1f8b*)             gzip -dc "$r" > "$r.cpio" ;;
        30373037)          cp "$r" "$r.cpio" ;;
        *) echo "== $r: unknown compression ($m)"; continue ;;
        esac
        (cd ex/vkb && cpio -idm --quiet < "../../$r.cpio") || echo "== cpio on $r ended early"
    done
    for p in vendor_dlkm system_dlkm; do
        f=$(ls img/${p}*.img | head -1)
        t=$(fstype "$f")
        case $t in
        ext4)  debugfs -R "rdump / $w/ex/$p" "$f" >/dev/null 2>&1 || { echo "KERNEL=FAIL debugfs $f"; exit 1; } ;;
        erofs) "$hb/fsck.erofs" --extract="$w/ex/$p" "$f" >/dev/null || { echo "KERNEL=FAIL fsck.erofs $f"; exit 1; } ;;
        *)     echo "KERNEL=FAIL $f: unknown image type ($(od -An -tx1 -N16 "$f"))"; exit 1 ;;
        esac
        echo "== $p ($t): $(find ex/$p -name '*.ko' | wc -l) modules"
    done
    echo "== vendor_kernel_boot: $(find ex/vkb -name '*.ko' | wc -l) modules"
    # Into the kernel folder: Google's files over Lineage's lists (sync-run puts Lineage's back)
    cp img/boot.img "$kd/boot.img"
    cp vkb/dtb "$kd/stock-cp4a.dtb"
    cp img/dtbo.img "$kd/dtbo.img"   # BoardConfig-common.mk:207 (full compile 6:25 PM ET stopped on it)
    find ex -name '*.ko' -exec cp -f {} "$kd/" \;
    lst() { local m; m=$(find "ex/$1" -name modules.load | head -1); if [[ -n $m ]]; then xargs -n1 basename < "$m" > "$kd/$2"; fi; }
    lst vkb vendor_kernel_boot.modules.load; lst vendor_dlkm vendor_dlkm.modules.load; lst system_dlkm system_dlkm.modules.load
    b=$(find ex/vendor_dlkm -name modules.blocklist | head -1); if [[ -n $b ]]; then cp "$b" "$kd/vendor_dlkm.modules.blocklist"; fi
    b=$(find ex/system_dlkm -name modules.blocklist | head -1); if [[ -n $b ]]; then cp "$b" "$kd/system_dlkm.modules.blocklist"; fi
    find ex/vendor_dlkm -name 'init.insmod.*.cfg' -exec cp -f {} "$kd/" \;
    # BoardConfig-common.mk:241 names this one without a wildcard: an empty list if Google has none
    [[ -f $kd/vendor_dlkm.modules.blocklist ]] || : > "$kd/vendor_dlkm.modules.blocklist"
    echo "== $kd: $(ls "$kd"/*.ko | wc -l) modules; lists:"; wc -l "$kd"/*.modules.load
    # Every module a list names must be there, or the image build fails later
    miss=$(cat "$kd"/*.modules.load | xargs -n1 basename | sort -u | while read -r k; do [[ -f $kd/$k ]] || echo "$k"; done)
    if [[ -n $miss ]]; then echo "== listed but missing:"; echo "$miss" | head -40; echo "KERNEL=FAIL modules missing"; exit 1; fi
    echo "KERNEL=OK $(TZ=America/New_York date)" ;;
round-run)
    bash "$kitc/aosp-proto.sh" sync-run && bash "$kitc/aosp-proto.sh" build-run ;;
*) fail "usage: aosp-proto.sh status|sync|build|full|kernel|round|clean" ;;
esac
