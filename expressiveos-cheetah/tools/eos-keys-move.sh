#!/usr/bin/env bash
# Moves ExpressiveOS's signing-key folder in the tree from vendor/evolution-priv to
# vendor/expressiveos-priv, 1.1's name (Sunday 2026-11-08, with no build running), or back.
# A move, never new keys and never a link: every key file stays byte-identical, so the 1.0
# phones keep taking updates. Only keys/keys.mk changes, on the lines that name the folder.
# The runner's action expressiveos-keys-move runs it (query: check, move or revert).
#
#   eos-keys-move.sh [check] [top]   read-only, the default: which folder the tree has, every
#                                    file in it (type, mode, size, sha256), whether a build or
#                                    a repo sync is running, free disk, and whether move or
#                                    revert would run now
#   eos-keys-move.sh move [top]      vendor/evolution-priv -> vendor/expressiveos-priv
#   eos-keys-move.sh revert [top]    vendor/expressiveos-priv -> vendor/evolution-priv
#
# move and revert refuse unless nothing builds or syncs: they take the kit's locks
# (~/.expressiveos.lock and the tree lock's two names) and hold them to the end, and no
# eos-setup, eos-build or eos-pack session and no soong_ui, ninja or repo of this user runs. The
# folder they move from must be a folder (not a symlink) on the tree's file system, with only
# files, folders and relative links, and keys/keys.mk must name it; the folder they move to
# must not exist. A link may stay inside the folder (releasekey.* -> testkey.*), or lead out
# of it to elsewhere in the tree without coming back in through either of the two names (the
# template's BUILD.bazel -> ../../../build/make/target/product/security/BUILD.bazel, a link to
# nothing: this tree's build/make has no such file): both names sit in vendor/, so such a link
# leads to the same place after the move. Only the files the build reads (*.mk, *.bp, *.bazel,
# *.bzl, BUILD, *.go) must not name the folder, keys.mk aside; a README or script that does
# gets a note and stays as it is. keys.mk must not name both folders: a revert couldn't tell
# its lines apart. Then:
#   1. a backup archive of the folder, ~/expressiveos-keys-<UTC time>.tar.gz (mode 600, its
#      contents as the first backup's: keys/), read back and checked against the files;
#   2. the sha256 of every file, before;
#   3. mv to the new name (a rename on the same file system: the same inode, nothing copied);
#   4. keys/keys.mk: the folder's old path rewritten to the new one, nothing else;
#   5. every other file's sha256, mode and size unchanged, and keys.mk different from the
#      backup's only on the lines that named the old path;
#   6. a second backup archive, of the folder under its new name, checked the same way.
# A failure after step 3 says where the folder is; revert (or move) takes it from there, as
# its keys.mk may name either path. Steps 3 and 4 ignore INT, TERM, HUP and PIPE (a cancelled
# job): they run to their end, so the rename and keys.mk's rewrite never part halfway. Elsewhere
# those signals stop the script through its last lines (KEYS_MOVE=FAIL, and the NOTE). A run
# killed outright (SIGKILL) between them can leave keys/.keys.mk.eos-keys-move, the new keys.mk
# before its rename; keys.mk itself is whole (replaced in one rename), and the next move or
# revert removes that file with a note. Any other kind of entry of that name is refused.
# Prints names, modes, sizes and sha256 sums only, never a file's contents, never makes a
# key and never makes a link. The last line is KEYS_MOVE=OK (...) or KEYS_MOVE=FAIL: <why>.
set -euo pipefail
# The script's own output, kept on 5 and 6: a trap can run while a command's output is redirected
# (a signal while a helper writes to a file), and its last lines must reach the log all the same
exec 5>&1 6>&2
done=0 why='' work='' tmpmk='' moved=''
cleanup() {
    local rc=$?
    trap '' INT TERM HUP
    [[ -z $tmpmk || ! -f $tmpmk || -L $tmpmk ]] || rm -f -- "$tmpmk"
    [[ -z $work ]] || rm -rf -- "$work"
    if [[ $done != 1 ]]; then
        [[ -z $moved ]] || echo "NOTE: the folder is at $moved now" >&5
        echo "KEYS_MOVE=FAIL: ${why:-see the lines above}" >&5
    fi
    exit $rc
}
trap cleanup EXIT
# A signal stops the script through cleanup, which says so and where the folder is
on_signal() { why="stopped by SIG$1${moved:+ after the rename}"; echo "FAIL: $why" >&6; exit 1; }
stop_on_signals() { trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP; trap - PIPE; }
stop_on_signals
# shellcheck source=../lib.sh
source "$(dirname -- "$(readlink -f -- "$0")")/../lib.sh"
# lib.sh's guards call fail too: keep the reason for the last line
fail() { why=$*; echo "FAIL: $*" >&2; exit 1; }

