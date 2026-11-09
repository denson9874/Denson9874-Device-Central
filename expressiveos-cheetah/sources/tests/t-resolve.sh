# Resolve frameworks/base's conflict the way it's done for real: a clone of the fork at its
# commit, git merge --no-commit of LineageOS's, the file fixed, update.py resolution
set -euo pipefail
source "$1/env.sh"
F=$(git --git-dir=$T/gh/ExpressiveOS/frameworks_base.git rev-parse expressiveos)
L=$(git --git-dir=$T/gh/LineageOS/android_frameworks_base.git rev-parse lineage-24.0)
R=$T/w/resolve-fb
rm -rf "$R"
git clone -q "$G/ExpressiveOS/frameworks_base" "$R"
git -C "$R" checkout -q "$F"
git -C "$R" fetch -q "$G/LineageOS/android_frameworks_base" lineage-24.0
git -C "$R" merge --no-commit -q FETCH_HEAD || true
printf 'class Power {\n  int a = 1;\n  int b = 200; // LineageOS, ExpressiveOS took it\n  int c = 3;\n}\n' > "$R/core/Power.java"
${2:-true}   # a hook: more changes
git -C "$R" add -A
mkdir -p "$kit/sources/updates/2026-11/resolutions/frameworks"
python3 -I "$kit/sources/update.py" resolution "$R" > "$kit/sources/updates/2026-11/resolutions/frameworks/base.patch"
cat "$kit/sources/updates/2026-11/resolutions/frameworks/base.patch"
