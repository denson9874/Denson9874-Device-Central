#!/usr/bin/env bash
# Read-only: what ExpressiveOS's builds for the six phones (cheetah, husky, kodiak, grizzly,
# cubs, yogi) look like on the build server, read off ExpressiveOS's tree (~/expressiveos) and
# ~/android-dt. The runner's expressiveos-devices action runs it
# (.github/workflows/kodiak-build.yml); query "recovery" runs recovery-check.sh instead, query
# "v4a" v4a-p11-check.sh, query "kernels" reads each phone's newest release kernel.
#
# It changes nothing: no repo or git command that writes (GIT_OPTIONAL_LOCKS=0), no build,
# scratch files only under a mktemp folder it removes. It prints names, sizes, commit SHAs,
# version strings, build-file lines (makefile variables, board names) and counts, never the
# contents of a proprietary file. It may run beside a build; du runs at low priority.
set -uo pipefail
export PATH=~/bin:$PATH GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C
eos=~/expressiveos kit=~/expressiveos-cheetah
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
DEVICES=(cheetah husky kodiak grizzly cubs yogi)
P11=(kodiak grizzly cubs yogi)
h() { echo; echo "== $*"; }
lowdu() { nice -n 19 ionice -c2 -n7 du -x -s -BG "$@" 2>/dev/null || true; }
mkbootimg_unpack() {  # <boot image> <out dir>
    local u=$eos/system/tools/mkbootimg/unpack_bootimg.py
    [[ -f $u ]] || return 1
    python3 -I "$u" --boot_img "$1" --out "$2" > /dev/null 2>&1
}
kernel_image() {  # <boot image> <out Image>: the uncompressed kernel of a boot image
    local t=$work/unpack.$$ ; rm -rf "$t"; mkdir -p "$t"
    mkbootimg_unpack "$1" "$t" || return 1
    [[ -f $t/kernel ]] || return 1
    if lz4 -t "$t/kernel" > /dev/null 2>&1; then lz4 -dcq "$t/kernel" > "$2"
    elif gzip -t "$t/kernel" 2> /dev/null; then gzip -dc "$t/kernel" > "$2"
    else cp "$t/kernel" "$2"; fi
    rm -rf "$t"
}
koinfo() { python3 -I "$kit/tools/ko-info.py" "$@"; }

# Query "kernels": the kernel version of each phone's newest release, read off the release's
# target-files (target-files/LATEST names it; IMAGES/boot.img, else BOOT/kernel), for the XDA
# posts' kernel source section. Read-only: unzip -p into the scratch folder.
if [[ ${1:-} = kernels ]]; then
    for d in "${DEVICES[@]}"; do
        tfd=~/releases/expressiveos-$d/target-files
        tf=$tfd/$(cat "$tfd/LATEST" 2> /dev/null)
        [[ -f $tf ]] || { echo "$d: no target-files named by $tfd/LATEST"; continue; }
        if unzip -p "$tf" IMAGES/boot.img > "$work/boot.$d.img" 2> /dev/null && [[ -s $work/boot.$d.img ]] \
                && kernel_image "$work/boot.$d.img" "$work/Image.$d"; then
            src="IMAGES/boot.img sha256 $(sha256sum < "$work/boot.$d.img" | cut -c1-16)"
        elif unzip -p "$tf" BOOT/kernel > "$work/kernel.$d" 2> /dev/null && [[ -s $work/kernel.$d ]]; then
            src="BOOT/kernel"
            if lz4 -t "$work/kernel.$d" > /dev/null 2>&1; then lz4 -dcq "$work/kernel.$d" > "$work/Image.$d"
            elif gzip -t "$work/kernel.$d" 2> /dev/null; then gzip -dc "$work/kernel.$d" > "$work/Image.$d"
            else cp "$work/kernel.$d" "$work/Image.$d"; fi
        else
            echo "$d: ${tf##*/}: no IMAGES/boot.img or BOOT/kernel"; continue
        fi
        echo "$d: ${tf##*/} ($src): $(strings "$work/Image.$d" | grep -m1 '^Linux version' | cut -c1-200)"
        rm -f "$work/boot.$d.img" "$work/kernel.$d" "$work/Image.$d"
    done
    exit 0
