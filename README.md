Linux [HAMMER2](https://gitweb.dragonflybsd.org/dragonfly.git/blob/HEAD:/sys/vfs/hammer2/DESIGN)
========

[![CI](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml/badge.svg)](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](COPYRIGHT)
[![Status](https://img.shields.io/badge/status-0.7%2C%20unreleased-yellow.svg)](doc/README.status.md)
[![Kernel](https://img.shields.io/badge/linux-7.3%2B-informational.svg)](doc/README.status.md)

A port of DragonFly BSD's HAMMER2 file system to the Linux kernel.

HAMMER2 is Matthew Dillon's copy-on-write filesystem for DragonFly BSD:
snapshots, transparent compression, block-level deduplication, an
integrity check on every block, and a design that has been in production
use for a decade. Tomohiro Kusumi has since ported it to
[FreeBSD](https://github.com/kusumi/freebsd_hammer2),
[NetBSD](https://github.com/kusumi/netbsd_hammer2) and
[OpenBSD](https://github.com/kusumi/openbsd_hammer2), and written the
Linux userland ([hammer2-utils](https://github.com/kusumi/hammer2-utils),
[hammer2-fuse](https://github.com/kusumi/hammer2-fuse)). The kernel side on
Linux is the piece that has been missing.

This is that piece, built the way his three ports are built: the DragonFly
core is carried and kept readable as DragonFly's, with every port edit
marked in place, and an OS shim makes it compile. Same file
names, same shim split, same section order, so a fix found here is legible
to the other three and can travel.

It mounts a HAMMER2 volume read-write, lists it, reads it, follows its
symlinks, writes to it, takes snapshots of it, and refuses media whose
checksums do not match. Files on it can be mapped and executed, so a
volume can be a root filesystem, and one has booted as one: a static
init on an otherwise empty volume, once, on a guest.

At a glance, on a kernel of 7.3 or newer:

+ works: mount read-write by PFS label, read, write, mmap and exec,
  snapshots, PFS create, delete and list through `hammer2-utils`,
  LZ4 and ZLIB media, crash recovery to the same tree as the FreeBSD port
+ works with a caution: a volume filled to capacity refuses the fill and
  keeps every accepted file whole, after four defects in that path were
  found and fixed; read the paragraph on it below before trying it. A
  real Nix closure of two hundred thousand files copies in and reads
  back identical beside squashfs and erofs on an 8 GiB guest; at 4 GiB
  a handful of writes are refused for want of a 64 KiB folio, and
  `doc/IO_MODEL.md` has why
+ not yet: a package, a tag, a kernel below 7.3, a backend adapter behind
  the snapshots, and any write to media that is not a scratch image

Every write operation has been run on scratch media and read back by
DragonFly, in both directions of a round trip, and the crash matrix, a
writer killed, a kernel panicked, the power cut and a volume header
torn, leaves media that this port and the FreeBSD port both recover to
the same tree. `find` walks the whole tree and every file compares byte
for byte against the tree it was made from, at 511 bytes, at 512, at one
page, at one 64 KiB block and at 200 KB, on images written with LZ4 and
with ZLIB compression, and on media created and written by DragonFly
itself.

Nothing is released: no tag exists, and the media it has written to are
scratch copies on a guest. To try a point that has been through the
fleet, take the newest row of [CHANGELOG.md](CHANGELOG.md): every row
pins the commits that delivered it and names the runs that verified
them, which is what a tag would say. See
[doc/README.status.md](doc/README.status.md) for exactly what exists and
what has been verified, and [doc/README.roadmap.md](doc/README.roadmap.md)
for the order the rest lands in. There is no schedule attached to any of
it.

## Where it stands

The version is a position on the roadmap, not a release. The first two
numbers name the milestone reached, the third counts point releases
inside it, and until 1.0 the number says nothing about stability.
[CHANGELOG.md](CHANGELOG.md) carries the current number and pins every
release to the commits that delivered it and the runs that verified it.
0.6 was crash recovery: a writer killed, the kernel panicked, the power
cut and a volume header torn, each twice, on media this port wrote and
on media the FreeBSD port wrote, with both ports recovering every image
to the same tree and `fsck_hammer2` clean afterwards.

0.7 is HAMMER2's ioctl surface, reachable as Linux ioctls, which is what
makes `hammer2-utils` work against this driver: snapshot create, PFS
create, delete, list and lookup, inode and volume queries, growfs and
bulkfree. A snapshot this port takes mounts on DragonFly and reads back
the tree as it stood. The rows for both milestones in
[CHANGELOG.md](CHANGELOG.md) pin the commits and the runs.

One thing to know before trying it: **be careful about filling a HAMMER2
volume to capacity.** A volume with no space left reports the failure
correctly, and two defects behind that have been fixed. The `sync` that
follows a fill used to trip a circular lock dependency, and unmounting a
filled volume used to take a page fault in the flush, on a PFS the
teardown had just released, which killed the unmount and left the module
impossible to unload.

The reproducer then grew a check nothing had done: hash every file
as written and compare the media afterwards. A volume allowed to fill
to its last block had lost nearly the whole fill, two files of five
hundred reading back whole with both checkers clean, because HAMMER2
needs free space for the flush that commits a fill and every tree this
port carries from keeps a reserve for it through a check this port had
declared and never carried. The check is carried now, with the page
cache's dirty pages counted against the reserve, and a fill is refused
with every accepted file whole on the media. A held lock freed during a
fill, seen twice and unexplained for a day, was captured whole once the
log was kept and fixed the same hour.

The reproducer is `script/test-enospc.sh`, a gate since it passed ten runs, and the account, wrong turns
included, is in [doc/README.status.md](doc/README.status.md).

What that buys you is a driver that can be tried, on media you can
afford to lose. What it does not yet do: the snapshots have no backend
adapter behind them, which keeps 0.7 open; nothing is packaged, and no
tag exists. It has booted as a root filesystem once, with a static init
and nothing else on the volume, which is a long way from a
distribution. Every write it has made was to a scratch image on a
guest.

To try it, make an image, put it on a loop device and mount the PFS by
label. `newfs_hammer2` is in hammer2-utils, and a mount that names no
PFS asks for `DATA`:

        $ make && sudo make install
        $ sudo modprobe hammer2
        $ truncate -s 8G scratch.img
        $ newfs_hammer2 -L TEST scratch.img
        $ sudo losetup -f --show scratch.img
        $ sudo mount -t hammer2 /dev/loop0@TEST /mnt

`losetup` prints the device it chose; `/dev/loop0` above is that device.
`modprobe` rather than `insmod`, because the codecs and the digest may
be modules on your kernel and only `modprobe` loads them first.

Add `-o ro` to read without writing; `mount -o remount,rw` goes the
other way and runs the flush recovery on the transition, refusing only
when the device itself is write-protected. A volume DragonFly made
mounts the same way.

`hammer2-utils` drives the ioctls once a PFS is mounted:

        $ sudo hammer2 -s /mnt pfs-list
        $ sudo hammer2 -s /mnt snapshot /mnt before-upgrade
        $ sudo hammer2 -s /mnt pfs-delete before-upgrade

Give `-s <mount>` before the subcommand, which is not optional here even
though it is on the BSDs. Without it the utility looks the mount up
through `libfs`, whose Linux build reports no mounted filesystems at
all, so anything that routes by mount reports the PFS as not found.
That is a defect in the utility rather than in this driver, and
`doc/upstream/libfs-linux-get_mnt_info.md` is the report against it. The kernel log carries every refusal by name, and a report of
anything the driver does that DragonFly would not, with the image if you
can share it, is the most useful thing a tester can send: the
[issue tracker](https://github.com/jdmanring/linux_hammer2/issues) is
open, and `doc/README.status.md` says what has already been measured so
you can see whether your case is new.

If you have ported this filesystem before, or maintain one of the trees it
comes from, the most useful thing you can do is tell us a port decision is
wrong. They are listed with their reasoning in
[doc/README.porting.md](doc/README.porting.md), and several are
load-bearing.

## Why a kernel module, when hammer2-fuse exists

[hammer2-fuse](https://github.com/kusumi/hammer2-fuse) already reads
HAMMER2 on Linux in userspace, and for inspecting a volume it is the
easier answer. A kernel driver buys three things FUSE cannot: the page
cache holds the filesystem's own buffers rather than copying through a
userspace daemon, the volume can be a root filesystem, and the write path
can order its flushes against the block layer directly, which is what a
copy-on-write filesystem's crash consistency depends on.

Neither replaces the other. They are independent implementations, not two
front ends on one core: hammer2-fuse is Rust over `libhammer2`, this port
is C carried from DragonFly. That independence is what makes hammer2-fuse
a useful cross-check - a second reader sharing no code with this one, so
agreement between the two says something about the on-disk format rather
than about a shared bug.

## Requirements

+ Linux 7.3 or newer, enforced by an `#error`. The floor is the kernel
  the port is developed and tested against, one tree: `script/test-syntax.sh`
  refuses to report a pass against anything else, the pin is `KERNEL_REF`
  in that script, and both move together when a release ships. There is
  no conditional compilation on the kernel version in the tree. Two
  things put it at 7.3, both from that release's VFS changes: the
  shared block device open that lets several PFSes on one device be
  mounted, and the `create` operation's signature. A build against 7.2
  fails on exactly those, recorded in `doc/README.status.md`. Older
  kernels are not blocked by anything deeper: measured from below, 6.18
  would need two compatibility conditionals and 6.15 is where the block
  layer first holds a 64 KiB folio. The decision is to stay on the kernel
  of record until 1.0 and then consider 6.18 alone, the one longterm
  kernel in that range; `doc/README.roadmap.md` records it

+ kernel headers for the running kernel

+ `CONFIG_TRANSPARENT_HUGEPAGE`, without which the block layer caps the
  block size below HAMMER2's 64KB physical buffer

+ `CONFIG_LZ4_COMPRESS`, `CONFIG_LZ4_DECOMPRESS`, `CONFIG_ZLIB_DEFLATE`,
  `CONFIG_ZLIB_INFLATE` and `CONFIG_XXHASH`, built in or as modules: the
  codecs HAMMER2 compresses and decompresses with and the digest in every
  blockref. Distribution kernels carry all five; a `defconfig` leaves the
  LZ4 compressor out, and the build names the missing one

+ userland from [hammer2-utils](https://github.com/kusumi/hammer2-utils),
  which already supports Linux

## Build

        $ cd linux_hammer2
        $ make

`make` builds against `/lib/modules/$(uname -r)/build`. Point `KDIR` at a
different tree when the running kernel is not the one you mean to build
for, which is the usual case on a development machine:

        $ make KDIR=/path/to/linux-7.3/build

Three build knobs, the same three the FreeBSD and NetBSD ports carry:
`HAMMER2_INVARIANTS` turns on `KKASSERT` and `KASSERTMSG`,
`HAMMER2_MALLOC` turns on the allocation leak counters, and
`HAMMER2_ATIME` turns on atime updates. Pass them on the `make` line.

## Install

        $ cd linux_hammer2
        $ make install

## Uninstall

        $ cd linux_hammer2
        $ make uninstall

## Test

Thirteen gates. The compile gates need a toolchain and a kernel tree:

        $ bash script/test-shim.sh        # needs only a C compiler
        $ bash script/test-syntax.sh      # needs kernel headers and clang
        $ bash script/test-checkpatch.sh  # needs scripts/checkpatch.pl

The repository gates check the documentation against the tree. They are
POSIX sh over grep, sed and git, so they run anywhere:

        $ bash script/test-inventory.sh   # the lists that claim to cover src/ and test/
        $ bash script/test-citations.sh   # every file:line citation in doc/
        $ bash script/test-history.sh     # every roadmap row's commit hash
        $ bash script/test-provenance.sh  # every file under src/ has an origin row
        $ bash script/test-absence.sh     # every "X() is not carried" resolves against src/
        $ bash script/test-doc-prose.sh   # vale over doc/, Saxum's styles

`test-provenance.sh` is the one of those six that asks a question this
repository cannot answer alone: a row claiming a byte-for-byte carry is
re-run with `cmp` against the origin clone, and where that clone is not on
the machine it reports COULD-NOT-RUN rather than passing on a table that
only agrees with itself.

One is neither. `script/test-vectors-contract.sh` freezes the output and
the constant spelling of the two files in `test/` that a gate in another
repository compiles, so an edit that breaks that consumer fails here
rather than there:

        $ bash script/test-vectors-contract.sh

And one parses the gates that declare `#!/bin/sh` with shells that are not
bash, because every gate here is normally run by bash and a bash-only
construct in such a script breaks only when something honors the shebang:

        $ bash script/test-posix.sh

Two need a guest, and exit 2 without one:

        $ bash script/test-fixtures.sh    # mounts every fixture on a guest and compares manifests
        $ bash script/test-enospc.sh      # fills a volume, checks what it kept and what each writer was told

No gate here is trusted on silence alone, because a check whose healthy
signature is silence cannot otherwise be told from a check that never ran.
How that is bought differs by gate, and they are not interchangeable:
`test-shim.sh` and `test-syntax.sh` carry built-in controls that must fail
on every run, `test-checkpatch.sh` compares against a recorded deviation
set rather than asking for silence, and each repository gate asserts the
population it searched before checking anything, so a glob that matches
nothing cannot report a clean run.

Exit 2 means the instrument could not run, which is not a verdict on the
code. [doc/README.testing.md](doc/README.testing.md) has the detail,
including what each gate cannot catch.

## Documentation

| | |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | every point release, pinned to its commit and its verifying gate |
| [doc/README.status.md](doc/README.status.md) | what exists, what is verified, what is missing |
| [doc/README.roadmap.md](doc/README.roadmap.md) | the order, with the check that ends each step |
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | the layering, the shim boundary, the object and locking model |
| [doc/IO_MODEL.md](doc/IO_MODEL.md) | the DIO layer, and which 64 KiB assumptions are format and which are ours |
| [doc/README.porting.md](doc/README.porting.md) | every port decision and why |
| [doc/README.testing.md](doc/README.testing.md) | what the gates prove and what they cannot |
| [doc/README.kernel-style.md](doc/README.kernel-style.md) | licensing, and the path to mainline |

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md). Questions, corrections and review of
the port decisions are as welcome as patches, and more useful at this
stage. The most useful test right now is the one above on a
distribution kernel at 7.3 or newer, with the kernel log from the
mount and from any refusal, since every run so far has been on one
maintainer's guests.

## Credit

**Matthew Dillon** designed and wrote HAMMER2 for DragonFly BSD. The
format, the algorithms and the core carried here are his.

**Tomohiro Kusumi** wrote the FreeBSD, NetBSD and OpenBSD kernel ports and
the entire Linux userland. This port is his method applied a fourth time,
and it borrows more than the method: the repository layout, the
`hammer2_os.h` / `hammer2_compat.h` split and its section order, the make
knobs, the `XXX` convention at non-mechanical mappings, and the
`<os>_hammer2` name. Where a port decision had a precedent in one of his
three trees, that precedent was followed and
[doc/README.porting.md](doc/README.porting.md) says which tree.

The work here is the Linux OS layer and the gates around it.

## License

BSD-3-Clause, matching DragonFly and the BSD ports, and listed in the
Linux kernel's own `LICENSES/preferred/`. See [COPYRIGHT](COPYRIGHT).
