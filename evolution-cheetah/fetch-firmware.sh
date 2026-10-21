#!/usr/bin/env bash
# Download the newest Pixel 7 Pro (cheetah) factory image from Google, verify its
# SHA-256 against Google's page, and keep only its bootloader and radio images
# for update-firmware.sh. Run it when Google ships a new monthly release.
#
#   fetch-firmware.sh [--check]     # --check: print the newest release, download nothing
#
# Result in ~/android-dt/firmware/cheetah/: bootloader-cheetah-*.img,
# radio-cheetah-*.img and CURRENT (the build id, e.g. cp3a.261005.005).
set -euo pipefail
dev=cheetah
dir=~/android-dt/firmware/$dev; mkdir -p "$dir"
here="$(cd "$(dirname "$0")" && pwd)"
conf="$here/firmware.conf"
# Newest generic (not carrier-specific) Android 17 release. Rows look like
#   <tr id="cheetahcp3a.261005.005"><td>17.0.0 (CP3A.261005.005, Oct 2026)</td>
#   <td><a href="https://dl.google.com/.../cheetah-cp3a.261005.005-factory-1a2b3c4d.zip">Link</a></td><td>sha256</td>
# The build id comes from the URL (it may carry a suffix such as .a1, as cheetah's
# generic CP3A.261005.002.A1 does); carrier builds have a third field in the
# description ("..., Oct 2026, Verizon"). The device tables may sit on
# the main page or on a per-device page it links to; both are tried.
if [[ -f "$conf" ]]; then
    # Copied by a person from https://developers.google.com/android/images#cheetah after
    # accepting Google's terms there: the newest generic Android 17 release's link and SHA-256.
    url=$(sed -n 's/^url=//p' "$conf" | head -1); sha=$(sed -n 's/^sha256=//p' "$conf" | head -1)
    build=$(sed -E -n "s#^https://dl\.google\.com/dl/android/aosp/$dev-([a-z0-9]{4}\.[0-9]{6}\.[0-9]{3}(\.[a-z0-9]+)?)-factory-[0-9a-f]{8}\.zip\$#\1#p" <<<"$url")
    [[ -n "$build" && "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "firmware.conf needs url=<generic $dev factory zip link> and sha256=<64 hex>" >&2; exit 1; }
else
read -r url sha build < <(python3 -I - "$dev" <<'PY'
import html as H, re, sys, urllib.parse, urllib.request
dev = sys.argv[1]
MAIN = "https://developers.google.com/android/images"
def get(u):
    req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.geturl(), r.read().decode("utf-8", "replace")
def parse(page):
    best, rows = None, re.findall(r'<tr[^>]*id="%s[^"]*"[^>]*>(.*?)</tr>' % re.escape(dev), page, re.S | re.I)
    for row in rows:
        url = re.search(r'href="(https://dl\.google\.com/dl/android/aosp/%s-([a-z0-9.]+)-factory-[0-9a-f]{8}\.zip)"' % re.escape(dev), row)
        sha = re.search(r"\b[0-9a-f]{64}\b", row)
        desc = " ".join(H.unescape(re.sub(r"<[^>]+>", " ", row.split("</td>")[0])).split())
        if not (url and sha) or not re.fullmatch(r"[a-z0-9]{4}\.\d{6}\.\d{3}(\.[a-z0-9]+)?", url.group(2)):
            continue
        paren = re.search(r"\(([^)]*)\)", desc)
        if not re.match(r"17(\.\d+)*\b", desc) or not paren or len(paren.group(1).split(",")) != 2:
            continue
        best = (url.group(1), sha.group(0), url.group(2))   # oldest first
    return best, rows
tried = []
final, page = get(MAIN); tried.append((final, page))
best, rows = parse(page)
links = sorted({urllib.parse.urljoin(final, h) for h in re.findall(r'href="([^"#]+)"', page) if "/android/images" in h})
if not best:
    for link in [l for l in links if re.search(r"%s|pixel-?7-?pro|pantah" % dev, l, re.I)][:4]:
        u, p = get(link); tried.append((u, p))
        best, rows = parse(p)
        if best:
            break
if best:
    print(*best)
    sys.exit(0)
print("no generic Android 17 %s factory image found" % dev, file=sys.stderr)
for u, p in tried:
    t = re.search(r"<title>(.*?)</title>", p, re.S | re.I)
    print("  %s: %d bytes, title %r, %d mentions of %s" % (u, len(p), H.unescape(t.group(1)).strip()[:60] if t else "-", p.count(dev), dev), file=sys.stderr)
print("  /android/images links on the main page (%d): %s" % (len(links), " ".join(links[:40])), file=sys.stderr)
last = tried[-1][1]; i = last.find(dev)
if i >= 0:
    print("  first mention: " + " ".join(last[max(0, i - 300):i + 500].split()), file=sys.stderr)
sys.exit(1)
PY
)
fi
[[ -n "${url:-}" && -n "${sha:-}" && -n "${build:-}" ]] || { echo "couldn't find the newest $dev factory image on Google's page" >&2; exit 1; }
echo "newest $dev factory image: $build ($url)"
[[ ${1:-} == --check ]] && { echo "cached: $(cat "$dir/CURRENT" 2>/dev/null || echo none)"; exit 0; }
if [[ "$(cat "$dir/CURRENT" 2>/dev/null)" == "$build" ]] && ls "$dir"/bootloader-$dev-*.img "$dir"/radio-$dev-*.img >/dev/null 2>&1; then
    echo "already cached: $build"; exit 0
fi
zip="$dir/$(basename "$url")"
curl -sSfL --retry 5 -C - -o "$zip" "$url"
echo "$sha  $zip" | sha256sum -c --quiet || { rm -f "$zip"; echo "SHA-256 mismatch for $zip" >&2; exit 1; }
work=$(mktemp -d -p "$dir"); trap 'rm -rf "$work"' EXIT
unzip -q -j -o "$zip" "*/bootloader-$dev-*.img" "*/radio-$dev-*.img" -d "$work"
ls "$work"/bootloader-$dev-*.img "$work"/radio-$dev-*.img >/dev/null
rm -f "$dir"/bootloader-$dev-*.img "$dir"/radio-$dev-*.img
mv "$work"/*.img "$dir/"
echo "$build" > "$dir/CURRENT"
rm -f "$zip"   # the two images are all a build needs
echo "FIRMWARE_OK $build: $(cd "$dir" && ls bootloader-$dev-*.img radio-$dev-*.img | paste -sd' ')"
