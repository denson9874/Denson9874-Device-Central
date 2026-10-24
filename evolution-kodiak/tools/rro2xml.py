#!/usr/bin/env python3
"""rro2xml.py: turn selected resources of stock (Google-built) RRO APKs into
resource XML for our own overlays.

  rro2xml.py <out-res-dir> <file-basename> <apk>[:<name>,<name>...] ...

Only the default-locale value of strings is kept. References to resources the
overlay itself defines (e.g. @dimen/yogi_unfolded_*) are inlined, so the
generated overlay only references resources of the target package.
"""
import os
import re
import subprocess
import sys
from collections import defaultdict
from xml.sax.saxutils import escape

AAPT2 = os.path.expanduser('~/evolution/out/host/linux-x86/bin/aapt2')


def parse(apk):
    """{(type, name): {config: raw value}} from `aapt2 dump resources`."""
    out = subprocess.run([AAPT2, 'dump', 'resources', apk],
                         capture_output=True, text=True, check=True).stdout
    res, cur, pending, buf = {}, None, None, ''
    for line in out.splitlines():
        m = re.match(r'\s+resource 0x[0-9a-f]+ (\w+)/(\S+)', line)
        if m:
            cur = (m.group(1), m.group(2)); res[cur] = {}; pending = None
            continue
        if cur is None:
            continue
        m = re.match(r'\s+\(([^)]*)\) (.*)$', line)
        if m:
            cfg, val = m.group(1), m.group(2)
            if val.startswith('(array)'):
                pending = cfg            # items follow on the next line
            else:
                res[cur][cfg] = val
            continue
        # aapt2 wraps long arrays over several lines: collect from '[' to the closing ']'
        if pending is not None and (buf or line.strip().startswith('[')):
            buf += line.strip()
            if buf.endswith(']'):
                res[cur][pending] = ('ARRAY', buf[1:-1]); pending = None; buf = ''
            else:
                buf += ' '
    return res


def split_items(s):
    items, cur, q = [], '', False
    for ch in s:
        if ch == '"' and not cur.endswith('\\'):
            q = not q
        if ch == ',' and not q:
            items.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def unquote(v):
    return v[1:-1].replace('\\"', '"').replace("\\'", "'") if v.startswith('"') else v


def resolve(v, res, cfg):
    """Inline @type/name when the overlay itself defines it."""
    m = re.fullmatch(r'@(\w+)/(\S+)', v)
    if m and (m.group(1), m.group(2)) in res:
        vals = res[(m.group(1), m.group(2))]
        return resolve(vals.get(cfg, vals.get('')), res, cfg)
    return v


def dimen(v):
    m = re.fullmatch(r'(-?[0-9.]+)(dp|sp|px)', v)
    if m:
        f = float(m.group(1))
        num = str(int(f)) if f.is_integer() else f'{f:.6f}'.rstrip('0').rstrip('.')
        return f'{num}{m.group(2)}', None
    if re.fullmatch(r'-?[0-9.]+', v):
        return v, 'float'
    return v, None


def main():
    out_dir, base = sys.argv[1], sys.argv[2]
    files = defaultdict(list)          # config -> xml lines
    for spec in sys.argv[3:]:
        apk, _, names = spec.partition(':')
        res = parse(apk)
        wanted = names.split(',') if names else None
        for (typ, name), vals in sorted(res.items()):
            if wanted is not None and name not in wanted:
                continue
            for cfg, raw in vals.items():
                if cfg not in ('',) and not re.fullmatch(r'[a-z0-9-]+', cfg):
                    continue                     # locales etc.: default only
                if typ == 'string' and cfg != '':
                    continue
                if isinstance(raw, tuple):
                    items = [unquote(resolve(i, res, cfg)) for i in split_items(raw[1])]
                    numeric = all(re.fullmatch(r'-?\d+', i) for i in items)
                    tag = 'integer-array' if numeric else 'string-array'
                    body = ''.join(f'\n        <item>{escape(i)}</item>' for i in items)
                    xml = f'    <{tag} name="{name}">{body}\n    </{tag}>'
                else:
                    v = unquote(resolve(raw, res, cfg))
                    if typ == 'dimen':
                        v, fmt = dimen(v)
                        xml = (f'    <item name="{name}" format="float" type="dimen">{v}</item>' if fmt
                               else f'    <dimen name="{name}">{v}</dimen>')
                    elif typ in ('bool', 'integer', 'string'):
                        tr = ' translatable="false"' if typ == 'string' else ''
                        xml = f'    <{typ} name="{name}"{tr}>{escape(v)}</{typ}>'
                    else:
                        print(f'skipping {typ}/{name}', file=sys.stderr); continue
                files[cfg].append(xml)
    for cfg, lines in files.items():
        d = os.path.join(out_dir, 'values' + (f'-{cfg}' if cfg else ''))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f'{base}.xml'), 'w') as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<!-- Generated by tools/rro2xml.py from the stock yogi CD1A.261005.003 overlays. -->\n'
                    '<resources>\n' + '\n'.join(sorted(set(lines))) + '\n</resources>\n')
        print(f'{d}/{base}.xml: {len(set(lines))} resources')


if __name__ == '__main__':
    main()
