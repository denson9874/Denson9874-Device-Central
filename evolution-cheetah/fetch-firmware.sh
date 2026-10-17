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
page=$(mktemp); trap 'rm -f "$page"' EXIT
final=$(curl -sSfL --retry 3 -o "$page" -w '%{url_effective}' https://developers.google.com/android/images)
# Newest generic (not carrier-specific) Android 17 release. Rows look like
#   <tr id="cheetahcp3a.261005.005"><td>17.0.0 (CP3A.261005.005, Oct 2026)</td>
#   <td><a href="https://dl.google.com/.../cheetah-cp3a.261005.005-factory-1a2b3c4d.zip">Link</a></td><td>sha256</td>
# The build id comes from the URL; carrier builds have a suffix (.a1) or a third
# field in the description ("..., Oct 2026, Verizon").
read -r url sha build < <(python3 -I - "$page" "$dev" "$final" <<'PY'
import html as H, re, sys
page, dev, final = open(sys.argv[1], encoding="utf-8", errors="replace").read(), sys.argv[2], sys.argv[3]
best = None
rows = re.findall(r'<tr[^>]*id="%s[^"]*"[^>]*>(.*?)</tr>' % re.escape(dev), page, re.S | re.I)
for row in rows:
    url = re.search(r'href="(https://dl\.google\.com/dl/android/aosp/%s-([a-z0-9.]+)-factory-[0-9a-f]{8}\.zip)"' % re.escape(dev), row)
    sha = re.search(r"\b[0-9a-f]{64}\b", row)
    desc = " ".join(H.unescape(re.sub(r"<[^>]+>", " ", row.split("</td>")[0])).split())
    if not (url and sha) or not re.fullmatch(r"[a-z0-9]{4}\.\d{6}\.\d{3}", url.group(2)):
        continue
    paren = re.search(r"\(([^)]*)\)", desc)
    if not re.match(r"17(\.\d+)*\b", desc) or not paren or len(paren.group(1).split(",")) != 2:
        continue
    best = (url.group(1), sha.group(0), url.group(2))   # the page lists oldest first
if best:
    print(*best)
    sys.exit(0)
# Say what the page was, so a layout change or a consent redirect is easy to see
title = re.search(r"<title>(.*?)</title>", page, re.S | re.I)
print("no generic Android 17 %s factory image found" % dev, file=sys.stderr)
print("  fetched %s (%d bytes), title: %s" % (final, len(page), title.group(1).strip()[:80] if title else "-"), file=sys.stderr)
print("  %d rows with id=%s*, %d mentions of %s-" % (len(rows), dev, page.count(dev + "-"), dev), file=sys.stderr)
for row in rows[-2:]:
    print("  last rows: " + " ".join(row.split())[:400], file=sys.stderr)
if not rows:
    i = page.find(dev)
    print("  first mention: " + (" ".join(page[max(0, i - 200):i + 300].split()) if i >= 0 else "none"), file=sys.stderr)
sys.exit(1)
PY
)
[[ -n "${url:-}" && -n "${sha:-}" && -n "${build:-}" ]] || { echo "couldn't find the newest $dev factory image on Google's page" >&2; exit 1; }
echo "newest $dev factory image: $build ($url)"
[[ ${1:-} == --check ]] && { echo "cached: $(cat "$dir/CURRENT" 2>/dev/null || echo none)"; exit 0; }
if [[ "$(cat "$dir/CURRENT" 2>/dev/null)" == "$build" ]] && ls "$dir"/bootloader-$dev-*.img "$dir"/radio-$dev-*.img >/dev/null 2>&1; then
    echo "already cached: $build"; exit 0
fi
zip="$dir/$(basename "$url")"
curl -sSfL --retry 5 -C - -o "$zip" "$url"
echo "$sha  $zip" | sha256sum -c --quiet || { rm -f "$zip"; echo "SHA-256 mismatch for $zip" >&2; exit 1; }
work=$(mktemp -d -p "$dir"); trap 'rm -rf "$work" "$page"' EXIT
unzip -q -j -o "$zip" "*/bootloader-$dev-*.img" "*/radio-$dev-*.img" -d "$work"
ls "$work"/bootloader-$dev-*.img "$work"/radio-$dev-*.img >/dev/null
rm -f "$dir"/bootloader-$dev-*.img "$dir"/radio-$dev-*.img
mv "$work"/*.img "$dir/"
echo "$build" > "$dir/CURRENT"
rm -f "$zip"   # the two images are all a build needs
echo "FIRMWARE_OK $build: $(cd "$dir" && ls bootloader-$dev-*.img radio-$dev-*.img | paste -sd' ')"
