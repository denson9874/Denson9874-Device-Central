#!/bin/bash
# p11-diff.sh: compare stock grizzly (Pixel 11 Pro) and cubs (Pixel 11)
# CD1A.261005.003 against kodiak, for everything the kodiak device tree
# depends on. Writes ~/android-dt/p11-diff/report.txt (+ detail files).
set -uo pipefail
B=cd1a.261005.003
F=~/android-dt/firmware
D=~/android-dt/dumps
H=~/evolution/out/host/linux-x86/bin
T=~/evolution/device/google/kodiak
R=~/android-dt/p11-diff${TAG:+-$TAG}
OTHERS=${OTHERS:-"grizzly cubs"}
rm -rf "$R"; mkdir -p "$R/detail"
exec > >(tee "$R/report.txt") 2>&1

# Replace device names so only real differences remain
norm() { sed -E 's/kodiak|grizzly|cubs|yogi/DEV/g; s/Kodiak|Grizzly|Cubs|Yogi/DEV/g'; }
hdr() { printf '\n==================== %s\n' "$*"; }

hdr "1. android-info.txt and factory zip contents"
for d in kodiak $OTHERS; do
    echo "-- $d: $(unzip -p $F/image-$d-$B.zip android-info.txt | tr '\n' ' ')"
    unzip -l $F/$d-$B-factory-*.zip | awk 'NR>3 && $4 ~ /[^\/]$/ {print "     " $1, $4}'
done

hdr "2. Partition images in image-*.zip (size, and same CRC as kodiak?)"
for d in kodiak $OTHERS; do
    unzip -v $F/image-$d-$B.zip | awk 'NR>3 && $8 ~ /\.(img|txt)$/ {print $8, $1, $7}' | sort > "$R/detail/images-$d.txt"
done
printf '%-24s %14s' image kodiak; for d in $OTHERS; do printf ' %22s' $d; done; echo
for img in $(cat "$R"/detail/images-*.txt | awk '{print $1}' | sort -u); do
    k=$(awk -v i=$img '$1==i' "$R/detail/images-kodiak.txt")
    row=$(printf '%-24s %14s' "$img" "$(awk '{print $2}' <<<"$k")")
    for d in $OTHERS; do
        o=$(awk -v i=$img '$1==i' "$R/detail/images-$d.txt")
        if [[ -z "$o" ]]; then c="ABSENT"
        elif [[ -z "$k" ]]; then c="$(awk '{print $2}' <<<"$o") (new)"
        elif [[ "$(awk '{print $3}' <<<"$o")" == "$(awk '{print $3}' <<<"$k")" ]]; then c="identical"
        else c="$(awk '{print $2}' <<<"$o") differs"; fi
        row+=$(printf ' %22s' "$c")
    done
    echo "$row"
done

hdr "3. Firmware partitions in firmware.txt vs each image zip"
for d in $OTHERS; do
    miss=""; for p in $(grep -vE '^(#|$)' $T/firmware.txt); do
        grep -q "^$p.img " "$R/detail/images-$d.txt" || miss+=" $p"
    done
    echo "$d: missing from its image zip:${miss:- none}"
done

hdr "4. super_empty.img (dynamic partition layout)"
for d in kodiak $OTHERS; do
    unzip -p $F/image-$d-$B.zip super_empty.img > "$R/detail/super_empty-$d.img"
    $H/lpdump "$R/detail/super_empty-$d.img" > "$R/detail/lpdump-$d.txt" 2>&1
done
for d in $OTHERS; do
    if diff -q "$R/detail/lpdump-kodiak.txt" "$R/detail/lpdump-$d.txt" >/dev/null; then echo "$d: identical to kodiak"
    else echo "$d: differs:"; diff "$R/detail/lpdump-kodiak.txt" "$R/detail/lpdump-$d.txt" | head -30; fi
done
grep -E "Size:|Maximum size|Name: " "$R/detail/lpdump-kodiak.txt" | head -12 | sed 's/^/  kodiak /'

hdr "5. vendor_boot header, kernel cmdline, bootconfig"
for d in kodiak $OTHERS; do
    python3 ~/evolution/system/tools/mkbootimg/unpack_bootimg.py --boot_img $D/$d/vendor_boot.img \
        --out "$R/detail/vb-$d" --format=mkbootimg > "$R/detail/vb-args-$d.txt" 2>&1
    python3 ~/evolution/system/tools/mkbootimg/unpack_bootimg.py --boot_img $D/$d/vendor_boot.img \
        --out "$R/detail/vb-$d" > "$R/detail/vb-info-$d.txt" 2>&1
