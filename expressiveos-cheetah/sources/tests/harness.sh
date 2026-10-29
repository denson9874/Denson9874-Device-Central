#!/usr/bin/env bash
# Test world for update.py plan/push: file:// repos standing in for LineageOS, AOSP and
# ExpressiveOS on GitHub, a tree, and a copy of the kit pointed at them.
#   harness.sh <kit dir> <world dir>     builds the world (fresh)
#   EOS_TEST_AOSP_FORK=1                 build/make is ExpressiveOS's fork of AOSP's platform/build
#                                        (on a tag), not AOSP's own
set -euo pipefail
KIT_SRC=$(cd "$1" && pwd)
T=$2
rm -rf "$T"
mkdir -p "$T"/{gh/LineageOS,gh/ExpressiveOS,aosp/platform,home,w}
T=$(cd "$T" && pwd)
export HOME=$T/home GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main
git config --global advance.detachedHead false 2>/dev/null || true
G=file://$T/gh

mkrepo() {   # mkrepo <bare path> <branch> <file=content>...: a repo with one commit
    local bare=$1 br=$2 w
    shift 2
    git init -q --bare "$bare"
    w=$(mktemp -d "$T/w/r.XXXX")
    git -C "$w" init -q -b "$br"
    for fc in "$@"; do mkdir -p "$w/$(dirname "${fc%%=*}")"; printf '%s\n' "${fc#*=}" > "$w/${fc%%=*}"; done
    git -C "$w" add -A && git -C "$w" commit -qm "initial $(basename "$bare")"
    git -C "$w" push -q "$bare" "$br"
    rm -rf "$w"
}
commit() {   # commit <bare> <branch> <msg> <file=content>...: one more commit on branch; prints it
    local bare=$1 br=$2 msg=$3 w
    shift 3
    w=$(mktemp -d "$T/w/c.XXXX")
    git clone -q -b "$br" "$bare" "$w"
    for fc in "$@"; do mkdir -p "$w/$(dirname "${fc%%=*}")"; printf '%s\n' "${fc#*=}" > "$w/${fc%%=*}"; done
    git -C "$w" add -A && git -C "$w" commit -qm "$msg"
    git -C "$w" push -q origin "$br"
    git -C "$w" rev-parse HEAD
    rm -rf "$w"
}
tip() { git --git-dir="$1" rev-parse "refs/heads/$2"; }

LB=lineage-24.0
# LineageOS's repos
mkrepo "$T/gh/LineageOS/android_frameworks_base.git" $LB "core/Power.java=$(printf 'class Power {\n  int a = 1;\n  int b = 2;\n  int c = 3;\n}')" "README=fb"
mkrepo "$T/gh/LineageOS/android_vendor_lineage.git" $LB "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto=value: \"2026-10-01\"" "config/x.mk=x"
mkrepo "$T/gh/LineageOS/android_packages_apps_Settings.git" $LB "S.java=settings"
mkrepo "$T/gh/LineageOS/android_development.git" $LB "dev.txt=dev"
mkrepo "$T/gh/LineageOS/android_external_foo.git" $LB "foo.c=foo"
mkrepo "$T/gh/LineageOS/android_external_new.git" $LB "new.c=new"
mkrepo "$T/gh/LineageOS/android_hardware_old.git" $LB "old.c=old"
mkrepo "$T/gh/LineageOS/android_prebuilts_x.git" $LB "x.bin=x"
mkrepo "$T/aosp/platform/build.git" main "core/main.mk=r1"
git --git-dir="$T/aosp/platform/build.git" tag -a -m r1 android-17.0.0_r1 main
commit "$T/aosp/platform/build.git" main "r2" "core/main.mk=r2" >/dev/null
git --git-dir="$T/aosp/platform/build.git" tag -a -m r2 android-17.0.0_r2 main
R1=$(git --git-dir="$T/aosp/platform/build.git" rev-parse 'android-17.0.0_r1^{commit}')
if [[ ${EOS_TEST_AOSP_FORK:-} = 1 ]]; then
    git clone -q --bare "$T/aosp/platform/build.git" "$T/gh/ExpressiveOS/platform_build.git"
    git --git-dir="$T/gh/ExpressiveOS/platform_build.git" branch -q -f expressiveos "$R1"
    commit "$T/gh/ExpressiveOS/platform_build.git" expressiveos "build: ExpressiveOS" "core/main.mk=eos" >/dev/null
fi

