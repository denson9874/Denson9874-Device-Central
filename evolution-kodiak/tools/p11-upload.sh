#!/bin/bash
# Upload a staged release to SourceForge, denson9874-s-user-builds/<dev>/17, in the order given:
# the files a pack script's --stage listed on its STAGED line. p11-routine.sh runs it after it
# releases the tree lock, so the next device builds meanwhile.
#
#   p11-upload.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> <file>...
#
# A file with a <file>.sha256 next to it must still match it. -b: any failed put fails the
# upload. Each zip that got there is marked <zip>.uploaded: p11-ota.sh doesn't upload a file
# marked so again (husky's release zip is its OTA package).
# The last line is UPLOAD_DONE <folder url>.
set -euo pipefail

dev=${1:-}; [ $# -gt 0 ] && shift
case $dev in
    kodiak|grizzly|cubs|yogi|cheetah|husky) ;;
    *) echo "usage: p11-upload.sh <kodiak|grizzly|cubs|yogi|cheetah|husky> <file>..." >&2; exit 2 ;;
esac
fail() { echo "FAIL: $*"; exit 1; }
[ $# -gt 0 ] || fail "no files to upload"
SF_USER=daryldenson0405; P=/home/frs/project/denson9874-s-user-builds; SF_DIR=$P/$dev/17
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

for f in "$@"; do
    [ -f "$f" ] || fail "no $f"
    n=$(basename "$f")
    [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "unexpected file name: $n"
    if [ -f "$f.sha256" ]; then
        (cd "$(dirname "$f")" && sha256sum -c --status "$n.sha256") || fail "$f doesn't match its .sha256 any more"
    fi
done

echo "== upload to SourceForge: $SF_DIR ($# files)"
{
    printf -- '-mkdir %s/%s\n-mkdir %s\n' "$P" "$dev" "$SF_DIR"
    for f in "$@"; do printf 'put %s %s/%s\n' "$f" "$SF_DIR" "$(basename "$f")"; done
    printf 'ls -l %s\nbye\n' "$SF_DIR"
} | sftp -b - -o BatchMode=yes -i ~/.ssh/sourceforge_ed25519 $SF_USER@frs.sourceforge.net > "$T/sftp.log" 2>&1 \
    || { tail -5 "$T/sftp.log"; fail "SourceForge upload failed"; }
grep -E "^-" "$T/sftp.log" | tail -"$#" || true
for f in "$@"; do
    if [[ $f == *.zip ]]; then touch "$f.uploaded"; fi
done
echo "UPLOAD_DONE https://sourceforge.net/projects/denson9874-s-user-builds/files/$dev/17/"
