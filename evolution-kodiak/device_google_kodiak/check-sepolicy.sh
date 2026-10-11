#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Compile the split SELinux policy the way init does at boot (init/selinux.cpp),
# combining a system/system_ext/product tree with the stock vendor policy.
# A failure here is a guaranteed bootloop with a prebuilt vendor. It then lists
# which Google system_ext types the stock vendor rules reach in this build.
#
#   check-sepolicy.sh <secilc> <root-with-system,system_ext,product> <vendor-root>
#
# <root> is e.g. out/target/product/kodiak (system/, system_ext/, product/)
# or a dumpyara dump (system/system/, system_ext/, product/).
set -euo pipefail
secilc="$1"; root="$2"; vendor="$3"

sys="$root/system/etc/selinux"
[[ -d "$sys" ]] || sys="$root/system/system/etc/selinux"
sext="$root/system_ext/etc/selinux"
prod="$root/product/etc/selinux"
ven="$vendor/etc/selinux"

vers="$(cat "$ven/plat_sepolicy_vers.txt")"
args=("$sys/plat_sepolicy.cil" "$sys/mapping/$vers.cil")
[[ -f "$sys/mapping/$vers.compat.cil" ]] && args+=("$sys/mapping/$vers.compat.cil")
if [[ -f "$ven/genfs_labels_version.txt" ]]; then
    genfs="$sys/plat_sepolicy_genfs_$(cat "$ven/genfs_labels_version.txt").cil"
    [[ -f "$genfs" ]] && args+=("$genfs")
fi
for p in "$sext/system_ext_sepolicy.cil" "$sext/mapping/$vers.cil" \
         "$prod/product_sepolicy.cil" "$prod/mapping/$vers.cil" \
         "$ven/plat_pub_versioned.cil" "$ven/vendor_sepolicy.cil"; do
    [[ -f "$p" ]] && args+=("$p")
done

out="$(mktemp)"; tmp="$(mktemp -d)"; trap 'rm -rf "$out" "$tmp"' EXIT
"$secilc" -m -M true -G -N -c 30 "${args[@]}" -o "$out" -f /dev/null
echo "OK: split policy compiles against vendor $vers ($(stat -c %s "$out") bytes)"

# The stock vendor policy names system-side types through versioned attributes
# (foo_<vers>). Only the ones a system or system_ext mapping file maps to a real
# type do anything; rules on the rest are dead. Report which Google system_ext
# domains our build provides to the stock vendor rules and which it still lacks.
v="${vers//./_}"
[[ -f "$sext/mapping/$vers.cil" ]] || \
    echo "WARN: no $sext/mapping/$vers.cil: stock vendor rules for Google system_ext types can't apply"
{ cat "$sys/mapping/$vers.cil" "$sext/mapping/$vers.cil" "$prod/mapping/$vers.cil" 2>/dev/null || true; } |
    { grep -oE "\(typeattributeset [A-Za-z0-9_]+_$v " || true; } | awk '{print $2}' | sort -u > "$tmp/mapped"
# base_typeattr_N are secilc-generated attributes the vendor policy defines
# itself; they need no mapping.
{ grep -oE "[A-Za-z0-9_]+_$v\b" "$ven/vendor_sepolicy.cil" || true; } |
    { grep -v '^base_typeattr_' || true; } | sort -u > "$tmp/used"
comm -12 "$tmp/used" "$tmp/mapped" | grep -E "^($(paste -sd'|' <<'TYPES'
euiccpixel_app
grilservice_app
imsstack_app
pixel_modem_app
rilextensionservice_app
edgetpu_app_server
edgetpu_app_service
ims_prop
system_ril_ext_prop
telephony_ril_ntn_sim_deact_prop
telephony_ntn_demo_mode_prop
TYPES
))_$v\$" | sed "s/_$v\$//" | paste -sd' ' | sed 's/^/mapped for the stock vendor: /; s/: $/: (none)/' || true
unmapped="$(comm -23 "$tmp/used" "$tmp/mapped" | sed "s/_$v\$//" | paste -sd' ')"
[[ -z "$unmapped" ]] || echo "unmapped (stock vendor rules on these are dead): $unmapped"