usage="usage: eos-keys-move.sh [check|move|revert] [top]"
mode=${1:-check}
[[ $mode =~ ^(check|move|revert)$ && $# -le 2 ]] || fail "$usage"
eos_top "${2:-}"
umask 077
command -v python3 >/dev/null || fail "python3 isn't installed"
command -v tar >/dev/null || fail "tar isn't installed"
work=$(mktemp -d "${TMPDIR:-/tmp}/eos-keys-move.XXXXXX") || fail "can't make a temporary folder"

OLD=$EOS_PRIV_OLD NEW=$EOS_PRIV_NEW MK=keys/keys.mk
TMPMK=keys/.keys.mk.eos-keys-move   # the new keys.mk, step 4, before its rename over keys.mk
if [[ $mode = revert ]]; then from=$NEW to=$OLD; else from=$OLD to=$NEW; fi
oneline() { tr '\n' ' ' <<<"$1" | sed 's/ *$//'; }
err1() { tail -n 1 -- "$work/err" 2>/dev/null | cut -c1-300; }   # a helper's error (its last line: notes come before it)
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }

# The helpers in Python (standard library only): a folder's list of files, an archive checked
# against that list, a keys.mk rewrite and the comparison of two lists. They print names,
# modes, sizes, sha256 sums and line numbers, never a file's contents
py() { python3 -I -c '
import hashlib, os, re, stat, sys, tarfile

def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def link_where(top, frel, names, rel, t):
    # A link rel (relative to the folder frel, itself relative to the tree top) to t: None when
    # it stays inside the folder; else the place in the tree it leads to, which must be the
    # same before and after the move: inside the tree, never back in through either of the
    # move'"'"'s two names, and not into either folder through other links. A link to nothing
    # is fine (the template'"'"'s BUILD.bazel).
    if os.path.isabs(t) or any(c in t for c in "\t\n\r\\"):
        die("%s is a link to %s, an absolute path or a name the kit does not take: a key folder of the tree'"'"'s own has only relative links" % (rel, t))
    base = frel.split("/")
    here = base + rel.split("/")[:-1]
    out = False
    for c in t.split("/"):
        if c in ("", "."):
            continue
        if c == "..":
            if not here:
                die("%s is a link to %s, which leads out of the tree" % (rel, t))
            here.pop()
            out = out or len(here) < len(base)
        else:
            here.append(c)
            if out and "/".join(here) in names:
                die("%s is a link to %s, which leaves the folder and comes back in through the name %s: it would lead elsewhere after the move" % (rel, t, "/".join(here)))
    if not out:
        return None
    real = os.path.realpath(os.path.join(top, frel, rel))
    rtop = os.path.realpath(top)
    if not real.startswith(rtop + "/"):
        die("%s is a link to %s, which leads out of the tree (to %s, through other links)" % (rel, t, real))
    for n in names:
        r = os.path.realpath(os.path.join(rtop, n))
        if real == r or real.startswith(r + "/"):
            die("%s is a link to %s, which comes back into %s through other links: it would lead elsewhere after the move" % (rel, t, n))
    return os.path.relpath(real, rtop)

def listing(top, frel, names, dev):
    # One line a file, folder or link under the folder top/frel (the folder itself left out),
    # sorted: type, mode, size, sha256 (files) or target (links) or -, path relative to it.
    # A note on stderr for each link that leads out of the folder (to the same place after the move)
    root = os.path.join(top, frel)
    out = []
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs + files):
            p = os.path.join(d, n)
            rel = os.path.relpath(p, root)
            if any(c in rel for c in "\t\n\r\\") or rel.startswith("-"):
                die("%r has a name the kit does not take (a tab, newline, backslash or leading -)" % rel)
            st = os.lstat(p)
            if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
                die("%s has other hard links (shared with another folder?): eos-keys-check.sh refuses that too" % rel)
            if dev is not None and st.st_dev != dev:
                die("%s is on another file system (a mount point inside the folder?)" % rel)
            m = "%o" % stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                t = os.readlink(p)
                w = link_where(top, frel, names, rel, t)
                if w is not None:
                    print("note: %s is a link out of the folder, to %s in the tree (%s): the same place after the move"
                          % (rel, w, "there" if os.path.lexists(os.path.join(top, w)) else "nothing there"), file=sys.stderr)
                out.append(("l", m, "-", t, rel))
            elif stat.S_ISDIR(st.st_mode):
                out.append(("d", m, "-", "-", rel))
            elif stat.S_ISREG(st.st_mode):
                out.append(("f", m, str(st.st_size), sha(p), rel))
            else:
                die("%s is not a file, folder or link" % rel)
    out.sort(key=lambda e: e[4])
    return out

def read_list(path):
    with open(path) as f:
        return [tuple(l.rstrip("\n").split("\t")) for l in f if l.strip()]

def pattern(old):
    return re.compile(rb"(?<![A-Za-z0-9_.-])" + re.escape(old.encode()) + rb"(?![A-Za-z0-9_.-])")

def rewrite(data, old, new):
    lines = data.split(b"\n")
    p = pattern(old)
    out = [p.sub(new.encode().replace(b"\\", b"\\\\"), l) for l in lines]
    changed = [i + 1 for i, (a, b) in enumerate(zip(lines, out)) if a != b]
    return b"\n".join(out), changed

# Any other error as one line (a file name at most), never a traceback
sys.excepthook = lambda t, v, tb: print("%s: %s" % (t.__name__, v), file=sys.stderr)
cmd = sys.argv[1]
if cmd == "list":            # list <top> <folder> <name> <name>: the listing of top/folder, checked (the names: the move'"'"'s two)
    if len(sys.argv) != 6:
        die("py list: wants <top> <folder> <old name> <new name>")
    top, frel = sys.argv[2:4]
    for e in listing(top, frel, sys.argv[4:6], os.lstat(os.path.join(top, frel)).st_dev):
        print("\t".join(e))
elif cmd == "archive":       # archive <tar.gz> <listing>: the archive holds exactly the listed entries
    want = {e[4]: e for e in read_list(sys.argv[3])}
    seen = {}
    with tarfile.open(sys.argv[2], "r:gz") as t:
        for m in t:
            n = m.name
            while n.startswith("./"):
                n = n[2:]
            n = n.rstrip("/")
            if not n or n == ".":
                continue
            if n in seen:
                die("the archive has %s twice" % n)
            mode = "%o" % (m.mode & 0o7777)
            if m.issym():
                seen[n] = ("l", mode, "-", m.linkname, n)
            elif m.isdir():
                seen[n] = ("d", mode, "-", "-", n)
            elif m.isfile():
                h = hashlib.sha256()
                f = t.extractfile(m)
                for b in iter(lambda: f.read(1 << 20), b""):
                    h.update(b)
                seen[n] = ("f", mode, str(m.size), h.hexdigest(), n)
            else:
                die("the archive has %s, which is not a file, folder or link" % n)
    bad = sorted(n for n in set(want) | set(seen) if want.get(n) != seen.get(n))
    # A link'"'"'s mode is not kept by every tar: compare links without it
    bad = [n for n in bad if not (n in want and n in seen and want[n][0] == "l" and seen[n][0] == "l"
                                  and want[n][2:] == seen[n][2:])]
    if bad:
        die("the archive differs from the folder on %d entries: %s" % (len(bad), " ".join(bad[:10])))
    print(len(seen))
elif cmd == "plan":          # plan <keys.mk> <old> <new> <out|->: the rewritten keys.mk, checked; prints the changed lines
    src, old, new, dst = sys.argv[2:6]
    data = open(src, "rb").read()
    # Both names in it (a comment naming the other folder?): a revert would rewrite those lines
    # too, so it could not give back the same keys.mk
    lines = data.split(b"\n")
    po = [i + 1 for i, l in enumerate(lines) if pattern(old).search(l)]
    pn = [i + 1 for i, l in enumerate(lines) if pattern(new).search(l)]
    if po and pn:
        die("keys.mk names both %s (lines %s) and %s (lines %s): a revert could not tell those lines apart. Make it name only %s (the template'"'"'s keys.mk does) first"
            % (old, ",".join(map(str, po)), new, ",".join(map(str, pn)), old))
    res, changed = rewrite(data, old, new)
    left = [i + 1 for i, l in enumerate(res.split(b"\n")) if old.encode() in l]
    if left:
        print("note: keys.mk has %s inside a longer name on lines %s (not the folder'"'"'s path), left as it is"
              % (old, ",".join(map(str, left))), file=sys.stderr)
    have = set(res.split(b"\n"))
    for want in ("AVB_CUSTOM_KEY_PATH := %s/keys/avb.pk8" % new,
                 "PRODUCT_DEFAULT_DEV_CERTIFICATE := %s/keys/testkey" % new):
        if want.encode() not in have:
            die("keys.mk would lack the line %r after the rewrite: it does not name the key folder as the template does (%s/keys/avb.pk8 and %s/keys/testkey)" % (want, old, old))
    if dst != "-":
        # A new file, never one already there and never through a link (O_EXCL, O_NOFOLLOW),
        # with keys.mk'"'"'s own mode; it goes again when it can'"'"'t be written whole
        st = os.lstat(src)
        if not stat.S_ISREG(st.st_mode):
            die("%s is not a plain file" % src)
        fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, stat.S_IMODE(st.st_mode))
            v = memoryview(res)
            while v:
                v = v[os.write(fd, v):]
            os.fsync(fd)
        except BaseException:
            os.close(fd)
            os.unlink(dst)
            raise
        os.close(fd)
    print(",".join(map(str, changed)) or "none")