fi

# Query "v4a": what the Pixel 11s' stock vendor images say about ViPER4Android (v4a-p11-check.sh)
if [[ ${1:-} = v4a ]]; then
    # shellcheck source=v4a-p11-check.sh
    source "$(dirname -- "$(readlink -f -- "$0")")/v4a-p11-check.sh"
    exit 0
fi
# Query "recovery": the Pixel 11s' stock boot chain beside ExpressiveOS's (recovery-check.sh)
if [[ ${1:-} = recovery ]]; then
    # shellcheck source=recovery-check.sh
    source "$(dirname -- "$(readlink -f -- "$0")")/recovery-check.sh"
    exit 0
fi

h "disk"
df -BG ~ | sed 1d
h "ExpressiveOS tree, per product (GiB)"
# One du per path: GNU du skips an operand nested in one it already counted
for p in .repo out/soong out/host out-kernel; do lowdu "$eos/$p"; done
lowdu "$eos"/out/target/product/*
for d in "${P11[@]}" husky; do lowdu "$eos/vendor/google/$d" "$eos/vendor/google/$d-images"; done
h "releases (GiB)"
lowdu ~/releases/*

h "local manifests in ~/expressiveos (names of the projects they add)"
for f in "$eos"/.repo/local_manifests/*.xml; do
    [[ -f $f ]] || continue
    echo "-- ${f##*/}"
    grep -oE '<(project|remove-project|remote)[^>]*>' "$f" | sed -E 's/[[:space:]]+/ /g' | cut -c1-220
done

h "device and vendor projects in ~/expressiveos: synced commit, HEAD, local commits, changes, remote"
for p in device/google/husky device/google/shusky device/google/shusky-kernels device/google/zuma vendor/google/husky \
         device/google/pantah device/google/gs201 vendor/google/cheetah \
         device/google/kodiak device/google/grizzly device/google/cubs device/google/yogi \
         vendor/google/kodiak vendor/google/grizzly vendor/google/cubs vendor/google/yogi; do
    d=$eos/$p
    [[ -e $d/.git ]] || { echo "$p: not a git checkout ($( [[ -d $d ]] && echo 'plain folder' || echo absent))"; continue; }
    # repo's m/<manifest branch> ref: the commit the manifest pins
    m=$(git -C "$d" for-each-ref --count=1 --format='%(objectname)' refs/remotes/m/ 2> /dev/null); m=${m:-none}
    hd=$(git -C "$d" rev-parse --verify -q 'HEAD^{commit}' || echo none)
    n=0; [[ $m = none || $hd = none || $m = "$hd" ]] || n=$(git -C "$d" rev-list --count "$m..$hd" 2> /dev/null || echo '?')
    ch=$(git -C "$d" status --porcelain 2> /dev/null | wc -l)
    url=$(git -C "$d" remote get-url "$(git -C "$d" remote | head -1)" 2> /dev/null || echo none)
    lfs=$(git -C "$d" config -f "$d/.lfsconfig" --get lfs.url 2> /dev/null || true)
    echo "$p: manifest $m HEAD $hd (+$n), $ch changed, $(git -C "$d" log -1 --format='%cs %s' HEAD 2> /dev/null | cut -c1-80), remote $url${lfs:+, lfs $lfs}"
    if [[ $n != 0 && $n != '?' ]]; then git -C "$d" log --format='   %h %s' "$m..$hd" | head -12; fi
done
for p in device_google_kodiak device_google_grizzly device_google_cubs device_google_yogi; do
    d=~/android-dt/trees/$p
    [[ -d $d/.git ]] && echo "android-dt/trees/$p: $(git -C "$d" log -1 --format='%h %cs %s' | cut -c1-90), $(git -C "$d" status --porcelain | wc -l) changed"
done

h "kernels: boot.img kernel version per product (out/ of ~/expressiveos, and the prebuilt kernel dirs)"
for d in "${DEVICES[@]}"; do
    b=$eos/out/target/product/$d/boot.img
    [[ -f $b ]] || { echo "$d: no out/ boot.img"; continue; }
    if kernel_image "$b" "$work/Image.$d"; then
        echo "$d: sha256 $(sha256sum < "$b" | cut -c1-16) $(strings "$work/Image.$d" | grep -m1 '^Linux version' | cut -c1-150)"
    else
        echo "$d: couldn't unpack $b"
    fi
