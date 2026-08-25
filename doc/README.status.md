Status
======

Nothing mounts yet. This is the state as of the initial import, and it is
the file to correct rather than to argue with: if a claim here is stale, it
is a defect.

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1315 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1198 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_io.c` | 899 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 471 | ours, the OS shim |
| `hammer2_compat.h` | 112 | ours, kernel look-alikes |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

`script/test-shim.sh` and `script/test-syntax.sh` both pass, 8 checks, of
which 2 are controls that must fail and do. That means the shim is valid C
in both knob positions, and that `hammer2.h` and `hammer2_io.c` type-check
against the real kernel headers of a 7.2 tree with clang 22.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, and no module has been built or loaded. There is no VFS layer, no
mount path and no fsck integration, so there is nothing to run yet.

## What is not here

Every remaining core file: `hammer2_chain.c`, `hammer2_flush.c`,
`hammer2_freemap.c`, `hammer2_inode.c`, `hammer2_subr.c`, `hammer2_xops.c`,
`hammer2_admin.c`, `hammer2_bulkfree.c`, `hammer2_cluster.c`,
`hammer2_ondisk.c`, `hammer2_strategy.c`, `hammer2_ioctl.c`,
`hammer2_vfsops.c`, `hammer2_vnops.c`, plus the check algorithms. The
first eight of those are expected to carry with few or no edits; the last
four are the OS-facing ones and are rewrites.
