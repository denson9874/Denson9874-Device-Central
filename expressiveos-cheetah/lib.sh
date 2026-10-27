# Shared by the ExpressiveOS cheetah scripts (sourced, never run): sets kit, reads
# eos.conf, and holds the guards they all use. The Evolution X tree (~/evolution) and
# the DerpFest tree (~/derpfest) are never touched, nothing is written through a
# symlink that leads out of the ExpressiveOS tree, and a git project is checked before
# git am runs in it.
# shellcheck shell=bash

kit="$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=eos.conf
source "$kit/eos.conf" || fail "can't read $kit/eos.conf"

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
    for p in out out-kernel out-kernel/google out-kernel/google/gs-6.1 out/eos out/ksu out/target/product/cheetah; do
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
    local d=$1 label=$2 patch subject before log h
    shift 2
    project_ok "$d"
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
            same_change "$d" "$h" "$patch" \
                || echo "WARNING: $label: ${d#"$top"/}'s commit ${h:0:12} has the subject of ${patch##*/} but not its change. If apply.sh or apply-ksu.sh made it (an older version of the patch): repo sync -d ${d#"$top"/}, then build again (tools/eos-images.sh puts the kit's patches back). If it came with Evolution X's source: compare the two, then drop or regenerate the patch"
            continue
        fi
        before=$(git -C "$d" rev-parse HEAD)
        # --keep-cr: some files have CRLF line ends (SystemUI's clocks/AnalogClockView.java),
        # and git am would strip the CRs from the patch so it no longer matches them
        if git -C "$d" am -q --keep-cr --3way "$patch"; then
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

same_change() {   # same_change <dir> <commit> <patch>: the patch put on the commit's parent gives the commit's tree
    local d=$1 h=$2 patch t ok=1
    patch=$(realpath -- "$3") || return 1
    t=$(mktemp -d "${TMPDIR:-/tmp}/eos-idx.XXXXXX") || return 1
    [[ "$t" = /* ]] || t=$PWD/$t   # git -C below would read a relative one from the project
    # In a scratch index, so the project's own index and files don't change. git apply --3way
    # falls back to a merge as git am --3way does, so a patch that needed one compares equal
    if GIT_INDEX_FILE=$t/index git -C "$d" read-tree "$h^" 2>/dev/null \
        && GIT_INDEX_FILE=$t/index git -C "$d" apply --cached --3way "$patch" >/dev/null 2>&1 \
        && [[ "$(GIT_INDEX_FILE=$t/index git -C "$d" write-tree 2>/dev/null)" = "$(git -C "$d" rev-parse "$h^{tree}")" ]]; then
        ok=0
    fi
    rm -rf -- "$t"
    return "$ok"
}

has_subject() {   # has_subject <dir> <subject>: the project's log has a commit with exactly that subject
    # Not grep -q: exiting at the first match would kill git log with SIGPIPE under pipefail
    git -C "$1" log --format=%s | grep -xF -- "$2" >/dev/null
}

clean_env() {   # drop what a shell set up for another tree: soong_ui and envsetup follow these
    unset TOP ANDROID_BUILD_TOP ANDROID_PRODUCT_OUT ANDROID_HOST_OUT OUT OUT_DIR OUT_DIR_COMMON_BASE \
        TARGET_PRODUCT TARGET_RELEASE TARGET_BUILD_VARIANT CHEETAH_KSU_INIT_BOOT KODIAK_PERSONAL \
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
    printf '%s\n' "out/target/product/cheetah/obj/PACKAGING/target_files_intermediates/${EOS_LUNCH%%-*}-target_files.zip"
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
