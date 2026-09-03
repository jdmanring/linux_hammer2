Linux [HAMMER2](https://gitweb.dragonflybsd.org/dragonfly.git/blob/HEAD:/sys/vfs/hammer2/DESIGN)
========

[![CI](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml/badge.svg)](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](COPYRIGHT)
[![Status](https://img.shields.io/badge/status-does%20not%20mount%20yet-red.svg)](doc/README.status.md)
[![Kernel](https://img.shields.io/badge/linux-6.15%2B-informational.svg)](doc/README.status.md)

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

**It does not mount anything yet.** See
[doc/README.status.md](doc/README.status.md) for exactly what exists and
what has been verified, and [doc/README.roadmap.md](doc/README.roadmap.md)
for the order the rest lands in. There is no schedule attached to any of
it.

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

+ Linux 6.15 or newer. That is the floor the code requires, enforced by an
  `#error`. The kernel it is DEVELOPED against is the latest release, and
  `script/test-syntax.sh` refuses to report a pass against anything else;
  the pin is `KERNEL_REF` in that script and moves when a release ships

+ kernel headers for the running kernel

+ `CONFIG_TRANSPARENT_HUGEPAGE`, without which the block layer caps the
  block size below HAMMER2's 64KB physical buffer

+ userland from [hammer2-utils](https://github.com/kusumi/hammer2-utils),
  which already supports Linux

## Build

        $ cd linux_hammer2
        $ make

`make` builds against `/lib/modules/$(uname -r)/build`. Point `KDIR` at a
different tree when the running kernel is not the one you mean to build
for, which is the usual case on a development machine:

        $ make KDIR=/path/to/linux-7.2/build

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

Sight gates. The compile gates need a toolchain and a kernel tree:

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
        $ bash script/test-doc-prose.sh   # vale over doc/, ArtNix's styles

`test-provenance.sh` is the one of those five that asks a question this
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
construct in such a script breaks only when something honours the shebang:

        $ bash script/test-posix.sh

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
stage.

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
