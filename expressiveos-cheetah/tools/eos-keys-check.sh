#!/usr/bin/env bash
# Checks that an ExpressiveOS build signs with ExpressiveOS's own keys, and never with
# Evolution X's, DerpFest's or the AOSP test keys.
# Evolution X's makefiles fall back to the AOSP test keys without a word when keys.mk is
# missing, and a phone keeps trusting whatever key its first build carried, so every
# stage of a build checks again:
#
#   eos-keys-check.sh tree [top]           before: vendor/evolution-priv/keys is the tree's
#                                          own, complete, and nobody else's
#   eos-keys-check.sh vars [top]           product config signs with it (dumpvars)
#   eos-keys-check.sh out [top]            after: otacerts, build tags, every AVB signer
#                                          and the OTA package's certificate
#   eos-keys-check.sh vbmeta <img> [top]   one image's AVB signer is the tree's key
#
# Pins: once the keys exist and are backed up, eos.conf's EOS_AVB_PUBKEY_SHA1 and
# EOS_OTA_CERT_SHA256 hold their public fingerprints (README.md, "Keys"), and a tree whose
# keys differ fails. While they are empty the checks pass with UNPINNED, and eos-pack.sh
# refuses a release. Prints names, paths and public fingerprints only, never key material.
# The last line is KEYS_CHECK=OK, KEYS_CHECK=UNPINNED or KEYS_CHECK=FAIL.
set -euo pipefail
done=0 work='' unpinned=0
cleanup() {
    local rc=$?
    [[ -z "$work" ]] || rm -rf -- "$work"
    [[ $done = 1 ]] || echo "KEYS_CHECK=FAIL"
    exit $rc
}
trap cleanup EXIT
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"

