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
change. The stranded lock is what made it visible, and that half is about
this port's XOP scheduling rather than about the release. At the time it
was found the port gated every XOP on the inode dependency, which the
synchronous ports do and DragonFly does not, so both lock orders could
land on one task. 0.9.19 exempted strategy XOPs from that dependency as
DragonFly does, and the lockdep cycle has not recurred since. The missed
release is not specific to anything and is present in all four trees.

## hammer2_chain-repchange-release-reptrack-spin

`dragonfly-hammer2_chain-repchange-release-reptrack-spin.patch` and
`ports-hammer2_chain-repchange-release-reptrack-spin.patch`.

`hammer2_chain_repchange()` takes `reptrack->spin`, links the reptrack
into the parent, and returns without releasing it. Every pass through the
loop leaks the write lock on that reptrack, and the next visitor to the
structure blocks on it for good.

Applied here on 2026-09-27, marked `XXX`, on the same rule as the freemap
entry above: a defect in carried code is fixed here and marked so the
port does not wait on anyone. The change is one line and the mark, 5198
lines to 5200. Verified by the syntax gate at 65 checks 0 failed and the
`XXX` table and origin line count moved with it. No run here drives
`hammer2_chain_repchange()` on a chain that carries a reptrack, which is
the permanent deletion of an indirect block or freemap node with live
children, so this rests on the reading rather than a reproduction: the
spin is taken on the line above and the only other release of a
`reptrack->spin` in the tree is a different local structure in
`hammer2_chain_repparent()`.

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
the syncer; `doc/history/verification-record.md` has the record. Linux reaches it
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
`doc/history/verification-record.md` has the record. One writer had not reached it
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
`doc/history/verification-record.md` has the record. The DragonFly patch does not
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

Tried on DragonFly 6.4-RELEASE on 2026-09-07, on a 2 GiB volume with
four writers reading `/dev/random` until refused: 119 files kept, the
volume 98% used, unmount clean, remount with the same 119 files,
`fsck_hammer2` clean, and nothing in the kernel log. That is not a
reproduction and is not evidence either way. The defect needs the
unmount's final sync to fail for want of a block, and a real fill
leaves the reserve the sync needs; the Linux reproduction had to make
the allocator refuse on a call count to reach it.

The release kernel carries `INVARIANTS` (`X86_64_GENERIC` line 56 in
the 6.4.2 source; the kernel binary holds the assertion strings), so
a chain left allocated at unmount is reported there, by the chain dump
`hammer2_unmount_helper()` prints after the final sync and by the
allocator teardown in `kmalloc_destroy_obj()`. What the release kernel
lacks is a way to make the allocator refuse. A kernel built from the
6.4.2 source with that added was the second try, on the same day: two
sysctls, `vfs.hammer2.fail_alloc_after` and `vfs.hammer2.alloc_count`,
and a refusal at the top of `hammer2_freemap_alloc()`, before its size
assertion, returning `HAMMER2_ERROR_ENOSPC` once the count passes the
threshold, the shape the Linux knob has. `script/dfly-enospc.sh` drives
the fill against that kernel.

