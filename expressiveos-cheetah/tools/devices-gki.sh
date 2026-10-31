# Sourced by devices-check.sh when its first argument is "gki" (the runner's
# expressiveos-devices action with query "gki"): what building ExpressiveOS's own kernelsu.ko
# for the Pixel 11s needs. Their kernel is Google's stock android16-6.12 GKI (EOS_KERNEL=prebuilt),
# so there is no kernel source in the tree to build against, as there is for cheetah and husky
# (gs-6.1, build_kernel). Read-only, with devices-check.sh's helpers and rules: it reads the
# stock boot images and the kit's KernelSU Next download, and asks Google's public servers
# (android.googlesource.com, ci.android.com) about the stock kernel's source and build. It
# prints names, versions, commit SHAs and kernel config lines (the GKI is GPL), never a
# proprietary file's contents, and writes only under devices-check.sh's mktemp folder, except
# its last part, the trial: KernelSU Next's DDK fetched and kernelsu.ko built in a scratch folder
# in ~ (about 12G, removed at the end), only while ~ has 80G free, so a build beside it keeps
# room.
# shellcheck shell=bash
gs=https://android.googlesource.com ci=https://ci.android.com
get() { timeout 60 curl -fsSL --retry 2 "$@"; }
# This checkout's kit (devices-check.sh's $kit is the one the last build installed)
here_kit=$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
# Gitiles: a file at a commit, base64 (?format=TEXT); JSON behind a )]}' line (?format=JSON)
gitiles_file() { get "$gs/$1/+/$2/$3?format=TEXT" | base64 -d; }
gitiles_json() { get "$gs/$1/+/$2?format=JSON" | sed 1d; }

h "stock Pixel 11 boot images: kernel release (the trees' prebuilt boot.img)"
first=
for d in "${P11[@]}"; do
    while IFS= read -r b; do
        if kernel_image "$b" "$work/Image.gki.$d"; then
            echo "$d: ${b#"$HOME"/}: sha256 $(sha256sum < "$b" | cut -c1-16) $(strings "$work/Image.gki.$d" | grep -m1 '^Linux version' | cut -c1-200)"
            [[ -n $first ]] || first=$d
        else
            echo "$d: couldn't unpack ${b#"$HOME"/}"
        fi
        break
    done < <(find "$eos/vendor/google/$d-images" "$evo/vendor/google/$d-images" -maxdepth 3 -name boot.img 2> /dev/null)
