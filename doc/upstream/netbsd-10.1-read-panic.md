# NetBSD port: reading a file's data panics or wedges NetBSD 10.1

A draft for Kusumi's NetBSD tree, staged here for James to file. Every
claim below is one this repository can show; the measurements are in
`/mnt/storage/hammer2-fixtures/netbsd-port-failure.txt` and
`netbsd-port-read.txt` on the workstation that took them.

## What was run

- Port: `netbsd-hammer2` at `64095c3947f246f3eb6a8d7341ba856e057b6a6c`,
  tagged v1.2.13, unmodified.
- Host: NetBSD 10.1 GENERIC amd64 in a libvirt guest, 4 GB, 4 vCPU.
- Build: gcc, `-Werror`, exit 0, no warnings. The module Makefile needs
  `syssrc.tgz` and `usr/src/sbin/mount` from `src.tgz`, both 10.1.
- Media: seven HAMMER2 images, four written by Kusumi's `makefs` and
  three by DragonFly 6.4-RELEASE's own kernel, attached read-only.

`modload` succeeds, every image mounts read-only, `ls -l` and `stat`
return every entry with the sizes and block counts the FreeBSD and
OpenBSD ports report for the same images.

## What fails

Reading file data. Four runs, four failures, two shapes.

The minimal reproducer, on the DragonFly-written image whose files were
written after `hammer2 setcomp zlib` on the mount root:

    mount -o ro /dev/ld6d@DFLY2 /mnt/f6     # OK
    ls -l /mnt/f6                           # OK, 7 entries
    stat -f "%N %z %b" /mnt/f6/*            # OK, every size and block count
    cat /mnt/f6/tiny.txt                    # OK, 3 bytes, embedded in the inode
    md5 -q /mnt/f6/compressible.txt         # wedge: 176000 bytes in 6 blocks

The wedge is whole-machine: no console, no ddb on the break sequence,
all four vCPUs accumulating time at wall-clock rate, recoverable only by
destroying the guest.

The other shape is a panic with the same backtrace on two runs:

    fatal page fault in supervisor mode
    trap type 6 code 0x10 rip 0 cs 0x8 rflags 0x10282 cr2 0
    panic: trap
    VOP_STRATEGY() at netbsd:VOP_STRATEGY+0x3c
    bio_doread() at netbsd:bio_doread+0x92
    bread() at netbsd:bread+0x18
    VOP_READ() at netbsd:VOP_READ+0x42
    vn_read() at netbsd:vn_read+0x18e
    dofileread() at netbsd:dofileread+0x79
    sys_read() at netbsd:sys_read+0x49
    syscall() at netbsd:syscall+0x1fc

`rip 0` with `cr2 0` is a call through a NULL function pointer, reached
from `VOP_STRATEGY` on a hammer2 vnode inside `bread()`, which is where
`hammer2_read_file()` fetches each logical block. Crash dumps are in
`/var/crash` on the guest.

## What is ruled out

- The media. Kusumi's FreeBSD port at `3df307f7` on FreeBSD 15.1 and his
  OpenBSD port at `a3747df9` on OpenBSD 7.9 read every file of every
  image, including `compressible.txt` on that image, and agree with each
  other and with DragonFly's own checksums on all of it.
- One fixture. Run A panicked in the fourth image, run C with that image
  skipped panicked in the sixth, run D wedged on the sixth alone.
- The already-fixed zlib panic. `CHANGES` records "Fix zlib panic" at
  v1.2.9; this is v1.2.13.

## What is not ruled out

The file the minimal reproducer wedges on is a ZLIB-compressed one, and
the same port read an LZ4-compressed `compressible.txt` on the sibling
image immediately before, which points at `hammer2_decompress_ZLIB_callback()`
over `net/zlib.h`'s `inflateInit2()` and `inflate(Z_FINISH)`. It is a
lead and not a finding: a `makefs`-written LZ4 image also failed in run
A while its byte-identical sibling read clean in two runs, and no codec
theory explains that. The runs isolated the file, not the code path.

## Versions

The port's last commit is v1.2.13 on 2025-08-22, and its tree names no
NetBSD version. NetBSD 10.1 shipped in December 2024 and NetBSD 11.0 on
2026-07-30, so 10.1 is the newest release the port could have been
written against and the one used here. The repository has issues
disabled, so nothing is recorded there as known.

## What would help settle it

A read of the same three DragonFly-written images on the NetBSD version
the port targets, if 10.1 is past it, and a run with `DIAGNOSTIC` and
`LOCKDEBUG`, which the GENERIC kernel used here does not carry. The
images are 2 GiB raw files and can be provided.
