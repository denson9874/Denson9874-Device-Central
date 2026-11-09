#!/usr/bin/env bash
# Offline test of lib.sh's verified_save and images_verified: when eos-pack.sh's candidate
# run may take the verify eos-images.sh just ran instead of running it again. A copy of the
# kit (its own git repo, so it has a commit and no local changes), a fake tree with cheetah's
# product out, and a fake verify log. It checks the choice only; eos-verify.sh itself runs on
# the server.
#
#   tools/tests/eos-verified-test.sh   # a few seconds; needs git. Each phone family:
#                                      # cheetah, husky (super_empty.img from out/) and
#                                      # kodiak (from the factory zip, plus vendor_kernel_boot)
set -euo pipefail
KITSRC=$(cd "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
if [[ -z ${EOS_DEVICE:-} ]]; then
    rc=0
    for d in cheetah husky kodiak; do echo "== $d"; EOS_DEVICE=$d bash "$0" || rc=1; done
    exit $rc
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/eos-verified-test.XXXXXX")
trap 'rm -rf -- "$W"' EXIT
pass=0 failed=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; failed=$((failed + 1)); }
yes_() { if images_verified "$P/pkg.zip"; then ok "$1"; else no "$1"; fi; }
not_() { if images_verified "$P/pkg.zip"; then no "$1"; else ok "$1"; fi; }

export HOME=$W/home
mkdir -p "$HOME"
kitc=$W/kit
cp -a "$KITSRC" "$kitc"
rm -rf -- "$kitc/.git"
git -C "$kitc" init -q
git -C "$kitc" -c user.name=t -c user.email=t@t add -A
git -C "$kitc" -c user.name=t -c user.email=t@t commit -q -m test

export EOS_DEVICE
# shellcheck source=../../lib.sh
source "$kitc/lib.sh"
set +e +o pipefail; set -u   # the tests count failures themselves
top=$W/tree
P=$EOS_PRODUCT_OUT
mkdir -p "$top/$P" "$top/$EOS_STATE"
cd "$top"
printf 'version 1\nflash boot\nflash init_boot\nflash vbmeta\nflash super\n' > "$P/fastboot-info.txt"
echo "require board=$EOS_DEVICE" > "$P/android-info.txt"
for i in boot init_boot vbmeta super super_empty dtbo vendor_kernel_boot; do head -c 4096 /dev/urandom > "$P/$i.img"; done
echo pkg > "$P/pkg.zip"
echo "kit: $(kit_version)" > "$EOS_STATE/sources.txt"
printf '== verify\nOK: incremental base: something\nVERIFIED %s\nVERIFY=OK\n' "$top/$P/pkg.zip" > "$W/step.log"

out=$(verified_save "$W/step.log")
[[ -f $EOS_STATE/verified.ok && -f $EOS_STATE/images-verify.log && $out == "OK: kept this verify"* ]] \
    && ok "verified_save keeps the log and verified.ok" || no "verified_save keeps the log and verified.ok ($out)"
want=6; [[ $EOS_SUPER_EMPTY != out ]] || want=$((want + 1)); [[ $EOS_FLASH_VKB != 1 ]] || want=$((want + 1))
[[ "$(wc -l < "$EOS_STATE/verified.ok")" = "$want" ]] && ok "verified.ok has the $want files the zip takes (EOS_SUPER_EMPTY=$EOS_SUPER_EMPTY, EOS_FLASH_VKB=$EOS_FLASH_VKB)" \
    || no "verified.ok has $(wc -l < "$EOS_STATE/verified.ok") lines, not $want"
yes_ "same package, same kit, out/ unchanged: taken"

images_verified "$P/other.zip" && no "another package: refused" || ok "another package: refused"

cp -p "$P/init_boot.img" "$W/ib"
echo x >> "$P/init_boot.img"
not_ "an image changed since the verify: refused"
cp -p "$W/ib" "$P/init_boot.img"
yes_ "the image back as it was: taken"

cp "$P/fastboot-info.txt" "$W/fbi"
echo 'flash dtbo' >> "$P/fastboot-info.txt"
not_ "fastboot-info.txt flashes another image now: refused"
cp "$W/fbi" "$P/fastboot-info.txt"

cp "$EOS_STATE/images-verify.log" "$W/log"
sed -i 's/^VERIFY=OK$/VERIFY=FAIL/' "$EOS_STATE/images-verify.log"
not_ "the verify log doesn't end VERIFY=OK: refused"
printf '== verify\nVERIFIED %s\nVERIFY=OK\nsomething after\n' "$top/$P/pkg.zip" > "$EOS_STATE/images-verify.log"
not_ "VERIFY=OK not the last line: refused"
cp "$W/log" "$EOS_STATE/images-verify.log"

echo "kit: 0000000000000000000000000000000000000000" > "$EOS_STATE/sources.txt"
not_ "the build's kit is another commit: refused"
echo "kit: $(kit_version)" > "$EOS_STATE/sources.txt"
echo change >> "$kitc/README.md"
not_ "the kit has local changes: refused"
echo "kit: $(kit_version)" > "$EOS_STATE/sources.txt"
not_ "the kit has local changes, even when sources.txt says the same: refused"
git -C "$kitc" checkout -q -- README.md
echo "kit: $(kit_version)" > "$EOS_STATE/sources.txt"
yes_ "the kit clean again: taken"

rm -f "$EOS_STATE/verified.ok"
not_ "no verified.ok (an older kit's build, or a failed save): refused"
rm -f "$P/vbmeta.img"
out=$(verified_save "$W/step.log")
[[ ! -e $EOS_STATE/verified.ok && ! -e $EOS_STATE/images-verify.log && $out == "note: no $P/vbmeta.img"* ]] \
    && ok "verified_save with an image missing keeps neither file, and says so" || no "verified_save with an image missing ($out)"

echo "PASSED $pass FAILED $failed"
[[ $failed = 0 ]]
