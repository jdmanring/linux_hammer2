# What HAMMER2 on Linux declares

This is the port's own statement of what it provides, for anyone who
builds above it. Each capability is declared at one of six levels
under one rule: the port is never reported as providing a guarantee
it cannot provide. The six levels and the capability names are the
vocabulary of the storage model of the first distribution built on
this port, used here because it is precise; nothing in this tree
depends on that model, and a consumer maps from this table to its
own. Every level below is read off a measurement in
`doc/history/verification-record.md` on the build the row names, and a row moves only
when a measurement moves it. Where a capability is not here, the row
says so and says what a consumer could compose above it.

The levels: native, provided directly with
documented semantics; composed, provided through an explicit lower
layer; emulated, implemented above the backend at a stated weaker
cost; limited, available only under stated constraints; unavailable;
and unsafe, possible but not acceptable for transactional use.

Measured on `artix-s6-kde` at 7.3.0-rc1 against the build the
0.9.0 row of `CHANGELOG.md` pins, unless a row says otherwise. The
kernel of record moved to 7.3.0-rc4 on 2026-09-26 and to 7.3.0-rc5 on
2026-09-29; the rows below still
name rc1 where that is where the measurement was taken, since a reading
records the build it ran on, and a row moves only when a reading moves
it. The writing ioctls are a hand run on 2026-09-05 and not a gate, since the
fixture gate's images are read-only; the fill, the round trip, the
closure and the PFS roots are fleet runs named in `README.testing.md`.