done
for d in $OTHERS; do
    echo "-- $d vs kodiak (header/cmdline/bootconfig):"
    diff <(grep -viE "ramdisk|^ *$" "$R/detail/vb-info-kodiak.txt" | norm) \
         <(grep -viE "ramdisk|^ *$" "$R/detail/vb-info-$d.txt" | norm) && echo "   identical"
    cmp -s "$R/detail/vb-kodiak/bootconfig" "$R/detail/vb-$d/bootconfig" 2>/dev/null && echo "   bootconfig identical" \
        || { echo "   bootconfig differs:"; diff "$R/detail/vb-kodiak/bootconfig" "$R/detail/vb-$d/bootconfig" | head; }
done

hdr "6. vendor_boot ramdisk (first stage + recovery)"
for d in kodiak $OTHERS; do
    (cd $D/$d/vendor_boot/ramdisk && find . -type f -o -type l | sort) > "$R/detail/vbramdisk-$d.txt"
done
for d in $OTHERS; do
    echo "-- $d: files only in kodiak (<) / only in $d (>), names normalized:"
    diff <(norm < "$R/detail/vbramdisk-kodiak.txt") <(norm < "$R/detail/vbramdisk-$d.txt") | grep '^[<>]' | grep -v '\.ko$' | head -40
    echo "   .ko modules: kodiak $(grep -c '\.ko$' "$R/detail/vbramdisk-kodiak.txt"), $d $(grep -c '\.ko$' "$R/detail/vbramdisk-$d.txt")"
    for f in first_stage_ramdisk/system/etc/fstab.malibu init.recovery.malibu.rc; do
        cmp -s "$D/kodiak/vendor_boot/ramdisk/$f" "$D/$d/vendor_boot/ramdisk/$f" && echo "   $f: identical" \
            || { echo "   $f: DIFFERS"; diff "$D/kodiak/vendor_boot/ramdisk/$f" "$D/$d/vendor_boot/ramdisk/$f" | head -20; }
    done
    f=init.recovery.$d.rc
    [[ -f "$D/$d/vendor_boot/ramdisk/$f" ]] && { diff <(norm < $D/kodiak/vendor_boot/ramdisk/init.recovery.kodiak.rc) <(norm < $D/$d/vendor_boot/ramdisk/$f) >/dev/null \
        && echo "   $f: same as kodiak's (names normalized)" || { echo "   $f: DIFFERS from kodiak's"; diff <(norm < $D/kodiak/vendor_boot/ramdisk/init.recovery.kodiak.rc) <(norm < $D/$d/vendor_boot/ramdisk/$f) | head -20; }; } \
        || echo "   $f: ABSENT"
    for fw in $(cd $D/kodiak/vendor_boot/ramdisk/lib/firmware && ls usb_phy_fw*); do
        cmp -s "$D/kodiak/vendor_boot/ramdisk/lib/firmware/$fw" "$D/$d/vendor_boot/ramdisk/lib/firmware/$fw" && echo "   $fw: identical" || echo "   $fw: DIFFERS/ABSENT"
    done
    ls $D/$d/vendor_boot/ramdisk/lib/firmware/ | grep -i usb_phy | sed 's/^/   present: /'
    for h in android.hardware.boot-service.default_recovery-pixel android.hardware.health-service.malibu_recovery; do
        cmp -s "$D/kodiak/vendor_boot/ramdisk/system/bin/hw/$h" "$D/$d/vendor_boot/ramdisk/system/bin/hw/$h" && echo "   recovery $h: identical" || echo "   recovery $h: DIFFERS/ABSENT"
    done
done

hdr "7. Kernel modules (vendor_kernel_boot, vendor_dlkm, system_dlkm)"
for d in kodiak $OTHERS; do
    for p in vendor_kernel_boot vendor_dlkm system_dlkm; do
        find $D/$d/$p -name '*.ko' -printf '%f\n' 2>/dev/null | sort -u > "$R/detail/ko-$p-$d.txt"
    done
done
for d in $OTHERS; do
    for p in vendor_kernel_boot vendor_dlkm system_dlkm; do
        a=$(comm -23 "$R/detail/ko-$p-kodiak.txt" "$R/detail/ko-$p-$d.txt" | paste -sd' ')
        b=$(comm -13 "$R/detail/ko-$p-kodiak.txt" "$R/detail/ko-$p-$d.txt" | paste -sd' ')
        echo "$d $p: $(wc -l < "$R/detail/ko-$p-$d.txt") modules (kodiak $(wc -l < "$R/detail/ko-$p-kodiak.txt")); only kodiak: ${a:-none}; only $d: ${b:-none}"
    done
