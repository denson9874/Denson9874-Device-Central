#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Compile the split SELinux policy the way init does at boot (init/selinux.cpp),
# combining a system/system_ext/product tree with the stock vendor policy.
# A failure here is a guaranteed bootloop with a prebuilt vendor.
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

out="$(mktemp)"; trap 'rm -f "$out"' EXIT
"$secilc" -m -M true -G -N -c 30 "${args[@]}" -o "$out" -f /dev/null
echo "OK: split policy compiles against vendor $vers ($(stat -c %s "$out") bytes)"
