#!/usr/bin/env python3
"""Compare the ROM's Google apps package (vendor/gms) with a stock Pixel image, for a Pixel Drop.

  gms-drop.py compare <stock-root> <vendor_gms>   report only, changes nothing
  gms-drop.py apply   <stock-root> <vendor_gms>   copy stock's newer APKs over the ones we carry

<stock-root> holds a stock image's partitions as folders: product/, system_ext/ and system/
(system/system/ is taken too), as extracted from Google's factory image or full OTA.
<vendor_gms> is a checkout of ExpressiveOS/vendor_gms with its Git LFS files present.

APKs are matched by package name, read from each APK's own manifest, because the folder names
carry versions (AiIconsPrebuilt_20260121) and change from one stock release to the next.

apply only replaces the bytes of an APK we already carry, at our path, and only when stock's
versionCode is higher. It never adds an app (a new app needs its Android.bp and gms_*.mk entry
written and reviewed), never downgrades, and never touches a file under blobs/: our sysconfig
and permission XMLs carry fixes (nowplaying.xml), so their differences are printed for a person.

Stock's own platform apps (com.android.*, android.*) and the system partition's config files are
counted, not listed: they come from the Android source, not from this package. CHANGES counts
what needs a decision: newer apps, and carried config files that differ or that stock dropped.

Last line: GMS_DROP=NONE, GMS_DROP=CHANGES <n> (compare) or GMS_DROP=APPLIED <n> (apply).
Exit status 0 unless the arguments or a folder are wrong.
"""
import hashlib
import os
import shutil
import struct
import sys
import zipfile

PARTS = ('product', 'system_ext', 'system')
RES_VERSION_CODE, RES_VERSION_NAME, RES_VERSION_MAJOR = 0x0101021b, 0x0101021c, 0x01010576
LFS_MAGIC = b'version https://git-lfs'


def _pool(data, start):
    """Decode the string pool chunk that starts at data[start]."""
    hsize, = struct.unpack_from('<H', data, start + 2)
    count, _styles, flags, strings_start, _ = struct.unpack_from('<5I', data, start + 8)
    utf8 = bool(flags & 0x100)
    out = []
    for i in range(count):
        off, = struct.unpack_from('<I', data, start + hsize + 4 * i)
        p = start + strings_start + off
        if utf8:
            for _ in range(2):          # length in characters, then length in bytes
                n = data[p]; p += 1
                if n & 0x80:
                    n = ((n & 0x7f) << 8) | data[p]; p += 1
            out.append(data[p:p + n].decode('utf-8', 'replace'))
        else:
            n, = struct.unpack_from('<H', data, p); p += 2
            if n & 0x8000:
                lo, = struct.unpack_from('<H', data, p); p += 2
                n = ((n & 0x7fff) << 16) | lo
            out.append(data[p:p + 2 * n].decode('utf-16-le', 'replace'))
    return out