# ExpressiveOS's forks: LineageOS's commit plus ExpressiveOS's own commits, on expressiveos
fork() {   # fork <LineageOS repo> <fork name>
    git clone -q --bare "$T/gh/LineageOS/$1.git" "$T/gh/ExpressiveOS/$2.git"
    git --git-dir="$T/gh/ExpressiveOS/$2.git" branch -q expressiveos "refs/heads/$LB"
}
fork android_frameworks_base frameworks_base
commit "$T/gh/ExpressiveOS/frameworks_base.git" expressiveos "Power: ExpressiveOS's b" \
    "core/Power.java=$(printf 'class Power {\n  int a = 1;\n  int b = 20; // ExpressiveOS\n  int c = 3;\n}')" >/dev/null
fork android_vendor_lineage vendor_lineage
commit "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos "vendor: ExpressiveOS's branding" "config/eos.mk=eos" >/dev/null
fork android_packages_apps_Settings packages_apps_Settings
mkrepo "$T/gh/ExpressiveOS/packages_apps_Evolver.git" expressiveos "E.kt=evolver"

# Kernel: LineageOS's kernel manifest with two projects
mkrepo "$T/gh/LineageOS/android_kernel_google_gs-6.1.git" $LB "Makefile=k1"
mkrepo "$T/gh/LineageOS/android_kernel_google_gs-6.1_devices.git" $LB "dev=d1"
mkrepo "$T/gh/LineageOS/android_kernel_google_gs-6.1_manifest.git" $LB "default.xml=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="github" fetch=".." />
  <default remote="github" revision="refs/heads/$LB" />
  <project name="LineageOS/android_kernel_google_gs-6.1" path="aosp" />
  <project name="LineageOS/android_kernel_google_gs-6.1_devices" path="private/devices" />
</manifest>
EOF
)"
K1=$(tip "$T/gh/LineageOS/android_kernel_google_gs-6.1.git" $LB)
K2=$(tip "$T/gh/LineageOS/android_kernel_google_gs-6.1_devices.git" $LB)

# LineageOS's manifest at the base (C0)
los_manifest() {   # los_manifest <aosp tag> <groups of external/foo> <with new> <with old>
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="aosp" fetch="file://$T/aosp" revision="refs/tags/$1" />
  <remote name="github" fetch=".." review="review.lineageos.org" />
  <default remote="github" revision="refs/heads/$LB" sync-c="true" />
  <include name="snippets/lineage.xml" />
  <project name="platform/build" path="build/make" remote="aosp" groups="pdk" />
</manifest>
EOF
}
los_snippet() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="LineageOS/android_frameworks_base" path="frameworks/base" groups="pdk" />
  <project name="LineageOS/android_vendor_lineage" path="vendor/lineage" />
  <project name="LineageOS/android_packages_apps_Settings" path="packages/apps/Settings" />
  <project name="LineageOS/android_development" path="development" groups="developers" />
  <project name="LineageOS/android_external_foo" path="external/foo" groups="$1" />
  <project name="LineageOS/android_prebuilts_x" path="prebuilts/x" clone-depth="1" />
$( [[ $2 = yes ]] && echo '  <project name="LineageOS/android_external_new" path="external/new" groups="pdk" />' )
$( [[ $3 = yes ]] && echo '  <project name="LineageOS/android_hardware_old" path="hardware/old" />' )
</manifest>
EOF
}
mkrepo "$T/gh/LineageOS/android.git" $LB "default.xml=$(los_manifest android-17.0.0_r1)" "snippets/lineage.xml=$(los_snippet pdk no yes)"
C0=$(tip "$T/gh/LineageOS/android.git" $LB)

