#!/usr/bin/env python3
"""What cheetah-ksu.sh and ksu-check.sh compare between our kernelsu.ko and Google's
kernel. kernelsu.ko carries no symbol versions (ksuinit resolves its symbols itself), so
Linux 6.1 loads it even when it was built for another struct module, and then crashes
reading past it: the first ExpressiveOS build (2026-10-26), built without pahole, lost
CONFIG_DEBUG_INFO_BTF_MODULES and shipped a 1,024-byte struct module to a kernel whose
struct module is 1,088 bytes. Run it with python3 -I.

  ko-info.py this-module <ko>...
      prints "<bytes> <ko>" for each module: the size of its .gnu.linkonce.this_module
      section, which is the struct module it was built for
  ko-info.py same-struct <ko> <dir>
      checks that <ko> is built for the struct module that every module under <dir> (the
      build's own, made with the kernel's config) shares; prints "<bytes> <modules>"
  ko-info.py embedded <file> <module name> <kernel release prefix> <out.ko>
      writes out the arm64 kernel module <file> carries inside it, DEFLATE-compressed, whose
      .modinfo names <module name> and whose vermagic starts with <kernel release prefix>:
      libksud.so's susfs guard module, which ksud loads by itself (susfs load or auto-load),
      or one of the modules the host ksud carries (it has an x86_64 build of each too),
      found the way rust-embed stores its assets; prints "<bytes> <vermagic>"
  ko-info.py config <kernel Image>
      prints the .config built into an uncompressed kernel image (CONFIG_IKCONFIG)
  ko-info.py config-diff <kernel Image> <.config>
      prints each option the module's .config sets differently from the kernel's own,
      leaving out the few that only describe Google's build host (IGNORED); exits 1 if
      there are any
"""
import os
import struct
import sys
import zlib

# Not compared: version numbers of the tools (each feature they decide has its own
# option, which is compared); whether the compiler can link user programs, which only
# Google's build sysroot can and which only gates the UAPI header test; and the export
# trimming of Google's own build (it keeps only the exports its symbol lists name; ksuinit
# resolves kernelsu.ko's symbols itself). Measured on 2026-10-26: these were the only
# differences besides the pahole ones that broke the module.
IGNORED = {
    'CC_VERSION_TEXT', 'CLANG_VERSION', 'GCC_VERSION', 'LD_VERSION', 'LLD_VERSION', 'AS_VERSION',
    'PAHOLE_VERSION', 'RUSTC_VERSION', 'RUSTC_LLVM_VERSION', 'BINDGEN_VERSION',
    'CC_CAN_LINK', 'CC_CAN_LINK_STATIC', 'UAPI_HEADER_TEST',
    'TRIM_UNUSED_KSYMS', 'UNUSED_KSYMS_WHITELIST',
}


def sections(d):
    """{name: (offset, size)} of a little-endian ELF64 file's sections."""
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        raise ValueError('not a little-endian ELF64 file')
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    if not shoff or shentsize < 64 or shoff + shnum * shentsize > len(d) or shstrndx >= shnum:
        raise ValueError('bad section header table')
    out = {}
    names = struct.unpack_from('<Q', d, shoff + shstrndx * shentsize + 24)[0]
    for i in range(shnum):
        name, _, _, _, offset, size = struct.unpack_from('<IIQQQQ', d, shoff + i * shentsize)
        start = names + name
        out[d[start:d.find(b'\0', start)].decode('ascii', 'replace')] = (offset, size)
    return out


def this_module(path):
    with open(path, 'rb') as f:
        d = f.read()
    s = sections(d).get('.gnu.linkonce.this_module')
    if s is None:
        raise ValueError('no .gnu.linkonce.this_module section (not a kernel module?)')
    return s[1]


def modinfo(d):
    offset, size = sections(d).get('.modinfo', (0, 0))
    return dict(f.split(b'=', 1) for f in d[offset:offset + size].split(b'\0') if b'=' in f)


EM_AARCH64 = 183


