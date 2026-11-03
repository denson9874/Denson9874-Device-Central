# Sourced by devices-check.sh when its first argument is "recovery" (the runner's
# expressiveos-devices action with query "recovery"): read-only, why recovery and fastbootd
# might not start on a Pixel 11. For each Pixel 11 it sets the stock factory image's boot
# chain (vendor_boot, vendor_kernel_boot, init_boot, boot, dtbo) beside the images the
# ExpressiveOS fastboot zip flashes: header fields, vendor ramdisk tables, the file names in
# each ramdisk and how the two sides differ, and the kernel module lists (module names and
# counts). With devices-check.sh's helpers and rules: never a proprietary file's contents.
#
# By hand, to set another build in stock's place (e.g. an Evolution X fastboot zip whose
# fastbootd worked): RC_STOCK_ZIP=<zip> RC_STOCK_LABEL=<name>. RC_CAP=<n> caps each list
# (default 150, 0 for none). RC_TEXT_DIFF=1 also prints diffs of the differing rc, prop and
# contexts files: only for two builds of our own sources, never with Google's stock zip.
# shellcheck shell=bash
unb=$eos/system/tools/mkbootimg/unpack_bootimg.py
cap=${RC_CAP:-150}
capped() { if [[ $cap = 0 ]]; then cat; else head -n "$cap"; fi; }

ours_zip() {  # <phone>: the newest ExpressiveOS fastboot zip on the server for it
    find ~/releases/expressiveos-"$1" -maxdepth 2 -name "*-$1-*-fastboot.zip" ! -name '*-quick-*' \
        -printf '%T@ %p\n' 2> /dev/null | sort -n | tail -1 | cut -d' ' -f2-
}
from_zip() {  # <zip> <image name> <out file>
    unzip -Z1 "$1" 2> /dev/null | grep -qx "$2" || return 1
    unzip -p "$1" "$2" > "$3"
}
unpack() {  # <image> <dir>: unpack it, print its header fields
    rm -rf "$2"; mkdir -p "$2"
    # board_id blocks (16 words of zeros each) left out
    python3 -I "$unb" --boot_img "$1" --out "$2" 2>&1 \
        | awk '/board_id: \[/ { skip = 1; next } skip && /\]/ { skip = 0; next } !skip' | sed 's/^/    /'
}
ramdisk_dir() {  # <compressed ramdisk> <dir>: extract it (device nodes need root: skipped)
    rm -rf "$2"; mkdir -p "$2"
    { lz4 -dcq "$1" 2> /dev/null || gzip -dc "$1" 2> /dev/null || cat "$1"; } \
        | (cd "$2" && cpio -id --quiet --no-absolute-filenames 2> /dev/null)
    return 0
}
names() {  # <dir>: its entries, one a line, sorted
    (cd "$1" && find . -mindepth 1 | sed 's|^\./||' | sort)
}
side_by_side() {  # <label> <stock dir> <ours dir>: entries only one side has, then files that differ
    local s=$work/s.$$ o=$work/o.$$
    names "$2" > "$s"; names "$3" > "$o"
    echo "  $1: $sl $(wc -l < "$s") entries, ExpressiveOS $(wc -l < "$o")"
    echo "  only in $sl:"
    comm -23 "$s" "$o" | capped | sed 's/^/    /'
    echo "  only in ExpressiveOS:"
    comm -13 "$s" "$o" | capped | sed 's/^/    /'
    echo "  in both, contents differ:"
    comm -12 "$s" "$o" | while read -r f; do
        [[ -f $2/$f && -f $3/$f ]] || continue
        cmp -s -- "$2/$f" "$3/$f" || echo "$f"
    done | grep -v '^res/images/' > "$work/differ.$$"
    capped < "$work/differ.$$" | sed 's/^/    /'
    echo "    (and $(comm -12 "$s" "$o" | grep -c '^res/images/') res/images files, not compared)"
    if [[ ${RC_TEXT_DIFF:-0} = 1 ]]; then
        grep -E '(\.rc|\.prop|prop\.default|_contexts|fstab\.[^/]*|\.xml)$' "$work/differ.$$" | while read -r f; do
            echo "  diff $f ($sl, ExpressiveOS):"
            diff -u -- "$2/$f" "$3/$f" | sed 1,2d | head -60 | sed 's/^/    /'
        done
    fi
    rm -f "$s" "$o" "$work/differ.$$"
}
modules() {  # <label> <ramdisk dir>: its module lists, counts and recovery-only modules
    local d m
    d=$(find "$2" -path '*lib/modules/modules.load*' 2> /dev/null | head -1)
    [[ -n $d ]] || { echo "  $1: no lib/modules/modules.load*"; return; }
    d=${d%/*}
    echo "  $1: ${d#"$2"/}: $(find "$d" -maxdepth 1 -name '*.ko' | wc -l) .ko files"
    for m in "$d"/modules.load*; do echo "    ${m##*/}: $(grep -c . "$m") lines"; done
    if [[ -f $d/modules.load.recovery && -f $d/modules.load ]]; then
        echo "    in modules.load.recovery, not modules.load:"
        comm -13 <(sed 's|.*/||' "$d/modules.load" | sort) <(sed 's|.*/||' "$d/modules.load.recovery" | sort) | sed 's/^/      /'
    fi
    if [[ -f $d/modules.load.recovery ]]; then
        echo "    named in modules.load.recovery but missing from the ramdisk:"
        sed 's|.*/||' "$d/modules.load.recovery" | while read -r m; do
            [[ -e $d/$m ]] || echo "      $m"
        done
    fi
}

