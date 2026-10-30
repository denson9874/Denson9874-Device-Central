# Sourced by devices-check.sh when its first argument is "more" (the runner's
# expressiveos-devices action with query "more"): the second round of read-only checks for
# the six-phone release, with devices-check.sh's helpers and rules. It prints names, sizes,
# commit SHAs, build-file lines and the open-source device trees' differences, never a
# proprietary file's contents.
# shellcheck shell=bash
dc=${GITHUB_WORKSPACE:-$PWD}   # this repo's checkout

h "ExpressiveOS tree, one path at a time (GiB)"
# One du per path: GNU du skips an operand nested in one it already counted
for p in .repo out/target/product/cheetah out/soong out/host out-kernel out; do lowdu "$eos/$p"; done
lowdu ~/releases/expressiveos-cheetah
h "other big folders (GiB)"
for p in ~/derpfest ~/derpfest/out ~/evolution ~/evolution/out ~/evolution/.repo ~/android-dt ~/android-dt/dumps ~/android-dt/firmware ~/releases ~/.ccache ~/.cache; do lowdu "$p"; done
ccache -s 2> /dev/null | grep -iE 'cache directory|cache size|max' | head -5

h "Evolution X routines around Sunday 2026-10-25 (log, last write, result)"
for f in ~/routine-logs/*-2026102[4-6]-*.log; do
    [[ -f $f ]] || continue
    echo "${f##*/}: last write $(date -u -r "$f" '+%F %T UTC'), $(grep -a '^ROUTINE_RESULT=' "$f" | tail -1 | cut -c1-60)"
done

h "Pixel 11 device trees: the server's against this repo's evolution-kodiak copies"
declare -A pub
for d in "${P11[@]}"; do
    pub[$d]=$(timeout 30 git -c credential.helper= ls-remote "https://github.com/denson9874/device_google_$d" refs/heads/cnb 2> /dev/null | cut -f1)
done
for d in "${P11[@]}"; do
    s=$evo/device/google/$d c=$dc/evolution-kodiak/device_google_$d
    echo "-- $d: server HEAD $(git -C "$s" log -1 --format='%H %cs %s' | cut -c1-110), $(git -C "$s" rev-list --count HEAD) commits, $(git -C "$s" status --porcelain | wc -l) changed"
    p=${pub[$d]:-}
    if [[ -z $p ]]; then echo "   public cnb: unknown"
    elif ! git -C "$s" cat-file -e "$p^{commit}" 2> /dev/null; then echo "   public cnb ${p:0:12}: not in the server's clone"
    elif git -C "$s" merge-base --is-ancestor "$p" HEAD; then echo "   public cnb ${p:0:12}: under HEAD, $(git -C "$s" rev-list --count "$p..HEAD") commits since"
    else echo "   public cnb ${p:0:12}: not under HEAD (diverged)"; fi
    [[ -d $c ]] || { echo "   no copy in this repo"; continue; }
    t=$work/tree-$d; rm -rf "$t"; mkdir -p "$t"
    git -C "$s" archive HEAD | tar -x -C "$t" || { echo "   can't read the server tree"; continue; }
    n=$(diff -rq "$c" "$t" 2> /dev/null | wc -l)
    echo "   files that differ from evolution-kodiak/device_google_$d: $n"
    diff -rq "$c" "$t" 2> /dev/null | sed "s|$dc/||g; s|$t|server|g" | head -40
    if (( n > 0 && n <= 80 )); then
        echo "   -- diff (copy, then server)"
        diff -ruN "$c" "$t" 2> /dev/null | sed "s|$dc/||g; s|$t|server|g" | head -2500
    fi
    rm -rf "$t"
done