def embedded(path, name, release):
    """The arm64 kernel module stored DEFLATE-compressed (raw, as include-flate does) in a file."""
    with open(path, 'rb') as f:
        d = f.read()
    found = []
    for o in range(len(d)):
        if d[o] & 6 not in (2, 4):   # a fixed or dynamic Huffman block starts the stream
            continue
        try:
            if not zlib.decompressobj(-15).decompress(d[o:o + 512], 64).startswith(b'\x7fELF'):
                continue
            ko = zlib.decompressobj(-15).decompress(d[o:])
            if struct.unpack_from('<H', ko, 0x12)[0] != EM_AARCH64:
                continue
            info = modinfo(ko)
        except (zlib.error, ValueError, struct.error):
            continue
        if info.get(b'name') == name.encode() and info.get(b'vermagic', b'').startswith(release.encode()):
            found.append((ko, info[b'vermagic'].decode('ascii', 'replace')))
    if len(found) != 1:
        raise ValueError('%s carries %d arm64 kernel modules named %s for %s*, want 1' % (path, len(found), name, release))
    return found[0]


def same_struct(ko, top):
    sizes = {}
    for root, _, files in os.walk(top):
        for f in sorted(files):
            if f.endswith('.ko'):
                sizes.setdefault(this_module(os.path.join(root, f)), []).append(f)
    if not sizes:
        raise ValueError('no kernel modules under %s' % top)
    if len(sizes) > 1:
        raise ValueError('the modules under %s disagree about struct module: %s' % (
            top, ', '.join('%d bytes (%s, ...)' % (n, fs[0]) for n, fs in sorted(sizes.items()))))
    (want, mods), = sizes.items()
    have = this_module(ko)
    if have != want:
        raise ValueError('%s is built for a %d-byte struct module, the kernel for %d bytes (as its %d modules under %s):'
                         ' the module was built with another kernel config' % (ko, have, want, len(mods), top))
    return want, len(mods)


def ikconfig(path):
    with open(path, 'rb') as f:
        d = f.read()
    start = d.find(b'IKCFG_ST\x1f\x8b\x08')
    if start < 0:
        raise ValueError('no IKCFG_ST config in it (a compressed image, or CONFIG_IKCONFIG off?)')
    try:
        # The gzip stream ends before IKCFG_ED; decompressobj stops at its end
        z = zlib.decompressobj(16 + zlib.MAX_WBITS)
        return z.decompress(d[start + 8:]).decode()
    except (zlib.error, UnicodeDecodeError) as e:
        raise ValueError('its IKCFG_ST config is unreadable: %s' % e)


def options(text):
    opts = {}
    for line in text.splitlines():
        if line.startswith('CONFIG_') and '=' in line:
            name, value = line[7:].split('=', 1)
            opts[name] = value
        elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
            opts[line[9:-11]] = 'n'
    return opts


def main():
    args = sys.argv[1:]
    usage = '\n'.join(l.strip() for l in __doc__.splitlines() if l.strip().startswith('ko-info.py'))
    try:
        if len(args) >= 2 and args[0] == 'this-module':
            for ko in args[1:]:
                print(this_module(ko), ko)
        elif len(args) == 3 and args[0] == 'same-struct':
            print('%d %d' % same_struct(args[1], args[2]))
        elif len(args) == 5 and args[0] == 'embedded':
            ko, vermagic = embedded(args[1], args[2], args[3])
            with open(args[4], 'wb') as f:
                f.write(ko)
            print(len(ko), vermagic)
        elif len(args) == 2 and args[0] == 'config':
            sys.stdout.write(ikconfig(args[1]))
        elif len(args) == 3 and args[0] == 'config-diff':
            kernel = options(ikconfig(args[1]))
            with open(args[2]) as f:
                ours = options(f.read())
            diffs = sorted(n for n in set(kernel) | set(ours)
                           if n not in IGNORED and kernel.get(n, 'n') != ours.get(n, 'n'))
            for n in diffs:
                print('CONFIG_%s: kernel %s, module build %s' % (n, kernel.get(n, 'n'), ours.get(n, 'n')))
            return 1 if diffs else 0
        else:
            sys.exit('usage:\n' + usage)
    except (OSError, ValueError) as e:
        sys.exit('ko-info.py: %s' % e)
    return 0


if __name__ == '__main__':
    sys.exit(main())