done
[[ -n $first ]] || { echo "no stock Pixel 11 boot.img found"; return 0; }
img=$work/Image.gki.$first
rel=$(strings "$img" | grep -m1 '^Linux version' | awk '{print $3}')
sha=$(grep -oE -- '-g[0-9a-f]{12,40}' <<<"$rel" | head -1); sha=${sha#-g}
bid=$(grep -oE -- '-ab[0-9]+' <<<"$rel" | head -1); bid=${bid#-ab}
echo "release $rel: kernel/common ${sha:-?}, ci.android.com build ${bid:-?}"

h "stock kernel config ($first, CONFIG_IKCONFIG): the options a module build has to match"
if koinfo config "$img" > "$work/stock.config" 2> /dev/null && [[ -s $work/stock.config ]]; then
    echo "$(grep -c '^CONFIG_' "$work/stock.config") options set, sha256 $(sha256sum < "$work/stock.config" | cut -c1-16)"
    grep -E '^(# )?CONFIG_(RUST|RUSTC_[A-Z_]+|BINDGEN_[A-Z_]+|CC_VERSION_TEXT|CLANG_VERSION|LD_VERSION|PAHOLE_VERSION|MODVERSIONS|GENDWARFKSYMS|GENKSYMS|ASM_MODVERSIONS|EXTENDED_MODVERSIONS|BASIC_MODVERSIONS|MODULE_SIG[A-Z_]*|MODULE_FORCE_LOAD|MODULE_UNLOAD|MODULE_SCMVERSION|MODULE_SRCVERSION_ALL|TRIM_UNUSED_KSYMS|LTO[A-Z_]*|CFI[A-Z_]*|DEBUG_INFO[A-Z_]*|KALLSYMS[A-Z_]*|LOCALVERSION[A-Z_]*|ARM64_[0-9]+K_PAGES|PAGE_SIZE_[0-9]+KB|SECURITY_SELINUX[A-Z_]*|KPROBES|KRETPROBES|HAVE_KPROBES|FTRACE|STACKPROTECTOR[A-Z_]*|SHADOW_CALL_STACK|ANDROID_VENDOR_HOOKS|GKI_HACKS[A-Z_]*|KSU[A-Z_]*)[= ]' \
        "$work/stock.config" | cut -c1-200
else
    echo "no IKCONFIG in $first's kernel"
fi

h "the stock kernel's source: kernel/common ${sha:-?} on $gs"
if [[ -n $sha ]] && j=$(gitiles_json kernel/common "$sha"); then
    python3 -I -c 'import json,sys; c=json.load(sys.stdin); print("commit", c["commit"], c["committer"]["time"], "|", c["message"].splitlines()[0][:100])' <<<"$j" \
        || echo "couldn't read the commit's JSON"
    full=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["commit"])' <<<"$j" 2> /dev/null || echo "$sha")
    echo "-- build.config.constants"
    gitiles_file kernel/common "$full" build.config.constants | grep -vE '^\s*(#|$)' | cut -c1-200 || echo "(none)"
    echo "-- Makefile"
    gitiles_file kernel/common "$full" Makefile | grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' || echo "(couldn't read it)"
    echo "-- gki_defconfig: Rust, symbol versions, module signing"
    gitiles_file kernel/common "$full" arch/arm64/configs/gki_defconfig > "$work/gki_defconfig" || true
    grep -E 'CONFIG_(RUST|MODVERSIONS|GENDWARFKSYMS|MODULE_SIG|TRIM_UNUSED_KSYMS|LTO|CFI|DEBUG_INFO)' "$work/gki_defconfig" | cut -c1-160 || echo "(none of them)"
    echo "-- rust/ and the Rust options in init/Kconfig"
    gitiles_file kernel/common "$full" init/Kconfig | grep -nE 'config RUST|RUSTC_VERSION|BINDGEN|depends on RUST|depends on !MODVERSIONS|GENDWARFKSYMS' | head -20 || true
    gitiles_file kernel/common "$full" scripts/min-tool-version.sh | grep -A1 -E 'rustc|bindgen' | head -8 || true
else
    echo "can't read kernel/common $sha from $gs"
fi

h "release branches and manifests for android16-6.12 on $gs"
timeout 60 git -c credential.helper= ls-remote "$gs/kernel/manifest" 'refs/heads/*android16-6.12*' 2> /dev/null \
    | sed -E 's#\trefs/heads/# #' | cut -c1-12,41- | tail -25 || echo "can't list kernel/manifest's branches"
echo "-- kernel/common: the android16-6.12 release branches whose tip is or contains ${sha:-?}"
timeout 60 git -c credential.helper= ls-remote "$gs/kernel/common" 'refs/heads/android16-6.12*' 2> /dev/null > "$work/common-heads" || true
wc -l < "$work/common-heads" | sed 's/^/branches: /'
sed -E 's#\trefs/heads/# #' "$work/common-heads" | cut -c1-12,41- | tail -15
[[ -z $sha ]] || grep "^$sha" "$work/common-heads" | sed 's/^/tip is the stock commit: /' || true

h "ci.android.com build ${bid:-?}: its repo manifest (project, path, revision) and the files it offers"
if [[ -n $bid ]]; then
    for t in kernel_aarch64 kernel_kleaf; do
        for u in "$ci/builds/submitted/$bid/$t/latest/raw/manifest_$bid.xml" "$ci/builds/submitted/$bid/$t/latest/manifest_$bid.xml"; do
            code=$(timeout 60 curl -sSL -o "$work/manifest.xml" -w '%{http_code}' "$u" 2> /dev/null || echo 000)
            echo "$code ${u#"$ci"/}"
            if [[ $code = 200 ]] && grep -q '<manifest' "$work/manifest.xml"; then
                grep -oE '<project [^>]*>' "$work/manifest.xml" | grep -oE '(name|path|revision|upstream|clone-depth)="[^"]*"' \
                    | awk '/^name=/ { if (l) print l; l=$0; next } { l=l" "$0 } END { if (l) print l }' | cut -c1-220
                break 2
            fi
        done
    done
    echo "-- artifacts (HTTP status of the ones a module build could use)"
    for f in BUILD_INFO kernel-headers.tar.gz kernel-uapi-headers.tar.gz Module.symvers vmlinux.symvers System.map \
             abi_symbollist abi_symbollist.raw kernel_aarch64_ddk_headers_archive.tar.gz kernel_aarch64_internal_outs.tar.gz \
             kernel_aarch64_modules_prepare_outdir.tar.gz modules_prepare_outdir.tar.gz kernel_aarch64_kmi_symbol_list ddk_artifacts.tar.gz \
             toolchain_version build.config.constants; do
        code=$(timeout 60 curl -sSL -o /dev/null -r 0-0 -w '%{http_code}' "$ci/builds/submitted/$bid/kernel_aarch64/latest/raw/$f" 2> /dev/null || echo 000)
        echo "$code $f"
    done