done
for b in "$eos"/device/google/shusky-kernels/*/boot.img "$eos"/device/google/pantah-kernels/*/boot.img \
         "$eos"/vendor/google/*-images/images/boot.img; do
    [[ -f $b ]] && echo "${b#"$HOME"/}: sha256 $(sha256sum < "$b" | cut -c1-16)"
done
echo "-- kernel source trees (out-kernel)"
ls -d "$eos"/out-kernel/*/* 2> /dev/null
if [[ -d $eos/out-kernel/google/gs-6.1/.repo ]]; then
    (cd "$eos/out-kernel/google/gs-6.1" && repo manifest -r -o "$work/kernel.xml" > /dev/null 2>&1) || true
    if [[ -f $work/kernel.xml && -f $kit/pins/kernel.xml ]]; then
        if diff -q <(grep -oE '<project [^>]*' "$work/kernel.xml" | grep -oE '(name|revision)="[^"]*"' | paste - - | sort) \
                   <(grep -oE '<project [^>]*' "$kit/pins/kernel.xml" | grep -oE '(name|revision)="[^"]*"' | paste - - | sort) > /dev/null; then
            echo "Upstream gs-6.1 kernel source: same projects and revisions as pins/kernel.xml"
        else
            echo "Upstream gs-6.1 kernel source differs from pins/kernel.xml:"
            diff <(grep -oE '<project [^>]*' "$work/kernel.xml" | grep -oE '(name|revision)="[^"]*"' | paste - - | sort) \
                 <(grep -oE '<project [^>]*' "$kit/pins/kernel.xml" | grep -oE '(name|revision)="[^"]*"' | paste - - | sort) | head -20
        fi
    fi
    ls "$eos/out-kernel/google/gs-6.1"/build_*.sh "$eos/out-kernel/google/gs-6.1"/private/devices/google/ 2> /dev/null | head -20
fi

h "stock and built kernel config facts (CONFIG_IKCONFIG) and struct module sizes"
for d in cheetah husky kodiak yogi; do
    [[ -f $work/Image.$d ]] || continue
    c=$(koinfo config "$work/Image.$d" 2> /dev/null | grep -E '^CONFIG_(MODVERSIONS|DEBUG_INFO_BTF_MODULES|MODULE_SIG|MODULE_SIG_PROTECT|PAHOLE_VERSION|RUST|KALLSYMS_ALL|LTO_CLANG_THIN|CFI_CLANG)=' | tr '\n' ' ')
    echo "$d: ${c:-no IKCONFIG}"
