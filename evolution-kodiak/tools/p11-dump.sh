#!/bin/bash
# p11-dump.sh <device>: unpack <device>-cd1a.261005.003 factory zip and dump it
# with dumpyara exactly like dumps/kodiak (see dumpyara.log).
set -euo pipefail
d=$1; B=cd1a.261005.003
cd ~/android-dt/firmware
fz=$(ls $d-$B-factory-*.zip)
grep -q "DL_OK $fz" ~/dl-p11.log || { echo "$fz not verified yet" >&2; exit 1; }
mkdir -p $d-$B-bootloader-radio
unzip -o -q -j "$fz" "$d-$B/image-$d-$B.zip" -d .
unzip -o -q -j "$fz" "$d-$B/bootloader-*.img" "$d-$B/radio-*.img" "$d-$B/*.ec.bin" -d $d-$B-bootloader-radio || true
unzip -l "$fz" > $d-$B-bootloader-radio/factory-zip-listing.txt
source ~/android-dt/.venv/bin/activate
export PATH=~/android-dt/bin:$PATH
rm -rf ~/android-dt/dumps/$d
python -m dumpyara -v ~/android-dt/firmware/image-$d-$B.zip -o ~/android-dt/dumps/$d > ~/android-dt/dumpyara-$d.log 2>&1 || true
ls ~/android-dt/dumps/$d
du -sh ~/android-dt/dumps/$d
echo "DUMP_DONE $d"
