# Where each staged patch stands against upstream

Every file in `doc/upstream/` has to be named here or in another document
beside it, and `script/test-inventory.sh` fails if one is not. The reason
is a defect in how this repository staged patches rather than in any of
them: three pairs sat here describing a fix without a word about whether
upstream had already made it, already rejected it, or already been told.
A patch with no such record invites the reader to assume nobody has
looked, and for a while nobody had.

What each entry has to carry: whether the code is still that way at
upstream's current head and how that was checked, what was searched for
and where, and what could not be searched. "Nothing was found" is only
worth writing next to what was looked at.

The PFS lifetime pair has its own file,
`README-pfs-lifetime-provenance.md`, because upstream has fixed a
sibling of it and that needed room.

## Checked on 2026-09-05, for all of the below

The three port trees are `kusumi/freebsd_hammer2`,
`kusumi/netbsd_hammer2` and `kusumi/openbsd_hammer2`. Each is at
`v1.2.13` of 2025-08-22, and each local clone is at the remote head
exactly, so the trees here are current and not a stale snapshot. All
three have issues disabled and carry no pull requests, so there is no
tracker on that side and nothing there means anything either way.

DragonFly's tracker at `bugs.dragonflybsd.org` refuses automated
fetches behind an Anubis proof of work, through a reader proxy as well.
A search of it for `hammer2 unmount` was read by hand. None of the three
below were searched for by their own terms, so none of them is claimed
to be unreported.

Upstream head content was read through the forge API rather than from
the local DragonFly clone, which is a shallow clone with one commit and
no history to search.

## hammer2_chain-create-keep-caller-chain

`dragonfly-hammer2_chain-create-keep-caller-chain.patch` and
`ports-hammer2_chain-create-keep-caller-chain.patch`.

`hammer2_chain_create()` clears the caller's chain pointer when it cannot
create an indirect block, which on a full volume is the first thing
`hammer2_chain_modify()` refuses. Two of the three callers that pass in a
chain release it under `if (chain)` and are skipped; a third reads
through the cleared pointer to assert a flag, which is a null dereference
in an invariants build.

Still present at DragonFly head: the `if (allocated)` block at
`hammer2_chain.c:3295` is unchanged.

Found here by measurement, not by reading: eight runs of
`script/test-enospc.sh` reported a lockdep cycle and none has since the
change. The stranded lock is what made it visible, and that half is
specific to this port, where XOPs run synchronously and put both lock
orders on one task. The missed release is not specific to anything.

## hammer2_chain-repchange-release-reptrack-spin

`dragonfly-hammer2_chain-repchange-release-reptrack-spin.patch` and
`ports-hammer2_chain-repchange-release-reptrack-spin.patch`.

`hammer2_chain_repchange()` takes `reptrack->spin`, links the reptrack
into the parent, and returns without releasing it.

Still present at DragonFly head: `hammer2_chain.c:2328` is followed by
the two other unlocks and not by this one.

## hammer2_vfsops-fixup_pfses-continue-loop

`dragonfly-hammer2_vfsops-fixup_pfses-continue-loop.patch` and
`ports-hammer2_vfsops-fixup_pfses-continue-loop.patch`.

`hammer2_fixup_pfses()` skips a non-inode chain with a bare `continue`
inside `while (chain)`, which returns to the condition without advancing
and without releasing the super-root inode lock.

Still present at DragonFly head, unchanged.

Reachability is the part to state plainly, because it is what a
maintainer will ask first: `hammer2_chain_lookup()` without `MATCHIND`
recurses into indirect blocks rather than returning them, so only a
damaged image reaches the branch. That is mount time recovery, which is
exactly when a damaged image turns up, but nothing here has produced one
that does.

## hammer2_admin-xop-ipdep-wakeup

`ports-hammer2_admin-xop-ipdep-wakeup.patch`, for the three ports only.
DragonFly has no `ipdep` mechanism: its XOPs run on their own threads,
and the per-inode dependency wait in `hammer2_admin.c` is the ports'
own, part of the synchronous XOP design, so there is no DragonFly
counterpart to patch.

`hammer2_xop_testset_ipdep()` sets `HAMMER2_PMPF_WAITING`, one bit on
the PFS, before sleeping on a condition variable that is one of several,
one per dependency index, under that index's lock.
`hammer2_xop_unset_ipdep()` on any index clears the bit and wakes its
own condition variable. A retire on index j while a task sleeps on
index i clears the bit and wakes nobody on i; the retire on i that
follows finds the bit clear and does not wake either, and the sleeper
has no timeout. The bit is also written from under different locks, so
the read-modify-write on `pmp->flags` is itself a race. The patch drops
the bit and wakes unconditionally, a wakeup on an empty queue costing
one uncontended lock.

