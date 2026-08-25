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
core is carried unchanged, and an OS shim makes it compile. Same file
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

## Requirements

+ Linux 6.15 or newer, and developed against 7.2

+ kernel headers for the running kernel

+ `CONFIG_TRANSPARENT_HUGEPAGE`, without which the block layer caps the
  block size below HAMMER2's 64KB physical buffer

+ userland from [hammer2-utils](https://github.com/kusumi/hammer2-utils),
  which already supports Linux

## Build

        $ cd linux_hammer2
        $ make

## Install

        $ cd linux_hammer2
        $ make install

## Uninstall

        $ cd linux_hammer2
        $ make uninstall

## Test

        $ bash script/test-shim.sh        # needs only a C compiler
        $ bash script/test-syntax.sh      # needs kernel headers and clang
        $ bash script/test-checkpatch.sh  # needs scripts/checkpatch.pl

Each gate carries a control that must fail, because a check whose healthy
signature is silence cannot otherwise be told from a check that never ran.
Exit 2 means the instrument could not run, which is not a verdict on the
code. [doc/README.testing.md](doc/README.testing.md) has the detail.

## Documentation

| | |
|---|---|
| [doc/README.status.md](doc/README.status.md) | what exists, what is verified, what is missing |
| [doc/README.roadmap.md](doc/README.roadmap.md) | the order, with the check that ends each step |
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