With the threshold at 20000 and left in place, the kernel reports the
refusal where the Linux port did, in `hammer2_chain_create_indirect()`
and `xop_strategy_write()`, and the unmount is never reached: a
strategy write that fails is completed with `B_ERROR` and `EIO`
(`hammer2_strategy.c`, the write XOP's completion), the buffer cache
redirties it, and `sync(8)` looped on the same buffers for the rest of
a 30 minute run at one kernel line per retry, with shutdown looping
the same way until the guest was destroyed. A refusal that never
lifts is a hung sync on DragonFly, the buffer cache's own retry
policy and not this defect.

With the threshold at 20000 during the fill and lifted before the
sync, the run reproduces the defect. The writers kept 83 files, the
sync and the unmount returned, and the unmount printed a chain dump
of eighteen chains still under the volume root, every one at zero
refs: ten leaves with `UPDATE` set and nothing on the media, eight
directory entries and two blocks, and above them the eight
on-media chains (five inodes, three indirect blocks) that stay on
their parents' trees only because a parked child hangs under each,
which is the shape the staged scrap walks. The allocator teardown then
reported 8064 bytes of `HAMMER2-chains` still allocated across seven
slabs. The remount counted 75 files and `fsck_hammer2` read clean:
the eight files whose data never reached the media were the ones
the refused strategy writes belonged to, and their `dd` was told
nothing, since DragonFly reports the error at the strategy layer
and not to `write(2)`. The leak is the reading the staged patch
addresses; the silent loss is `hammer2_strategy.c`'s and is a
separate matter.

The patch as first staged was built into that kernel, hunk 2 placed
by hand because 6.4.2 keeps the chain dump unconditional where head
has it under `#if 0`. The fill on that run wedged in the same way as
the permanent refusal, four writers in disk wait at 84 files with the
syncer retrying, and the threshold was lifted by hand at that point;
the writers then ran to a real full volume at 119 files. The scrap
printed thirteen lines, the ten `UPDATE` leaves and the three chains
above them, and freed nothing: the dump that followed showed the same
thirteen chains with `UPDATE` clear and `ONLRU` set, the teardown
reported 5824 bytes across five slabs, and the remount counted 109
files. 6.4.2's `hammer2_chain_lastdrop()` does not free a zero-ref
chain that has a PFS unless `DESTROY` or `RELEASE` is set on it; it
parks the chain on the PFS's LRU list as a cache entry, and the PFS
holding that list had already been freed by `hammer2_pfsfree()`.
Head removed the LRU list, so the patch was right against the tree
it was written for and wrong against the release, and the fix is one
line both trees honor: `RELEASE` set before the drop, which is what
`hammer2_pfsfree()`'s own LRU drain and the recovery scan do. That is
the version staged here.

With that line in, on a third kernel from the same source and with the
threshold lifted on a timer 120 s into the fill so the fill cannot
wedge, the unmount scrapped twenty-three chains, the twenty `UPDATE`
leaves and the three chains above them, the dump that followed showed
nothing under the volume root or the freemap root, and the allocator
teardown printed no line, which is what it prints when nothing is
left. The remount counted 263 of 283 files and `fsck_hammer2` read
clean. That is the reading the staged patch is filed with: the leak
is closed on 6.4.2 and, by the same code, on head; the twenty files
the refused strategy writes belonged to are still lost without a
word to their writers, and that remains `hammer2_strategy.c`'s.

## hammer2_ioctl-volume-list-string-copy

`dragonfly-hammer2_ioctl-volume-list-string-copy.patch` and
`ports-hammer2_ioctl-volume-list-string-copy.patch`.

`hammer2_ioctl_volume_list()` fills each entry's `path` and the list's
`pfs_name` with `bcopy()` of `sizeof` the destination, 1024 and 256
bytes, from `vol->dev->path` and `pmp->pfs_names[0]`, which are
`kstrdup()` strings sized to their length. The copy reads past the
source allocation by the difference, and on a kernel with KASAN the
read of `/dev/vdb` from a 9-byte object is reported at once. What
lands in the entry past the terminator is whatever followed the
string in the slab, copied out to the caller. The FreeBSD port has
the same four copies across both list versions; the NetBSD and OpenBSD
ports are byte-identical there and the ports patch applies to both.

Still present at head on 2026-09-26: DragonFly `b47adf86e5` has the
`bcopy` at `hammer2_ioctl.c:1439` and `:1449`; `kusumi/freebsd_hammer2`
`3df307f7db`, `netbsd_hammer2` `64095c3947` and `openbsd_hammer2`
`a3747df966` each have all four, read through the forge API. Not
searched for on DragonFly's tracker, which is behind a proof of work.

Found here by the sanitizer kernel and not by reading: `test-fixtures.sh`
drives the ioctl on every image and had passed 100 results on the
debug kernel for three weeks, because a read past a slab object
returns bytes and lockdep and kmemleak do not watch reads. The Linux
tree takes `strscpy_pad()`, which is `strlcpy()` with the tail zeroed
as `bzero()` of the entry had already done; the upstream patches use
`strlcpy()`, which every BSD has.

## hammer2_freemap-bmap-pointer-past-bound

`dragonfly-hammer2_freemap-bmap-pointer-past-bound.patch` and
`ports-hammer2_freemap-bmap-pointer-past-bound.patch`.

`hammer2_freemap_try_alloc()` scans the 256 `bmdata[]` entries of a
freemap leaf outward from a starting index, and forms
`&chain->data->bmdata[n]` before testing whether `n` is inside the
array, in both directions; the comment beside each says the pointer is
invalid then, and it is never dereferenced. Forming it is still an
out-of-bounds index in C, and UBSAN with bounds checking reports it on
the first allocation of any mount, three times in the first file
created, with `n` at -1 and -34. The patch forms the pointer only
inside the bound, which is the same statement moved after the test.

Still present at head on 2026-09-26 in all four trees, the same two
lines as above, read through the forge API. Not searched for on the
tracker.

Found by the same kernel as the string copies: the debug kernel has
no bounds sanitizer, and a pointer formed and not dereferenced is
invisible to every other instrument here.


## hammer2_freemap-adjust-null-chain-on-recover

`dragonfly-hammer2_freemap-adjust-null-chain-on-recover.patch` and
`ports-hammer2_freemap-adjust-null-chain-on-recover.patch`.

`hammer2_freemap_adjust()` looks up the level1 freemap chain and stops
early when the lookup returns null, but only when `how` is not
`HAMMER2_FREEMAP_DORECOVER`:

	if (chain == NULL && how != HAMMER2_FREEMAP_DORECOVER) {
		...
		goto done;
	}
	if (chain->error) {

A recovery pass that finds no leaf for the block it is marking therefore
reaches the `chain->error` dereference with `chain` null. The block that
creates the missing leaf runs below it, and only for the recovery case, so
it cannot have run yet. The patch tests the pointer as well as the error.
The window is a recovery pass over a freemap leaf the volume does not
hold, which is a damaged freemap being repaired, and the three ports have
the same five lines.

Found by `script/analyze.sh` on 2026-09-26 and not by a run: clang's
static analyzer reports the null reaching a dereference along that path,
which the two compilers and sparse do not ask about.

Applied here on 2026-09-27, marked `XXX`, as the maintenance document's
rule for a carried defect requires: the port does not wait on anyone, and
a defect present in all four trees is a defect here. The staging was the
delay, not a decision to leave it out. The change is the pointer test and
the mark, 1033 lines to 1034, and the instrument that found it is the one
that confirms it: `script/analyze.sh` over that file reports 0 candidates
with its planted-null control still firing, where the same run before the
edit reported this one. The syntax gate reports 65 checks 0 failed.

The reach condition, measured rather than assumed: `script/cut-flush.sh`
runs the freemap replay in its fourth stage. It lowers the header's
`freemap_tid` by `H2_CUT_LAG` transactions and the guest prints
`hammer2_recovery: freemap recovery <lo>-<hi>`, so the recovery path this
function sits on is exercised on every run and needs no damaged volume.
That run is not a control for this fix, and was reverted to check: with
the guard removed the same run passes, 0 failures and no report, because
the lookup returns a chain for these images and the null branch is not
taken. The replay is reachable; the null leaf inside it is not what that
image produces. So the fix stands on the analyzer, which does exercise
the path, and the fleet run establishes only that the applied guard does
not disturb a recovery that was working.

Still present at head on 2026-09-26 in all four trees, read in the local
clones at each head and confirmed by dry-run applying the patch to each.
Not searched for on the tracker.
