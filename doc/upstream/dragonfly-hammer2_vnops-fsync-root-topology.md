# DragonFly: a file fsync'ed on HAMMER2 is lost across a power cut

An observation for DragonFly, staged here until it is sent. It is not a
patch: DragonFly's `hammer2_vop_fsync()` says what it does, and what
follows is what that costs a program that relies on `fsync(2)`, measured
on DragonFly's own kernel.

## What upstream's code says

`hammer2_vop_fsync()` syncs the inode's front-end state to its chains and
flushes the inode's chain with `HAMMER2_XOP_INODE_STOP` alone. Its comment
reads "This function does not flush the root topology down to the inode",
and a note inside it, "We are not in a flush transaction. The inode
remains on the sideq so the filesystem syncer can synchronize it to the
volume root." Nothing the volume header points at reaches the new blocks
until the next filesystem sync, which the syncer runs every thirty
seconds.

## What was run

DragonFly 6.4.2 in a libvirt guest, its own kernel and its own HAMMER2, on
a copy of a volume this port's fixture set carries. Five rounds; in each
the guest mounts the copy and writes three files, each beginning with the
round number:

- `s`, a line, then `sync(2)`: the control, which must survive;
- `n`, a line left in the page cache: the control that the cut loses
  what was not written;
- `f`, one 4 KiB block written by a small C program that calls `fsync(2)`
  and prints `acked` only once it returns 0.

The host destroys the guest the moment it reads `acked`. The image is a
raw file on the host, so every write the guest completed is kept and only
what the guest still held is lost. The guest then boots on the image and
reads the three files.

Result, all five rounds: `s` present with its round number, `n` absent,
`f` absent. The volume header's `mirror_tid` is the same before and after
the `fsync`. The probe is `dfly-fsync-probe.sh`, kept with its output
`dfly-fsync-probe-20261116.out` in the port's working notes outside this
repository (`linux_hammer2-data/p7-notes/crash-instrument/`).

## Where it stands against upstream

Checked on 2026-11-16. Upstream's head, `master` at `b4111474907e`, read
through the forge API rather than the local clone, which is shallow:
`sys/vfs/hammer2/hammer2_vnops.c` has the same comment (its line 211) and
the same `HAMMER2_XOP_INODE_STOP` flush (its line 257). The three BSD
ports at `v1.2.13` carry the same body. DragonFly's tracker refuses
automated fetches behind a proof of work and was not searched for this,
so it is not claimed to be unreported.

## What the Linux port did, and why it is a port decision

Linux defines `fsync(2)` as durable on return, and programs that save by
write, rename and `fsync` depend on it. The port's `fsync` therefore runs
the PFS sync after upstream's flush, the same commit its `->sync_fs` runs,
calling the carried `hammer2_vfs_sync_pmp()` without changing it
(`doc/README.porting.md`, "fsync commits the PFS"). On DragonFly the
syncer's window is upstream's design, and nothing here says it is wrong
for DragonFly; the note exists so the cost of that window is on record
with a reproducer.

Dillon's own design notes describe a faster route to the same place,
deep blockref updates short-cut into auxiliary space in the volume header
(`doc/DESIGN.md`). The current volume header has no such table, so that
route is a format change and is not what the port built.