mode=${1:-}
usage="usage: eos-keys-check.sh tree|vars|out [top] | vbmeta <img> [top]"
case "$mode" in
    tree|vars|out) [[ $# -le 2 ]] || fail "$usage"; eos_top "${2:-}" ;;
    vbmeta) [[ $# -ge 2 && $# -le 3 ]] || fail "$usage"; img=$2; eos_top "${3:-}" ;;
    *) fail "$usage" ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/eos-keys.XXXXXX")
rel=vendor/evolution-priv/keys
keys=$top/$rel
command -v openssl >/dev/null || fail "openssl isn't installed"

oneline() { tr '\n' ' ' <<<"$1" | sed 's/ *$//'; }
# Fingerprints, upper-case hex without colons
norm() { tr -d ':' <<<"$1" | tr 'a-f' 'A-F'; }
cert_fp() {   # cert_fp <x509.pem>
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null) || return 1
    norm "${fp#*=}"
}
avbtool() {
    if [[ -x "$top/out/host/linux-x86/bin/avbtool" ]]; then
        "$top/out/host/linux-x86/bin/avbtool" "$@"
    else
        python3 -I "$top/external/avb/avbtool.py" "$@"
    fi
}
key_sha1() {   # key_sha1 <private key>: the sha1 avbtool info_image shows for an image it signs
    avbtool extract_public_key --key "$1" --output "$work/pk" 2>/dev/null || return 1
    sha1sum "$work/pk" | cut -d' ' -f1 | tr 'a-f' 'A-F'
}
blob_sha1() { sha1sum "$1" | cut -d' ' -f1 | tr 'a-f' 'A-F'; }
img_sha1() { avbtool info_image --image "$1" 2>/dev/null | sed -n 's/^Public key (sha1): *//p' | sed -n 1p | tr 'a-f' 'A-F'; }
chains() {   # chains <image>: "<partition> <sha1>" for every partition the image chains to (its descriptors)
    avbtool info_image --image "$1" 2>/dev/null | awk '
        /^ *Chain Partition descriptor:/ { c = 1; n = ""; next }
        c && /^ *Partition Name:/ { n = $3 }
        c && /^ *Public key \(sha1\):/ { print n, toupper($4); c = 0 }'
}

pin() {   # pin <what> <fingerprint> <eos.conf name>
    local want=${!3:-}
    if [[ -z "$want" ]]; then
        echo "UNPINNED: $1 is $2. Once the keys are backed up, set $3=$2 in eos.conf (README.md, \"Keys\")"
        unpinned=1
    elif [[ "$(norm "$want")" != "$2" ]]; then
        fail "$1 is $2, but eos.conf pins $3=$want: these aren't the keys ExpressiveOS shipped with. Restore $rel from the backup"
    else
        echo "OK: $1 matches eos.conf's $3"
    fi
}

# Certificates and AVB keys that must never sign ExpressiveOS, as "fingerprint<TAB>whose"
others() {
    local c f d label
    : > "$work/certs"; : > "$work/avb"
    printf '%s\tEvolution X'"'"'s OTA certificate (eos.conf EVO_OTA_CERT_SHA256)\n' "$(norm "$EVO_OTA_CERT_SHA256")" >> "$work/certs"
    printf '%s\tEvolution X'"'"'s AVB key (eos.conf EVO_AVB_PUBKEY_SHA1)\n' "$(norm "$EVO_AVB_PUBKEY_SHA1")" >> "$work/avb"
    for f in "$top"/build/make/target/product/security/*.x509.pem; do
        [[ -f "$f" ]] && c=$(cert_fp "$f") && printf '%s\tthe AOSP test key %s\n' "$c" "${f##*/}" >> "$work/certs"
    done
    for f in "$top"/external/avb/test/data/testkey_rsa*.pem; do
        [[ -f "$f" ]] && c=$(key_sha1 "$f") && printf '%s\tthe AOSP AVB test key %s\n' "$c" "${f##*/}" >> "$work/avb"
    done
    for d in "$evo/vendor/evolution-priv/keys:Evolution X" "$derp/vendor/lineage-priv/keys:DerpFest"; do
        label="${d##*:}'s"; d=${d%:*}
        [[ "$d" != /vendor/* ]] || continue        # that tree isn't on this server
        if [[ ! -d "$d" ]]; then continue; fi
        if [[ ! -r "$d" || ! -x "$d" ]]; then echo "note: can't read $d; relying on eos.conf's pins for $label keys"; continue; fi
        for f in "$d"/*.x509.pem; do
            [[ -f "$f" ]] && c=$(cert_fp "$f") && printf '%s\t%s %s\n' "$c" "$label" "${f##*/}" >> "$work/certs"
        done
        [[ -f "$d/avb_custom_key.bin" ]] && printf '%s\t%s avb_custom_key.bin\n' "$(blob_sha1 "$d/avb_custom_key.bin")" "$label" >> "$work/avb"
        for f in "$d"/avb*.pk8 "$d"/avb*.pem; do
            [[ -f "$f" ]] || continue
            if c=$(key_sha1 "$f"); then printf '%s\t%s %s\n' "$c" "$label" "${f##*/}" >> "$work/avb"
            else echo "note: can't read $f; its public half (avb_custom_key.bin) and the pins still count"; fi
        done
    done
    return 0
}
whose() {   # whose certs|avb <fingerprint>: who else holds it, or nothing
    awk -F'\t' -v k="$2" '$1 == k {print $2; exit}' "$work/$1"
}

# ExpressiveOS's own public fingerprints: the OTA/platform certificate and the AVB key
ours() {
    [[ -f "$keys/testkey.x509.pem" ]] || fail "no $rel/testkey.x509.pem (run: eos-keys-check.sh tree)"
    ota=$(cert_fp "$keys/testkey.x509.pem") || fail "can't read $rel/testkey.x509.pem"
    [[ -f "$keys/avb_custom_key.bin" ]] || fail "no $rel/avb_custom_key.bin (run: eos-keys-check.sh tree)"
    avb=$(blob_sha1 "$keys/avb_custom_key.bin")
}

signed_by_us() {   # signed_by_us <image> <label>
    local s w
    s=$(img_sha1 "$1")
    [[ -n "$s" ]] || fail "$2 has no AVB signature (avbtool info_image shows no public key)"
    w=$(whose avb "$s")
    [[ -z "$w" ]] || fail "$2 is signed with $w"
    [[ "$s" = "$avb" ]] || fail "$2 is signed by AVB key $s, not the tree's ($avb from $rel/avb_custom_key.bin)"
    echo "OK: $2 signed by ExpressiveOS's AVB key"
    # A partition chained from it is checked against the key named here, not against
    # vbmeta's: each must be ours too, or a test-key partition would still verify
    local part k
    while read -r part k; do
        [[ -n "$part" && -n "$k" ]] || fail "$2 has a chain descriptor avbtool doesn't show fully"
        w=$(whose avb "$k")
        [[ -z "$w" ]] || fail "$2 chains $part with $w"
        [[ "$k" = "$avb" ]] || fail "$2 chains $part with AVB key $k, not the tree's ($avb)"
        echo "$part" >> "$work/chained"
    done < <(chains "$1")
}

case "$mode" in
tree)
    in_top "$top/vendor/evolution-priv"
    in_top "$keys"
    [[ -d "$keys" && ! -L "$keys" ]] \
        || fail "no $rel folder of the tree's own: create ExpressiveOS's keys first (README.md, \"Keys\"). Without it the build signs with the AOSP test keys"
    # The template's own symlinks (releasekey.* -> testkey.*, BUILD.bazel) stay in the tree
    while IFS= read -r -d '' l; do in_top "$l"; done < <(find "$keys" -type l -print0)
    hard=$(find "$keys" -type f -links +1 -printf '%P\n')
    [[ -z "$hard" ]] || fail "$rel holds hard-linked files ($(oneline "$hard")): shared with another tree's keys?"
    mk=$keys/keys.mk
    [[ -f "$mk" && ! -L "$mk" ]] || fail "no $rel/keys.mk of the tree's own: Evolution X would build with the AOSP test keys"
    for line in 'AVB_CUSTOM_KEY_PATH := vendor/evolution-priv/keys/avb.pk8' \
                'AVB_CUSTOM_ALGORITHM := SHA256_RSA4096' \
                'PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/evolution-priv/keys/testkey'; do
        grep -qxF -- "$line" "$mk" || fail "$rel/keys.mk lacks the line '$line' (the template's)"
    done
    # A key pair for every AOSP key name and every certificate override keys.mk names
    names=$( { for f in "$top"/build/make/target/product/security/*.pk8; do basename "$f" .pk8; done
               { grep -o ':[A-Za-z0-9_.]*certificate\.override' "$mk" || true; } | cut -c2-; } | sort -u)
    [[ -n "$names" ]] || fail "found no key names (build/make/target/product/security is empty?)"
    missing=()
    for n in $names avb; do
        for x in pk8 x509.pem; do
            [[ "$n.$x" != avb.x509.pem ]] || continue
            [[ -s "$keys/$n.$x" && ! -L "$keys/$n.$x" ]] || missing+=("$n.$x")
        done
    done
    for f in avb_custom_key.bin Android.bp; do [[ -s "$keys/$f" && ! -L "$keys/$f" ]] || missing+=("$f"); done
    (( ${#missing[@]} == 0 )) || fail "$rel lacks ${#missing[@]} key files of its own (${missing[*]:0:6}...), or has symlinks in their place: run the template's keys.sh there (README.md, \"Keys\")"
    for n in $names avb; do
        [[ -r "$keys/$n.pk8" ]] || fail "can't read $rel/$n.pk8 (run this as the user that builds)"
    done
    echo "OK: $rel has keys.mk and all $(wc -w <<<"$names") key pairs, plus avb.pk8"
    loose=$(find "$keys" -type f -name '*.pk8' -perm /o+r -printf '%P\n' | awk 'NR <= 3')
    [[ -z "$loose" ]] || echo "WARNING: other users can read private keys in $rel ($(oneline "$loose")...): chmod 600 $rel/*.pk8"

    others
    for n in $names; do
        c=$(cert_fp "$keys/$n.x509.pem") || fail "can't read $rel/$n.x509.pem"
        w=$(whose certs "$c")
        [[ -z "$w" ]] || fail "$rel/$n.x509.pem is $w; generate ExpressiveOS's own keys (README.md, \"Keys\")"
    done
    echo "OK: no certificate in $rel is Evolution X's, DerpFest's or AOSP's"
    ours
    k=$(key_sha1 "$keys/avb.pk8") || fail "avbtool can't read $rel/avb.pk8"
    [[ "$k" = "$avb" ]] || fail "$rel/avb_custom_key.bin isn't avb.pk8's public key: regenerate it with avbtool extract_public_key"
    w=$(whose avb "$avb")
    [[ -z "$w" ]] || fail "$rel/avb.pk8 is the same AVB key as $w; generate ExpressiveOS's own (README.md, \"Keys\")"
    echo "OK: the AVB key is the tree's own"
    pin "the OTA certificate ($rel/testkey.x509.pem, SHA-256)" "$ota" EOS_OTA_CERT_SHA256
    pin "the AVB public key ($rel/avb_custom_key.bin, sha1)" "$avb" EOS_AVB_PUBKEY_SHA1
    ;;
vars)
    # gs201 signs vbmeta and chains vbmeta_system, vbmeta_vendor, boot and init_boot with
    # AVB_CUSTOM_KEY_PATH (keys.mk); a key path set for any other partition would chain it too
    extra="PVMFW VENDOR_BOOT VENDOR_KERNEL_BOOT DTBO SYSTEM SYSTEM_EXT PRODUCT VENDOR SYSTEM_DLKM VENDOR_DLKM ODM ODM_DLKM RECOVERY"
    extra_vars=()
    for p in $extra; do extra_vars+=("BOARD_AVB_${p}_KEY_PATH"); done
    vars=$(dump_vars PRODUCT_DEFAULT_DEV_CERTIFICATE BUILD_KEYS BOARD_AVB_KEY_PATH BOARD_AVB_ALGORITHM \
        BOARD_AVB_BOOT_KEY_PATH BOARD_AVB_INIT_BOOT_KEY_PATH BOARD_AVB_VBMETA_SYSTEM_KEY_PATH \
        BOARD_AVB_VBMETA_VENDOR_KEY_PATH "${extra_vars[@]}" 2>"$work/dumpvars.log") \
        || { tail -5 "$work/dumpvars.log" >&2; fail "dumpvars failed for $EOS_LUNCH"; }
    want_key=$rel/avb.pk8
    check_var() {
        local v
        v=$(var_of "$vars" "$1")
        [[ "$v" = "$2" ]] || fail "$1 is '${v:-unset}', want '$2'${3:+ ($3)}"
    }
    check_var PRODUCT_DEFAULT_DEV_CERTIFICATE "$rel/testkey" "keys.mk isn't read: is EVO_BUILD_TYPE right?"
    # Evolution X's build/make tags builds whose certificate is under vendor/evolution-priv/
    # release-keys (core/config.mk); test-keys means the AOSP test keys
    check_var BUILD_KEYS release-keys
    check_var BOARD_AVB_ALGORITHM SHA256_RSA4096
    for v in BOARD_AVB_KEY_PATH BOARD_AVB_BOOT_KEY_PATH BOARD_AVB_INIT_BOOT_KEY_PATH \
             BOARD_AVB_VBMETA_SYSTEM_KEY_PATH BOARD_AVB_VBMETA_VENDOR_KEY_PATH; do
        check_var "$v" "$want_key" "otherwise that partition is signed with the AOSP test key"
    done
    for p in $extra; do
        v=$(var_of "$vars" "BOARD_AVB_${p}_KEY_PATH")
        case $v in
            ''|"$want_key") ;;
            external/avb/test/*|build/make/target/product/security/*|*/testkey*)
                fail "BOARD_AVB_${p}_KEY_PATH is the AOSP test key $v: that partition would be chained with it" ;;
            *) echo "WARNING: BOARD_AVB_${p}_KEY_PATH is $v, not $want_key: the out check fails if vbmeta chains that partition with another key" ;;
        esac
    done
    echo "OK: $EOS_LUNCH signs with $rel (release-keys, AVB $want_key)"
    ;;