# ExpressiveOS's manifest, in own-manifest.py's layout, every project at a commit
pin() { tip "$1" "$2"; }
EVO_OLD=$(git --git-dir="$T/gh/LineageOS/android.git" rev-parse $LB)
mkrepo "$T/gh/ExpressiveOS/manifest.git" expressiveos "README=old evo manifest"
EVO_MAN=$(tip "$T/gh/ExpressiveOS/manifest.git" expressiveos)
build_make() {   # ExpressiveOS's manifest's build/make line: AOSP's own, or ExpressiveOS's fork of it
    if [[ ${EOS_TEST_AOSP_FORK:-} = 1 ]]; then
        echo "  <project name=\"platform_build\" path=\"build/make\" remote=\"expressiveos\" revision=\"$(pin "$T/gh/ExpressiveOS/platform_build.git" expressiveos)\" upstream=\"refs/heads/expressiveos\" dest-branch=\"refs/heads/expressiveos\" groups=\"pdk\">"
    else
        echo "  <project name=\"platform/build\" path=\"build/make\" remote=\"aosp\" revision=\"$R1\" upstream=\"refs/tags/android-17.0.0_r1\" dest-branch=\"refs/tags/android-17.0.0_r1\" groups=\"pdk\">"
    fi
}
eos_manifest() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- test manifest -->
<manifest>
  <remote name="aosp" fetch="file://$T/aosp" review="android-review.googlesource.com" revision="refs/tags/android-17.0.0_r1" />
  <remote name="expressiveos" fetch="file://$T/gh/ExpressiveOS" />
  <remote name="github" fetch=".." review="review.lineageos.org" />
  <remote name="lineageos" fetch="file://$T/gh/LineageOS" />

  <default remote="github" revision="refs/heads/$LB" sync-j="4" sync-c="true" />

  <project name="LineageOS/android_development" path="development" revision="$(pin "$T/gh/LineageOS/android_development.git" $LB)" upstream="refs/heads/$LB" dest-branch="refs/heads/$LB" groups="developers" />
$(build_make)
    <copyfile src="core/root.mk" dest="Makefile" />
  </project>
  <project name="LineageOS/android_external_foo" path="external/foo" revision="$(pin "$T/gh/LineageOS/android_external_foo.git" $LB)" upstream="refs/heads/$LB" dest-branch="refs/heads/$LB" groups="pdk" />
  <project name="LineageOS/android_hardware_old" path="hardware/old" revision="$(pin "$T/gh/LineageOS/android_hardware_old.git" $LB)" upstream="refs/heads/$LB" dest-branch="refs/heads/$LB" />
  <project name="LineageOS/android_prebuilts_x" path="prebuilts/x" revision="$(pin "$T/gh/LineageOS/android_prebuilts_x.git" $LB)" upstream="refs/heads/$LB" dest-branch="refs/heads/$LB" clone-depth="1" />
  <project name="frameworks_base" path="frameworks/base" remote="expressiveos" revision="$(pin "$T/gh/ExpressiveOS/frameworks_base.git" expressiveos)" upstream="refs/heads/expressiveos" dest-branch="refs/heads/expressiveos" groups="pdk" />
  <project name="vendor_lineage" path="vendor/lineage" remote="expressiveos" revision="$(pin "$T/gh/ExpressiveOS/vendor_lineage.git" expressiveos)" upstream="refs/heads/expressiveos" dest-branch="refs/heads/expressiveos" />
  <project name="packages_apps_Settings" path="packages/apps/Settings" remote="expressiveos" revision="$(pin "$T/gh/ExpressiveOS/packages_apps_Settings.git" expressiveos)" upstream="refs/heads/expressiveos" dest-branch="refs/heads/expressiveos" />
  <project name="packages_apps_Evolver" path="packages/apps/Evolver" remote="expressiveos" revision="$(pin "$T/gh/ExpressiveOS/packages_apps_Evolver.git" expressiveos)" upstream="refs/heads/expressiveos" dest-branch="refs/heads/expressiveos" />
  <project name="manifest" path="evolution/manifest" remote="expressiveos" revision="$EVO_MAN" upstream="refs/heads/expressiveos" dest-branch="refs/heads/expressiveos" />
</manifest>
EOF
}
W=$(mktemp -d "$T/w/m.XXXX")
git clone -q -b expressiveos "$T/gh/ExpressiveOS/manifest.git" "$W"
eos_manifest > "$W/default.xml"
git -C "$W" add -A && git -C "$W" commit -qm "ExpressiveOS's own manifest" && git -C "$W" push -q origin expressiveos
rm -rf "$W"

