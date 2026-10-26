#!/usr/bin/env python3
"""Where the time went in past Android builds, from soong_ui's build traces
(out/build.trace*.gz) and ninja's logs (out/.ninja_log, out/soong/.ninja_log).

    build-timings.py <tree> [<tree>...]

Prints names, counts and durations only (phases, kinds of build step, the longest
steps by output path), never file contents. Read-only.
"""
import bisect
import collections
import gzip
import json
import os
import re
import sys
import time

DETAILED = 2      # newest traces per tree always shown in full
LONG = 600        # ...and every trace of a build that took this many seconds or more
MAX_TRACES = 8


def hms(sec):
    sec = int(round(sec))
    return '%d:%02d:%02d' % (sec // 3600, sec // 60 % 60, sec % 60)


def when(epoch):
    return time.strftime('%Y-%m-%d %H:%M', time.localtime(epoch))


# Kinds of build step, by output path. First match wins.
KINDS = [
    ('C/C++ compile', re.compile(r'\.(o|obj)$')),
    ('ABI dumps and checks', re.compile(r'\.(sdump|lsdump|abidiff)$|/abi-dumps?/|abi_diff')),
    ('API stubs, metalava', re.compile(r'metalava|droidstubs|-stubs-source|_api\.txt$|api_lint|check_last_released_api|check_current_api|\.api_contribution')),
    ('dexpreopt (dex2oat)', re.compile(r'\.(odex|vdex|art|oat)$|/dexpreopt|dex_bootjars|boot\.(art|oat)|/oat/')),
    ('R8, D8 (dexing)', re.compile(r'/(dex|r8|d8|proguard)/|classes\.dex|\.dex$|proguard_dictionary')),
    ('Java, Kotlin compile', re.compile(r'/(javac|turbine|kotlin|kapt|combined|javac-header|withres|aligned)/.*\.(jar|srcjar)$|\.(jar|srcjar)$')),
    ('Rust', re.compile(r'\.(rlib|rmeta|dylib\.so)$|/rustc/|clippy')),
    ('resources (aapt2)', re.compile(r'\.(flata|flat|arsc)$|/aapt2/|/R\.jar$|package-res')),
    ('code generation (aidl, hidl, protos, sysprop)', re.compile(r'/gen/|aidl|hidl|\.pb\.|proto|sysprop|\.srcjar$')),
    ('linking (.so, .a, binaries)', re.compile(r'\.(so|a|toc)$|/unstripped/|/linker|/stripped/')),
    ('APK, APEX packaging and signing', re.compile(r'\.(apk|apex|capex|aab|apks)$|signapk|apexer')),
    ('SELinux policy', re.compile(r'sepolicy|\.cil$|_contexts$|\.conf\.policy')),
    ('partition images (.img)', re.compile(r'\.img$|/IMAGES/|_image_info|build_image')),
    ('target-files, OTA and other zips', re.compile(r'target_files|ota|\.zip$|payload|care_map')),
    ('copying and installing', re.compile(r'^out/target/product/[^/]+/(system|vendor|product|system_ext|odm|vendor_dlkm|system_dlkm|recovery|ramdisk|vendor_ramdisk|data|apex|debug_ramdisk)/')),
    ('notices, licenses, metadata', re.compile(r'NOTICE|notice|license|sbom|module-info|\.pb$|\.json$|\.textproto$')),
]


def kind(path):
    for name, rx in KINDS:
        if rx.search(path):
            return name
    return 'other'


def edges_profile(edges, label_ok=True):
    """edges: list of (start_s, dur_s, output). Prints totals, kinds, longest steps and
    how parallel the build was."""
    if not edges:
        print('    (no build steps recorded)')
        return
    t0 = min(s for s, d, o in edges)
    t1 = max(s + d for s, d, o in edges)
    wall = t1 - t0
    cpu = sum(d for s, d, o in edges)
    print('    build steps: %d, wall %s, step time %s (on average %.1f running at once)'
          % (len(edges), hms(wall), hms(cpu), cpu / wall if wall else 0))
    # How much of the wall time ran 1, 2-4, 5-15 or 16+ steps at once
    ev = []
    for s, d, o in edges:
        ev.append((s, 1))
        ev.append((s + d, -1))
    ev.sort()
    bands = collections.OrderedDict((b, 0.0) for b in ('1', '2-4', '5-15', '16+'))
    cur, last = 0, ev[0][0]
    for t, delta in ev:
        if cur > 0:
            b = '1' if cur == 1 else '2-4' if cur <= 4 else '5-15' if cur <= 15 else '16+'
            bands[b] += t - last
        cur += delta
        last = t
    print('    wall time with 1 / 2-4 / 5-15 / 16+ steps running: '
          + ' / '.join('%s' % hms(v) for v in bands.values()))
    by = collections.defaultdict(lambda: [0, 0.0])
    for s, d, o in edges:
        k = by[kind(o)]
        k[0] += 1
        k[1] += d
    print('    step time by kind:')
    for name, (n, d) in sorted(by.items(), key=lambda kv: -kv[1][1])[:16]:
        print('      %-46s %8s  %6d steps, %6.1f s each' % (name, hms(d), n, d / n if n else 0))
    other = collections.Counter()
    for s, d, o in edges:
        if kind(o) == 'other':
            m = re.search(r'(\.[A-Za-z0-9_]+)$', o.rsplit('/', 1)[-1])
            other[m.group(1) if m else '(no extension)'] += d
    if other:
        print('      other, by extension: ' + ', '.join('%s %s' % (e, hms(d)) for e, d in other.most_common(8)))
    # Steps running at once over time, and its running integral, so the average
    # number of steps running beside any one step is a lookup
    times, conc, area = [], [], [0.0]
    cur = 0
    for t, delta in ev:
        if times and t == times[-1]:
            cur += delta
            conc[-1] = cur
            continue
        if times:
            area.append(area[-1] + conc[-1] * (t - times[-1]))
        times.append(t)
        cur += delta
        conc.append(cur)

    def integral(t):
        i = bisect.bisect_right(times, t) - 1
        if i < 0:
            return 0.0
        return area[i] + conc[i] * (t - times[i])

    def beside(s, d):
        return (integral(s + d) - integral(s)) / d - 1 if d else 0
    print('    longest steps (and how many steps ran beside them on average):')
    longest = sorted(edges, key=lambda e: -e[1])[:15]
    for s, d, o in longest:
        if d < 30:
            break
        print('      %s  at +%s  beside %4.1f  %s' % (hms(d), hms(s - t0), beside(s, d), o[:150]))
    # The steps that ran (nearly) alone, in order: the build's serial part
    big = [e for e in edges if e[1] >= 15]
    serial = [(s, d, o) for s, d, o in big if beside(s, d) <= 1.5]
    if serial:
        print('    steps of 15 s or more that ran nearly alone, in order (%s in all):' % hms(sum(d for s, d, o in serial)))
        for s, d, o in sorted(serial)[:25]:
            print('      +%s  %s  %s' % (hms(s - t0), hms(d), o[:150]))


def read_trace(path):
    """soong_ui's Chrome-format trace: one JSON event per line."""
    opener = gzip.open if open(path, 'rb').read(2) == b'\x1f\x8b' else open
    events = []
    with opener(path, 'rt', errors='replace') as f:
        for line in f:
            line = line.strip().lstrip('[').rstrip(',').rstrip(']').strip().rstrip(',')
            if not line.startswith('{'):
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
    return events


def trace_summary(path, newest):
    try:
        events = read_trace(path)
    except (OSError, EOFError) as e:
        print('  %s: unreadable (%s)' % (path, e))
        return
    stacks = collections.defaultdict(list)
    phases = []          # (depth, name, start_us, dur_us)
    edges = []           # (start_s, dur_s, output)
    for e in events:
        ph = e.get('ph')
        ts = e.get('ts', 0)
        key = (e.get('pid', 0), e.get('tid', 0))
        if ph == 'B':
            stacks[key].append((e.get('name', '?'), ts))
        elif ph == 'E' and stacks[key]:
            name, start = stacks[key].pop()
            phases.append((len(stacks[key]), name, start, ts - start))
        elif ph == 'X':
            dur = e.get('dur', 0)
            name = e.get('name', '?')
            args = e.get('args') or {}
            if isinstance(args, dict):
                outs = args.get('outputs') or args.get('output')
                if isinstance(outs, list) and outs:
                    name = outs[0]
                elif isinstance(outs, str):
                    name = outs
            edges.append((ts / 1e6, dur / 1e6, str(name)))
    if not phases and not edges:
        print('  %s: no events' % path)
        return
    starts = [p[2] for p in phases] + [s * 1e6 for s, d, o in edges]
    ends = [p[2] + p[3] for p in phases] + [(s + d) * 1e6 for s, d, o in edges]
    t0, t1 = min(starts), max(ends)
    start_txt = when(t0 / 1e6) if t0 > 1e15 else '?'
    tops = [p for p in phases if p[0] == 0]
    prods = collections.Counter(m.group(1) for s, d, o in edges for m in [re.match(r'out/target/product/([^/]+)/', o)] if m)
    line = '  %s: started %s, %s in all, product %s' % (os.path.basename(path), start_txt, hms((t1 - t0) / 1e6),
                                                      prods.most_common(1)[0][0] if prods else '?')
    line += ' | ' + ', '.join('%s %s' % (n, hms(d / 1e6)) for dep, n, s, d in sorted(tops, key=lambda p: p[2]) if d >= 1e6)
    print(line[:400])
    if not newest and (t1 - t0) / 1e6 < LONG:
        return
    print('    phases (5 s or more):')
    for dep, n, s, d in sorted(phases, key=lambda p: p[2]):
        if dep <= 2 and d >= 5e6:
            print('      %s%-30s %s  at +%s' % ('  ' * dep, n[:30], hms(d / 1e6), hms((s - t0) / 1e6)))
    edges_profile(edges)


def ninja_log(path, detailed_builds=4, min_edges=20):
    """ninja's log, cut into builds where the end times start over."""
    builds, cur, prev = [], [], None
    try:
        f = open(path, errors='replace')
    except OSError:
        return
    with f:
        for line in f:
            if line.startswith('#'):
                continue
            p = line.rstrip('\n').split('\t')
            if len(p) < 4:
                continue
            try:
                s, e, mt = int(p[0]), int(p[1]), int(p[2])
            except ValueError:
                continue
            if prev is not None and e < prev[1]:
                builds.append(cur)
                cur = []
            # One line per output: keep one per step
            if not (cur and cur[-1][0] == s and cur[-1][1] == e):
                cur.append((s, e, mt, p[3]))
            prev = (s, e)
    if cur:
        builds.append(cur)
    real = [b for b in builds if len(b) >= min_edges]
    st = os.stat(path)
    print('  %s: %d builds recorded (%d with %d+ steps), last written %s, %.0f MiB'
          % (path, len(builds), len(real), min_edges, when(st.st_mtime), st.st_size / 2**20))

    def date_of(b):
        mts = sorted(m for s, e, m, o in b if m > 0)
        if not mts:
            return '?'
        m = mts[len(mts) // 2]
        m = m / 1e9 if m > 1e14 else m
        return when(m)

    for i, b in enumerate(real[-12:]):
        wall = (max(e for s, e, m, o in b) - min(s for s, e, m, o in b)) / 1000
        cpu = sum(e - s for s, e, m, o in b) / 1000
        print('    build ~%s: %6d steps, wall %s, step time %s' % (date_of(b), len(b), hms(wall), hms(cpu)))
    for b in real[-detailed_builds:] if detailed_builds else []:
        print('    -- build ~%s' % date_of(b))
        edges_profile([(s / 1000, (e - s) / 1000, o) for s, e, m, o in b])


def bootstrap_log(path):
    """out/soong/.ninja_log: soong_build's runs (the analysis) and the other bootstrap steps."""
    rows = []
    try:
        f = open(path, errors='replace')
    except OSError:
        return
    with f:
        for line in f:
            if line.startswith('#'):
                continue
            p = line.rstrip('\n').split('\t')
            if len(p) < 4:
                continue
            try:
                s, e, mt = int(p[0]), int(p[1]), int(p[2])
            except ValueError:
                continue
            if e - s >= 10000:
                m = mt / 1e9 if mt > 1e14 else mt
                rows.append((m, (e - s) / 1000, p[3]))
    print('  %s: steps of 10 s or more, newest last' % path)
    for m, d, o in sorted(rows)[-25:]:
        print('    %s  %s  %s' % (when(m) if m > 0 else '?', hms(d), o[:150]))


def main():
    for top in sys.argv[1:]:
        out = os.path.join(top, 'out')
        if not os.path.isdir(out):
            continue
        print('==== %s' % top)
        products = []
        for n in os.listdir(os.path.join(out, 'soong')) if os.path.isdir(os.path.join(out, 'soong')) else []:
            m = re.match(r'build\.(.+)\.ninja$', n)
            if m:
                st = os.stat(os.path.join(out, 'soong', n))
                products.append((st.st_mtime, m.group(1), st.st_size))
        if products:
            print('  Soong analyses kept (product, last run): '
                  + ', '.join('%s %s' % (p, when(t)) for t, p, sz in sorted(products, reverse=True)))
        traces = []
        for n in os.listdir(out):
            if n.startswith('build.trace'):
                fp = os.path.join(out, n)
                traces.append((os.stat(fp).st_mtime, fp))
        traces.sort(reverse=True)
        if traces:
            print('  soong_ui build traces, newest first:')
        for i, (mt, fp) in enumerate(traces[:MAX_TRACES]):
            trace_summary(fp, i < DETAILED)
        bootstrap_log(os.path.join(out, 'soong', '.ninja_log'))
        ninja_log(os.path.join(out, '.ninja_log'), detailed_builds=0 if traces else 3)
        sys.stdout.flush()


if __name__ == '__main__':
    main()