done
for d in cheetah husky kodiak grizzly cubs yogi; do
    v=
    for c in "$eos/out/target/product/$d/vendor_kernel_boot.img" "$eos/vendor/google/$d-images/radio/vendor_kernel_boot.img" \
             "$eos/vendor/google/$d-images/images/vendor_kernel_boot.img"; do
        [[ -f $c ]] && { v=$c; break; }
    done
    [[ -n $v ]] || { echo "$d: no vendor_kernel_boot.img found"; continue; }
    t=$work/vkb.$d; mkdir -p "$t/m"
    if mkbootimg_unpack "$v" "$t"; then
        for r in "$t"/vendor_ramdisk*; do
            [[ -f $r ]] || continue
            { lz4 -dcq "$r" 2> /dev/null || gzip -dc "$r" 2> /dev/null || cat "$r"; } | (cd "$t/m" && cpio -id --quiet --no-absolute-filenames '*.ko' 2> /dev/null)
        done
        n=$(find "$t/m" -name '*.ko' | wc -l)
        s=$(find "$t/m" -name '*.ko' -print0 | xargs -0 -r python3 -I "$kit/tools/ko-info.py" this-module 2> /dev/null | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')
        echo "$d: ${v#"$HOME"/}: $n modules, struct module sizes (count bytes): $s"
    else
        echo "$d: couldn't unpack ${v#"$HOME"/}"
    fi
    rm -rf "$t"
done

h "firmware: factory and image zips, cached firmware"
ls -l ~/android-dt/firmware/*.zip 2> /dev/null | awk '{print $5, $9}' | numfmt --to=iec --field=1 | sed "s#$HOME/##"
for f in ~/android-dt/firmware/*/CURRENT; do [[ -f $f ]] && echo "${f#"$HOME"/}: $(head -c 200 "$f" | tr '\n' ' ')"; done
for d in "${P11[@]}"; do
    z=$(ls ~/android-dt/firmware/image-"$d"-*.zip 2> /dev/null | tail -1)
    [[ -n $z ]] && echo "$d stock android-info: $(unzip -p "$z" android-info.txt 2> /dev/null | tr '\n' ' ')"
done
echo "-- husky radio images named by vendor/google/husky"
grep -ohE 'radio/[A-Za-z0-9_.-]+\.img' "$eos/vendor/google/husky/Android.mk" 2> /dev/null | sort -u | tr '\n' ' '; echo

h "fastboot files per product in ~/expressiveos/out"
for d in "${DEVICES[@]}"; do
    o=$eos/out/target/product/$d
    [[ -d $o ]] || { echo "$d: no out/"; continue; }
    echo "-- $d"
    echo "android-info: $(tr '\n' ' ' < "$o/android-info.txt" 2> /dev/null)"
    echo "ab_partitions: $(tr '\n' ' ' < "$o/ab_partitions.txt" 2> /dev/null)"
    echo "images: $(cd "$o" && ls -1 *.img 2> /dev/null | tr '\n' ' ')"
    [[ -f $o/fastboot-info.txt ]] && echo "fastboot-info: $(grep -vE '^#|^$' "$o/fastboot-info.txt" | tr '\n' ';' | cut -c1-400)"
    ls "$o"/vendor_kernel_ramdisk/lib/modules 2> /dev/null | wc -l | sed 's/^/vendor_kernel_ramdisk modules: /'
done

h "AVB, kernel and board settings in the device trees (makefile lines)"
for t in device/google/zuma device/google/shusky device/google/husky device/google/kodiak device/google/grizzly device/google/cubs device/google/yogi device/google/gs201 device/google/pantah; do
    [[ -d $eos/$t ]] || continue
    echo "-- $t"
    grep -rnE '^\s*[^#]*(BOARD_AVB_[A-Z_]*(KEY_PATH|ALGORITHM|ROLLBACK_INDEX_LOCATION)|BOARD_AVB_[A-Z_]*CHAIN|BOARD_PREBUILT_[A-Z_]*IMAGE|PRODUCT_BUILD_[A-Z_]*_IMAGE|BOARD_KERNEL_IMAGE_NAME|TARGET_KERNEL_[A-Z_]*|BOARD_USES_GENERIC_KERNEL_IMAGE|TARGET_BOARD_INFO_FILE|TARGET_INCLUDE_BOOT_ANIMATIONS|TARGET_BOOT_ANIMATION_RES|COPY_IMAGES_FOR_TARGET_FILES_ZIP|BOARD_[A-Z_]*FILE_SYSTEM_TYPE|BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE|BOARD_USES_SYSTEM_OTHER_ODEX|TARGET_FS_CONFIG_GEN|PRODUCT_COPY_FILES.*bootanimation|inherit-product.*bootanimation)' \
        "$eos/$t" --include='*.mk' 2> /dev/null | sed "s#$eos/##" | cut -c1-200 | head -40
done
echo "-- Updater overlays and feed URLs"
grep -rnE 'updater_server_url|ota_url|<string name="updater' "$eos"/device/google/{pantah,gs201,shusky,zuma,kodiak,grizzly,cubs,yogi} --include='*.xml' 2> /dev/null | sed "s#$eos/##" | cut -c1-200
grep -rhoE 'UpdaterOverlay[A-Za-z0-9]*' "$eos"/device/google/{pantah,gs201,shusky,zuma,kodiak,grizzly,cubs,yogi} --include='*.mk' --include='*.bp' 2> /dev/null | sort -u | tr '\n' ' '; echo
echo "-- maintainer strings"
grep -rnE 'build_maintainer|maintainer_summary' "$eos"/device/google/{pantah,gs201,shusky,zuma,kodiak,grizzly,cubs,yogi} --include='*.xml' 2> /dev/null | sed "s#$eos/##" | cut -c1-200

h "audio effect HAL type (for ViPER4Android)"
for d in husky kodiak cheetah; do
    o=$eos/out/target/product/$d/vendor
    [[ -d $o ]] || o=$eos/vendor/google/$d-images/vendor
    [[ -d $o ]] || { echo "$d: no vendor folder"; continue; }
    echo "-- $d: $(grep -rhoE '(android\.hardware\.audio\.effect[^<" ]*|IEffectsFactory[^<" ]*|<version>7\.[0-9]</version>)' "$o/etc/vintf" 2> /dev/null | sort -u | tr '\n' ' ')"
    echo "   effect configs: $(ls "$o/etc" 2> /dev/null | grep -iE 'effect' | tr '\n' ' ')"
    echo "   audio HAL binaries: $(ls "$o/bin/hw" 2> /dev/null | grep -iE 'audio' | tr '\n' ' ')"
    echo "   soundfx libs: $(ls "$o/lib64/soundfx" 2> /dev/null | wc -l)"
done
for d in "${P11[@]}"; do
    v=~/android-dt/dumps/$d/vendor
    [[ -d $v ]] && echo "$d stock dump: $(grep -rhoE 'android\.hardware\.audio\.effect[^<" ]*' "$v/etc/vintf" 2> /dev/null | sort -u | tr '\n' ' ')"