# The tree: .repo with the manifest checkout and each project's objects
top=$T/tree
mkdir -p "$top/.repo/projects" "$top/build"
touch "$top/build/envsetup.sh"
git clone -q -b expressiveos "$T/gh/ExpressiveOS/manifest.git" "$top/.repo/manifests"
git -C "$top/.repo/manifests" checkout -q -b default --track origin/expressiveos 2>/dev/null || git -C "$top/.repo/manifests" branch -q -f default origin/expressiveos
git -C "$top/.repo/manifests" checkout -q default
git -C "$top/.repo/manifests" config branch.default.merge refs/heads/expressiveos
git -C "$top/.repo/manifests" config branch.default.remote origin
git -C "$top/.repo/manifests" remote set-url origin "$G/ExpressiveOS/manifest.git"
git -C "$top/.repo/manifests" fetch -q origin
printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n  <include name="default.xml" />\n</manifest>\n' > "$top/.repo/manifest.xml"
python3 - "$top/.repo/manifests/default.xml" <<'EOF' | while read -r path url; do git clone -q --bare "$url" "$top/.repo/projects/$path.git"; done
import sys, urllib.parse, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
rem = {e.get("name"): e.get("fetch") for e in r.iter("remote")}
d = r.find("default")
base = "file://" + sys.argv[1].rsplit("/tree/", 1)[0] + "/gh/ExpressiveOS/manifest"
for p in r.iter("project"):
    f = urllib.parse.urljoin(base, rem[p.get("remote") or d.get("remote")]).rstrip("/")
    print(p.get("path") or p.get("name"), f + "/" + p.get("name"))
EOF

# The kit, pointed at this world
kit=$T/kit
cp -a "$KIT_SRC" "$kit"
rm -rf "$kit/sources/updates" "$kit/sources/__pycache__"
sed -i "s#^EOS_MANIFEST_URL=.*#EOS_MANIFEST_URL=$G/ExpressiveOS/manifest#; s#^EOS_KERNEL_MANIFEST_URL=.*#EOS_KERNEL_MANIFEST_URL=$G/LineageOS/android_kernel_google_gs-6.1_manifest#" "$kit/eos.conf"
sed -i "s#^LINEAGE_MANIFEST = .*#LINEAGE_MANIFEST = \"$G/LineageOS/android\"#; s#^LINEAGE_BASE = .*#LINEAGE_BASE = \"$C0\"#" "$kit/sources/update.py"
cat > "$kit/pins/kernel.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- test kernel pins -->
<manifest>
  <remote name="github" fetch=".." />
  <default remote="github" revision="refs/heads/$LB" />
  <project name="LineageOS/android_kernel_google_gs-6.1" path="aosp" revision="$K1" upstream="refs/heads/$LB" />
  <project name="LineageOS/android_kernel_google_gs-6.1_devices" path="private/devices" revision="$K2" upstream="refs/heads/$LB" />
</manifest>
EOF

# What LineageOS does after the base: commits, then its manifest's C1
commit "$T/gh/LineageOS/android_frameworks_base.git" $LB "Power: LineageOS's b" \
    "core/Power.java=$(printf 'class Power {\n  int a = 1;\n  int b = 200; // LineageOS\n  int c = 3;\n}')" >/dev/null
commit "$T/gh/LineageOS/android_frameworks_base.git" $LB "README: more" "README=fb2" >/dev/null
commit "$T/gh/LineageOS/android_vendor_lineage.git" $LB "release: Bump Security String to 2026-11-01" \
    "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto=value: \"2026-11-01\"" >/dev/null
commit "$T/gh/LineageOS/android_development.git" $LB "dev 2" "dev.txt=dev2" >/dev/null
commit "$T/gh/LineageOS/android_development.git" $LB "dev 3" "dev.txt=dev3" >/dev/null
commit "$T/gh/LineageOS/android_prebuilts_x.git" $LB "x 2" "x.bin=x2" >/dev/null
commit "$T/gh/LineageOS/android_kernel_google_gs-6.1.git" $LB "kernel: ACK merge" "Makefile=k2" >/dev/null
W=$(mktemp -d "$T/w/l.XXXX")
git clone -q -b $LB "$T/gh/LineageOS/android.git" "$W"
los_manifest android-17.0.0_r2 > "$W/default.xml"
los_snippet "pdk,pdk-fs" yes no > "$W/snippets/lineage.xml"
git -C "$W" add -A && git -C "$W" commit -qm "manifest: r2, external/new, drop hardware/old" && git -C "$W" push -q origin $LB
rm -rf "$W"
C1=$(tip "$T/gh/LineageOS/android.git" $LB)
mkdir -p "$kit/sources/updates/2026-11"
echo "LINEAGE_MANIFEST=$C1" > "$kit/sources/updates/2026-11/update.conf"
cat > "$T/env.sh" <<EOF
export HOME=$T/home GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$T
kit=$T/kit
top=$T/tree
G=$G
C0=$C0
C1=$C1
EOF
echo "world ready: $T (C0 ${C0:0:12}, C1 ${C1:0:12})"