elif cmd == "same-but-mk":   # same-but-mk <before> <after> <keys.mk>: the listings agree, keys.mk aside on size and sha256
    a = {e[4]: e for e in read_list(sys.argv[2])}
    b = {e[4]: e for e in read_list(sys.argv[3])}
    mk = sys.argv[4]
    bad = []
    for n in sorted(set(a) | set(b)):
        x, y = a.get(n), b.get(n)
        if n == mk and x and y:
            if x[:2] != y[:2]:
                bad.append(n)
        elif x != y:
            bad.append(n)
    if bad:
        die("%d entries differ from before the move: %s" % (len(bad), " ".join(bad[:10])))
    print(len(a))
elif cmd == "mk-diff":       # mk-diff <before> <after> <old> <new>: after is before with only the old path rewritten
    before = open(sys.argv[2], "rb").read()
    after = open(sys.argv[3], "rb").read()
    want, changed = rewrite(before, sys.argv[4], sys.argv[5])
    if want != after:
        die("keys.mk differs from the backup on more than the lines naming %s" % sys.argv[4])
    print(",".join(map(str, changed)) or "none")
else:
    die("py: unknown command " + cmd)
' "$@"; }

# What builds or syncs now, one line each (nothing when nothing does)
busy() {
    local s p l
    if command -v tmux >/dev/null; then
        for s in eos-setup eos-build eos-pack; do
            ! tmux has-session -t "=$s" 2>/dev/null || echo "the tmux session $s is open (expressiveos-status shows its log)"
        done
    fi
    # pgrep alone in its command substitution: a command beside it in a pipeline (a sed whose
    # script says "repo") would match too
    p=$(pgrep -a -u "$(id -u)" -f 'soong_ui|bin/ninja' 2>/dev/null || true)
    while IFS= read -r l; do [[ -z $l ]] || echo "a build runs: ${l:0:150}"; done <<<"$p"
    p=$(pgrep -a -u "$(id -u)" -f '(^|[ /])repo( |$)|\.repo/repo/main\.py' 2>/dev/null || true)
    while IFS= read -r l; do [[ -z $l || $l == *eos-keys-move.sh* ]] || echo "a repo command runs: ${l:0:150}"; done <<<"$p"
}
# Who holds a lock: /proc/locks names the process and the file's inode
holder() {
    local i p
    i=$(stat -c %i -- "$1" 2>/dev/null) || return 0
    for p in $(awk -v i="$i" '$2 != "->" { split($6, f, ":"); if (f[3] == i) print $5 }' /proc/locks 2>/dev/null | sort -u); do
        echo " by $p: $(ps -o args= -p "$p" 2>/dev/null | cut -c1-120 || true)"
    done
}
locks() {   # read-only: each lock free or held (a missing file is free, and isn't made)
    local l
    for l in "$EOS_LOCK" "$EOS_TREE_LOCK" "$EOS_TREE_LOCK_OLD"; do
        if [[ ! -e $l ]]; then echo "${l/#"$HOME"/\~}: free (no file yet)"
        elif flock -n "$l" true 2>/dev/null; then echo "${l/#"$HOME"/\~}: free"
        else echo "${l/#"$HOME"/\~}: held$(holder "$l")"; fi
    done
}
# A folder the script may move: a real folder on the tree's file system, keys/keys.mk its own
folder_ok() {   # folder_ok <rel>: nothing, or why not
    local d=$top/$1
    if [[ -L $d ]]; then echo "$1 is a symlink (the key folder is the tree's own, never linked)"; return; fi
    [[ -d $d ]] || { echo "$1 isn't in the tree"; return; }
    [[ $(stat -c %d -- "$d") = "$(stat -c %d -- "$top/vendor")" ]] || { echo "$1 is on another file system than vendor/ (a mount point): mv would copy it"; return; }
    [[ -d $d/keys && ! -L $d/keys ]] || { echo "$1 has no keys/ folder of its own"; return; }
    [[ -f $d/$MK && ! -L $d/$MK ]] || { echo "$1 has no $MK of its own"; return; }
    return 0
}
naming() {   # naming <rel> <path>: the files in the folder that name <path>, one a line (names only): keys.mk, git's own files and TMPMK aside
    grep -rlF --exclude-dir=.git --exclude="${TMPMK##*/}" -- "$2" "$top/$1" 2>/dev/null | sed "s|^$top/$1/||" | grep -vxF -- "$MK" || true
}
# The files the build reads: one that names the folder's old path would read a path that's gone
# after the move. Any other file (the template's README, keys.sh) stays as it is, with a note
build_reads() { case ${1##*/} in *.mk|*.bp|*.bazel|*.bzl|BUILD|*.go) return 0 ;; *) return 1 ;; esac; }
others_naming() {   # others_naming <rel> <path>: of naming's files, the ones the build reads (move and revert refuse them)
    local n
    while IFS= read -r n; do [[ -z $n ]] || ! build_reads "$n" || printf '%s\n' "$n"; done <<<"$(naming "$1" "$2")"
}
notes_naming() {   # notes_naming <rel> <path>: of naming's files, the ones the build doesn't read (left as they are)
    local n
    while IFS= read -r n; do [[ -z $n ]] || build_reads "$n" || printf '%s\n' "$n"; done <<<"$(naming "$1" "$2")"
}
leftover() {   # leftover <rel>: nothing when <rel>/TMPMK isn't there; "file" for a stopped run's; else what else it is
    local p=$top/$1/$TMPMK
    if [[ -L $p ]]; then echo "a symlink"
    elif [[ ! -e $p ]]; then return 0
    elif [[ -f $p && $(stat -c %h -- "$p") = 1 ]]; then echo file
    elif [[ -f $p ]]; then echo "a file with other hard links"
    else echo "not a plain file"; fi
}
free_bytes() { df -B1 --output=avail -- "$1" | tail -1 | tr -dc 0-9; }
need_bytes() {   # need_bytes <rel>: room for two archives of the folder, and some
    local s
    s=$(du -sb -- "$top/$1" | cut -f1)
    echo $(( 2 * s + 64 * 1024 * 1024 ))
}
show_list() {   # show_list <listing>: the listing, for a person
    awk -F'\t' '{ if ($1 == "l") printf "  link %4s %10s  %-64s %s -> %s\n", $2, "-", "-", $5, $4
                  else if ($1 == "d") printf "  dir  %4s %10s  %-64s %s/\n", $2, "-", "-", $5
                  else printf "  file %4s %10s  %-64s %s\n", $2, $3, $4, $5 }' "$1"
}
backup() {   # backup <rel> <listing> <var>: a checked archive of the folder in ~, mode 600, its path in <var>
    local d=$top/$1 b='' n i
    # A name not taken yet: a second backup in the same second waits for the next
    for i in 1 2 3 4 5; do
        b=$HOME/expressiveos-keys-$(date -u +%Y%m%d-%H%M%S).tar.gz
        [[ -e $b || -L $b ]] || break
        b=''; sleep 1
    done
    [[ -n $b ]] || fail "can't find a free backup name in ~ (expressiveos-keys-<time>.tar.gz)"
    find "$d" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z > "$work/top-entries"
    [[ -s $work/top-entries ]] || fail "$1 is empty"
    # noclobber: never over another file of that name
    if ! ( set -o noclobber; tar -C "$d" --null --verbatim-files-from -T "$work/top-entries" -czf - > "$b" ); then
        rm -f -- "$b"
        fail "tar couldn't make the backup $b"
    fi
    chmod 600 -- "$b"
    n=$(py archive "$b" "$2" 2> "$work/err") || fail "the backup $b doesn't hold the folder's files as they are ($(err1)); it stays for a look"
    echo "OK: backup ${b/#"$HOME"/\~}: $n entries, each checked against the folder, $(du -h -- "$b" | cut -f1), mode $(stat -c %a -- "$b")"
    printf -v "$3" '%s' "$b"
}

echo "== ExpressiveOS's key folder in $top, $mode ($(date -u '+%F %T') UTC)"
have_old=0 have_new=0
[[ ! -e $top/$OLD && ! -L $top/$OLD ]] || have_old=1
[[ ! -e $top/$NEW && ! -L $top/$NEW ]] || have_new=1
for r in "$OLD" "$NEW"; do
    if [[ -L $top/$r ]]; then echo "$r: a symlink to $(readlink -- "$top/$r")"
    elif [[ -d $top/$r ]]; then echo "$r: a folder"
    elif [[ -e $top/$r ]]; then echo "$r: there, but not a folder"
    else echo "$r: absent"; fi
done
# Which folder the tree's sources read (the manifest bump after the move switches them)
for r in "$NEW" "$OLD"; do
    if grep -qsF "$r/keys/keys.mk" "$top"/vendor/lineage/config/*.mk; then echo "vendor/lineage's config includes $r/keys/keys.mk"; fi
done

if [[ $mode = check ]]; then
    for r in "$OLD" "$NEW"; do
        [[ -d $top/$r && ! -L $top/$r ]] || continue
        echo "== files in $r (type, mode, size, sha256, name)"
        L=$work/list-${r##*/}.txt
        if py list "$top" "$r" "$OLD" "$NEW" > "$L" 2> "$work/list.err"; then
            show_list "$L"
            echo "  $(awk -F'\t' '$1 == "f"' "$L" | wc -l) files, $(awk -F'\t' '$1 == "l"' "$L" | wc -l) links, $(du -sh -- "$top/$r" | cut -f1)"
            sed 's/^/  /' -- "$work/list.err"   # its notes: the links out of the folder
        else
            sed 's/^/  /' -- "$work/list.err"
            echo "  (move and revert refuse this folder: see the line above)"
            echo "x" > "$work/bad-${r##*/}"
        fi
        case $(leftover "$r") in
            '') ;;
            file) echo "  note: $TMPMK is there, the new $MK of a run that was stopped before its rename ($MK is whole): move and revert remove it first" ;;
            *) echo "  $TMPMK is $(leftover "$r"): only this script makes that name, as a plain file, so move and revert refuse it"
               echo "x" > "$work/bad-${r##*/}" ;;
        esac
        if [[ -f $top/$r/$MK && ! -L $top/$r/$MK ]]; then
            for p in "$OLD" "$NEW"; do
                l=$(grep -nF -- "$p/" "$top/$r/$MK" | cut -d: -f1 | paste -sd, - || true)
                echo "  $MK names $p/ on lines: ${l:-none}"
            done
        fi
        o=$( { others_naming "$r" "$OLD"; others_naming "$r" "$NEW"; } | sort -u)
        echo "  files the build reads, $MK aside, that name a key folder path: ${o:-none}"
        o=$( { notes_naming "$r" "$OLD"; notes_naming "$r" "$NEW"; } | sort -u)
        [[ -z $o ]] || echo "  note: other files name a key folder path, and stay as they are (the build doesn't read them): $(oneline "$o")"
    done
    echo "== builds and syncs"
    locks
    b=$(busy)
    echo "${b:-nothing builds or syncs now}"
    echo "== free disk"
    echo "the tree's file system: $(gib "$(free_bytes "$top")") free"
    echo "~ (where the backups go): $(gib "$(free_bytes "$HOME")") free"
    echo "== backups in ~"
    ls -l -- "$HOME"/expressiveos-keys-*.tar.gz 2>/dev/null | cut -c1-200 || echo "none"
    # Would move or revert run now (they check all of this again, and more, holding the locks)
    for m in move revert; do
        if [[ $m = move ]]; then f=$OLD t=$NEW; else f=$NEW t=$OLD; fi
        r=()
        [[ -z $b ]] || r+=("something builds or syncs")
        if l=$(locks | grep ': held'); then r+=("a lock is held"); fi
        w=$(folder_ok "$f"); [[ -z $w ]] || r+=("$w")
        [[ ! -e $top/$t && ! -L $top/$t ]] || r+=("$t is there already")
        if [[ -z $w ]]; then
            [[ ! -e $work/bad-${f##*/} ]] || r+=("$f holds an entry it refuses (above)")
            [[ -z $(others_naming "$f" "$f") ]] || r+=("a file in $f that the build reads, other than $MK, names $f")
            py plan "$top/$f/$MK" "$f" "$t" - > /dev/null 2> "$work/plan.err" || r+=("$(tail -n 1 "$work/plan.err")")
            [[ $(free_bytes "$HOME") -ge $(need_bytes "$f") ]] || r+=("~ has too little free disk for the two backups")
        fi
        if (( ${#r[@]} )); then echo "${m^^}_READY=no: $(IFS=';'; echo "${r[*]}" | sed 's/;/; /g')"
        else echo "${m^^}_READY=yes: $f -> $t, $MK lines $(py plan "$top/$f/$MK" "$f" "$t" -) rewritten"; fi
    done
    done=1
    echo "KEYS_MOVE=OK (check only, nothing changed: $( ((have_old)) && echo "$OLD there" || echo "no $OLD"), $( ((have_new)) && echo "$NEW there" || echo "no $NEW"))"
    exit 0
fi

# ---- move or revert: held to the end, so no kit run starts meanwhile -----------------------
exec 7>"$EOS_LOCK" 8>"$EOS_TREE_LOCK" 9>"$EOS_TREE_LOCK_OLD"
flock -n 7 || fail "~/.expressiveos.lock is held$(holder "$EOS_LOCK"): an ExpressiveOS build, pack, setup or kit script runs; nothing was changed"
flock -n 8 || fail "~/.expressiveos-tree.lock is held$(holder "$EOS_TREE_LOCK"): a build or server-cleanup runs; nothing was changed"
flock -n 9 || fail "~/.evolution-tree.lock is held$(holder "$EOS_TREE_LOCK_OLD"): a build of an older kit runs; nothing was changed"
echo "OK: holding ~/.expressiveos.lock, ~/.expressiveos-tree.lock and ~/.evolution-tree.lock"
b=$(busy)
[[ -z $b ]] || fail "$(oneline "$b"); nothing was changed"
echo "OK: no eos-setup, eos-build or eos-pack session, and no soong_ui, ninja or repo of $(id -un)"
w=$(folder_ok "$from")
[[ -z $w ]] || fail "$w; nothing was changed"
[[ ! -e $top/$to && ! -L $top/$to ]] || fail "$to is there already: the keys are moved, never copied or merged; nothing was changed (check shows both)"
in_top "$top/$from"; in_top "$top/$to"
case $(leftover "$from") in
    '') ;;
    file) rm -f -- "$top/$from/$TMPMK"
          echo "note: removed $from/$TMPMK, the new $MK of a run that was stopped before its rename ($MK itself is whole: it is replaced in one rename)" ;;
    *) fail "$from/$TMPMK is $(leftover "$from"): only this script makes that name, as a plain file; look at it and remove it by hand; nothing was changed" ;;
esac
o=$(others_naming "$from" "$from")
[[ -z $o ]] || fail "$(oneline "$o") in $from name $from, and the build reads them (only $MK is rewritten); nothing was changed"
while IFS= read -r n; do
    [[ -z $n ]] || echo "note: $n names $from; left as it is (the build doesn't read it)"
done <<<"$(notes_naming "$from" "$from")"
need=$(need_bytes "$from")
[[ $(free_bytes "$HOME") -ge $need ]] || fail "~ has $(gib "$(free_bytes "$HOME")") free, the two backups need $(gib "$need"); nothing was changed"
echo "OK: $from is a folder of the tree's own, $to isn't there, $(gib "$(free_bytes "$HOME")") free in ~"

# 1, 2: the files and their sha256, then the first backup, checked against them
py list "$top" "$from" "$OLD" "$NEW" > "$work/before.txt" 2> "$work/err" || fail "$(err1) (in $from); nothing was changed"
echo "== $from, before: $(awk -F'\t' '$1 == "f"' "$work/before.txt" | wc -l) files, $(awk -F'\t' '$1 == "l"' "$work/before.txt" | wc -l) links (type, mode, size, sha256, name)"
show_list "$work/before.txt"
[[ ! -s $work/err ]] || cat -- "$work/err"   # its notes: the links out of the folder
cp -p -- "$top/$from/$MK" "$work/keys.mk.before"
[[ $(sha256sum < "$work/keys.mk.before" | cut -d' ' -f1) = "$(awk -F'\t' -v m="$MK" '$5 == m { print $4 }' "$work/before.txt")" ]] \
    || fail "$MK changed while it was read; nothing was changed"
lines=$(py plan "$work/keys.mk.before" "$from" "$to" - 2> "$work/err") || fail "$MK can't be rewritten: $(err1); nothing was changed"
[[ ! -s $work/err ]] || cat -- "$work/err"
echo "OK: $MK names $from on lines $lines, which become $to"
backup "$from" "$work/before.txt" bak1

# 3 and 4 ignore INT, TERM, HUP and PIPE, and so does what they start: a cancelled job stops
# before the rename or after keys.mk's, never between them with a helper still writing
trap '' INT TERM HUP PIPE

# 3: the move, a rename on the same file system
id_before=$(stat -c %d:%i -- "$top/$from")
mv -n -T -- "$top/$from" "$top/$to" || fail "mv $from $to failed (the backup $bak1 has the folder)"
[[ ! -e $top/$from && ! -L $top/$from ]] || fail "mv left $from in place (the backup $bak1 has it)"
moved=$top/$to
[[ -d $top/$to && ! -L $top/$to ]] || fail "$to isn't a folder after mv (the backup $bak1 has it)"
[[ $(stat -c %d:%i -- "$top/$to") = "$id_before" ]] || fail "$to isn't the same folder (inode) as $from was: mv copied it (the backup $bak1 has the originals)"
echo "OK: moved $from to $to (the same folder, renamed)"

# 4: keys.mk's paths: the new one written beside it (a new file, keys.mk's mode), then renamed over it
tmpmk=$top/$to/$TMPMK
py plan "$top/$to/$MK" "$from" "$to" "$tmpmk" > /dev/null 2> "$work/err" \
    || fail "can't write the new $MK ($(err1)); $to/$MK still names $from: eos-keys-move.sh $( [[ $mode = move ]] && echo revert || echo move ) puts the folder back"
mv -f -T -- "$tmpmk" "$top/$to/$MK"
tmpmk=''
stop_on_signals
echo "OK: $to/$MK rewritten (lines $lines)"

# 5: nothing else changed, and keys.mk only on those lines
py list "$top" "$to" "$OLD" "$NEW" > "$work/after.txt" 2> "$work/err" || fail "$(err1) (in $to, after the move)"
n=$(py same-but-mk "$work/before.txt" "$work/after.txt" "$MK" 2> "$work/err") || fail "the folder isn't what it was before the move: $(err1). Restore it from $bak1 (README.md, \"Keys\")"
echo "OK: all $n entries as before (type, mode, size, sha256), $MK aside"
tar -xzOf "$bak1" "$MK" > "$work/keys.mk.backup" 2>/dev/null || fail "can't read $MK back from $bak1"
d=$(py mk-diff "$work/keys.mk.backup" "$top/$to/$MK" "$from" "$to" 2> "$work/err") || fail "$to/$MK isn't the backup's with only the folder's path rewritten: $(err1)"
echo "OK: $to/$MK differs from the backup's only on lines $d, the ones that named $from"

# 6: the second backup, of the folder as it is now
backup "$to" "$work/after.txt" bak2
# The tree's sources read one name only: 1.1's vendor/lineage the new one, 1.0's the old one
if grep -qsF "$from/keys/keys.mk" "$top"/vendor/lineage/config/*.mk; then
    echo "note: vendor/lineage's config still includes $from/keys/keys.mk: the next build needs the sources that read $to ($( [[ $mode = move ]] && echo "1.1's: the manifest bump, then expressiveos-setup" || echo "1.0's: the manifest revert, then expressiveos-setup" )) first"
fi
done=1
echo "KEYS_MOVE=OK ($mode: $from -> $to, $(( $(awk -F'\t' '$1 == "f"' "$work/after.txt" | wc -l) - 1 )) files byte-identical and $MK's paths rewritten; backups ${bak1/#"$HOME"/\~} (before) and ${bak2/#"$HOME"/\~} (after))"