out|vbmeta)
    others
    ours
    w=$(whose avb "$avb"); [[ -z "$w" ]] || fail "$rel/avb.pk8 is the same AVB key as $w"
    w=$(whose certs "$ota"); [[ -z "$w" ]] || fail "$rel/testkey.x509.pem is $w"
    if [[ "$mode" = vbmeta ]]; then
        [[ -f "$img" ]] || fail "no $img"
        signed_by_us "$img" "$img"
        pin "the AVB public key" "$avb" EOS_AVB_PUBKEY_SHA1
    else
        O=$top/out/target/product/cheetah
        [[ -d "$O" ]] || fail "no $O: build first"
        # Recovery and the Updater only take packages signed by a certificate in otacerts.
        # Evolution X's config/common.mk adds LineageOS's release certificate to recovery's
        # (PRODUCT_EXTRA_RECOVERY_KEYS), so recovery also sideloads official LineageOS
        # packages, as on Evolution X. That one certificate, as this tree has it, is allowed
        # in recovery's otacerts and nowhere else
        lineage='' lf=vendor/lineage/build/target/product/security/lineage.x509.pem
        if [[ -f "$top/$lf" ]]; then
            lineage=$(cert_fp "$top/$lf") || fail "can't read $lf"
            w=$(whose certs "$lineage"); [[ -z "$w" ]] || fail "$lf is $w"
        fi
        n=0
        for z in "$O"/{system,system_ext,product,vendor}/etc/security/otacerts.zip "$O"/recovery/root/system/etc/security/otacerts.zip; do
            [[ -f "$z" ]] || continue
            rm -rf "$work/oc"; mkdir "$work/oc"
            unzip -q -o "$z" -d "$work/oc" || fail "can't unpack ${z#"$O"/}"
            mapfile -t certs < <(find "$work/oc" -type f)
            (( ${#certs[@]} > 0 )) || fail "${z#"$O"/} is empty"
            mine=0
            for c in "${certs[@]}"; do
                fp=$(cert_fp "$c") || fail "${z#"$O"/} holds ${c##*/}, which isn't a certificate"
                if [[ "$fp" = "$ota" ]]; then
                    mine=1
                elif [[ "$z" = "$O"/recovery/* && -n "$lineage" && "$fp" = "$lineage" ]]; then
                    echo "note: ${z#"$O"/} also trusts LineageOS's release certificate ($lf, Evolution X's PRODUCT_EXTRA_RECOVERY_KEYS)"
                else
                    w=$(whose certs "$fp"); [[ "$fp" != "$lineage" ]] || w="LineageOS's release certificate, allowed in recovery's only"
                    fail "${z#"$O"/} trusts ${c##*/} (${w:+$w, }${fp:0:16}...), not only ExpressiveOS's OTA certificate"
                fi
            done
            (( mine )) || fail "${z#"$O"/} doesn't trust ExpressiveOS's OTA certificate"
            n=$((n + 1))
        done
        [[ -f "$O/system/etc/security/otacerts.zip" ]] || fail "no system/etc/security/otacerts.zip in $O"
        echo "OK: $n otacerts.zip trust ExpressiveOS's OTA certificate and no other key (LineageOS's aside, recovery only)"
        # update_engine's older payload key, where a build still installs it
        pk() { openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }
        openssl x509 -in "$keys/testkey.x509.pem" -noout -pubkey > "$work/ota.pub" || fail "can't read $rel/testkey.x509.pem's public key"
        for f in "$O"/{system,system_ext,product}/etc/update_engine/update-payload-key.pub.pem; do
            [[ -f "$f" ]] || continue
            [[ "$(pk "$f")" = "$(pk "$work/ota.pub")" ]] || fail "${f#"$O"/} isn't ExpressiveOS's OTA key: update_engine would take another key's payloads"
            echo "OK: ${f#"$O"/} is ExpressiveOS's OTA key"
        done
        bad=$(grep -h '\.build\.tags=' "$O"/{system,system_ext,product,vendor,odm}/{,etc/}build.prop 2>/dev/null | grep -v '=release-keys$' || true)
        [[ -z "$bad" ]] || fail "build.prop tags aren't release-keys: $(oneline "$bad")"
        grep -q '^ro\.\(system\.\)\?build\.tags=release-keys$' "$O/system/build.prop" || fail "system/build.prop has no release-keys tag"
        echo "OK: every build.prop is tagged release-keys"
        : > "$work/chained"
        for i in vbmeta vbmeta_system vbmeta_vendor boot init_boot; do
            [[ -f "$O/$i.img" ]] || fail "no $i.img in $O"
            signed_by_us "$O/$i.img" "$i.img"
        done
        # Whatever else vbmeta chains (a partition given its own key) is signed with ours too
        while read -r i; do
            [[ -f "$O/$i.img" ]] || fail "vbmeta.img chains $i, but there's no $i.img in $O"
            signed_by_us "$O/$i.img" "$i.img (chained)"
        done < <(sort -u "$work/chained" | grep -vxE 'vbmeta|vbmeta_system|vbmeta_vendor|boot|init_boot' || true)
        # The OTA package m evolution made last, named by patches/vendor_lineage/0001
        pkg=$(find "$O" -maxdepth 1 -name 'ExpressiveOS-*.zip' ! -name '*-fastboot.zip' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
        [[ -n "$pkg" ]] || fail "no ExpressiveOS-*.zip OTA package in $O (m evolution not run, or the version patch missing)"
        unzip -p "$pkg" META-INF/com/android/otacert > "$work/otacert" 2>/dev/null || fail "${pkg##*/} has no META-INF/com/android/otacert"
        fp=$(cert_fp "$work/otacert") || fail "${pkg##*/}'s otacert isn't a certificate"
        [[ "$fp" = "$ota" ]] || fail "${pkg##*/} is signed by certificate ${fp:0:16}... ($(whose certs "$fp"; true)), not ExpressiveOS's OTA key"
        echo "OK: ${pkg##*/} is signed with ExpressiveOS's OTA key"
        pin "the OTA certificate" "$ota" EOS_OTA_CERT_SHA256
        pin "the AVB public key" "$avb" EOS_AVB_PUBKEY_SHA1
    fi
    ;;
esac
done=1
if [[ $unpinned = 1 ]]; then echo "KEYS_CHECK=UNPINNED"; else echo "KEYS_CHECK=OK"; fi