Seen on Linux on 2026-09-06 as a writeback worker asleep in that wait
with the inode it waited on held by no XOP, while the syncer waited on
the worker's folios and a `link(2)` retried the four-inode lock behind
the syncer; `doc/README.status.md` has the record. Linux reaches it
because writeback runs XOPs on a kernel thread beside the caller's;
the ports run XOPs on the calling thread, so the three tasks it needs
are rarer there but nothing rules them out.

Still present at `v1.2.13` in all three ports, read in the local clones
at the remote head, `hammer2_admin.c:257` and `:279` in FreeBSD's; the
clones are single-commit snapshots with no history to search, and the
three repositories have issues disabled and no pull requests, so nothing
can be concluded from silence there.

## hammer2_io-hash-cleanup-lock-dio

`ports-hammer2_io-hash-cleanup-lock-dio.patch`, for the three ports
only. DragonFly's `hammer2_io_putblk()` keeps `HAMMER2_DIO_INPROG` set
in `dio->refs` from the last drop until the buffer is disposed of, and
its `hammer2_io_hash_cleanup()` skips a dio with that bit; the ports
replaced the bit with `dio->lock`, held across the same window, and
their cleanup reads `dio->refs` under the hash lock alone.

So a dio whose last reference has been dropped, whose buffer is still
being written back under `dio->lock`, and whose `act` has aged to zero
reads as free to a cleanup running on another thread: it is unhashed,
put on the clean list and freed, and the holder's `hammer2_mtx_unlock()`
lands on freed memory. The patch takes `dio->lock` before reading the
count, the order `hammer2_io_hash_lookup()` already takes it in under
the hash lock, so the cleanup waits for the disposal to finish.

Seen on Linux on 2026-09-06 with four `cp` processes writing a Nix
closure at once, as the writeback worker releasing a reader it had
never taken, the rwsem's count zero and its owner clear;
`doc/README.status.md` has the record. One writer had not reached it
in nine runs. The ports write back on the calling thread, which
narrows the window and does not close it.

Still present at `v1.2.13` in all three ports, read in the local clones
at the remote head, `hammer2_io_hash_cleanup()` in each; the clones are
single-commit snapshots with no history to search, and the three
repositories have issues disabled and no pull requests, so nothing can
be concluded from silence there.


## hammer2_vfsops-unmount-scrap-parked-chains

`dragonfly-hammer2_vfsops-unmount-scrap-parked-chains.patch` and
`ports-hammer2_vfsops-unmount-scrap-parked-chains.patch`, the second
applying to all three ports, whose unmount tails are the same text.
`hammer2_chain_lastdrop()` parks a chain that has a parent and `UPDATE`
or `MODIFIED` set at zero references on the parent's tree, because a
later flush needs it, and `hammer2_flush_core()` re-sets `UPDATE` on
the child when the parent's modify fails with `ENOSPC`. The unmount's
final sync is the last flush there will be. When it fails the same way,
`hammer2_unmount_helper()` clears the two flags on the embedded volume
and freemap roots only, drops them, and leaves every parked chain below
allocated. The patch walks the two trees after that sync, children
first, takes the reference a parked chain does not hold, clears the
flags and drops it, printing each as unflushed.

Seen on Linux on 2026-09-07 with the debug build's allocator refusing
from its 20,000th call: four inode chains in one line of descent from
the super-root, each at zero references, counted by the unload check
and named by the same build's list of every chain;
`doc/README.status.md` has the record. The DragonFly patch does not
call `hammer2_pfs_memory_wakeup()` for a scrapped `MODIFIED` chain,
where the root clears above it do, because the PFS a parked chain
points at was freed by `hammer2_pfsfree_scan()` earlier in the same
function; the surviving-chain `pmp` patch above is the same hazard.

Still that way at DragonFly's head `250a8b49` and the three ports'
`v1.2.13`, read on 2026-09-07 through the forge API and the local
clones. DragonFly's `hammer2_vfsops.c` history was read through the
forge for the file's last five commits: the newest, `40e5c562` of
2026-09-02, disables the two chain dumps at unmount and names a memory
leak fixed in `bfcedfb4`, which is a queued dmsg message in
`kdmsg_iocom_uninit()` and not this. Nothing was searched for by this
defect's own terms on DragonFly's tracker, so it is not claimed to be
unreported there; the ports have no tracker.