done

h "ExpressiveOS's build/make and vendor/gms"
git -C "$eos/build/make" merge-base --is-ancestor 646e567 HEAD 2> /dev/null && echo "build/make has 646e567" || echo "build/make: 646e567 not an ancestor (or unknown)"
grep -n 'Prebuilt partitions (BOARD_PREBUILT_VENDORIMAGE' "$eos/build/make/tools/releasetools/common.py" 2> /dev/null | head -3
grep -rnE 'nowplaying\.xml' "$eos/vendor/gms" --include='*.mk' --include='Android.bp' 2> /dev/null | cut -c1-160 | head -5
grep -nE 'kodiak|grizzly|cubs|yogi|husky' "$eos/vendor/gms/gms_full.mk" "$eos/vendor/gms/"*.mk 2> /dev/null | cut -c1-160 | head -10

h "ExpressiveOS tree: device and vendor folders"
ls "$eos/device/google" "$eos/vendor/google" 2> /dev/null | tr '\n' ' '; echo

h "ExpressiveOS build times (last lines of the build logs)"
grep -aoE '#### build completed successfully \([^)]*\)' ~/expressiveos-build.log ~/expressiveos-build.log.1 2> /dev/null | tail -4

h "device-ok records (first line), crontab, sessions"
for f in ~/releases/*/check/*.device-ok ~/releases/*/*.device-ok; do
    [[ -f $f ]] && echo "${f#"$HOME"/}: $(head -1 "$f" | cut -c1-90)"
done
crontab -l 2> /dev/null | grep -vE '^#|^$' | cut -c1-160
tmux ls 2> /dev/null || echo "no tmux sessions"

h "release destinations (names only)"
if [[ -r ~/.ssh/sourceforge_ed25519 ]]; then
    printf 'ls /home/frs/project/denson9874-s-user-builds\nbye\n' | timeout 60 sftp -q -b - -o BatchMode=yes -o ConnectTimeout=20 -i ~/.ssh/sourceforge_ed25519 daryldenson0405@frs.sourceforge.net 2>&1 | tr '\n' ' ' | cut -c1-600; echo
else
    echo "no ~/.ssh/sourceforge_ed25519"; ls ~/.ssh 2> /dev/null | grep -vE '^known_hosts' | tr '\n' ' '; echo
fi
[[ -x ~/bin/rclone ]] && { echo "R2 top level: $(timeout 60 ~/bin/rclone lsf r2:denson9874-ota 2>&1 | tr '\n' ' ' | cut -c1-300)"; echo "R2 expressiveos/: $(timeout 60 ~/bin/rclone lsf -R --max-depth 2 r2:denson9874-ota/expressiveos/ 2>&1 | head -20 | tr '\n' ' ')"; }
echo "DEVICES_CHECK=DONE"