fi

h "KernelSU Next (the kit's pin) for android16-6.12"
v=$(sed -n 's/^version=//p' "$kit/ksu/ksu.conf" 2> /dev/null | head -1)
src=$HOME/android-dt/ksu/$v/src
echo "pinned $v; source $( [[ -d $src/.git ]] && git -C "$src" log -1 --format='%h %cs %s' | cut -c1-90 || echo "missing ($src)")"
if [[ -d $src ]]; then
    echo "-- where the source names 6.12 or android16 (file: count)"
    grep -rlE 'android16|6\.12|KERNEL_VERSION\(6, ?12' "$src" --include='*.c' --include='*.h' --include='Kbuild' --include='Makefile' \
        --include='*.rs' --include='*.yml' --include='*.yaml' --include='*.sh' 2> /dev/null \
        | while read -r f; do echo "${f#"$src"/}: $(grep -cE 'android16|6\.12|KERNEL_VERSION\(6, ?12' "$f")"; done | head -40
    echo "-- the LKM build in its CI (job names, images and KMIs)"
    for f in "$src"/.github/workflows/*.yml; do
        [[ -f $f ]] || continue
        grep -qiE 'lkm|ddk|kernelsu\.ko' "$f" || continue
        echo "${f#"$src"/}:"
        grep -nE 'android1[2-9]-[0-9.]+|ddk|image:|container:|kernel_version|KMI' "$f" | cut -c1-160 | head -25
    done
    echo "-- kernel/Kbuild and kernel/Makefile lines about versions and flags"
    for f in "$src"/kernel/Kbuild "$src"/kernel/Makefile; do
        [[ -f $f ]] && grep -nE 'VERSION|ccflags|KBUILD_MODPOST|MODVERSIONS|obj-' "$f" | cut -c1-160 | head -20
    done
fi
echo "-- ksud's embedded modules"
k=$HOME/android-dt/ksu/$v/ksud
[[ -f $k ]] && echo "${k#"$HOME"/}: $(strings "$k" | grep -oE '(aarch64_)?android1[2-9]-[0-9]+\.[0-9]+_(kernelsu|susfs_guard_lkm)\.ko' | sort -u | tr '\n' ' ')"
echo "-- the manager's libksud.so (in the tree's built product): its susfs guard module for 6.12"
for l in "$eos"/out/target/product/*/product/app/KernelSUNext/lib/arm64/libksud.so; do
    [[ -f $l ]] || continue
    if out=$(python3 -I "$kit/ksu/tools/ko-info.py" embedded "$l" susfs_guard_lkm 6.12. "$work/guard612.ko" 2>&1); then
        echo "${l#"$HOME"/}: has one: $out"
        python3 -I "$kit/ksu/tools/ko-info.py" this-module "$work/guard612.ko" 2> /dev/null | awk '{print "its struct module: " $1 " bytes"}'
    else
        echo "${l#"$HOME"/}: none ($(tail -1 <<<"$out" | cut -c1-120))"
    fi
    break
done