done

hdr "8. Screen (boot animation size, density)"
for d in kodiak $OTHERS; do
    echo "$d: bootanimation $(unzip -p $D/$d/product/media/bootanimation.zip desc.txt 2>/dev/null | head -1)," \
        "$(grep -h -E '^ro\.sf\.lcd_density|^ro\.surface_flinger\.(max_graphics|primary_display_orientation)' $D/$d/vendor/build.prop $D/$d/vendor/default.prop $D/$d/product/etc/build.prop 2>/dev/null | paste -sd' ')"
done

hdr "9. SELinux: our current build's system policy against each stock vendor policy"
for d in kodiak $OTHERS; do
    echo "-- $d:"
    (cd ~/evolution && device/google/kodiak/check-sepolicy.sh $H/secilc out/target/product/kodiak $D/$d/vendor 2>&1 | sed 's/^/   /')
done
for d in $OTHERS; do
    echo "-- $d vendor/etc/selinux vs kodiak (names normalized):"
    for f in $(ls $D/kodiak/vendor/etc/selinux | grep -v precompiled); do
        [[ -f $D/$d/vendor/etc/selinux/$f ]] || { echo "   $f: ABSENT"; continue; }
        n=$(diff <(norm < $D/kodiak/vendor/etc/selinux/$f) <(norm < $D/$d/vendor/etc/selinux/$f) | grep -c '^[<>]')
        [[ $n == 0 ]] || echo "   $f: $n changed lines"
        diff <(norm < $D/kodiak/vendor/etc/selinux/$f) <(norm < $D/$d/vendor/etc/selinux/$f) > "$R/detail/sepolicy-$d-$f.diff"
    done
    for f in $(ls $D/kodiak/system_ext/etc/selinux | grep -v -E 'precompiled|sha256'); do
        [[ -f $D/$d/system_ext/etc/selinux/$f ]] || { echo "   system_ext/$f: ABSENT"; continue; }
        n=$(diff <(norm < $D/kodiak/system_ext/etc/selinux/$f) <(norm < $D/$d/system_ext/etc/selinux/$f) | grep -c '^[<>]')
        [[ $n == 0 ]] || echo "   system_ext/$f: $n changed lines"
    done
done

hdr "10. VINTF HALs on the stock vendor (hardware features)"
for d in kodiak $OTHERS; do
    cat $D/$d/vendor/etc/vintf/manifest.xml $D/$d/vendor/etc/vintf/manifest/*.xml $D/$d/vendor/odm/etc/vintf/manifest*.xml 2>/dev/null |
        grep -oE '<(name|fqname)>[^<]+' | sed -E 's/<(name|fqname)>//' | sort -u > "$R/detail/hals-$d.txt"
done
for d in $OTHERS; do
    echo "$d: only kodiak: $(comm -23 "$R/detail/hals-kodiak.txt" "$R/detail/hals-$d.txt" | paste -sd' ')"
    echo "$d: only $d: $(comm -13 "$R/detail/hals-kodiak.txt" "$R/detail/hals-$d.txt" | paste -sd' ')"
done

hdr "11. Apps and overlays (product, system_ext, vendor; names normalized)"
for d in kodiak $OTHERS; do
    (cd $D/$d && find product/app product/priv-app product/overlay system_ext/app system_ext/priv-app vendor/app vendor/overlay vendor/priv-app \
        -name '*.apk' 2>/dev/null | norm | sort) > "$R/detail/apks-$d.txt"
done
for d in $OTHERS; do
    echo "-- $d: $(wc -l < "$R/detail/apks-$d.txt") APKs (kodiak $(wc -l < "$R/detail/apks-kodiak.txt"))"
    comm -23 "$R/detail/apks-kodiak.txt" "$R/detail/apks-$d.txt" | sed 's/^/   only kodiak: /'
    comm -13 "$R/detail/apks-kodiak.txt" "$R/detail/apks-$d.txt" | sed "s/^/   only $d: /"
done

hdr "12. Blobs in our proprietary-files lists (exists? identical to kodiak's?)"
blobs() { grep -vE '^(#|$)' "$1" | sed -E 's/^-//; s/;.*//; s/:.*//'; }
for list in $T/proprietary-files.txt ~/evolution/device/google/kodiak-personal/proprietary-files.txt $T/proprietary-files-carriersettings.txt; do
    [[ -f $list ]] || continue
    for d in $OTHERS; do
        same=0; diffl=""; miss=""
        for b in $(blobs $list); do
            if [[ ! -e $D/$d/$b ]]; then miss+=" $b"
            elif cmp -s $D/kodiak/$b $D/$d/$b; then same=$((same+1))
            else diffl+=" $b"; fi
        done
        echo "-- $(basename $(dirname $list))/$(basename $list) on $d: $same identical"
        [[ -z "$diffl" ]] || echo "$diffl" | tr ' ' '\n' | grep . | sed 's/^/   DIFFERS: /'
        [[ -z "$miss" ]] || echo "$miss" | tr ' ' '\n' | grep . | sed 's/^/   MISSING: /'
    done
