# Shared by the ExpressiveOS scripts (sourced, never run): sets kit, reads eos.conf and
# the phone's devices/<device>.conf (EOS_DEVICE, cheetah unless set), and holds the guards
# they all use. The Evolution X tree (~/evolution) and the DerpFest tree (~/derpfest) are
# never touched, nothing is written through a symlink that leads out of the ExpressiveOS
# tree, and a git project is checked before git am runs in it.
# shellcheck shell=bash

kit="$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=eos.conf
source "$kit/eos.conf" || fail "can't read $kit/eos.conf"

# The phone a run builds (Daryl, 2026-10-29: cheetah, husky, kodiak, grizzly, cubs, yogi):
# EOS_DEVICE, cheetah unless set. devices/<device>.conf holds what differs between phones,
# cheetah's restating eos.conf's, so cheetah builds exactly as before. A device file is read,
# never run: NAME=value lines, only the names below, and values without quotes, $, `, \ or ;.
# Nothing in it can move the keys, the feed or the manifest, which stay eos.conf's.
EOS_DEVICE_KEYS=" EOS_LUNCH EOS_MODEL EOS_BOARD EOS_RELEASES EOS_SF_DIR EOS_R2_PREFIX EOS_DEVICE_TREE \
EOS_BOARDCONFIG EOS_VENDOR_DIR EOS_RADIO_MK EOS_FIRMWARE EOS_FIRMWARE_MODE EOS_LFS_PROJECTS EOS_UPDATER_OVERLAY \
EOS_SENTINEL EOS_KERNEL EOS_KMI EOS_KSU EOS_V4A EOS_SUPER_EMPTY EOS_FLASH_VKB EOS_SCONE_PATCH EOS_SYSUI_ODEX "
device_conf() {   # device_conf <file>: set the device keys it names (EOS_DEVICE_KEYS), checked
    local f=$1 line k v n=0 rel=${1#"$kit"/}
    [[ -f $f && -r $f ]] || fail "can't read $rel"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || fail "$rel:$n isn't NAME=value: $line"
        k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
        [[ $EOS_DEVICE_KEYS == *" $k "* ]] || fail "$rel:$n sets $k, which a device file may not (EOS_DEVICE_KEYS in lib.sh)"
        [[ $v =~ ^[A-Za-z0-9\ _./:@%+,=|-]*$ ]] || fail "$rel:$n: $k's value has a character a device file may not use: $v"
        printf -v "$k" '%s' "$v"
    done < "$f"
}
EOS_DEVICE=${EOS_DEVICE:-cheetah}
[[ $EOS_DEVICE =~ ^[a-z0-9]+$ && -f $kit/devices/$EOS_DEVICE.conf ]] \
    || fail "EOS_DEVICE '$EOS_DEVICE' isn't one of the kit's devices: $(cd "$kit/devices" 2>/dev/null && printf '%s ' *.conf | sed 's/\.conf//g')"
export EOS_DEVICE
# eos.conf's own values of the keys cheetah's file restates, which must agree (sources/update.py
# reads eos.conf's EOS_LUNCH); then none of the device keys from the caller's environment
_eosc="$EOS_LUNCH|$EOS_RELEASES|$EOS_SF_DIR|$EOS_R2_PREFIX"
for _k in $EOS_DEVICE_KEYS; do unset "$_k"; done
device_conf "$kit/devices/$EOS_DEVICE.conf"
[[ $EOS_DEVICE != cheetah || $_eosc = "$EOS_LUNCH|$EOS_RELEASES|$EOS_SF_DIR|$EOS_R2_PREFIX" ]] \
    || fail "eos.conf and devices/cheetah.conf disagree on EOS_LUNCH, EOS_RELEASES, EOS_SF_DIR or EOS_R2_PREFIX: change both"
unset _eosc
for _k in $EOS_DEVICE_KEYS; do
    [[ -n ${!_k:-} || $_k = EOS_SCONE_PATCH ]] || fail "devices/$EOS_DEVICE.conf doesn't set $_k"
done
unset _k
# One phone's names only: its lunch product, board line, release and upload folders are its own
[[ $EOS_LUNCH =~ ^lineage_${EOS_DEVICE}-[a-z0-9]+-(user|userdebug)$ ]] || fail "devices/$EOS_DEVICE.conf: EOS_LUNCH $EOS_LUNCH isn't lineage_$EOS_DEVICE-<release>-<variant>"
[[ $EOS_BOARD = "$EOS_DEVICE" ]] || fail "devices/$EOS_DEVICE.conf: EOS_BOARD is $EOS_BOARD; a zip names its own phone only"
[[ $EOS_RELEASES = "releases/expressiveos-$EOS_DEVICE" ]] || fail "devices/$EOS_DEVICE.conf: EOS_RELEASES isn't releases/expressiveos-$EOS_DEVICE"
[[ $EOS_SF_DIR == /home/frs/project/*/expressiveos/"$EOS_DEVICE" ]] || fail "devices/$EOS_DEVICE.conf: EOS_SF_DIR isn't .../expressiveos/$EOS_DEVICE"
[[ $EOS_R2_PREFIX = "expressiveos/$EOS_DEVICE/" ]] || fail "devices/$EOS_DEVICE.conf: EOS_R2_PREFIX isn't expressiveos/$EOS_DEVICE/"
for _v in "$EOS_DEVICE_TREE" "$EOS_BOARDCONFIG" "$EOS_VENDOR_DIR" "$EOS_RADIO_MK" "$EOS_SENTINEL" $EOS_LFS_PROJECTS ${EOS_SCONE_PATCH:-}; do
    [[ $_v =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*$ && /$_v/ != */../* ]] || fail "devices/$EOS_DEVICE.conf: '$_v' isn't a plain relative path"
done
unset _v
_e() { [[ " $2 " == *" ${!1} "* ]] || fail "devices/$EOS_DEVICE.conf: $1 is '${!1}', not one of: $2"; }
_e EOS_FIRMWARE_MODE "cache blobs images"; _e EOS_KERNEL "gs-6.1 prebuilt"; _e EOS_KSU "lkm none"
_e EOS_V4A "0 1"; _e EOS_SUPER_EMPTY "out factory"; _e EOS_FLASH_VKB "0 1"; _e EOS_SYSUI_ODEX "0 1"
_e EOS_KMI "android14-6.1 android16-6.12"
unset -f _e
# KernelSU Next on Google's prebuilt kernel: kernelsu.ko builds against the DDK for its KMI
if [[ $EOS_KSU = lkm && $EOS_KERNEL = prebuilt ]] && ! grep -q "^${EOS_KMI}_digest=" "$kit/ksu/ddk.conf"; then
    fail "devices/$EOS_DEVICE.conf: KernelSU Next (EOS_KSU=lkm) on a prebuilt $EOS_KMI kernel needs its DDK in ksu/ddk.conf"
fi
# Where a device's build keeps its own records: cheetah's are where they always were, so its
# builds, packs and logs don't move; the other phones' sit beside them in the one tree
EOS_PRODUCT_OUT=out/target/product/$EOS_DEVICE
if [[ $EOS_DEVICE = cheetah ]]; then
    EOS_STATE=out/eos EOS_KSU_OUT=out/ksu EOS_BUILD_LOG=$HOME/expressiveos-build.log EOS_KSU_INIT_BOOT_VAR=CHEETAH_KSU_INIT_BOOT
else
    EOS_STATE=out/eos-$EOS_DEVICE EOS_KSU_OUT=out/ksu-$EOS_DEVICE
    EOS_BUILD_LOG=$HOME/expressiveos-build-$EOS_DEVICE.log EOS_KSU_INIT_BOOT_VAR=EOS_KSU_INIT_BOOT
fi

kit_patch_dirs() {   # kit_patch_dirs: the kit's patch folders for EOS_DEVICE, one a line: the shared ones (patches/, ksu/patches/, viper4android/patches/), then devices/<device>/patches/ and ksu-patches/
    local d
    for d in "$kit"/patches/* "$kit"/ksu/patches/* "$kit"/viper4android/patches/* \
             "$kit/devices/$EOS_DEVICE"/patches/* "$kit/devices/$EOS_DEVICE"/ksu-patches/*; do
        [[ -d $d ]] && printf '%s\n' "$d"
    done
    return 0
}

# The other trees on the server, symlinks resolved (empty when absent)
evo=$(cd "$HOME/evolution" 2>/dev/null && pwd -P) || evo=
derp=$(cd "$HOME/derpfest" 2>/dev/null && pwd -P) || derp=

not_other() {   # not_other <path>: <path>, as given and resolved, isn't in the Evolution X or DerpFest tree
    local p=${1%/} r o
    [[ "$p" != */evolution && "$p" != evolution && "$p" != */derpfest && "$p" != derpfest ]] \
        || fail "$1 is the Evolution X or DerpFest tree; this kit is for the ExpressiveOS tree only"
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    for o in "$evo" "$derp"; do
        [[ -z "$o" || ( "$r" != "$o" && "$r" != "$o"/* ) ]] || fail "$1 leads into $o; this kit is for the ExpressiveOS tree only"
    done
}

eos_top() {   # eos_top [path]: sets top to the ExpressiveOS tree (default ~/expressiveos), checked
    local arg=${1:-$HOME/expressiveos}
    not_other "$arg"
    [[ -d "$arg" ]] || fail "no tree at $arg (run setup.sh)"
    top=$(cd "$arg" && pwd -P)
    not_other "$top"
    [[ -f "$top/build/envsetup.sh" ]] || fail "$top isn't an Android tree (no build/envsetup.sh)"
    # The build writes here before anything else checks: a linked out/ or out-kernel/ would
    # build into another tree (Evolution X's kernel output is the same gs-6.1 source)
    local p
    for p in out out-kernel out-kernel/google out-kernel/google/gs-6.1 "$EOS_STATE" "$EOS_KSU_OUT" "$EOS_PRODUCT_OUT"; do
        in_top "$top/$p"
    done
}

in_top() {   # in_top <path>: <path>, symlinks resolved, is inside $top and in no other tree
    local r o
    r=$(realpath -m -- "$1") || fail "can't resolve $1"
    [[ "$r" == "$top"/* ]] || fail "${1#"$top"/} leads to $r, outside $top (a symlink?); this kit writes only inside the ExpressiveOS tree"
    for o in "$evo" "$derp"; do
        [[ -z "$o" || ( "$r" != "$o" && "$r" != "$o"/* ) ]] || fail "${1#"$top"/} leads into $o"
    done
}

project_ok() {   # project_ok <dir>: a git project of its own in this tree, git folder included, with no am or rebase running
    local d=$1 gd
    in_top "$d"
    [[ -d "$d" && "$(cd "$d" && git rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$d" && pwd -P)" ]] \
        || fail "${d#"$top"/} isn't a git project (run setup.sh)"
    { gd=$(git -C "$d" rev-parse --absolute-git-dir) && gd=$(realpath -- "$gd"); } || fail "can't find ${d#"$top"/}'s git folder"
    [[ "$gd" == "$top"/* ]] || fail "${d#"$top"/}'s git folder is $gd, outside $top (shared with another tree?)"
    # An am or rebase someone else left running is theirs to finish: am_patches' cleanup
    # (am --abort) would drop the commits it already made
    [[ ! -e "$gd/rebase-apply" && ! -e "$gd/rebase-merge" ]] \
        || fail "${d#"$top"/} has a git am or rebase in progress ($gd); finish it or abort it yourself, then run this again"
}

patch_project() {   # patch_project <patches/dir>: the tree project it patches (<dir>/PROJECT, else its path with _ for /)
    local p=${1%/}
    # A project whose own name has a _ (system/update_engine) names itself in PROJECT
    if [[ -f $p/PROJECT ]]; then
        p=$(sed -n 1p -- "$p/PROJECT")
        [[ $p =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && /$p/ != */../* ]] || fail "${1%/}/PROJECT doesn't name a tree project: '$p'"
        printf '%s\n' "$p"
        return
    fi
    p=${p##*/}
    printf '%s\n' "${p//_//}"
}

subject_of() {   # subject_of <patch>: its Subject:, folded lines joined, [PATCH n/m] dropped
    awk '/^Subject: /{s=substr($0,10); while ((getline l) > 0 && l ~ /^ /) s = s l; print s; exit}' "$1" | sed 's/^\[PATCH[^]]*\] //'
}

am_patches() {   # am_patches <dir> <label> <patch>...: each patch as a local commit (git am --3way), unless its subject is in the log
    local d=$1 label=$2 patch subject before log h rc own
    shift 2
    project_ok "$d"
    # A project from ExpressiveOS's manifest that's one of its own repos (github.com/ExpressiveOS)
    # has the kit's patches as commits already: a patch it lacks, or has another version of, is a
    # kit change made the old way. Those go into the repo itself (README.md, "Sources")
    own=$(git -C "$d" config --get remote.expressiveos.url || true)
    git -C "$d" var GIT_COMMITTER_IDENT >/dev/null || fail "git has no user.name/user.email here; git am needs one"
    # One git log per project: frameworks/base has over a million commits. Each line is the
    # commit's hash, a tab and its subject
    log=$(mktemp "${TMPDIR:-/tmp}/eos-log.XXXXXX")
    git -C "$d" log --format='%H%x09%s' > "$log" || { rm -f -- "$log"; fail "can't read ${d#"$top"/}'s log"; }
    for patch in "$@"; do
        subject=$(subject_of "$patch")
        [[ -n "$subject" ]] || { rm -f -- "$log"; fail "no Subject: in $patch"; }
        h=$(S=$subject awk '{ if (substr($0, 42) == ENVIRON["S"]) { print substr($0, 1, 40); exit } }' "$log")
        if [[ -n "$h" ]]; then
            echo "already applied: $label: $subject"
            # A kit patch changed in place keeps its subject, so the tree can still have the
            # older version: then the patch put on that commit's parent doesn't give its tree
            rc=0
            same_change "$d" "$h" "$patch" || rc=$?
            if [[ $rc = 1 && -n "$own" ]]; then
                rm -f -- "$log"
                fail "$label: ${d#"$top"/}'s commit ${h:0:12} has the subject of ${patch##*/} but not its change, and ${d#"$top"/} is ExpressiveOS's own repo ($own): change it with a new commit there, never by editing a kit patch (README.md, \"Sources\")"
            elif [[ $rc = 1 ]]; then
                echo "WARNING: $label: ${d#"$top"/}'s commit ${h:0:12} has the subject of ${patch##*/} but not its change. If apply.sh or apply-ksu.sh made it (an older version of the patch): repo sync -d ${d#"$top"/}, then build again (tools/eos-images.sh puts the kit's patches back). If it came with Evolution X's source: compare the two, then drop or regenerate the patch"
            elif [[ $rc != 0 ]]; then
                echo "note: $label: ${d#"$top"/}'s commit ${h:0:12} has the subject of ${patch##*/}, but its change can't be compared with the patch here (no parent in this clone, or git failed)"
            fi
            continue
        fi
        if [[ -n "$own" ]]; then
            rm -f -- "$log"
            # A clone cut short (clone-depth) shows only the commits above the cut
            [[ "$(git -C "$d" rev-parse --is-shallow-repository 2>/dev/null)" != true ]] \
                || fail "$label: ${d#"$top"/} lacks ${patch##*/} in its log, but it's ExpressiveOS's own repo ($own) cloned shallow (clone-depth in the manifest), so that commit may be under the cut: a project the kit has patches for needs its full history (README.md, \"Sources\")"
            fail "$label: ${d#"$top"/} lacks ${patch##*/}, and it's ExpressiveOS's own repo ($own): commit the change there, on its expressiveos branch, and move its revision in ExpressiveOS's manifest; a kit patch for it is never applied (README.md, \"Sources\")"
        fi
        before=$(git -C "$d" rev-parse HEAD)
        # --keep-cr: some files have CRLF line ends (SystemUI's clocks/AnalogClockView.java),
        # and git am would strip the CRs from the patch so it no longer matches them
        # merge.renames: git am's 3-way merge follows renames even where git config turns them
        # off, as same_change's does
        if git -C "$d" -c merge.renames=true am -q --keep-cr --3way "$patch"; then
            # git am exits 0 without a commit when the tree already has the change
            [[ "$(git -C "$d" rev-parse HEAD)" != "$before" && "$(git -C "$d" log -1 --format=%s)" = "$subject" ]] || {
                rm -f -- "$log"
                fail "$label: git am made no commit for ${patch##*/}: the project already has that change under another subject (did Evolution X take it?). Check, then drop the patch from the kit"
            }
            printf '%s\t%s\n' "$(git -C "$d" rev-parse HEAD)" "$subject" >> "$log"
            echo "applied: $label: $subject"
        else
            rm -f -- "$log"
            # project_ok refused an am already running, so this one is ours to abort
            [[ ! -e "$(git -C "$d" rev-parse --absolute-git-dir)/rebase-apply" ]] || git -C "$d" am --abort || true
            fail "$label: git am failed on ${patch##*/} and was aborted (git's message is above; on a conflict, Evolution X changed that code: regenerate the patch)"
        fi
    done
    rm -f -- "$log"
}

same_change() {   # same_change <dir> <commit> <patch>: 0 if git am of the patch on the commit's parent gives the
    # commit's tree, 1 if not, 2 if that can't be checked here (no parent in this clone, a root commit)
    local d=$1 h=$2 patch t objs tree base theirs rc=1
    patch=$(realpath -- "$3") || return 2
    git -C "$d" rev-parse -q --verify "$h^^{commit}" >/dev/null 2>&1 || return 2
    objs=$(git -C "$d" rev-parse --path-format=absolute --git-path objects) || return 2
    t=$(mktemp -d "${TMPDIR:-/tmp}/eos-am.XXXXXX") || return 2
    [[ "$t" = /* ]] || t=$PWD/$t   # git -C below would read a relative one from the project
    mkdir -p "$t/mail" "$t/objects"
    # Every git call below works on scratch indexes and keeps the objects it writes in $t, so
    # the project's index, files, refs and objects don't change (a split index would put its
    # shared part in the project's git folder)
    am_git() { GIT_OBJECT_DIRECTORY=$t/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=$objs git -C "$d" -c core.splitIndex=false "$@"; }
    # Redo what git am --keep-cr --3way did. The mail is split first, so a line in the commit
    # message that looks like a hunk isn't read as one
    if [[ "$(git mailsplit -b --keep-cr -o"$t/mail" -- "$patch" 2>/dev/null)" = 1 ]] \
        && git mailinfo "$t/msg" "$t/diff" < "$t/mail/0001" >/dev/null 2>&1 \
        && GIT_INDEX_FILE=$t/index am_git read-tree "$h^" 2>/dev/null; then
        rc=0
        # A plain apply to the parent (offsets allowed) ...
        if GIT_INDEX_FILE=$t/index am_git apply --cached -- "$t/diff" >/dev/null 2>&1; then
            tree=$(GIT_INDEX_FILE=$t/index am_git write-tree 2>/dev/null) || rc=2
        # ... else a merge of the patch's own base and result into the parent, renames followed
        # and directory renames not (git am's fallback; merge-tree follows renames whatever git
        # config says, so am_patches' git am does too). The fake ancestor takes what the patch
        # has no blob id for from the index, which for git am was the parent's
        elif GIT_INDEX_FILE=$t/index am_git apply --build-fake-ancestor="$t/base" -- "$t/diff" >/dev/null 2>&1 \
            && base=$(GIT_INDEX_FILE=$t/base am_git write-tree 2>/dev/null) \
            && GIT_INDEX_FILE=$t/base am_git apply --cached -- "$t/diff" >/dev/null 2>&1 \
            && theirs=$(GIT_INDEX_FILE=$t/base am_git write-tree 2>/dev/null) \
            && base=$(echo base | GIT_AUTHOR_NAME=eos GIT_AUTHOR_EMAIL=eos@localhost GIT_COMMITTER_NAME=eos \
                GIT_COMMITTER_EMAIL=eos@localhost am_git commit-tree "$base" 2>/dev/null) \
            && theirs=$(echo patch | GIT_AUTHOR_NAME=eos GIT_AUTHOR_EMAIL=eos@localhost GIT_COMMITTER_NAME=eos \
                GIT_COMMITTER_EMAIL=eos@localhost am_git commit-tree "$theirs" 2>/dev/null); then
            # merge-tree exits 1 on a conflict, and git am would have stopped there
            tree=$(am_git -c merge.directoryRenames=false merge-tree --write-tree --merge-base="$base" "$h^" "$theirs" 2>/dev/null) \
                || rc=$(( $? == 1 ? 1 : 2 ))
            tree=${tree%%$'\n'*}
        else
            rc=1
        fi
        [[ $rc != 0 || "$tree" = "$(git -C "$d" rev-parse "$h^{tree}")" ]] || rc=1
    else
        rc=2
    fi
    unset -f am_git
    rm -rf -- "$t"
    return "$rc"
}

has_subject() {   # has_subject <dir> <subject>: the project's log has a commit with exactly that subject
    # Not grep -q: exiting at the first match would kill git log with SIGPIPE under pipefail
    git -C "$1" log --format=%s | grep -xF -- "$2" >/dev/null
}

clean_env() {   # drop what a shell set up for another tree: soong_ui and envsetup follow these
    unset TOP ANDROID_BUILD_TOP ANDROID_PRODUCT_OUT ANDROID_HOST_OUT OUT OUT_DIR OUT_DIR_COMMON_BASE \
        TARGET_PRODUCT TARGET_RELEASE TARGET_BUILD_VARIANT CHEETAH_KSU_INIT_BOOT EOS_KSU_INIT_BOOT KODIAK_PERSONAL \
        KERNEL_REPO_PROJECT_OBJECTS_DIR KERNEL_REPO_PROJECTS_DIR
}

dump_vars() {   # dump_vars <var>...: VAR='value' lines for EOS_LUNCH, without lunch (which runs build_kernel)
    local product=${EOS_LUNCH%%-*} rest=${EOS_LUNCH#*-}
    # What lunch would export: EVO_BUILD_TYPE as eos-images.sh builds (it decides whether
    # keys.mk is read), and LINEAGE_BUILD, which check_product sets from the product name
    # and vendor/lineage's version.mk puts in the zip's name
    (cd "$top" && clean_env &&
        EVO_BUILD_TYPE=$EOS_BUILD_TYPE LINEAGE_BUILD=${product#lineage_} \
        TARGET_PRODUCT=$product TARGET_RELEASE=${rest%%-*} TARGET_BUILD_VARIANT=${rest#*-} \
        build/soong/soong_ui.bash --dumpvars-mode --vars="$*")
}

var_of() {   # var_of <dumpvars output> <name>: one value from dump_vars' output
    sed -n "s/^$2='\(.*\)'\$/\1/p" <<<"$1"
}

tf_zip() {   # tf_zip: the target-files zip m evolution keeps (patches/vendor_lineage/0003), relative to the tree
    printf '%s\n' "$EOS_PRODUCT_OUT/obj/PACKAGING/target_files_intermediates/${EOS_LUNCH%%-*}-target_files.zip"
}

eos_lock() {   # eos_lock <script> [arg]...: run <script> holding ~/.expressiveos.lock and ~/.evolution-tree.lock (shared with the Evolution X routines), waiting up to 8 h for each
    local rc=0
    # Its own lock first: waiting for an ExpressiveOS run (eos-pack.sh) never holds up the routines
    echo "== waiting for ~/.expressiveos.lock, then ~/.evolution-tree.lock (the Evolution X routines and builds share the server)"
    env EOS_HOLDS_LOCK=1 flock -o -E 75 -w 28800 "$HOME/.expressiveos.lock" \
        flock -o -E 75 -w 28800 "$HOME/.evolution-tree.lock" "$@" || rc=$?
    [[ $rc != 75 ]] || echo "FAIL: a lock was held for 8 hours; nothing was built" >&2
    return $rc
}

locks_held() {   # locks_held: fail unless this run's own eos_lock holds both locks (EOS_HOLDS_LOCK=1 says a parent does)
    local l n rc inode p=$$ up=' '
    # eos_lock's two flock processes hold the locks: they're among this run's parents
    while [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 ]]; do
        up+="$p "
        p=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null)
    done
    for l in "$HOME/.expressiveos.lock" "$HOME/.evolution-tree.lock"; do
        n=${l/#"$HOME"/\~}
        rc=0; flock -n "$l" true 2>/dev/null || rc=$?
        case $rc in
            0) fail "EOS_HOLDS_LOCK=1 is set, but nothing holds $n: run this without EOS_HOLDS_LOCK" ;;
            1) ;;   # held
            *) fail "can't check $n (flock exited $rc)" ;;
        esac
        # Held, but by whom: /proc/locks names the process that holds a flock and the file's inode
        [[ -r /proc/locks ]] || continue
        inode=$(stat -c %i -- "$l") || fail "can't stat $n"
        awk -v i="$inode" -v up="$up" '$2 != "->" { split($6, f, ":"); if (f[3] == i && index(up, " " $5 " ")) h = 1 }
            END { exit !h }' /proc/locks \
            || fail "EOS_HOLDS_LOCK=1 is set, but another run holds $n, not this one's eos_lock: run this without EOS_HOLDS_LOCK"
    done
}

run_locked() {   # run_locked <status line> <script> [arg]...: run alone, the script runs again under eos_lock, and this exits with it
    local line=$1 started rc=0
    shift
    if [[ "${EOS_HOLDS_LOCK:-}" = 1 ]]; then
        # The locked run (or a script it runs). From here this run prints its own status
        # line: its trap stays quiet only while the marker is there
        [[ -z "${EOS_STARTED:-}" ]] || rm -f -- "$EOS_STARTED"
        unset EOS_STARTED
        # EOS_HOLDS_LOCK=1 has to mean eos_lock holds the locks, not just that someone set it
        locks_held
        return 0
    fi
    started=$(mktemp "${TMPDIR:-/tmp}/eos-started.XXXXXX") || fail "can't make a temporary file"
    trap - EXIT
    eos_lock env EOS_STARTED="$started" bash "$(readlink -f -- "$1")" "${@:2}" || rc=$?
    # The locked run removes the marker as it starts. Still here: a lock was never free
    # (75) or flock failed, so nothing ran, and the status line is this run's to print
    if [[ -e $started ]]; then
        rm -f -- "$started"
        echo "$line"
        exit $(( rc ? rc : 1 ))
    fi
    exit $rc
}

wait_builds() {   # wait until no soong_ui or ninja of this user is running (a build started by hand), up to 8 h
    local i
    for ((i = 0; i < 960; i++)); do
        pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' >/dev/null || return 0
        ((i % 20)) || echo "waiting for a running build to finish: $(pgrep -a -u "$(id -u)" -f 'soong_ui|bin/ninja' | head -1 | cut -c1-150)"
        sleep 30
    done
    fail "a build has been running for 8 hours; not starting another on top of it"
}

tree_build() {   # tree_build: the soong_ui or ninja of this user running in $top (a build started by hand there), or nothing
    local pid cwd
    for pid in $(pgrep -u "$(id -u)" -f 'soong_ui|bin/ninja' || true); do
        cwd=$(readlink -- "/proc/$pid/cwd" 2>/dev/null) || continue
        [[ "$cwd" != "$top" && "$cwd" != "$top"/* ]] || { ps -o args= -p "$pid" 2>/dev/null | cut -c1-150; return 0; }
    done
}

tree_manifest() {   # tree_manifest: the manifest file $top syncs to, after checking it's ExpressiveOS's (eos.conf) as GitHub has it, alone
    local m=$top/.repo/manifests url b f
    url=$(git -C "$m" config --get remote.origin.url 2>/dev/null) || fail "$top has no repo manifest (run setup.sh)"
    [[ "${url%.git}" = "$EOS_MANIFEST_URL" ]] || fail "$top's manifest is $url, not $EOS_MANIFEST_URL (run setup.sh)"
    b=$(git -C "$m" config --get branch.default.merge 2>/dev/null) || b=
    [[ "${b#refs/heads/}" = "$EOS_MANIFEST_BRANCH" ]] || fail "$top's manifest is on branch '${b#refs/heads/}', not $EOS_MANIFEST_BRANCH (run setup.sh)"
    grep -qF '<include name="default.xml" />' "$top/.repo/manifest.xml" 2>/dev/null \
        || fail "$top/.repo/manifest.xml isn't ExpressiveOS's default.xml (run setup.sh)"
    # What GitHub has, nothing edited or committed here: the build's sources are on record there
    [[ -z "$(git -C "$m" status --porcelain 2>/dev/null)" && \
       "$(git -C "$m" rev-parse HEAD 2>/dev/null)" = "$(git -C "$m" rev-parse -q --verify "refs/remotes/origin/$EOS_MANIFEST_BRANCH" 2>/dev/null)" ]] \
        || fail "$top's manifest (.repo/manifests) has local changes or commits (git -C $m status): it must be ExpressiveOS's as GitHub has it, and a change to it is a commit there (README.md, \"Sources\"). Undo the change, then run setup.sh"
    for f in "$top"/.repo/local_manifests/*.xml; do
        [[ ! -e "$f" ]] || fail "$f: ExpressiveOS's tree is its manifest alone; move that local manifest out of .repo/local_manifests"
    done
    printf '%s\n' "$m/default.xml"
}

pins_list() {   # pins_list <manifest>...: "<path> <revision>" for each project the repo manifests name
    python3 -c '
import sys, xml.etree.ElementTree as ET
for f in sys.argv[1:]:
    for e in ET.parse(f).getroot().iter("project"):
        print(e.get("path") or e.get("name"), e.get("revision") or "-")
' "$@"
}

pins_check() {   # pins_check <tree> <manifest branch> <manifest>...: each project the manifests pin was synced to its pinned commit (repo's m/<branch>) and has it under HEAD (the kit's commits sit on top); names each that isn't and returns 1
    local tree=$1 branch=$2 list p rev m n=0 bad=0
    shift 2
    list=$(pins_list "$@") || fail "can't read $*"
    while read -r p rev; do
        n=$((n + 1))
        if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
            echo "off the pins: $p follows '$rev', not a commit"; bad=$((bad + 1)); continue
        fi
        m=$(git -C "$tree/$p" rev-parse -q --verify "refs/remotes/m/$branch^{commit}" 2>/dev/null) || m=
        if [[ $m != "$rev" ]]; then
            echo "off the pins: $p was synced to ${m:-nothing}, not ${rev:0:12}"; bad=$((bad + 1))
        elif ! git -C "$tree/$p" merge-base --is-ancestor "$rev" HEAD 2>/dev/null; then
            echo "off the pins: $p's HEAD $(git -C "$tree/$p" rev-parse --short HEAD 2>/dev/null) isn't ${rev:0:12} or a commit on top of it"; bad=$((bad + 1))
        fi
    done <<<"$list"
    (( bad == 0 )) || { echo "$bad of $n projects are off the pins"; return 1; }
    echo "OK: all $n projects on their pinned commits"
}

pins_install() {   # pins_install <tree> <pins file>: <tree>'s repo uses <pins file> (as .repo/manifests/expressiveos-pins.xml), so every repo sync there, by hand too, lands on its commits
    local tree=$1 m=$1/.repo/manifests
    in_top "$m/expressiveos-pins.xml"
    if cmp -s -- "$2" "$m/expressiveos-pins.xml"; then
        echo "unchanged: ${m#"$top"/}/expressiveos-pins.xml"
    else
        { cp -- "$2" "$m/.expressiveos-pins.xml.tmp" && mv -f -- "$m/.expressiveos-pins.xml.tmp" "$m/expressiveos-pins.xml"; } \
            || fail "can't install ${m#"$top"/}/expressiveos-pins.xml"
        echo "installed: ${m#"$top"/}/expressiveos-pins.xml"
    fi
    # repo init -m writes .repo/manifest.xml as an include of the named file. No terminal on
    # stdin: repo init then asks nothing
    grep -qF '<include name="expressiveos-pins.xml" />' "$tree/.repo/manifest.xml" 2>/dev/null \
        || (cd "$tree" && repo init -m expressiveos-pins.xml </dev/null) || fail "repo init -m expressiveos-pins.xml failed in $tree"
    grep -qF '<include name="expressiveos-pins.xml" />' "$tree/.repo/manifest.xml" \
        || fail "$tree/.repo/manifest.xml doesn't use expressiveos-pins.xml after repo init -m"
}

kernel_pinned() {   # kernel_pinned: out-kernel/google/gs-6.1 holds the kernel source pins/kernel.xml pins, synced to it first when it's missing or EOS_KERNEL_SYNC=1; build_kernel then never syncs (SKIP_KERNEL_SYNC=1)
    local kt=$top/out-kernel/google/gs-6.1
    in_top "$kt/.repo"
    if [[ ! -d $kt/.repo/manifests || "${EOS_KERNEL_SYNC:-0}" = 1 ]]; then
        echo "== kernel source: out-kernel/google/gs-6.1 to pins/kernel.xml"
        if [[ ! -d $kt/.repo/manifests ]]; then
            # Laid out as build_kernel does it: repo's own copy from the tree, and the marker
            # that keeps the platform build from scanning the kernel source
            mkdir -p -- "$kt/.repo" || fail "can't make $kt/.repo"
            # repo runs the first .repo/repo/main.py it finds from its directory up: a copy cut
            # off before main.py would send every repo command below to the main tree. So the
            # copy is made under another name, and only a whole one is renamed into place
            if [[ ! -f $kt/.repo/repo/main.py ]]; then
                rm -rf -- "$kt/.repo/repo" "$kt/.repo/repo.tmp" \
                    && cp -R -- "$top/.repo/repo" "$kt/.repo/repo.tmp" \
                    && mv -- "$kt/.repo/repo.tmp" "$kt/.repo/repo" || fail "can't copy repo into $kt/.repo"
            fi
            touch -- "$kt/.out-dir" || fail "can't write $kt/.out-dir"
            (cd "$kt" && repo init -u "$EOS_KERNEL_MANIFEST_URL" -b "$EOS_KERNEL_MANIFEST_BRANCH" </dev/null) \
                || fail "repo init of the kernel source failed"
        fi
        [[ -f $kt/.repo/repo/main.py && -d $kt/.repo/manifests ]] \
            || fail "out-kernel/google/gs-6.1/.repo has no repo of its own: remove out-kernel/google/gs-6.1 and build again (the main tree is untouched)"
        pins_install "$kt" "$kit/pins/kernel.xml"
        (cd "$kt" && repo sync --detach --force-sync) || fail "repo sync of the kernel source failed"
    fi
    pins_check "$kt" "$EOS_KERNEL_MANIFEST_BRANCH" "$kit/pins/kernel.xml" \
        || fail "out-kernel/google/gs-6.1 isn't the kernel source pins/kernel.xml pins (EOS_KERNEL_SYNC=1 syncs it to them)"
    export SKIP_KERNEL_SYNC=1
}