| capability | level | what backs the row | what would move it |
|---|---|---|---|
| Snapshot | native | `HAMMER2IOC_PFS_SNAPSHOT` created `SNAP1`; the live PFS was changed and synced and the snapshot still read the old content, mounted as a filesystem of its own (status, "The ioctls, and a snapshot read back on DragonFly") | nothing; a snapshot is one PFS, see ConcurrentSnapshot |
| WritableSnapshot | native | `pfs-domains.sh` takes a snapshot of a PFS root written here, mounts it read-write by label, changes one file in it and adds another; the live root's file reads unchanged here, and DragonFly checks the snapshot's 22 files against this side's manifest, reads the changed file apart from the live root's and finds the added file absent from the live root (status, "Verified again on `3d364be`") | nothing |
| Clone | native | the same object as WritableSnapshot: the snapshot is a full clone of the PFS root, sharing blocks by copy on write, and the run above is the measurement | nothing |
| Rollback | composed | nothing reverts a PFS in place; a generation rolls back by mounting another PFS by label, which `script/pfs-domains.sh` measures on both sides, and the model's boot contract chooses the label | an in-place revert is not in the format and is not planned |
| DurableCheckpoint | composed | the snapshot ioctl and a `sync`, whose flush writes the volume header last; `script/cut-flush.sh` measured what a cut flush leaves, the newest valid header (status, "A flush cut off, and what each recovery made of it") | nothing |
| AtomicNamespaceSwitch | unavailable | the port switches no mounted namespace; the model composes the switch at boot from mount by label (its section 27.10) | nothing on this side |
| DurableFlush | native | `->fsync` and `->sync_fs` carried over the core's flush, the device flush through `blkdev_issue_flush()`; the order the flush writes in was read from the block layer (status, "The order the flush writes in") | nothing |
| Deduplication | native | on by default and asked by the write path before every data block is allocated; a 4 MiB file written twice cost 64 blocks for the first copy and 2 for the second on a live mount, the data pseudo-random so no zero-elision, and `tmpfs` and `btrfs` both charge a duplicate its full price, which is what makes the reading specific to this port (`doc/history/verification-record.md`, "Deduplication, which was on by default and never run") | nothing; the heuristic table is upstream's |
| DataChecksum | native | XXH64 on every data block, verified on read; one byte changed in a data block was refused naming the check (status, "Media altered on purpose") | nothing |
| SparseRead | native | `SEEK_DATA` and `SEEK_HOLE` answer the whences of `lseek(2)` and `->bmap` is registered, so a tool that asks where the data is gets the offsets the media holds: `test/hammer2-seek.c` runs twelve checks on a live mount and passes them, and the same twelve pass on `tmpfs` and `btrfs` (`doc/history/verification-record.md`, "SEEK_DATA and SEEK_HOLE, and the block count that was not refreshed") | nothing; a hole is an offset no chain covers, which is the format's own answer |
| MetadataChecksum | native | the same check code on every blockref, inode and indirect block; a volume header failing its CRC is not mounted | nothing |
| SelfHealing | unavailable | the inode's `ncopies` field is stored and set through the ioctl and nothing writes a second copy; a failed check is refused, not repaired. The mechanism the copies would use is now carried: a cluster may hold up to `HAMMER2_MAXCLUSTER` chains, `hammer2_cluster_check()` runs DragonFly's quorum passes over them, and `hammer2_xop_alloc()` allocates a FIFO per chain. What is missing is the writer that emits a second blockref for a block, which neither this port nor DragonFly has, the format's own comment reading "Up to 4 copies are supported. Not implemented." The two-chain state itself is reachable: a cluster is formed without `HAMMER2IOC_REMOTE_ADD` or `HAMMER2IOC_RECLUSTER`, by creating a second PFS with the first's cluster id and mounting both volumes' ROOT, which `script/cluster-sync.sh` and `script/cluster-quorum.sh` do | the write side is absent upstream too; the format's comment is DragonFly's, carried unchanged |
| Scrub | limited | offline only: `fsck_hammer2` over the unmounted volume, run after every fleet run on the host and on DragonFly; nothing scrubs a mounted volume | an online walk verifying every check code, which no port has |
| OnlineRepair | unavailable | nothing repairs a mounted volume | as Scrub |
| SpaceAccounting | limited | every `statfs` field checked against its source (status, "What statfs reports"); the free count moves at allocation and at the second bulkfree pass, not at a remove, so a removed file is counted until two passes have run; `script/bulkfree.sh` measured two passes returning a removed 800 MB set to the free count, each pass under a second on a 2G volume (status, "Space a remove does not free") | nothing; this is the format's accounting |
| MetadataAccounting | limited | `f_files` reports the inode count; data and metadata space are one pool, not the two the model's 27.5 asks a transaction to measure separately, and the reserve below is what keeps the flush's metadata allocatable | nothing on this side; the model measures headroom against the one pool |
| Reservation | limited | `hammer2_vfs_enospace()` carried, a twentieth of the volume set at mount, refusing a write, a create, a link, a rename, a remove and a size change under it; `script/test-enospc.sh` is a gate with ten clean fills as root and as a user, every accepted file read back whole (status, "A full volume") | one reserve, not the model's three categories; a reserve per mount would be a mount option, and no consumer has asked for one |
| Quota | unavailable | the inode carries quota fields the ioctl reads and sets, and the core enforces none of them, on DragonFly either | upstream enforcement |
| Compression | native | LZ4 and ZLIB written here and read on DragonFly, written there and read here, block counts and checksums matching both ways (status, "Compressed blocks" and "The same tree written by makefs and by the kernel") | nothing |
| Encryption | unavailable | the format has none | upstream |
| MultiDevice | native | `pfs-domains.sh` with `H2_PFS_VOLUMES=2`: a filesystem formatted across two 1 GiB images, mounted here by the device pair, `volume-list` reporting 2, the first root filled with 1200 MB so the writes cross into the second volume, and DragonFly mounting the same pair, reporting 2 volumes and checking every manifest including the fill with 0 mismatches (status, "Verified again on `3d364be`") | a volume added to a mounted filesystem, which the format allows and neither side has run here |
| FailureDomains | unavailable | one volume, no copies; the chain-and-quorum half is carried as SelfHealing records, and the writer that would place a copy on a second volume is not | as SelfHealing |
| Replication | limited | between devices attached to one host, which is the whole of what upstream's synchronization code does without its message transport. `hammer2_synchro.c` is carried: a SLAVE or soft PFS whose cluster id matches a MASTER on another device gets a thread that copies the master's inodes, directory entries and data onto it every five seconds, and writes what it copied. `script/cluster-sync.sh` measured it on the debug kernel: a MASTER holding 55 files written before the SLAVE existed, then a SLAVE on a second volume, then the master changed with both mounted, files removed, rewritten, added and renamed, and the slave's PFS ended identical to the master's entry for entry and block for block, every check code equal, both volumes clean by `fsck_hammer2`, nothing scrapped at unmount, no warning, lockdep report or kmemleak entry, 22 checks 0 failed on the debug kernel and on the KASAN and UBSAN kernel (`doc/history/verification-record.md`, "The slave's copies were never written" and "A slave kept in step through change"). `script/cluster-quorum.sh` then made the other shape, two MASTERs of one cluster id across two volumes, which is what the quorum code decides for: `pfs_nmasters` is 2, so the quorum is both, and each master element takes a support thread where a lone master takes none. A set written through the cluster's own mount read back by checksum, each volume's media holding all of it, and the two identical entry for entry and block for block, 20 checks 0 failed on the debug kernel and on the KASAN and UBSAN kernel. Within that: the masters are this host's, so the quorum is over local devices; a master that changes while the slave is mounted reaches the slave's media at its unmount, since a mounted PFS's own sync stops at inode boundaries; and a slave that fails to take a chain is retried, where upstream marks it synchronized | a member on another host, which is `kern_dmsg.c` and the `REMOTE` ioctls; and a quorum that cannot be met, a master absent from a cluster whose quorum counts it, which no run here has made |
| IncrementalReplication, RemoteCheckpoint | unavailable | both need a member on another host, and the transport that would reach it, `kern_dmsg.c` and the `HAMMER2IOC_REMOTE_*` ioctls, is carried by none of the three BSD ports and not here. Of the four cluster files, `hammer2_synchro.c` and `hammer2_ccms.c` need no transport and the first is carried, as Replication says. What `kern_dmsg.c` would need is the transport, 2202 lines, and its shape is the kernel's own: the descriptor resolves to a `struct socket` and the calls are `kernel_recvmsg` with `MSG_WAITALL`, `kernel_sendmsg` and `kernel_sock_shutdown`, which is what `ocfs2` and `gfs2` do and what `nbd` and `nfsd` do with a descriptor a daemon passes in |upstream is stalled rather than intending it, and a consumer asking |
| ConcurrentSnapshot | unavailable | one PFS per snapshot ioctl; a set across PFSes is the model's transactionally coordinated class, never its atomic one | nothing on this side; the model's class is the honest claim |
| SnapshotDelete | native | `pfs-delete` removed `SNAP1` and `NEWPFS` in the hand run; the space returns over the next two bulkfree passes | nothing |
| SnapshotRetentionHold | unavailable | the backend keeps no hold; the model's registry does | nothing on this side |
| GC candidates | limited | two bulkfree passes through `HAMMER2IOC_BULKFREE_SCAN` are what free removed blocks, the first staging and the second freeing, and they are a run, not a gate; `script/bulkfree.sh` measured them, 52134 blocks staged by the first and freed by the second | a scheduled pass is the consumer's; the port answers the ioctl |
| Health | limited | the header CRC at mount and the offline checker; no online health reading | an online reading, which no port has |
| NFSExport | native | `export_operations` is registered (`hammer2_export.c`), so `exportfs_may_export()` is true: the table carries `fh_to_dentry`, `fh_to_parent` and `get_parent` and sets no `->open` or `->permission`, which is the whole of that predicate (include/linux/exportfs.h), so `exp_export()` no longer returns `EINVAL` for the type; the handle carries the inode number masked with `HAMMER2_DIRHASH_USERMSK`, DragonFly's `hammer2_vfs_vptofh()` encoding, under the kernel's `FILEID_INO64_GEN` types, and the reverse lookup is the FreeBSD port's `hammer2_vget()` on the carried `hammer2_lookup_desc` XOP, with `fh_to_parent` and `get_parent` so a connectable handle encodes and a directory handle reconnects. Measured through the two syscalls that drive the same table, since the acceptance predicate above is not the same thing as an export having run: `name_to_handle_at(2)` calls `encode_fh` and `open_by_handle_at(2)` calls `fh_to_dentry` and, for a directory, the reconnect path calling `get_parent`, and `test/hammer2-fh.c` opens two files by handle and each reads its own bytes and reports its own `st_ino`, opens a directory handle and lists it, refuses a handle with a bit flipped in its inode number, refuses a buffer too short for the connectable form with the size needed, sees a handle to a removed file go stale and not answer the file made after it, and opens a file by a handle taken before it was renamed, 9 checks 0 failed on the volume `test-enospc.sh` mounts (status, "a file handle, as a file is looked up by number rather than by name"). NOT measured, and the row is `native` on the syscall reading rather than on an export: no `nfsd` run has been made, because the kernel of record's guest is built with `CONFIG_NFSD` unset and enabling it means rebuilding a pinned tree, so what is shown is the predicate nfsd checks and the table it drives, not a mount served over NFS. Within that, `fh_to_parent` is registered but its decode body runs in no test, and that is a property of the interface rather than a gap this tree left: `exportfs_decode_fh_raw()` reaches `fh_to_parent` only from its non-directory branch and only after `find_acceptable_alias()` fails, and the two callers differ in whether that can happen. nfsd passes `flags = 0` and `nfsd_acceptable`, which returns 0 unless the walk up from the decoded dentry reaches `exp->ex_path.dentry`, so it can refuse and the parent decode is reached on a subtree-checked export. `open_by_handle_at(2)` cannot: its callback, `vfs_dentry_acceptable`, returns 1 without looking while `ctx->flags` is zero, `ctx->flags` is set only for a handle opened with `O_DIRECTORY`, and a directory handle is the one form that encodes no parent (`exportfs_encode_fh()` passes a parent only for a connectable non-directory). So `fh_to_parent` is unreachable through the syscalls the gate drives, whatever the gate does, and only an nfsd run can exercise it. `exp_export`, nfsd's export admission, is the other live call site no test here reaches. The generation field is zero and read as accept-any: HAMMER2 allocates inode numbers from `pmp->inode_tid` with `atomic_fetchadd_64()` (`hammer2_trans_newinum()`), so a number is not reused within a PFS and a stale handle resolves to ENOENT rather than to a different inode. Read off a live mount, not argued from the allocator alone: a file at inode 203029 was removed and 4,000 files made after it took 203030 through 207029, consecutive and strictly increasing, none of them the removed number, and the gate's own check removes a file and confirms the file made next does not answer its handle | an export actually served, which needs an `nfsd` built against the kernel of record; and a handle held across a reformat, which would reuse numbers and is what a generation derived from the PFS `fsid` would catch |