done

hdr "13. Props our tree sets (product.prop, system_ext.prop) vs each stock device"
sprop() { cat $D/$1/product/etc/build.prop $D/$1/system_ext/etc/build.prop $D/$1/vendor/build.prop $D/$1/vendor/odm/etc/build.prop 2>/dev/null | grep -m1 "^$2=" | cut -d= -f2-; }
for f in product.prop system_ext.prop; do
    for k in $(grep -vE '^(#|$)' $T/$f | cut -d= -f1 | sort -u); do
        vk=$(sprop kodiak $k); line="$f $k: ours=[$(grep -m1 "^$k=" $T/$f | cut -d= -f2-)] kodiak=[$vk]"; diff=0
        for d in $OTHERS; do v=$(sprop $d $k); line+=" $d=[$v]"; [ "$v" = "$vk" ] || diff=1; done
        [ $diff = 0 ] || echo "$line"
    done
done
echo "(only keys whose stock values differ are listed)"

hdr "14. Build props: all stock differences (names normalized; build dates/ids dropped)"
for d in $OTHERS; do
    for p in vendor/build.prop vendor/odm/etc/build.prop product/etc/build.prop system_ext/etc/build.prop vendor_dlkm/etc/build.prop system/system/build.prop system/build.prop; do
        [[ -f $D/kodiak/$p ]] || continue
        diff <(grep -vE 'build\.(date|id)|incremental|fingerprint|description' $D/kodiak/$p | norm | sort) \
             <(grep -vE 'build\.(date|id)|incremental|fingerprint|description' $D/$d/$p | norm | sort) | grep '^[<>]' | sed "s|^|   $d $p |"
    done
done

hdr "15. vendor init scripts and firmware (names only, normalized)"
for d in kodiak $OTHERS; do
    (cd $D/$d && find vendor/etc/init vendor/firmware vendor/odm/etc/init -type f 2>/dev/null | norm | sort) > "$R/detail/vinit-$d.txt"
done
for d in $OTHERS; do
    comm -23 "$R/detail/vinit-kodiak.txt" "$R/detail/vinit-$d.txt" | sed 's/^/   only kodiak: /' | head -60
    comm -13 "$R/detail/vinit-kodiak.txt" "$R/detail/vinit-$d.txt" | sed "s/^/   only $d: /" | head -60
done
hdr "16. Product RROs (the ones our builds don't ship): framework-res and others, normalized"
for d in kodiak $OTHERS; do
    for apk in $D/$d/product/overlay/*__${d}__auto_generated_rro_product.apk; do
        n=$(basename $apk | sed "s/__${d}__/__DEV__/")
        $H/aapt2 dump resources $apk 2>/dev/null | grep -vE "^Package|^  type |^Binary" | sed -E 's/0x[0-9a-f]{8}//g' | norm > "$R/detail/rro-$d-$n.txt"
    done
done
for d in $OTHERS; do
    for f in "$R"/detail/rro-$d-*.txt; do
        n=${f##*/rro-$d-}; k="$R/detail/rro-kodiak-$n"
        if [ ! -f "$k" ]; then echo "$d only: $n"; continue; fi
        c=$(diff "$k" "$f" | grep -c '^[<>]'); [ "$c" = 0 ] || echo "$d $n: $c changed lines; resources only in $d: $(diff <(grep -oE 'resource [a-z]+/[A-Za-z0-9_.]+' $k | sort -u) <(grep -oE 'resource [a-z]+/[A-Za-z0-9_.]+' $f | sort -u) | grep '^>' | awk '{print $3}' | paste -sd' ' | cut -c1-900)"
    done
done
hdr "17. Device state and display config files on the stock vendor"
for d in kodiak $OTHERS; do
    echo "$d: $(cd $D/$d/vendor/etc && ls devicestate displayconfig 2>/dev/null | paste -sd' ')"
done
echo; echo REPORT_DONE