h "KernelSU Next's kernel/Makefile (the DDK build runs make in kernel/) and ksuinit's module loader"
if [[ -d $src ]]; then
    echo "---- kernel/Makefile"
    grep -vE '^\s*$' "$src/kernel/Makefile" | cut -c1-200 | head -80
    echo "---- kernel/Kbuild: the manager and version lines"
    grep -nE 'MANAGER|KSU_NEXT_|KDIR|KERNEL_SRC' "$src/kernel/Kbuild" | cut -c1-200 | head -30
    echo "---- ksuinit: how it loads kernelsu.ko (vermagic, symbols, flags)"
    grep -rnE -i 'vermagic|modinfo|SHN_ABS|kallsyms|init_module|IGNORE_|modversions|__versions' "$src/userspace/ksuinit/src" 2> /dev/null \
        | sed "s#^$src/##" | cut -c1-200 | head -40
    echo "---- ksud boot-patch: the KMI and -m (module) lines"
    grep -rnE 'kmi|KMI|fn .*module|--module|"-m"' "$src/userspace/ksud/src/boot_patch.rs" 2> /dev/null | cut -c1-180 | head -30
fi
echo "-- the arm64 android16-6.12 kernelsu.ko ksud embeds (what boot-patch --kmi android16-6.12 uses without -m)"
ko612=$work/ksu612.ko
if [[ -f $k ]] && out=$(python3 -I "$here_kit/ksu/tools/ko-info.py" embedded "$k" kernelsu 6.12. "$ko612" 2>&1); then
    echo "found: $out"
    python3 -I "$here_kit/ksu/tools/ko-info.py" this-module "$ko612" 2> /dev/null | awk '{print "its struct module: " $1 " bytes"}'
    echo "sha256 $(sha256sum < "$ko612" | cut -c1-16), $(stat -c %s "$ko612") bytes, __versions sections: $(readelf -S "$ko612" 2> /dev/null | grep -c '__versions')"
    strings "$ko612" | grep -E '^(name|vermagic|srcversion|depends|license)=' | head -6 || true
    echo "undefined symbols: $(readelf -sW "$ko612" 2> /dev/null | awk '$7 == "UND" && $8 != ""' | wc -l)"
    echo "mentions of /data/app: $(strings "$ko612" | grep -c '/data/app'), of /product/app: $(strings "$ko612" | grep -c '/product/app')"
else
    echo "none found in ${k#"$HOME"/}: $(tail -1 <<<"${out:-}" | cut -c1-160)"
fi

h "the DDK image KernelSU Next builds its modules in (ghcr.io/ylarod/ddk-min:android16-6.12-<release>)"
rel=$(grep -A4 -E '^\s*ddk_release:' "$src/.github/workflows/ddk-lkm-ksu.yml" 2> /dev/null | sed -nE "s/^\s*default: *['\"]?([A-Za-z0-9._-]+)['\"]?.*/\1/p" | head -1)
echo "the CI's ddk_release default: ${rel:-?}"
tok=$(timeout 60 curl -fsS "https://ghcr.io/token?scope=repository:ylarod/ddk-min:pull" 2> /dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2> /dev/null || true)
reg() {  # <path under /v2/ylarod/ddk-min/> <out file> [Accept]
    timeout 120 curl -fsSL -H "Authorization: Bearer $tok" ${3:+-H "Accept: $3"} -D "$2.hdr" -o "$2" "https://ghcr.io/v2/ylarod/ddk-min/$1"
}
accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'
if [[ -n $tok && -n $rel ]]; then
    for tag in "android16-6.12-$rel" android16-6.12; do
        echo "---- tag $tag"
        reg "manifests/$tag" "$work/m.json" "$accept" 2> /dev/null || { echo "no manifest"; continue; }
        echo "digest $(grep -i '^docker-content-digest' "$work/m.json.hdr" | tr -d '\r' | awk '{print $2}')"
        mt=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("mediaType",""))' "$work/m.json")
        echo "mediaType $mt"
        if [[ $mt = *index* || $mt = *list* ]]; then
            python3 -I -c 'import json,sys; [print("platform", x.get("platform",{}).get("os"), x.get("platform",{}).get("architecture"), x["digest"]) for x in json.load(open(sys.argv[1]))["manifests"]]' "$work/m.json"
            d=$(python3 -I -c 'import json,sys; print(next(x["digest"] for x in json.load(open(sys.argv[1]))["manifests"] if x.get("platform",{}).get("architecture")=="amd64"))' "$work/m.json" 2> /dev/null || true)
            if [[ -z $d ]] || ! reg "manifests/$d" "$work/m.json" "$accept" 2> /dev/null; then echo "no amd64 manifest"; continue; fi
        fi
        python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); L=m.get("layers",[]); [print("layer", x["mediaType"].split(".")[-1], x["size"], x["digest"]) for x in L]; print("layers total %.2f GB" % (sum(x["size"] for x in L)/1e9)); print("config", m["config"]["digest"])' "$work/m.json"
        cfg=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"]["digest"])' "$work/m.json")
        if reg "blobs/$cfg" "$work/c.json" 2> /dev/null; then
            python3 -I - "$work/c.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("os/arch", c.get("os"), c.get("architecture"), "created", c.get("created"))
