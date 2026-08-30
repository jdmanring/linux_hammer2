# H1 reading 1: the spin regions, and what Linux may use for them

The first of the three readings `HAMMER2_LINUX_PORT_PLAN.md` puts before
any H1 estimate is written. Measured 2026-08-25 by the implementation
session over the four trees on this disk, with
`scripts/hammer2-spin-audit.py`, which carries a selftest that falsifies
its matcher in both directions and prints its population before any
verdict.

## The question, which has two directions

The plan takes `rw_semaphore` as the default lock with `spinlock_t` only
where the audit shows atomic context. Those are opposite constraints and
only one of them is a Linux problem:

- A region that SLEEPS under the lock forbids `spinlock_t`. FreeBSD has
  already answered this and the answer is that it does not matter:
  `hammer2_spin_ex` in `hammer2_os.h` (cited by symbol: the line was 344 when read and is 345 at linux_hammer2 `e27a40c`) maps `hammer2_spin_ex` onto `sx_xlock`, a sleepable
  lock, for every site in the tree. A sleeping region is legal there.
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

The scanner named two candidates, both in the syncer loop of
`hammer2_vfsops.c`, and both are artifacts of loop structure rather than
findings. The lock is dropped at `hammer2_vfsops.c:2565`; the sleeping
calls (`hammer2_mtx_unlock` at 2623, `vput` at 2650) run with it dropped;
lines 2633 and 2652 re-acquire at the tail of the iteration and
`continue`. A linear scan sees acquire, then sleeping call, then release,
and the lock is held for none of it.

The three unresolved sites:

- `hammer2_chain.c:159` and `hammer2_flush.c:1273` are hand-over-hand:
  the first takes the parent's spin before releasing the child's while
  walking up the topology, the second re-acquires at the tail of an RB
  scan callback and returns with the lock held to its caller. Both are
  correct and both matter to Linux for one mechanical reason: lockdep
  wants `__acquires()` and `__releases()` annotations on a function that
  does not balance its own locking, and a port that carries these lines
  without them gets a warning that reads like a bug.
- `hammer2_chain.c:2324` is the one real finding, below.

So the answer to the first direction is zero, and `rw_semaphore` is legal
at all 62 port-relevant sites on the evidence of the source. FreeBSD's
`sx` mapping is the same answer reached by a different route, and it has
run in production since v1.1.5.

## The one finding: an unreleased lock, in all four trees

`hammer2_chain_repchange()` acquires `reptrack->spin` and releases it on
no path:

    hammer2_chain.c:2324   hammer2_spin_ex(&reptrack->spin);

The only other user of that lock object is the waiter in
`hammer2_chain_repparent()`, which takes `&reptrack.spin` at
`hammer2_chain.c:2268` on each iteration while it follows a re-parented
chain. So once `repchange` has run against a reptrack, the waiter's next
iteration blocks on a lock nothing will release.

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
reserves for Dillon. Staged here; James files.

For the port itself the disposition is not blocked on that answer. The
line is carried into the Linux tree with a `HAMMER2-LINUX:` provenance
note naming this document, so the port neither silently fixes upstream's
code nor silently inherits a hang.

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
