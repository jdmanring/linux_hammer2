# What HAMMER2 on Linux declares

This is the port's own statement of what it provides, for anyone who
builds above it. Each capability is declared at one of six levels
under one rule: the port is never reported as providing a guarantee
it cannot provide. The levels and the list of capabilities are the
vocabulary of one storage model, section 27 of the Saxum reference,
used here because it is precise; nothing in this tree depends on that
model or on any distribution, and a consumer maps from this table to
its own. Every level below is read off a measurement in
`README.status.md` on the build the row names, and a row moves only
when a measurement moves it. Where a capability is not here, the row
says so and says what a consumer could compose above it.

The levels: native, provided directly with
documented semantics; composed, provided through an explicit lower
layer; emulated, implemented above the backend at a stated weaker
cost; limited, available only under stated constraints; unavailable;
and unsafe, possible but not acceptable for transactional use.

Measured on `artix-s6-kde` at 7.3.0-rc1 against the build the
0.9.0 row of `CHANGELOG.md` pins, unless a row says otherwise. The
writing ioctls are a hand run on 2026-09-05 and not a gate, since the
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
| DataChecksum | native | XXH64 on every data block, verified on read; one byte changed in a data block was refused naming the check (status, "Media altered on purpose") | nothing |
| MetadataChecksum | native | the same check code on every blockref, inode and indirect block; a volume header failing its CRC is not mounted | nothing |
| SelfHealing | unavailable | the inode's `ncopies` field is stored and set through the ioctl and nothing writes a second copy; a failed check is refused, not repaired | the copies mechanism is not carried in any port |
| Scrub | limited | offline only: `fsck_hammer2` over the unmounted volume, run after every fleet run on the host and on DragonFly; nothing scrubs a mounted volume | an online walk verifying every check code, which no port has |
| OnlineRepair | unavailable | nothing repairs a mounted volume | as Scrub |
| SpaceAccounting | limited | every `statfs` field checked against its source (status, "What statfs reports"); the free count moves at allocation and at the second bulkfree pass, not at a remove, so a removed file is counted until two passes have run; `script/bulkfree.sh` measured two passes returning a removed 800 MB set to the free count, each pass under a second on a 2G volume (status, "Space a remove does not free") | nothing; this is the format's accounting |
| MetadataAccounting | limited | `f_files` reports the inode count; data and metadata space are one pool, not the two the model's 27.5 asks a transaction to measure separately, and the reserve below is what keeps the flush's metadata allocatable | nothing on this side; the model measures headroom against the one pool |
| Reservation | limited | `hammer2_vfs_enospace()` carried, a twentieth of the volume set at mount, refusing a write, a create, a link, a rename, a remove and a size change under it; `script/test-enospc.sh` is a gate with ten clean fills as root and as a user, every accepted file read back whole (status, "A full volume") | one reserve, not the model's three categories; a reserve per mount would be a mount option, and no consumer has asked for one |
| Quota | unavailable | the inode carries quota fields the ioctl reads and sets, and the core enforces none of them, on DragonFly either | upstream enforcement |
| Compression | native | LZ4 and ZLIB written here and read on DragonFly, written there and read here, block counts and checksums matching both ways (status, "Compressed blocks" and "The same tree written by makefs and by the kernel") | nothing |
| Encryption | unavailable | the format has none | upstream |
| MultiDevice | native | `pfs-domains.sh` with `H2_PFS_VOLUMES=2`: a filesystem formatted across two 1 GiB images, mounted here by the device pair, `volume-list` reporting 2, the first root filled with 1200 MB so the writes cross into the second volume, and DragonFly mounting the same pair, reporting 2 volumes and checking every manifest including the fill with 0 mismatches (status, "Verified again on `3d364be`") | a volume added to a mounted filesystem, which the format allows and neither side has run here |
| FailureDomains | unavailable | one volume, no copies | as SelfHealing |
| Replication, IncrementalReplication, RemoteCheckpoint | unavailable | DragonFly's cluster synchronization and its `REMOTE` ioctls are carried by none of the three BSD ports and not here | upstream, and a consumer asking |
| ConcurrentSnapshot | unavailable | one PFS per snapshot ioctl; a set across PFSes is the model's transactionally coordinated class, never its atomic one | nothing on this side; the model's class is the honest claim |
| SnapshotDelete | native | `pfs-delete` removed `SNAP1` and `NEWPFS` in the hand run; the space returns over the next two bulkfree passes | nothing |
| SnapshotRetentionHold | unavailable | the backend keeps no hold; the model's registry does | nothing on this side |
| GC candidates | limited | two bulkfree passes through `HAMMER2IOC_BULKFREE_SCAN` are what free removed blocks, the first staging and the second freeing, and they are a run, not a gate; `script/bulkfree.sh` measured them, 52134 blocks staged by the first and freed by the second | a scheduled pass is the consumer's; the port answers the ioctl |
| Health | limited | the header CRC at mount and the offline checker; no online health reading | an online reading, which no port has |

What the table says at a glance: the checkpoint primitives the model
needs, snapshot, delete, durable flush and the two checksums, are
native and measured on both sides; rollback and the durable checkpoint
are composed from those and the mount by label; the accounting is the
format's lazy accounting with a fixed reserve; and everything to do
with copies, replication, quota and online repair is absent, in every
port, and is declared absent rather than emulated.

`README.roadmap.md`'s 0.7 milestone is the adapter over these rows, and
this file is the half of it that belongs here.
