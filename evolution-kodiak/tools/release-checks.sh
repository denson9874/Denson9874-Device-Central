#!/bin/bash
# Pre-release checks on a finished build in out/, for the two kinds of regression
# the 10-18 build shipped without anyone noticing (HANDOFF 2aj):
#
#   1. Association rules: every <allow-association> in the build's sysconfig and
#      permissions XML must also be in stock firmware (~/android-dt/dumps/<dev>).
#      vendor/gms's nowplaying.xml added one for com.google.android.as.oss, which
#      cut Android System Intelligence off from Private Compute Services (Now
#      Playing and At a Glance settings couldn't be changed, ISS-20261019-01/-05).
#      Skipped (with a note) for a device without a stock dump.
#   2. Stale apps: every APK under */app and */priv-app in out/ must be one this
#      build installs (listed in obj/PACKAGING/<part>_intermediates/file_list.txt). A SystemUI.apk left in out/
#      from 10-15 shipped next to SystemUIGoogle and won, crashing SystemUI after
#      fingerprint unlock (ISS-20261020-01). Also flags SystemUI next to SystemUIGoogle.
#
#   release-checks.sh <kodiak|grizzly|cubs|yogi|cheetah>
#
# Exit 0 and RELEASE_CHECKS=OK when both pass; exit 1 and RELEASE_CHECKS=FAILED otherwise.
set -uo pipefail

dev=${1:?usage: release-checks.sh <device>}
TOP=~/evolution
O=$TOP/out/target/product/$dev
STOCK=~/android-dt/dumps/$dev
[ -d "$O" ] || { echo "no $O"; echo "RELEASE_CHECKS=FAILED"; exit 1; }
cd "$TOP" || exit 1

python3 -I - "$dev" "$O" "$STOCK" <<'EOF'
import glob, os, re, sys
import xml.etree.ElementTree as ET

dev, out, stock = sys.argv[1:4]
bad = 0

# 1. Association rules
def assocs(root):
    rules = {}
    for part in ('system', 'system_ext', 'product', 'vendor', 'odm'):
        for d in ('sysconfig', 'permissions'):
            for f in glob.glob(f'{root}/{part}/etc/{d}/*.xml'):
                try:
                    tree = ET.parse(f)
                except ET.ParseError:
                    continue
                for e in tree.iter('allow-association'):
                    key = (e.get('target'), e.get('allowed'))
                    rules.setdefault(key, f'{part}/etc/{d}/{os.path.basename(f)}')
    return rules

built = assocs(out)
if os.path.isdir(f'{stock}/product'):
    ref = assocs(stock)
    print(f'== association rules: {len(built)} in the build, {len(ref)} in stock')
else:
    ref = built
    print(f'== association rules: SKIPPED, no stock dump at {stock}')
extra = sorted(k for k in built if k not in ref)
for target, allowed in extra:
    print(f'   NOT IN STOCK: target={target} allowed={allowed} ({built[(target, allowed)]})')
if extra:
    print('   A target with any allow-association refuses every package not listed: compare with stock')
    bad += 1
else:
    print('   OK')

# 2. Stale apps: APKs in a partition's staging dir that aren't in the list of files the build
# installs there (obj/PACKAGING/<part>_intermediates/file_list.txt). The images are made from
# the staging dirs, so anything left over from an earlier build ships.
print('== stale apps')
checked = 0
for part in ('system', 'system_ext', 'product', 'vendor', 'odm'):
    fl = f'{out}/obj/PACKAGING/{part}_intermediates/file_list.txt'
    root = f'{out}/{part}'
    if part == 'system' and os.path.isdir(f'{out}/system/system'):
        root = f'{out}/system/system'
    if not os.path.exists(fl) or not os.path.isdir(root):
        continue
    want = {l.strip() for l in open(fl) if l.strip()}
    apks = sorted(os.path.relpath(p, root) for p in glob.glob(f'{root}/*app/*/*.apk'))
    apks = [a for a in apks if a.split('/')[0] in ('app', 'priv-app')]
    stale = [a for a in apks if a not in want]
    checked += 1
    print(f'   {part}: {len(apks)} APKs, {len(stale)} not installed by this build')
    for a in stale:
        print(f'   NOT INSTALLED BY THIS BUILD: {part}/{a} (delete it from out/ and rebuild)')
    if stale:
        bad += 1
dirs = {os.path.basename(os.path.dirname(p)) for p in glob.glob(f'{out}/**/priv-app/*/*.apk', recursive=True)}
if 'SystemUI' in dirs and 'SystemUIGoogle' in dirs:
    print('   SystemUI and SystemUIGoogle are both in out/')
    bad += 1
if checked < 3:
    print(f'   only {checked} partitions had a file list (expected system, system_ext, product)')
    bad += 1

print('RELEASE_CHECKS=' + ('FAILED' if bad else 'OK'))
sys.exit(1 if bad else 0)
EOF