h "Pixel 11: firmware lists, images folders, product makefile lines"
for d in "${P11[@]}"; do
    s=$evo/device/google/$d
    echo "-- $d"
    echo "firmware.txt: $(tr '\n' ' ' < "$s/firmware.txt" 2> /dev/null | cut -c1-600)"
    echo "-images: $(ls "$evo/vendor/google/$d-images" 2> /dev/null | tr '\n' ' ')"
    echo "-images/radio: $(ls "$evo/vendor/google/$d-images/radio" 2> /dev/null | tr '\n' ' ' | cut -c1-700)"
    echo "-images/images: $(ls "$evo/vendor/google/$d-images/images" 2> /dev/null | tr '\n' ' ' | cut -c1-500)"
    grep -hoE 'radio/[A-Za-z0-9_.-]+\.img|images/[A-Za-z0-9_.-]+\.img' "$evo/vendor/google/$d-images/Android.mk" 2> /dev/null | sort -u | tr '\n' ' '; echo
    head -3 "$evo/vendor/google/$d-images/SOURCE" 2> /dev/null
    grep -nE 'super_empty|vendor_kernel_boot|BOARD_PREBUILT_[A-Z_]*IMAGE|TARGET_NO_KERNEL|TARGET_BOOTLOADER_BOARD_NAME|TARGET_INCLUDE_BOOT_ANIMATIONS|COPY_IMAGES_FOR_TARGET_FILES_ZIP|TARGET_FS_CONFIG_GEN|PRODUCT_BUILD_INIT_BOOT_IMAGE|BOARD_AVB_[A-Z_]*KEY_PATH|BOARD_AVB_MAKE_VBMETA' \
        "$s"/*.mk 2> /dev/null | sed "s|$evo/||" | cut -c1-180 | head -40
    grep -rn 'updater_server_url\|maintainer' "$s/rro_overlays" --include='*.xml' 2> /dev/null | sed "s|$evo/||" | cut -c1-200 | head -6
    echo "vendor/google/$d: $(git -C "$evo/vendor/google/$d" rev-list --count HEAD 2> /dev/null) commits, first: $(git -C "$evo/vendor/google/$d" log --reverse --format='%cs %s' 2> /dev/null | head -1 | cut -c1-90)"
done
echo "dumps: $(ls ~/android-dt/dumps 2> /dev/null | tr '\n' ' ')"

h "husky: board, AVB chain, makefile lines, Updater and maintainer"
echo "board-info.txt: $(tr '\n' ' ' < "$evo/device/google/shusky/husky/board-info.txt" 2> /dev/null)"
avb=$evo/out/host/linux-x86/bin/avbtool
[[ -x $avb ]] && "$avb" info_image --image "$evo/out/target/product/husky/vbmeta.img" 2> /dev/null \
    | grep -E 'Algorithm|Partition Name|Public key|Rollback Index Location' | sed 's/^[[:space:]]*//' | head -30
grep -rnE 'COPY_IMAGES_FOR_TARGET_FILES_ZIP|TARGET_INCLUDE_BOOT_ANIMATIONS|TARGET_FS_CONFIG_GEN|BOARD_PREBUILT_INIT_BOOT|PRODUCT_BUILD_INIT_BOOT_IMAGE|AVB_CUSTOM|testkey' \
    "$evo/device/google/zuma" "$evo/device/google/shusky" "$evo/device/google/husky" --include='*.mk' 2> /dev/null | sed "s|$evo/||" | cut -c1-180 | head -30
grep -rn 'updater_server_url' "$evo/device/google/shusky" "$evo/device/google/zuma" --include='*.xml' 2> /dev/null | sed "s|$evo/||" | cut -c1-200
grep -rhoE 'UpdaterOverlay[A-Za-z]+' "$evo/device/google/shusky" "$evo/device/google/zuma" --include='*.mk' --include='*.bp' 2> /dev/null | sort -u | tr '\n' ' '; echo
echo "husky stock firmware cached: $(ls ~/android-dt/firmware 2> /dev/null | grep -i husky | tr '\n' ' ')"

h "shared projects ExpressiveOS's Pixel 11 builds read"
sed -n '85,100p' "$eos/vendor/gms/gms_full.mk" 2> /dev/null | cut -c1-400
git -C "$evo/vendor/gms" show --stat --format='%h %s' fc94da7 2> /dev/null | head -8
git -C "$evo/vendor/gms" show --format= fc94da7 -- '*.mk' '*.bp' 2> /dev/null | head -60
git -C "$eos/build/make" log --oneline -3 -- tools/releasetools/common.py 2> /dev/null
echo "DEVICES_MORE=DONE"
