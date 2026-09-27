# H1 reading 1: the spin regions, and what Linux may use for them

The first of the three readings `HAMMER2_LINUX_PORT_PLAN.md` puts before
any H1 estimate is written. Measured 2026-08-25 in the implementation
phase over the four trees on this disk, with
`scripts/hammer2-spin-audit.py`, which carries a selftest that falsifies
its matcher in both directions and prints its population before any
verdict.

## The question, which has two directions

The plan takes `rw_semaphore` as the default lock with `spinlock_t` only
where the audit shows atomic context. Those are opposite constraints and
only one of them is a Linux problem:

- A region that SLEEPS under the lock forbids `spinlock_t`. FreeBSD has
  already answered this and the answer is that it does not matter:
  `hammer2_spin_ex` in `hammer2_os.h` maps the acquire onto a sleepable
  lock for every site in the tree, so a sleeping region is legal there.
  Cited by symbol rather than by line, because the mapping has been
  rewritten since. The mechanism was named as FreeBSD's `sx_xlock` when
  this was read; the port now takes a Linux `rw_semaphore` with
  `down_write`, which is sleepable the same way, so the answer did not
  move with the mechanism.
- A region entered from ATOMIC context forbids `rw_semaphore`. Neither
  BSD port faced this, and Linux introduces it, which is why the reading
  is worth taking rather than inheriting.

## Population

69 acquire sites in DragonFly's `sys/vfs/hammer2` (`hammer2_spin_ex` and
`hammer2_spin_sh`; the plan's figure of 177 counts every `hammer2_spin_*`
token, which includes the releases, the initialisers, the typedef and the
assertions, and is relayed back for correction). Seven of the 69 are in
`hammer2_ccms.c`, which no BSD port carries, so 62 are port-relevant.

66 resolved to a release of the same lock in the same function. Three did
not and were hand-read.

## Result: no region sleeps under the lock

Line numbers below are the measured tree's, and the reading mixes two
trees. The hand-over-hand pair and the finding are cited in DragonFly's
`sys/vfs/hammer2` numbering; the syncer-loop cites are this port's
`src/sys/fs/hammer2`. Both were re-read against their own tree rather
than carried over: the DragonFly cites resolve to the named statements at
head, and the syncer-loop cites resolve to this port's current lines,
which had drifted from the ones first written here.

The scanner named two candidates, both in the syncer loop of
`hammer2_vfsops.c`, and both are artifacts of loop structure rather than
findings. The lock is released inside the branch; the sleeping calls
(`hammer2_mtx_unlock` at `hammer2_vfsops.c:2633`, `iput` where DragonFly
has `vput` at 2636) run with it dropped; and the branch re-acquires at
2594 and 2638 before `continue`. A linear scan sees acquire, then
sleeping call, then release, and the lock is held for none of it.

The three unresolved sites:

- `hammer2_chain.c:159` and `hammer2_flush.c:1273` are hand-over-hand:
  the first takes the parent's spin before releasing the child's while
  walking up the topology, the second re-acquires at the tail of an RB
  scan callback and returns with the lock held to its caller. Both are
  correct and both matter to Linux for one mechanical reason: lockdep
  wants `__acquires()` and `__releases()` annotations on a function that
  does not balance its own locking, and a port that carries these lines
  without them gets a warning that reads like a bug.
- `hammer2_chain.c:2324` is the one real finding, below. That number is
  DragonFly's; the carried file here has it at 2149.

So the answer to the first direction is zero, and `rw_semaphore` is legal
at all 62 port-relevant sites on the evidence of the source. FreeBSD's
`sx` mapping is the same answer reached by a different route, and it has
run in production since v1.1.5.

## The one finding: an unreleased lock in DragonFly and all three ports

`hammer2_chain_repchange()` acquires `reptrack->spin` and releases it on
no path. The line is DragonFly's `hammer2_chain.c:2324`:

    hammer2_chain.c:2324   hammer2_spin_ex(&reptrack->spin);

The only other user of that lock object is the waiter in
`hammer2_chain_repparent()`, which takes `&reptrack.spin` at
`hammer2_chain.c:2268` and drops it at `:2271` on each iteration while it
follows a re-parented chain. So once `repchange` has run against a
reptrack, the waiter's next iteration blocks on a lock nothing will
release.

Carried verbatim by every port: `freebsd:2019`, `netbsd:2038`,
`openbsd:2019`, each with the matched stack-local pair intact above it
and the pointer acquire unmatched. Under DragonFly's spinlock this
spins; under FreeBSD's `sx_xlock` it sleeps forever.

It survives because the path is rare, and the source says so in its own
voice: the line above the acquire is a `kprintf` beginning "hammer2:
debug repchange", and the waiter's re-parent branch has a matching
"debug REPTRACK". Both are debug notices on a path the author expected to
be uncommon.

Read it as a question, not a verdict. Whether the acquire is a defect or
an intentional freeze whose release was lost in an edit is exactly what
the source cannot answer, and it is the shape the upstream strategy
reserves for Dillon. The filing draft is `doc/upstream/README-provenance.md`;
staged here, James files.

For the port itself the disposition is not blocked on that answer, and
the one this document first recorded is not the one the port took. It
said the line was carried with a `HAMMER2-LINUX:` provenance note naming
this document; no such note was ever written, and the marker does not
occur anywhere in `src/`. What happened instead is the rule in
`doc/README.maintenance.md`: a defect found here in carried code is fixed
here and marked `XXX`, so the port does not wait on anyone. The release
was added at `hammer2_chain.c:2156` in `c70f4b7`, marked
`/* XXX Linux: the spin taken above, released before the drop */`, on
2026-09-27. That is a Linux-only release added to a carried function, so
it is recorded here rather than presented as a silent fix.

Whether any run exercises it is a separate question and the answer is no:
no measurement here drives `hammer2_chain_repchange()` on a chain that
carries a reptrack, which is the permanent deletion of an indirect block
or a freemap node with live children. The fix rests on the source and the
record says so rather than implying a reproduction. The upstream copy is
unchanged and the question above is still open for Dillon.

## What this decides for reading 2

The second direction stays open and is not a call-graph question anyone
can dodge: it is a design choice, and this reading constrains it.

No spin site sits on an I/O completion path today. `hammer2_strategy.c`,
the file that calls `biodone` on DragonFly and `bufdone` on FreeBSD, has
zero acquire sites in either tree, and the seven in `hammer2_io.c` are
all in the DIO hash table, reached from the allocate and get paths on the
submission side.

That is a property of the BSD ports' synchronous buffer cache, not of
HAMMER2. A Linux DIO layer built directly on `submit_bio` gets its
`bi_end_io` in softirq, and if that callback touches the DIO hash then
those seven sites become atomic-context sites and `rw_semaphore` becomes
illegal at exactly the place the format's 64 KiB physical buffers live.

So the two readings join here, and the decision is one line: complete
bios into a workqueue, keep every DIO hash operation in process context,
and the lock question stays closed with `rw_semaphore` everywhere, which
is the configuration FreeBSD has already run for two years. Completing in
the interrupt handler saves a context switch and reopens the audit for
the seven hottest sites in the driver. Reading 2 designs the DIO layer on
that constraint rather than discovering it afterwards.