cc = c.get("config", {})
for k in ("Env", "Entrypoint", "Cmd", "WorkingDir", "User", "Labels"):
    v = cc.get(k)
    if v:
        for x in (v if isinstance(v, list) else [v]) if not isinstance(v, dict) else ["%s=%s" % i for i in v.items()]:
            print("%s: %s" % (k, str(x)[:300]))
for i, h in enumerate(c.get("history", [])):
    print("history %d%s: %s" % (i, " (empty)" if h.get("empty_layer") else "", h.get("created_by", "")[:400].replace("\n", " ")))
PY
        fi
    done
else
    echo "no anonymous pull token from ghcr.io, or no ddk_release"
fi
for c in docker podman skopeo crane umoci; do p=$(command -v "$c" 2> /dev/null || true); echo "$c: ${p:-not installed}"; done
[[ -f /usr/include/elfutils/libdw.h ]] && echo "libdw-dev: installed (gendwarfksyms can build)" || echo "libdw-dev: not installed"

h "host tools a 6.12 module build may use (the server's own; Google's prebuilts are preferred)"
for c in rustc bindgen pahole clang make bc flex bison lz4 git-lfs repo; do
    p=$(command -v "$c" 2> /dev/null || true)
    echo "$c: ${p:-not installed}${p:+ ($("$p" --version 2> /dev/null | head -1 | cut -c1-80))}"
done
df -BG ~ | sed 1d

h "trial: ExpressiveOS's own kernelsu.ko for android16-6.12 with KernelSU Next's DDK (ksu/tools/ksu-ddk.sh, in a scratch folder)"
# The DDK unpacks to about 12G: a scratch folder on the home disk, not /tmp, removed at the end
free=$(df -BG --output=avail ~ | tail -1 | tr -dc 0-9)
if (( free < 80 )); then
    echo "skipped: ~ has ${free}G free; the trial takes about 12G and runs only with 80G free (a build beside it needs the rest)"
    return 0