def manifest_info(data):
    """(package, versionCode, versionName) from a binary AndroidManifest.xml."""
    if len(data) < 8 or struct.unpack_from('<H', data, 0)[0] != 0x0003:
        raise ValueError('not a binary AndroidManifest.xml')
    strings, resmap, pos = [], [], 8
    while pos + 8 <= len(data):
        ctype, _hsize, size = struct.unpack_from('<HHI', data, pos)
        if size < 8 or pos + size > len(data):
            raise ValueError('bad chunk at %d' % pos)
        if ctype == 0x0001:
            strings = _pool(data, pos)
        elif ctype == 0x0180:
            resmap = list(struct.unpack_from('<%dI' % ((size - 8) // 4), data, pos + 8))
        elif ctype == 0x0102:
            name, attr_start, attr_size, attr_count = struct.unpack_from('<IHHH', data, pos + 20)
            if strings[name] != 'manifest':
                raise ValueError('first element is <%s>' % strings[name])
            package, code, major, vname = None, None, 0, ''
            for i in range(attr_count):
                a = pos + 16 + attr_start + i * attr_size
                _ns, aname, raw, _sz, _r0, dtype, value = struct.unpack_from('<IIIHBBI', data, a)
                res = resmap[aname] if aname < len(resmap) else 0
                text = strings[raw] if raw != 0xffffffff else (strings[value] if dtype == 3 else None)
                if res == RES_VERSION_CODE:
                    code = value
                elif res == RES_VERSION_MAJOR:
                    major = value
                elif res == RES_VERSION_NAME:
                    vname = text if text is not None else str(value)
                elif res == 0 and strings[aname] == 'package':
                    package = text
            if package is None or code is None:
                raise ValueError('<manifest> has no package or versionCode')
            return package, (major << 32) | code, vname
        pos += size
    raise ValueError('no <manifest> element')


def apk_info(path):
    """dict for one APK file: package, code, name; or lfs=True / error=<text>."""
    with open(path, 'rb') as f:
        head = f.read(len(LFS_MAGIC))
    if head == LFS_MAGIC:
        return {'lfs': True}
    try:
        with zipfile.ZipFile(path) as z:
            package, code, name = manifest_info(z.read('AndroidManifest.xml'))
    except (ValueError, KeyError, IndexError, struct.error, zipfile.BadZipFile, OSError) as e:
        return {'error': '%s: %s' % (type(e).__name__, e)}
    return {'package': package, 'code': code, 'name': name}


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def walk(top, suffix=''):
    for d, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(files):
            p = os.path.join(d, name)
            if name.endswith(suffix) and not os.path.islink(p):
                yield p


def stock_part(root, part):
    """The folder that holds <part>'s files in the stock root, or None."""
    for cand in ((part, part), (part,)) if part == 'system' else ((part,),):
        p = os.path.join(root, *cand)
        if os.path.isdir(os.path.join(p, 'etc')) or os.path.isdir(os.path.join(p, 'app')) \
                or os.path.isdir(os.path.join(p, 'priv-app')):
            return p
    return None


def scan(stock, gms):
    notes = []
    ours, ours_other = {}, []            # package -> (path, info); [(path, why)]
    for part in PARTS:
        top = os.path.join(gms, part, 'packages')
        for p in walk(top, '.apk') if os.path.isdir(top) else ():
            info = apk_info(p)
            if 'package' not in info:
                ours_other.append((p, 'Git LFS pointer: run git lfs pull' if info.get('lfs') else info['error']))
            elif info['package'] in ours:
                ours_other.append((p, 'second copy of %s (also %s)' % (info['package'], os.path.relpath(ours[info['package']][0], gms))))
            else:
                ours[info['package']] = (p, info)
    theirs, parts_found = {}, {}
    for part in PARTS:
        sp = stock_part(stock, part)
        parts_found[part] = sp
        if sp is None:
            notes.append('stock has no %s partition folder: nothing in it was compared' % part)
            continue
        for sub in ('app', 'priv-app'):
            top = os.path.join(sp, sub)
            for p in walk(top, '.apk') if os.path.isdir(top) else ():
                info = apk_info(p)
                if 'package' not in info:
                    notes.append('stock APK not read: %s (%s)' % (os.path.relpath(p, stock), info.get('error', 'LFS pointer')))
                    continue
                old = theirs.get(info['package'])
                if old is None or info['code'] > old[1]['code']:
                    theirs[info['package']] = (p, info)
    return ours, ours_other, theirs, parts_found, notes


def etc_report(stock_root, stock_parts, gms):
    """Differences in the config files we carry, and stock sysconfig/permissions we don't."""
    differ, gone, new, platform = [], [], [], 0
    for part in PARTS:
        top, sp = os.path.join(gms, part, 'blobs', 'etc'), stock_parts.get(part)
        if not os.path.isdir(top) or sp is None:
            continue
        shown = os.path.relpath(sp, stock_root)
        carried = set()
        for p in walk(top):
            rel = os.path.relpath(p, top)
            if os.path.basename(p) in ('Android.bp', 'Android.mk'):
                continue
            carried.add(rel)
            s = os.path.join(sp, 'etc', rel)
            if not os.path.isfile(s):
                gone.append('%s/etc/%s' % (shown, rel))
            elif sha256(s) != sha256(p):
                differ.append('%s/etc/%s' % (shown, rel))
        for sub in ('sysconfig', 'permissions', 'default-permissions'):
            d = os.path.join(sp, 'etc', sub)
            for p in walk(d, '.xml') if os.path.isdir(d) else ():
                rel = os.path.relpath(p, os.path.join(sp, 'etc'))
                if rel in carried:
                    continue
                if part == 'system':
                    platform += 1
                else:
                    new.append('%s/etc/%s' % (shown, rel))
    return differ, gone, new, platform


def ver(info):
    return '%s (%d)' % (info['name'] or '?', info['code'])


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('compare', 'apply'):
        sys.exit(__doc__)
    mode, stock, gms = sys.argv[1:]
    for d, what in ((stock, 'stock root'), (gms, 'vendor_gms')):
        if not os.path.isdir(d):
            sys.exit('%s: not a folder (%s)' % (d, what))
    if not any(os.path.isdir(os.path.join(gms, p, 'packages')) for p in PARTS):
        sys.exit('%s: no <partition>/packages folder: not a vendor_gms checkout' % gms)
    ours, ours_other, theirs, stock_parts, notes = scan(stock, gms)
    if not theirs:
        sys.exit('%s: no readable APK under product/, system_ext/ or system/: not a stock root' % stock)

    newer, same, older, only_ours = [], [], [], []
    for pkg in sorted(ours):
        path, info = ours[pkg]
        if pkg not in theirs:
            only_ours.append((pkg, path, info))
        elif theirs[pkg][1]['code'] > info['code']:
            newer.append((pkg, path, info) + theirs[pkg])
        elif theirs[pkg][1]['code'] < info['code']:
            older.append((pkg, path, info) + theirs[pkg])
        else:
            same.append(pkg)
    only_stock = sorted((pkg,) + theirs[pkg] for pkg in theirs if pkg not in ours)
    n_platform = sum(1 for o in only_stock if o[0].startswith(('com.android.', 'android.')))
    only_stock = [o for o in only_stock if not o[0].startswith(('com.android.', 'android.'))]
    differ, gone, new, etc_platform = etc_report(stock, stock_parts, gms)

    print('== apps we carry that stock has newer (%d)%s' % (len(newer), ': apply copies these' if mode == 'compare' else ''))
    for pkg, path, info, spath, sinfo in newer:
        print('  %s  %s -> %s\n      ours  %s\n      stock %s' % (pkg, ver(info), ver(sinfo), os.path.relpath(path, gms), os.path.relpath(spath, stock)))
    print('== apps we carry at the same version: %d' % len(same))
    print('== apps we carry that are NEWER than stock (%d): left alone' % len(older))
    for pkg, path, info, spath, sinfo in older:
        print('  %s  ours %s, stock %s' % (pkg, ver(info), ver(sinfo)))
    print('== apps we carry that this stock image does not have (%d): left alone' % len(only_ours))
    for pkg, path, info in only_ours:
        print('  %s  %s  %s' % (pkg, ver(info), os.path.relpath(path, gms)))
    print('== our APK files that could not be compared (%d)' % len(ours_other))
    for path, why in ours_other:
        print('  %s: %s' % (os.path.relpath(path, gms), why))
    print('== stock apps we do not carry (%d): a new one may be a Drop app; adding it is a hand change' % len(only_stock))
    for pkg, spath, sinfo in only_stock:
        print('  %s  %s  %s' % (pkg, ver(sinfo), os.path.relpath(spath, stock)))
    print('== stock platform apps (com.android.*, android.*) we do not carry: %d, not listed' % n_platform)
    print('== config files we carry that differ from stock (%d): diff by hand, ours carry fixes' % len(differ))
    for f in differ:
        print('  ' + f)
    print('== config files we carry that stock no longer has (%d)' % len(gone))
    for f in gone:
        print('  ' + f)
    print('== stock sysconfig/permission files we do not carry (%d)' % len(new))
    for f in new:
        print('  ' + f)
    print('== stock system-partition config files we do not carry: %d, not listed' % etc_platform)
    for n in notes:
        print('note: ' + n)

    if mode == 'apply':
        for pkg, path, info, spath, sinfo in newer:
            tmp = path + '.gms-drop'
            shutil.copyfile(spath, tmp)
            os.replace(tmp, path)
            print('applied: %s %s -> %s' % (os.path.relpath(path, gms), ver(info), ver(sinfo)))
        print('GMS_DROP=APPLIED %d' % len(newer))
    else:
        n = len(newer) + len(differ) + len(gone)
        print('GMS_DROP=CHANGES %d' % n if n else 'GMS_DROP=NONE')


if __name__ == '__main__':
    main()