What the table says at a glance: the checkpoint primitives the model
needs, snapshot, delete, durable flush and the two checksums, are
native and measured on both sides; rollback and the durable checkpoint
are composed from those and the mount by label; the accounting is the
format's lazy accounting with a fixed reserve; and everything to do
with copies across hosts, quota and online repair is absent, in every
port, and is declared absent rather than emulated. Replication between
local devices is the one cluster capability here, `limited` to that. No row is now absent
here and present upstream: NFS export, the one such gap, is closed at
`native` above, and the operation DragonFly reaches through `vfs_vptofh`,
`vfs_fhtovp` and `vfs_checkexp` is reached here through the kernel's
`export_operations` and measured by `test/hammer2-fh.c`.

This file is the port's side of any adapter a consumer writes over
these rows; `README.roadmap.md`'s 0.7 milestone closed on it.

## The ioctl surface, against DragonFly's

The rows above are capabilities; this is the interface, because a
consumer asks both and only the second is a list. DragonFly declares 27
`HAMMER2IOC_*` names, of which 22 are commands and 5 are the
`HAMMER2IOC_INODE_FLAG_*` bits that `INODE_SET` reads out of
`ino->flags` rather than dispatching. This port declares 20 names on the
same split, 15 commands and the same 5 flag bits, and dispatches one
command DragonFly does not have, `HAMMER2IOC_VOLUME_LIST2`. The eight
DragonFly commands it does not carry are enumerated here rather than
left to be discovered, and each maps onto a row above so the two cannot
drift apart:

| ioctl | what it does upstream | covered by |
|---|---|---|
| `HAMMER2IOC_REMOTE_ADD` | add a cluster member | IncrementalReplication, RemoteCheckpoint: `unavailable`; Replication between local devices needs no remote member |
| `HAMMER2IOC_REMOTE_DEL` | remove a cluster member | the same row |
| `HAMMER2IOC_REMOTE_REP` | replicate to a member | the same row |
| `HAMMER2IOC_REMOTE_SCAN` | scan for members | the same row |
| `HAMMER2IOC_SOCKET_GET` | read cluster comms socket settings | the same row |
| `HAMMER2IOC_SOCKET_SET` | set them | the same row |
| `HAMMER2IOC_RECLUSTER` | re-form the cluster after a topology change | the same row |
| `HAMMER2IOC_BULKFREE_ASYNC` | start a bulkfree scan and return | GC candidates: the port answers the synchronous `HAMMER2IOC_BULKFREE_SCAN`, which `script/bulkfree.sh` measures |

Seven of the eight are the cluster surface, which the rows above declare
absent and which no BSD port carries either. The eighth is the
asynchronous form of an ioctl this port does carry, so a consumer that
wants bulkfree without waiting composes it by running the scan on its own
thread; it is not a missing operation, it is a missing convenience, and
the difference matters when sizing a port against upstream.

So the answer to "is every upstream ioctl implemented" is no, and the
answer to "is anything missing that a consumer would expect" is the same
eight names, all but one of them clustering. Both statements are here so
neither has to be inferred.

