Linux [HAMMER2](https://gitweb.dragonflybsd.org/dragonfly.git/blob/HEAD:/sys/vfs/hammer2/DESIGN)
========

A port of DragonFly BSD's HAMMER2 file system to the Linux kernel, in the
shape of Tomohiro Kusumi's [FreeBSD](https://github.com/kusumi/freebsd_hammer2),
[NetBSD](https://github.com/kusumi/netbsd_hammer2) and
[OpenBSD](https://github.com/kusumi/openbsd_hammer2) ports: the DragonFly
core is carried unchanged and an OS shim makes it compile.

**This does not mount anything yet.** See [doc/README.status.md](doc/README.status.md)
for what exists, and [doc/README.roadmap.md](doc/README.roadmap.md) for the
order the rest lands in.

## Requirements

+ Linux 6.12 or newer

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

        $ bash script/test-shim.sh
        $ bash script/test-syntax.sh

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Questions, corrections and review
of the port decisions are as welcome as patches, and more useful at this
stage.
