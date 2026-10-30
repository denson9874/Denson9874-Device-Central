#!/usr/bin/env bash
# The DDK (../ddk.conf) ksu-module.sh builds ExpressiveOS's own kernelsu.ko with on a phone
# whose kernel is Google's prebuilt GKI (EOS_KERNEL=prebuilt: the Pixel 11s, android16-6.12),
# whose tree has no kernel source: the image KernelSU Next's CI builds its own modules in. The
# server has no docker, podman or root, so fetch takes the image apart itself: the manifest and
# each layer from the registry with curl, the manifest checked against ddk.conf's digest and
# each layer against the manifest's, and only /opt/ddk unpacked. Nothing runs inside the image:
# build runs its clang (Google's prebuilt) and the prepared tree's host tools on this host, once
# ldd finds every library they need here. It takes no lock and writes only under the folders
# it's given: ksu-module.sh runs it under its own lock, and devices-check.sh gki tries it in a
# scratch folder beside a running build.
#
#   ksu-ddk.sh fetch <kmi> <dir>             # unpack ddk.conf's image for <kmi> into <dir>, once
#                                            # (<dir>/IMAGE names it); a <dir> with another pin is replaced
#   ksu-ddk.sh build <kmi> <dir> <src> <out> # build kernelsu.ko from <src>, a KernelSU Next checkout
#                                            # (patched, with its git history), against <dir>'s prepared
#                                            # tree: <out>/kernelsu.ko (debug info stripped),
#                                            # <out>/kbuild/.config (the prepared tree's) and
#                                            # <out>/kbuild.log
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
here="$(cd "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
usage="usage: ksu-ddk.sh fetch <kmi> <dir> | ksu-ddk.sh build <kmi> <dir> <src> <out>"
[[ $# -ge 3 ]] || fail "$usage"
cmd=$1 kmi=$2 dir=$3
[[ $kmi =~ ^android[0-9]+-[0-9]+\.[0-9]+$ ]] || fail "'$kmi' isn't a KMI like android16-6.12"
# Absolute and plain: fetch writes it into sed and symlinks
[[ $dir =~ ^/[A-Za-z0-9/._-]+$ && /$dir/ != */../* ]] || fail "'$dir' isn't a plain absolute path"
dir=${dir%/}
conf() { awk -F= -v k="${kmi}_$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$here/ddk.conf"; }
image=$(conf image) tag=$(conf tag) digest=$(conf digest) clangv=$(conf clang) rustv=$(conf rust)
[[ -n $image ]] || fail "ddk.conf has no DDK for $kmi"
[[ $image =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+$ ]] || fail "ddk.conf: ${kmi}_image $image isn't a ghcr.io image (the only registry fetch knows)"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "ddk.conf: ${kmi}_digest isn't sha256:<64 hex digits>"
[[ $clangv =~ ^clang-r[0-9a-z]+$ && $rustv =~ ^rust-[0-9a-z.]+$ ]] || fail "ddk.conf: ${kmi}_clang or ${kmi}_rust is missing"
repo=${image#ghcr.io/}
want="$image@$digest ($tag)"
have() { [[ "$(head -1 "$dir/IMAGE" 2>/dev/null)" = "$want" && -d $dir/kdir/$kmi ]]; }

fetch() {
    if have; then echo "OK: DDK $want in $dir"; return; fi
    [[ ! -e $dir || -f $dir/IMAGE ]] || fail "$dir isn't a DDK folder (no IMAGE in it): not replacing it"
    local part=$dir.part tok m layers d size mt n=0 pre free
    mkdir -p -- "${dir%/*}"
    free=$(df -BG --output=avail -- "${dir%/*}" | tail -1 | tr -dc 0-9)
    (( free >= 20 )) || fail "${dir%/*} has ${free}G free: unpacking the DDK takes about 12G (20G to be safe)"
    rm -rf -- "$part"; mkdir -p -- "$part/root"
    tok=$(curl -fsS --retry 3 "https://ghcr.io/token?scope=repository:$repo:pull" \
        | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])') || fail "no pull token from ghcr.io for $repo"
    # The token goes to ghcr.io only: curl drops it when a blob redirects to its storage host
    reg() { curl -fsSL --retry 3 -H "Authorization: Bearer $tok" "${@:2}" "https://ghcr.io/v2/$repo/$1"; }
    m=$part/manifest.json
    reg "manifests/$digest" -o "$m" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        || fail "can't fetch $image@$digest's manifest"
    [[ "sha256:$(sha256sum < "$m" | cut -d' ' -f1)" = "$digest" ]] || fail "$image's manifest isn't $digest"
    # "<digest> <size> <media type>", one line per layer, lowest first
    layers=$(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
if m.get("schemaVersion") != 2 or not m.get("layers"):
    sys.exit("not a single-platform image manifest")
for l in m["layers"]:
    print(l["digest"], l["size"], l["mediaType"])' "$m") || fail "$image@$digest isn't a single-platform image manifest"
    while read -r d size mt; do
        n=$((n + 1))
        [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || fail "layer $n's digest '$d' isn't sha256"
        [[ $mt = *.tar+gzip || $mt = *.tar.gzip ]] || fail "layer $n ($d) is $mt, not a gzip tarball"
        reg "blobs/$d" -o "$part/layer" || fail "can't fetch layer $n ($d, $size bytes)"
        [[ "sha256:$(sha256sum < "$part/layer" | cut -d' ' -f1)" = "$d" ]] || fail "layer $n isn't $d"
        tar -tzf "$part/layer" > "$part/list" || fail "layer $n ($d) isn't a gzip tarball"
        if grep -qE '^(\./)?opt/ddk/' "$part/list"; then
            # A later layer deleting a lower one's files (whiteouts) isn't something this applies
            if grep -qE '^(\./)?opt/ddk/(.*/)?\.wh\.' "$part/list"; then fail "layer $n ($d) deletes files under /opt/ddk (whiteouts), which fetch doesn't apply"; fi
            pre=; grep -q '^\./opt/ddk/' "$part/list" && pre=./
            tar -xzf "$part/layer" -C "$part/root" --no-same-owner --wildcards "${pre}opt/ddk/*" \
                || fail "can't unpack /opt/ddk from layer $n ($d)"
            echo "OK: layer $n ($d): $(grep -cE '^(\./)?opt/ddk/' "$part/list") files under /opt/ddk"
        fi
        rm -f -- "$part/layer" "$part/list"
    done <<<"$layers"
    local r=$part/root/opt/ddk
    [[ -d $r/kdir/$kmi && -d $r/src/$kmi && -x $r/clang/$clangv/bin/clang ]] \
        || fail "$image@$digest has no /opt/ddk/kdir/$kmi, /opt/ddk/src/$kmi or /opt/ddk/clang/$clangv"
    rm -rf -- "$dir"
    mv -- "$r" "$dir"
    # The image's absolute paths (/opt/ddk/...) lead into <dir> now: its symlinks, and the
    # Makefile modules_prepare wrote in the prepared tree (it includes the source's)
    local l t
    while IFS= read -r -d '' l; do
        t=$(readlink -- "$l")
        [[ $t != /opt/ddk/* ]] || ln -sfn -- "$dir/${t#/opt/ddk/}" "$l"
    done < <(find "$dir" -type l -print0)
    sed -i "s#/opt/ddk/#$dir/#g" "$dir/kdir/$kmi/Makefile"
    printf '%s\n%s\n' "$want" "$layers" > "$dir/IMAGE"
    rm -rf -- "$part"
    echo "OK: DDK $want unpacked in $dir ($(du -sh -- "$dir" | cut -f1))"
}

build() {
    [[ $# = 5 ]] || fail "$usage"
    local src=$4 out=$5 kdir=$dir/kdir/$kmi clang=$dir/clang/$clangv/bin rust=$dir/rust/$rustv/bin x miss log
    have || fail "$dir isn't ddk.conf's DDK for $kmi (ksu-ddk.sh fetch $kmi $dir)"
    [[ -f $src/kernel/Kbuild && -d $src/.git ]] || fail "$src isn't a KernelSU Next checkout with its history"
    [[ -x $clang/clang && -x $clang/llvm-strip ]] || fail "no $clang/clang"
    [[ -f $kdir/.config && -f $kdir/include/config/auto.conf ]] || fail "$kdir isn't a prepared kernel tree (no .config or include/config/auto.conf)"
    # The prepared tree's host tools (fixdep, modpost...) were built in the image (its own
    # Ubuntu): every library and symbol version they need must be on this host
    while IFS= read -r -d '' x; do
        [[ "$(head -c4 -- "$x" | od -An -tx1 | tr -d ' ')" = 7f454c46 ]] || continue
        miss=$(ldd -- "$x" 2>&1 | grep 'not found' || true)
        [[ -z $miss ]] || fail "the DDK's ${x#"$kdir"/} doesn't run on this host: $(head -1 <<<"$miss" | sed 's/^[[:space:]]*//')"
    done < <(find "$kdir/scripts" -type f -perm -u+x -print0)
    # KernelSU includes SELinux's private headers, which only a kernel build generates
    if [[ ! -f $kdir/security/selinux/flask.h ]]; then
        [[ -x $kdir/scripts/selinux/genheaders/genheaders ]] || fail "$kdir has neither security/selinux/flask.h nor genheaders"
        mkdir -p -- "$kdir/security/selinux"
        "$kdir/scripts/selinux/genheaders/genheaders" "$kdir/security/selinux/flask.h" "$kdir/security/selinux/av_permissions.h"
    fi
    mkdir -p -- "$out/kbuild"; rm -f -- "$out/kernelsu.ko"
    log=$out/kbuild.log
    # What the image's environment sets (its ENV), and KernelSU Next's CI's make in kernel/
    PATH=$clang:$rust:$PATH make -C "$kdir" M="$src/kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
        CONFIG_KSU=m -j"$(nproc)" modules > "$log" 2>&1 \
        || { tail -30 "$log" >&2; fail "kernelsu.ko didn't build with the DDK (log: $log)"; }
    # Debug info would make it several MB, too big for an init_boot with a ramdisk
    "$clang/llvm-strip" --strip-debug -o "$out/kernelsu.ko" "$src/kernel/kernelsu.ko"
    cp -- "$kdir/.config" "$out/kbuild/.config"
    echo "OK: $out/kernelsu.ko built with the DDK $want"
}

case $cmd in
    fetch) [[ $# = 3 ]] || fail "$usage"; fetch ;;
    build) build "$@" ;;
    *) fail "$usage" ;;
esac
