# Sourced by devices-check.sh when its first argument is "v4a" (the runner's
# expressiveos-devices action with query "v4a"): read-only, what each Pixel 11's stock vendor
# image says about putting ViPER4Android's AIDL driver beside Google's audio HAL
# (viper4android/README.md, "Pixel 11"). For each phone it reads the vendor.img the build ships
# (vendor/google/<phone>-images/images/vendor.img, extracted with the tree's own fsck.erofs into
# devices-check.sh's mktemp folder, no root, removed after), or ~/android-dt/dumps/<phone>/vendor
# when that can't be done, and prints: the vendor props that matter (ro.vndk.version,
# ro.board.api_level), any audio_effects* config, the soundfx library names, the audio HAL's
# binary, rc service lines and vendor APEXes, which of a fixed list of strings the HAL binary
# contains, its effect/audio NEEDED libraries, the VINTF effect HAL entry, the vendor policy's
# version, the hal_audio_server members, the labels vendor_file_contexts gives under /vendor/etc,
# mounts the vendor makes under /vendor/etc or /vendor/lib64, executables under /vendor/etc, and
# the driver's vendor-side dependencies. With devices-check.sh's helpers and rules: names,
# labels, build-file lines and counts, never a proprietary file's contents.
# shellcheck shell=bash
hostbin=$eos/out/host/linux-x86/bin
tool() {  # <name>: the first runnable copy, the tree's host build first
    local t
    for t in "$hostbin/$1" ~/bin/"$1" "$(command -v "$1" 2> /dev/null)"; do
        [[ -n $t && -x $t ]] && { echo "$t"; return 0; }
    done
    return 1
}
fsck=$(tool fsck.erofs) || fsck=
s2i=$(tool simg2img) || s2i=
echo "fsck.erofs: ${fsck:-none}${fsck:+ ($("$fsck" -V 2>&1 | head -1))}; simg2img: ${s2i:-none}"

extract() {  # <phone> <vendor.img> <dir>: extract it rootless, keeping modes when it can
    local raw=$2
    if [[ "$(od -An -tx1 -N4 "$2" | tr -d ' \n')" = 3aff26ed ]]; then
        [[ -n $s2i ]] || { echo "sparse image and no simg2img"; return 1; }
        raw=$work/$1-vendor.raw
        "$s2i" "$2" "$raw" > /dev/null 2>&1 || { echo "simg2img failed"; rm -f "$raw"; return 1; }
    fi
    if ! "$fsck" --extract="$3" --no-preserve-owner "$raw" > "$work/$1-fsck.log" 2>&1; then
        rm -rf "$3"
        "$fsck" --extract="$3" --no-preserve "$raw" > "$work/$1-fsck.log" 2>&1 \
            || { echo "fsck.erofs: $(tail -2 "$work/$1-fsck.log" | tr '\n' ' ')"; rm -rf "$3"; [[ $raw = "$2" ]] || rm -f "$raw"; return 1; }
    fi
    [[ $raw = "$2" ]] || rm -f "$raw"
}

