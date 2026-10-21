#!/bin/bash
D=~/android-dt/dumps; A=~/evolution/out/host/linux-x86/bin
# apksigner from the tree, else fall back to the v1 block
AS=$(ls ~/evolution/out/host/linux-x86/bin/apksigner 2>/dev/null || ls ~/evolution/prebuilts/sdk/tools/linux/bin/apksigner 2>/dev/null)
cert() { "$AS" verify --print-certs "$1" 2>/dev/null | grep -m1 "SHA-256 digest" | awk '{print substr($NF,1,16)}'; }
lists="$HOME/evolution/device/google/kodiak/proprietary-files.txt $HOME/evolution/device/google/kodiak-personal/proprietary-files.txt"
printf '%-46s %-9s %-17s %-17s %-17s %s\n' apk presigned kodiak grizzly cubs content
for l in $lists; do
  grep -vE '^(#|$)' $l | grep '\.apk' | while IFS= read -r e; do
    p=$(sed -E 's/^-//; s/;.*//; s/:.*//' <<<"$e"); ps=$([[ $e == *PRESIGNED* ]] && echo yes || echo no)
    k=$(cert $D/kodiak/$p); g=$(cert $D/grizzly/$p); c=$(cert $D/cubs/$p)
    same=same
    for d in grizzly cubs; do
      diff <(unzip -v $D/kodiak/$p | awk 'NR>3 && $8!="" && $8 !~ /^META-INF/ {print $7,$8}' | sort) \
           <(unzip -v $D/$d/$p | awk 'NR>3 && $8!="" && $8 !~ /^META-INF/ {print $7,$8}' | sort) >/dev/null || same="DIFF($d)"
    done
    sig=$([[ $k == $g && $k == $c ]] && echo "" || echo "  <- per-device signer")
    printf '%-46s %-9s %-17s %-17s %-17s %s%s\n' "$(basename $p)" $ps "$k" "$g" "$c" "$same" "$sig"
  done
done
echo "apksigner: $AS"
echo "## platform cert (mac_permissions first signer) per device"
for d in kodiak grizzly cubs; do grep -oE 'signature="[0-9a-f]{120}' $D/$d/vendor/etc/selinux/vendor_mac_permissions.xml | head -1 | cut -c1-80 | sed "s/^/$d /"; done
for d in kodiak grizzly cubs; do grep -oE 'signature="[0-9a-f]{120}' $D/$d/system/system/etc/selinux/plat_mac_permissions.xml $D/$d/system/etc/selinux/plat_mac_permissions.xml 2>/dev/null | head -1 | cut -c1-120 | sed "s/^/$d plat: /"; done