for d in "${P11[@]}"; do
    h "$d"
    fz=${RC_STOCK_ZIP:-$(find ~/android-dt/firmware -maxdepth 1 -name "image-$d-*.zip" 2> /dev/null | sort | tail -1)}
    sl=${RC_STOCK_LABEL:-stock}
    oz=$(ours_zip "$d")
    echo "$sl: ${fz:-none}"
    po=$eos/out/target/product/$d
    echo "ExpressiveOS: ${oz:-none, so the images in $po}"
    [[ -n $fz ]] || { echo "skipped: no stock factory image zip"; continue; }
    echo "ExpressiveOS fastboot-info.txt:"
    { if [[ -n $oz ]]; then unzip -p "$oz" fastboot-info.txt; else cat "$po/fastboot-info.txt"; fi; } 2> /dev/null \
        | grep -v '^#' | sed 's/^/    /'
    for img in boot dtbo vendor_kernel_boot init_boot vendor_boot pvmfw; do
        from_zip "$fz" "$img.img" "$work/s-$img.img" || rm -f "$work/s-$img.img"
        if [[ -n $oz ]]; then from_zip "$oz" "$img.img" "$work/o-$img.img" || rm -f "$work/o-$img.img"
        elif [[ -f $po/$img.img ]]; then cp -- "$po/$img.img" "$work/o-$img.img"; fi
        s=$( [[ -f $work/s-$img.img ]] && sha256sum < "$work/s-$img.img" | cut -c1-16 || echo none)
        o=$( [[ -f $work/o-$img.img ]] && sha256sum < "$work/o-$img.img" | cut -c1-16 || echo none)
        echo "$img.img: $sl $s, ExpressiveOS $o$([[ $s = "$o" ]] && echo ' (same)')"
    done
    for img in vendor_boot vendor_kernel_boot init_boot; do
        for side in s o; do
            [[ -f $work/$side-$img.img ]] || continue
            echo "-- $img.img header ($([[ $side = s ]] && echo "$sl" || echo ExpressiveOS))"
            unpack "$work/$side-$img.img" "$work/$side-$img"
            rm -rf "$work/$side-$img.root"; mkdir -p "$work/$side-$img.root"
            for r in "$work/$side-$img"/vendor_ramdisk* "$work/$side-$img"/ramdisk; do
                [[ -f $r ]] || continue
                ramdisk_dir "$r" "$work/$side-$img.frag/${r##*/}"
                echo "    ${r##*/}: $(names "$work/$side-$img.frag/${r##*/}" | wc -l) entries"
                cp -a "$work/$side-$img.frag/${r##*/}/." "$work/$side-$img.root/" 2> /dev/null || true
            done
        done
        [[ -d $work/s-$img.root && -d $work/o-$img.root ]] && side_by_side "$img ramdisks, merged" "$work/s-$img.root" "$work/o-$img.root"
    done
    for side in s o; do
        for img in vendor_kernel_boot vendor_boot; do
            [[ -d $work/$side-$img.root ]] && modules "$img ($([[ $side = s ]] && echo "$sl" || echo ExpressiveOS))" "$work/$side-$img.root"
        done
        # Recovery boots from all of them in one root: vendor_boot's files, then vendor_kernel_boot's over them
        rm -rf "$work/$side-both"; mkdir -p "$work/$side-both"
        cp -a "$work/$side-vendor_boot.root/." "$work/$side-vendor_kernel_boot.root/." "$work/$side-both/" 2> /dev/null || true
        modules "vendor_boot + vendor_kernel_boot ($([[ $side = s ]] && echo "$sl" || echo ExpressiveOS))" "$work/$side-both"
    done
    echo "USB and recovery properties in vendor_boot's ramdisk:"
    for side in s o; do
        [[ -d $work/$side-vendor_boot.root ]] || continue
        echo "  $([[ $side = s ]] && echo "$sl" || echo ExpressiveOS):"
        find "$work/$side-vendor_boot.root" -maxdepth 3 \( -name '*.prop' -o -name prop.default -o -name default.prop \) -type f \
            -exec grep -hE '^(ro\.recovery\.usb|ro\.boot\.|ro\.hardware|ro\.product\.(device|board)|ro\.build\.version\.(release|sdk))' {} + 2> /dev/null \
            | sort -u | sed 's/^/    /'
    done
    rm -rf "$work"/s-* "$work"/o-*
done
echo "RECOVERY_CHECK=DONE"
