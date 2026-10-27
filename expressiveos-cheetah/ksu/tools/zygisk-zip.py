#!/usr/bin/env python3
"""Check the Zygisk provider zip ksu.conf pins (NeoZygisk) without running anything in it,
for fetch-ksu.sh, apply-ksu.sh and ksu-check.sh. Run it with python3 -I.

  zygisk-zip.py <zip> <module id> <versionCode> [<risk.json>]

- module.prop names <module id> and <versionCode>;
- every file has its <file>.sha256 next to it and matches it (customize.sh's verify.sh
  checks the same on the phone, and aborts the install if one doesn't);
- with <risk.json> (KernelSU Next's risk/risk.json, from the pinned source): no rule
  matches any file, the way ksud's install-time scan matches them (risk.rs: NFKC,
  lower case, everything but letters and digits a space, a pattern's words in a row).
  A match would stop the first-boot install: "medium" and "low" wait 5 s for a
  volume-down press nobody makes, "high" and "extreme" refuse.
Prints what it checked and, last, ZYGISK_ZIP=OK or ZYGISK_ZIP=FAIL.
"""
import hashlib
import json
import sys
import unicodedata
import zipfile

MAX_SCAN = 8 * 1024 * 1024   # risk.rs MAX_SCAN_BYTES_PER_FILE


def fail(msg):
    print('FAIL: ' + msg)
    print('ZYGISK_ZIP=FAIL')
    sys.exit(1)


def words(text):
    text = unicodedata.normalize('NFKC', text).lower()
    return ''.join(c if c.isalnum() else ' ' for c in text).split()


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__.strip())
    path, want_id, want_code = sys.argv[1:4]
    try:
        z = zipfile.ZipFile(path)
        files = [i for i in z.infolist() if not i.is_dir()]
        names = {i.filename for i in files}
        prop = {}
        for line in z.read('module.prop').decode('utf-8', 'replace').splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                prop[k.strip()] = v.strip()
    except (OSError, KeyError, zipfile.BadZipFile) as e:
        fail('%s: %s' % (path, e))
    if prop.get('id') != want_id or prop.get('versionCode') != want_code:
        fail('module.prop is id=%s versionCode=%s, ksu.conf wants %s %s'
             % (prop.get('id'), prop.get('versionCode'), want_id, want_code))
    print('OK: module.prop: %s %s (%s), by %s' % (want_id, prop.get('version'), want_code, prop.get('author')))

    payload = sorted(n for n in names if not n.endswith('.sha256'))
    for n in sorted(names - set(payload)):
        if n[:-len('.sha256')] not in names:
            fail('%s has no file %s' % (n, n[:-len('.sha256')]))
    for n in payload:
        if n + '.sha256' not in names:
            fail('%s has no %s.sha256' % (n, n))
        want = z.read(n + '.sha256').decode('ascii', 'replace').split()
        if not want or hashlib.sha256(z.read(n)).hexdigest() != want[0]:
            fail('%s doesn\'t match its .sha256' % n)
    print('OK: all %d files match their .sha256' % len(payload))

    if len(sys.argv) == 5:
        try:
            with open(sys.argv[4], 'rb') as f:
                catalog = json.load(f)
            # A pattern's words in a row = its words, space-joined, inside the file's
            rules = [(r['severity'], r['reason'], [' %s ' % ' '.join(w) for w in (words(p) for p in r['patterns']) if w])
                     for r in catalog['rules']]
        except (OSError, ValueError, KeyError, TypeError) as e:
            fail('%s: %s' % (sys.argv[4], e))
        for i in files:
            with z.open(i) as f:
                text = ' %s ' % ' '.join(words(f.read(MAX_SCAN).decode('utf-8', 'replace')))
            for severity, reason, patterns in rules:
                for p in patterns:
                    if p in text:
                        fail('%s matches KernelSU Next\'s risk rule "%s" (%s, %s): ksud would stop the install'
                             % (i.filename, p.strip(), severity, reason))
        print('OK: no KernelSU Next risk rule matches (%d rules, catalog %s)' % (len(rules), catalog.get('hash', '?')[:12]))
    print('ZYGISK_ZIP=OK')


if __name__ == '__main__':
    main()
