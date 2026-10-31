# Sourced by devices-check.sh when its first argument is "ramdisk" (the runner's
# expressiveos-devices action with query "ramdisk"): why eos-verify.sh finds another init_boot
# ramdisk in a phone's OTA payload than in its out/init_boot.img, on a phone without KernelSU
# Next (EOS_KSU=none: the target-files step packs the build's ramdisk again). For each phone
# with an out/ in ExpressiveOS's tree it lists the dev/ entries (and every other entry that
# differs) of three init_boot ramdisks: out/'s, the target-files zip's and the newest OTA
# payload's, as name, mode, owner, device and size; then the build-file lines that pack them
# (the dev node list, the fs_config lines for dev/, how mkbootfs and releasetools use them).
# Read-only, with devices-check.sh's helpers and rules: it writes only under its mktemp folder.
# shellcheck shell=bash
here_kit=$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
H=$eos/out/host/linux-x86/bin
entries() {   # entries <ramdisk> <out file>: one "name mode uid gid rdev size" line per cpio entry
    python3 -I - "$1" > "$2" <<'PY' || return 1
import subprocess, sys
raw = None
for cmd in (["lz4", "-dc", sys.argv[1]], ["gzip", "-dc", sys.argv[1]]):
    try:
        r = subprocess.run(cmd, capture_output=True)
    except OSError:
        continue
    if r.returncode == 0 and r.stdout:
        raw = r.stdout
        break
if raw is None:
    sys.exit("can't decompress " + sys.argv[1])
i = 0
while i + 110 <= len(raw):
    if raw[i:i + 6] not in (b"070701", b"070702"):
        sys.exit(f"not a newc cpio at byte {i}")
    f = [int(raw[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
    n = i + 110
    name = raw[n:n + f[11] - 1].decode("utf-8", "surrogateescape")
    d = (n + f[11] + 3) & ~3
    if name == "TRAILER!!!":
        break
    print(f"{name} {f[1]:07o} {f[2]} {f[3]} {f[9]}:{f[10]} {f[6]}")
    i = (d + f[6] + 3) & ~3
PY
}
ramdisk_of() {   # ramdisk_of <init_boot image> <label>: $work/<label>.list, its ramdisk's entries
    rm -rf -- "$work/u.$2"; mkdir -p -- "$work/u.$2"
    if [[ -x $H/unpack_bootimg ]]; then "$H/unpack_bootimg" --boot_img "$1" --out "$work/u.$2" > /dev/null 2>&1
    else mkbootimg_unpack "$1" "$work/u.$2"; fi || { echo "$2: can't unpack ${1#"$HOME"/}"; return 1; }
    entries "$work/u.$2/ramdisk" "$work/$2.list" || { echo "$2: can't read its ramdisk"; return 1; }
    echo "$2: ${1#"$HOME"/}, sha256 $(sha256sum < "$1" | cut -c1-16), ramdisk $(wc -l < "$work/$2.list") entries, sha256 $(sha256sum < "$work/u.$2/ramdisk" | cut -c1-16)"
}

found=0
for d in "${DEVICES[@]}"; do
    O=$eos/out/target/product/$d
    [[ -f $O/init_boot.img ]] || continue
    found=1
    h "$d: init_boot ramdisks (name mode uid gid major:minor bytes)"
    lists=()
    ramdisk_of "$O/init_boot.img" out && lists+=(out)
    tf=$(find "$O/obj/PACKAGING/target_files_intermediates" -maxdepth 1 -name '*-target_files.zip' 2> /dev/null | head -n 1)
    if [[ -n $tf ]] && unzip -p -- "$tf" IMAGES/init_boot.img > "$work/tf-init_boot.img" 2> /dev/null && [[ -s $work/tf-init_boot.img ]]; then
        ramdisk_of "$work/tf-init_boot.img" target-files && lists+=(target-files)
    else
        echo "target-files: no IMAGES/init_boot.img${tf:+ in ${tf#"$HOME"/}}"
    fi
    ota=$(ls -t -- "$O"/ExpressiveOS-*-"$d"-*.zip 2> /dev/null | head -n 1)
    if [[ -n $ota && -x $H/ota_extractor ]] && off=$(python3 -I "$here_kit/tools/payload.py" offset "$ota" 2> /dev/null); then
        mkdir -p -- "$work/x.$d"
        if "$H/ota_extractor" -payload "$ota" -payload_offset "$off" -output_dir "$work/x.$d" -partitions init_boot > /dev/null 2>&1; then
            echo "payload: ${ota##*/}"
            ramdisk_of "$work/x.$d/init_boot.img" payload && lists+=(payload)
        else
            echo "payload: ota_extractor couldn't extract init_boot from ${ota##*/}"
        fi
        rm -rf -- "$work/x.$d"
    else
        echo "payload: no OTA package in out/ (or no ota_extractor)"
    fi
    for l in "${lists[@]}"; do
        echo "-- $l: dev/ entries"
        grep -E '^dev( |/)' "$work/$l.list" || echo "(none)"
    done
    for l in "${lists[@]}"; do
        [[ $l != out ]] || continue
        echo "-- out/ vs $l: entries that differ (< out/, > $l), first 30"
        diff <(sort "$work/out.list") <(sort "$work/$l.list") | grep '^[<>]' | head -n 30 || true
    done
    if [[ -n $tf ]]; then
        echo "-- target-files META: node lists and fs_config files"
        unzip -Z1 -- "$tf" 'META/*' 2> /dev/null | grep -iE 'node|filesystem_config|fs_config' || echo "(none)"
        for m in $(unzip -Z1 -- "$tf" 'META/*' 2> /dev/null | grep -iE 'node_list|dev_node'); do
            echo "$m:"; unzip -p -- "$tf" "$m" | head -n 20
        done
        for m in $(unzip -Z1 -- "$tf" 'META/*' 2> /dev/null | grep -iE '(init_boot|ramdisk|boot)_filesystem_config'); do
            echo "$m, its first line and dev lines:"; unzip -p -- "$tf" "$m" | sed -n '1p; /^dev[ /]/p' | head -n 12
        done
        echo "misc_info.txt lines on ramdisks and init_boot:"
        unzip -p -- "$tf" META/misc_info.txt 2> /dev/null | grep -iE 'ramdisk|init_boot|node' | head -n 20
    fi
done
(( found )) || echo "no phone has an out/target/product/<device>/init_boot.img in $eos"

h "how the build packs ramdisks (build-file lines)"
grep -nE 'NODE_LIST|node_list|dev_node' "$eos/build/make/core/Makefile" 2> /dev/null | head -n 30
for f in "$eos/build/make/tools/releasetools/common.py" "$eos/build/make/tools/releasetools/add_img_to_target_files.py"; do
    echo "-- ${f#"$eos"/}"
    grep -nE 'mkbootfs|node|fs_config_file|def _MakeRamdisk|def _BuildBootableImage' "$f" 2> /dev/null | head -n 30
done
m=$(find "$eos/system/core/mkbootfs" -maxdepth 1 -name 'mkbootfs.c*' 2> /dev/null | head -n 1)
if [[ -n $m ]]; then
    echo "-- ${m#"$eos"/}"
    grep -nE 'fix_stat|canned|empty_path|nod|S_IFCHR|-n' "$m" | head -n 40
fi
git -C "$eos/build/make" log -1 --format='build/make at %h %ci %s' 2> /dev/null
git -C "$eos/system/core" log -1 --format='system/core at %h %ci %s' 2> /dev/null