for d in "${P11[@]}"; do
    h "ViPER4Android facts: $d's stock vendor"
    imgs=$eos/vendor/google/$d-images
    echo "images: $(cat "$imgs/SOURCE" 2> /dev/null || echo 'no SOURCE')"
    V=
    if [[ -f $imgs/images/vendor.img && -n $fsck ]]; then
        if extract "$d" "$imgs/images/vendor.img" "$work/$d-vendor"; then
            V=$work/$d-vendor
            echo "read from: vendor/google/$d-images/images/vendor.img ($(stat -c %s "$imgs/images/vendor.img") bytes, sha256 $(sha256sum "$imgs/images/vendor.img" | cut -c1-16)...)"
        fi
    fi
    if [[ -z $V && -d ~/android-dt/dumps/$d/vendor ]]; then
        V=~/android-dt/dumps/$d/vendor
        echo "read from: ~/android-dt/dumps/$d/vendor (may be older than the images: compare the fingerprint)"
    fi
    [[ -n $V ]] || { echo "no vendor to read"; continue; }

    echo "-- props: $(grep -hE '^ro\.(vendor\.build\.fingerprint|vndk\.version|board\.api_level|board\.first_api_level|vendor\.api_level)=' "$V/build.prop" "$V/default.prop" "$V/etc/build.prop" 2> /dev/null | tr '\n' ' ')"
    echo "-- audio_effects* files: $(cd "$V" && find . -iname '*audio_effects*' 2> /dev/null | sed 's|^\./||' | tr '\n' ' ')"
    echo "-- lib64/soundfx: $(ls "$V/lib64/soundfx" 2> /dev/null | tr '\n' ' ' || true)"
    echo "-- bin/hw audio: $(ls "$V/bin/hw" 2> /dev/null | grep -i audio | tr '\n' ' ')"
    echo "-- apex: $(ls "$V/apex" 2> /dev/null | tr '\n' ' ')"
    echo "-- audio HAL rc files:"
    grep -lE 'audio\.service|audio-hal|audio\.effect' "$V"/etc/init/*.rc "$V"/etc/init/hw/*.rc 2> /dev/null | while read -r f; do
        echo "   ${f#"$V"/}:"
        grep -nE '^[[:space:]]*(service|class|critical|onrestart|disabled|oneshot|user|group)\b' "$f" | head -20 | sed 's/^/     /'
    done
    for f in "$V"/bin/hw/*audio*; do
        [[ -f $f ]] || continue
        echo "-- ${f#"$V"/}: $(stat -c %s "$f") bytes; strings found:"
        strings -n 6 "$f" > "$work/$d-strings" 2> /dev/null
        for s in /vendor/etc/audio_effects_config.xml /vendor/lib64/soundfx/ /odm/ /system/etc/ /apex/ audio/config ro.boot.product.vendor.sku \
                 libbundleaidl.so libdynamicsprocessingaidl.so libvisualizeraidl.so createEffect queryEffect; do
            echo "     $s: $(grep -cF -- "$s" "$work/$d-strings")"
        done
        echo "   NEEDED (audio/effect/apex): $(readelf -d "$f" 2> /dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | grep -iE 'effect|audio|apex' | tr '\n' ' ')"
        rm -f "$work/$d-strings"
    done
    echo "-- VINTF effect HAL: $(grep -rh -A8 'android.hardware.audio.effect' "$V/etc/vintf" 2> /dev/null | grep -oE '<(name|version|fqname|instance)>[^<]*' | sort -u | tr '\n' ' ')"
    se=$V/etc/selinux
    echo "-- plat_sepolicy_vers: $(cat "$se/plat_sepolicy_vers.txt" 2> /dev/null)"
    echo "-- hal_audio_server members: $(grep -oE '\(typeattributeset hal_audio_server \([^)]*\)\)' "$se/vendor_sepolicy.cil" 2> /dev/null | tr '\n' ' ')"
    echo "-- audio HAL labels: $(grep -E 'audio.{1,2}service|audio-hal' "$se/vendor_file_contexts" 2> /dev/null | awk '{print $1, $NF}' | tr '\n' ' ')"
    echo "-- files under etc/selinux naming viper (want none): $(grep -rli viper "$se" 2> /dev/null | sed "s|^$V/||" | tr '\n' ' ')"
    echo "-- labels vendor_file_contexts gives under /vendor/etc:"
    grep -E '^/(\(vendor\|system/vendor\)|vendor|system/vendor)/etc' "$se/vendor_file_contexts" 2> /dev/null | awk '{print "     " $1, $NF}' | head -80
    types=$(grep -E '^/(\(vendor\|system/vendor\)|vendor|system/vendor)/etc' "$se/vendor_file_contexts" 2> /dev/null | awk '{print $NF}' | sed -E 's/^u:object_r:([^:]+):.*/\1/' | sort -u)
    vft=$(grep -oE '\(typeattributeset vendor_file_type \([^)]*\)\)' "$se/vendor_sepolicy.cil" 2> /dev/null | tr ' ()' '\n\n\n' | sort -u)
    echo "-- of those, types the vendor CIL doesn't put in vendor_file_type (platform types like vendor_configs_file are, in platform policy): $(for t in $types; do grep -qx "$t" <<< "$vft" || printf '%s ' "$t"; done)"
    echo "-- vendor mounts under /vendor/etc or /vendor/lib64:"
    grep -nE '^[[:space:]]*mount[[:space:]]' "$V"/etc/init/*.rc "$V"/etc/init/hw/*.rc 2> /dev/null | grep -E '/vendor/(etc|lib64)' | sed "s|^$V/|     |" | head -10
    for f in "$V"/etc/fstab*; do
        [[ -f $f ]] && awk -v n="${f##*/}" '$2 ~ /^\/vendor\// {print "     " n ": " $2}' "$f"
    done
    echo "-- executables under etc: $(cd "$V" && find etc -type f -perm /111 2> /dev/null | head -20 | tr '\n' ' ')"
    echo "-- driver's vendor-side deps: $(for l in libbase libfmq libcutils; do [[ -f $V/lib64/$l.so ]] && printf '%s ' "$l.so" || printf 'MISSING:%s ' "$l.so"; done)"
    [[ $V = "$work"/* ]] && rm -rf "$V"
done
echo "V4A_P11_CHECK=DONE"