fi
big=$(mktemp -d ~/eos-gki-trial.XXXXXX)
trap 'rm -rf "$work" "$big"' EXIT
df -BG /tmp ~ | sed 1d
ddk=$big/ddk K=android16-6.12
if nice -n 19 bash "$here_kit/ksu/tools/ksu-ddk.sh" fetch "$K" "$ddk"; then
    kd=$ddk/kdir/$K
    echo "-- layout"
    find "$ddk" -mindepth 1 -maxdepth 2 | sed "s#^$ddk/##" | sort | head -30
    echo "-- the prepared tree: kernel.release $(cat "$kd/include/config/kernel.release" 2> /dev/null || echo '?'), Module.symvers $(wc -l < "$kd/Module.symvers" 2> /dev/null || echo none) lines"
    head -8 "$kd/Makefile"
    find "$kd" -maxdepth 1 | sed "s#^$kd/##" | sort | tr '\n' ' '; echo
    echo "security/selinux: $(find "$kd/security/selinux" -maxdepth 1 -name '*.h' -printf '%f ' 2> /dev/null)"
    grep -E '^(# )?CONFIG_(LTO[A-Z_]*|CFI[A-Z_]*|PAHOLE_VERSION|DEBUG_INFO_BTF[A-Z_]*|LOCALVERSION[A-Z_]*|RUST|RUSTC_VERSION_TEXT|MODVERSIONS|GENDWARFKSYMS|MODULE_SIG_PROTECT|TRIM_UNUSED_KSYMS|CC_VERSION_TEXT)[= ]' "$kd/.config" | cut -c1-160
    echo "files still naming /opt/ddk: $(grep -rIl /opt/ddk "$kd" --include='Makefile*' 2> /dev/null | wc -l) Makefiles, $(find "$ddk" -type l -lname '/opt/ddk/*' | wc -l) symlinks"
    "$ddk/clang/clang-r536225/bin/clang" --version 2>&1 | head -1
    "$ddk/rust/rust-1.82.0/bin/rustc" --version 2>&1 | head -1
    echo "rust/bin: $(find "$ddk/rust/rust-1.82.0/bin" -maxdepth 1 -printf '%f ' 2> /dev/null)"
    echo "-- BTF: the kernels' MODULE_ALLOW_BTF_MISMATCH, and the sections of ksud's own 6.12 module"
    grep -hE '^(# )?CONFIG_MODULE_ALLOW_BTF_MISMATCH[= ]' "$work/stock.config" | sed 's/^/stock: /'
    grep -hE '^(# )?CONFIG_MODULE_ALLOW_BTF_MISMATCH[= ]' "$kd/.config" | sed 's/^/DDK: /'
    [[ -s $ko612 ]] && echo "ksud's: $(readelf -SW "$ko612" | grep -oE '\.(BTF[._a-z]*|modinfo|gnu\.linkonce\.this_module|__versions)' | sort -u | tr '\n' ' ')"
    grep -rnE -i 'btf' "$src/userspace/ksuinit/src" 2> /dev/null | sed "s#^$src/##" | cut -c1-160 | head -8
    echo "-- the build"
    cp -a "$src" "$big/ksn"
    for p in "$here_kit"/ksu/kernel-patches/*.patch; do git -C "$big/ksn" apply "$p" && echo "OK: applied ${p##*/}"; done
    nice -n 19 bash "$here_kit/ksu/tools/ksu-ddk.sh" build "$K" "$ddk" "$big/ksn" "$big/out"; echo "build exit $?"
    grep -E '^-- KernelSU-Next|warning: the compiler differs|error' "$big/out/kbuild.log" 2> /dev/null | head -12
    tail -6 "$big/out/kbuild.log" 2> /dev/null
    ko=$big/out/kernelsu.ko
    if [[ -s $ko ]]; then
        echo "-- ours: $(stat -c %s "$ko") bytes, $(strings "$ko" | grep -m1 '^vermagic=')"
        koinfo this-module "$ko" | awk '{print "struct module: " $1 " bytes"}'
        echo "__versions sections: $(readelf -S "$ko" | grep -c __versions); product/app: $(strings "$ko" | grep -c '^/product/app/KernelSUNext/KernelSUNext.apk$'); undefined symbols: $(readelf -sW "$ko" | awk '$7 == "UND" && $8 != ""' | wc -l)"
        if [[ -s $ko612 ]]; then
            echo "-- undefined symbols: ours vs ksud's own 6.12 module (< only ours, > only theirs)"
            diff <(readelf -sW "$ko" | awk '$7 == "UND" && $8 != "" {print $8}' | sort -u) \
                 <(readelf -sW "$ko612" | awk '$7 == "UND" && $8 != "" {print $8}' | sort -u) | grep '^[<>]' | head -20
            echo "ko-info.py like (what cheetah-ksu.sh checks): $(python3 -I "$here_kit/ksu/tools/ko-info.py" like "$ko" "$ko612" 2>&1)"
        fi
        echo "-- against the stock kodiak kernel"
        vkb=$(find "$eos/vendor/google/kodiak-images" "$evo/vendor/google/kodiak-images" -maxdepth 3 -name vendor_kernel_boot.img 2> /dev/null | head -1)
        if [[ -n $vkb ]] && mkbootimg_unpack "$vkb" "$big/vkb"; then
            mkdir -p "$big/vkm"
            for rd in "$big"/vkb/vendor_ramdisk*; do
                [[ -f $rd ]] || continue
                (cd "$big/vkm" && { lz4 -dc "$rd" 2> /dev/null || gzip -dc "$rd"; } | cpio -id --quiet --no-absolute-filenames 'lib/modules/*.ko')
            done
            echo "same-struct vs ${vkb#"$HOME"/}: $(koinfo same-struct "$ko" "$big/vkm" 2>&1)"
            km=$(find "$big/vkm" -name '*.ko' -print -quit)
            echo "a stock module's vermagic: $(strings "$km" | grep -m1 '^vermagic=')"
        else
            echo "no stock kodiak vendor_kernel_boot.img to compare with"
        fi
        echo "-- config-diff vs the stock kernel's IKCONFIG ($first)"
        koinfo config-diff "$img" "$big/out/kbuild/.config"; echo "config-diff exit $?"
    fi
fi
