Roadmap
=======

The order is chosen so each step is verifiable on its own. A step is done
when the check beside it passes, not when the code is written.

| # | step | done when |
|---|---|---|
| 1 | OS shim and DIO layer | both compile against real kernel headers, controls fail. **done** |
| 2 | Carried core files import | the whole core compiles as a module against the shim |
| 3 | First module build and load | `insmod` succeeds and `rmmod` leaves nothing behind |
| 4 | Read-only mount | a volume written by DragonFly `newfs_hammer2` mounts read-only and `ls -lR` matches |
| 5 | Read path | file contents, symlinks, directory iteration and stat match the source volume byte for byte |
| 6 | fsck and utils | [hammer2-utils](https://github.com/kusumi/hammer2-utils) drives this volume on Linux |
| 7 | Write path | a volume written here mounts and verifies on DragonFly |
| 8 | Compression, dedup, snapshots | each verified round trip against DragonFly |

Steps 4 and 7 are the two that matter, and they are deliberately
symmetrical: a port that only reads its own writes has proved nothing. The
cross-implementation round trip is the acceptance test, because HAMMER2's
XXH64 block checks make a subtly wrong implementation look like corruption
rather than like a bug.

There is no schedule attached to any of this.
