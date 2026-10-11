# CCMS: the primary sources, and what each one answers

This is the working reference for HAMMER2's cache-coherency layer. It
exists so that the sources behind `doc/CCMS_DESIGN.md` do not have to be
found twice. The design note states conclusions; this file holds the raw
evidence for them, quoted, with the exact command or URL that produced
each reading.

Read `doc/CCMS_DESIGN.md` first if the question is what the layer is and
what remains open. Read this file when the question is "where does that
claim come from" or "what does the original actually say".

## The four sources

| source | what it answers | where it is |
|---|---|---|
| Dillon's HAMMER2 design document, 2015-04-03 (v3) | the architecture: which protocol runs under which, who holds state, who may revoke it | `doc/research/primary/DILLON_HAMMER2_DESIGN_2015.md`, captured from the DragonFly users list |
| The pre-`94491fa098` `hammer2_ccms.c` and `.h` | the protocol's intended shape in code: the state machine, the front end, the key range | `doc/research/primary/hammer2_ccms.{c,h}.deleted` |
| The pre-`94491fa098` `hammer2.h` and the port's `hammer2.h` | where the state was placed, and where it is placed now | `doc/research/primary/hammer2.h.at-94491fa098-parent` |
| The surviving `hammer2_ccms.c`, carried at 1.0.6 | what is in the build here, and what it is missing | `src/sys/fs/hammer2/hammer2_ccms.c` |

The DragonFly clone at `~/Projects/dragonfly-hammer2-upstream` is shallow
at `250a8b4`, so `94491fa098^` is read from the object store rather than
from history. The captures above make the clone unnecessary for reading
the deleted revision.

## Source 1: the design document

Fetched 2026-10-10 with `defuddle parse` from
`https://lists.dragonflybsd.org/pipermail/users/2015-April/448614.html`.
The file is the mailing-list post; the design document proper begins at
its `HAMMER2 DESIGN DOCUMENT` heading and is dated 03-Apr-2015 (v3),
14-May-2013 (v2), 08-Feb-2012 (v1).

### The status table, which is the first page

```
* Filesystem Core    - operational
  - bulkfree        - operational
  - Compression        - operational
  - Snapshots        - operational
  - Deduper        - specced
  - Subhierarchy quotas - specced
  - Logical Encryption    - not specced yet
  - Copies        - not specced yet
  - fsync bypass    - not specced yet

* Clustering core
  - Network msg core    - operational
  - Network blk device    - operational
  - Error handling    - under development
  - Quorum Protocol    - under development
  - Synchronization    - under development
  - Transaction replay    - not specced yet
  - Cache coherency    - not specced yet
```

"Cache coherency - not specced yet" sits beside "Quorum Protocol - under
development". Both are in the same table and the same subsystem list.

### The cache sub-protocol, and what it runs under

Under `There are four major protocols:` the document gives the Cache
sub-protocol as the second of four, and its first sentence states the
layering:

> This is the MESI sub-protocol which runs under the Quorum protocol.
> This protocol is used to maintain cache state for sub-trees to ensure
> that operations remain cache coherent.

The same entry continues with the revocation policy:

> Depending on administrative rights this protocol may or may not allow
> a leaf node in the cluster to hold a cache element indefinitely. The
> administrative controller may preemptively downgrade a leaf with
> insufficient administrative rights without giving it a chance to
> synchronize any modified state back to the cluster.

### The proxy protocol, and what happens to a dead leaf

The third of the four protocols. This is where the document answers what
happens to a grant whose holder stops answering:

> The Quorum and Cache protocols only operate between MASTER and
> SOFT_MASTER nodes. All other node types must use the Proxy protocol to
> perform similar actions. This protocol differs in that proxy requests
> are typically sent to just one adjacent node and that node then
> maintains state and forwards the request or performs the required
> operation. When the link is lost to the proxy, the proxy automatically
> forwards a deletion of the state to the other nodes based on what it
> has recorded.

> If a leaf has insufficient administrative rights it may not be
> allowed to actually initiate a quorum operation and may only be
> allowed to maintain partial MESI cache state or perhaps none at all
> (since cache state can block other machines in the cluster). Instead a
> leaf with insufficient rights will have to make due with a preemptive
> loss of cache state and any allowed modifying operations will have to
> be forwarded to the proxy which continues forwarding it until a node
> with sufficient administrative rights is encountered.

### Who holds the state

From the feature list, under the cache-coherency entry:

> MESI Cache coherency for multi-master/multi-client clustering
> operations. The servers hosting the MASTERs are also responsible for
> keeping track of the cache state.

So the masters hold it. The design document uses the word "controller"
exactly once in the whole text, in the administrative-rights sentence
quoted above, where it means an administrative actor rather than an
architectural node.

### Sub-cluster fan-out

Also from the proxy protocol entry, and relevant to any topology work:

> To reduce issues and give the cluster more breath, sub-clusters made
> up of SOFT_MASTERs can be formed in order to provide full cache
> coherent within a subset of machines and yet still tie them into a
> greater cluster that they normally would not have such access to. This
> effectively makes it possible to create a two or three-tier fan-out of
> groups of machines which are cache-coherent within the group, but
> perhaps not between groups, and use other means to synchronize between
> the groups.

### The node types

```
    SLAVE    - A SLAVE in the cluster, can source data on quorum agreement.
    MASTER    - A MASTER in the cluster, can source and sink data on quorum
    SOFT_SLAVE    - A SLAVE in the cluster, can source data locally without
          quorum agreement (must be directly mounted).
    SOFT_MASTER    - A local MASTER but *not* a MASTER in the cluster.  Can source
          and sink data locally without quorum agreement, intended to
          be synchronized with the real MASTERs when connectivity
          allows.
```

The port's `pfs_types[]` accepts five types, and
`HAMMER2_CLUSTER_STATE_MODEL.md` in the handoff names six roles including
`DUMMY` and `CACHE`, which appear in the document's mount discussion as
node types a mount may have.

## Source 2: the deleted CCMS implementation

Extracted 2026-10-10:

```
git show 94491fa098^:sys/vfs/hammer2/hammer2_ccms.c
git show 94491fa098^:sys/vfs/hammer2/hammer2_ccms.h
```

The `.c` is 516 lines including its `#if 0` blocks; the coherency half
sits inside `#if 0`, so it was never compiled even before the deletion.
The deletion commit is `94491fa098a9b62dd517fe5e5f0c8bf3315b9d5a`,
"hammer2 - locking revamp", dated 2015-03-22, whose message says:

> Temporarily remove hammer2_ccms.c from the build and remove the ccms
> container. The CCMS container will be used again when we get cache
> coherent in, but for now it isn't needed.

### `ccms_rstate_get()`, the function the whole finding turns on

At line 508, inside `#if 0`:

```c
static
void
ccms_rstate_get(ccms_lock_t *lock, ccms_cst_t *cst, ccms_state_t state)
{
	/* XXX */
	cst->state = state;
}
```

It assigns the requested state to the granted state. The introductory
comment above it says what it was meant to do instead:

> Acquire remote grant state. This routine can be used to upgrade or
> downgrade the state. If it blocks it will release any local locks
> acquired via (lock) but then it will continue getting the requested
> remote grant.

A caller reading `cst->state` after this returns gets back what it asked
for rather than what was granted.

### `ccms_lock_get()`, the front end, at line 98

The ordering rule, taken as local locks first and then remote
resolution, with the reason stated in its own comment:

```c
again:
	lock->flags &= ~CCMS_LOCK_FAILED;

	/*
	 * Acquire all local locks first, then resolve them against the
	 * remote cache state.  Order is important here.
	 */
	if (lock->req_t) {
		KKASSERT(lock->req_d <= lock->req_t);
		KKASSERT(lock->req_a <= lock->req_t);
		ccms_thread_lock(&cino->topo_cst, lock->req_t);
	}
	if (lock->req_a)
		ccms_thread_lock(&cino->attr_cst, lock->req_a);
	if (lock->req_d)
		ccms_thread_lock(&cino->data_cst[0], lock->req_d);
```

> Once the local locks are established the CST grant state cannot be
> pulled out from under us. However, it is entirely possible to deadlock
> on it so when CST grant state cannot be obtained trivially we have to
> unwind our local locks, then get the state, and then loop.

And the failure contract, which is what the `goto again` is for:

> If the ccms_rstate_get() code deadlocks (or even if it just blocks), it
> will release all local locks and set the FAILED bit. The routine will
> still acquire the requested remote grants before returning but since
> the local locks are lost at that point the remote grants are no longer
> protected and we have to retry.

`ccms_lock_put()` at line 160 releases the three in reverse order.

The function's own header comment says this is the hot path: "This code
is in the critical path and highly streamlined." That is the constraint
any grant protocol has to respect, and it is why inheritance exists.

### The key range, and the one thing not placed

`struct ccms_lock` carries `key_beg` and `key_end`, "applies to dstate"
on both, while `struct ccms_cst` in the same header carries `key_beg`,
`key_end`, `path_id` and `tid`. The front end indexes
`cino->data_cst[0]`, and `data_cst` is declared nowhere: not in the
deleted `hammer2.h`, not in the deleted `.c`, not in the header. The
`ccms_inode_t` the front end dereferences is likewise undefined in that
revision. So the data-state container's shape is the one part of the
original that is written down nowhere, and the `[0]` index is its only
use in the tree.

### `ccms_domain_init()`, and how ranges were meant to be held

At line 59, the one comment that describes the intended structure:

> Initialize a new CCMS dataspace. Create a new RB tree with a single
> element covering the entire 64 bit offset range. This simplifies
> algorithms enormously by removing a number of special cases.

Its body is `bzero(dom, sizeof(*dom))` with the `kmalloc_create` and the
root assignment commented out, so the tree was never actually built. The
comment is still the design's statement about how data state was to be
held: an RB tree over the 64-bit offset space, with a single element
covering everything as the initial case.

## Source 3: where the state was placed

From the deleted `hammer2.h`, `struct hammer2_inode`:

```
 * NOTE: The inode's attribute CST which is also used to lock the inode
 *	 is embedded in the chain (chain.cst) and aliased w/ attr_cst.
```
```c
struct hammer2_inode {
	RB_ENTRY(hammer2_inode) rbnode;		/* inumber lookup (HL) */
	ccms_cst_t		topo_cst;	/* directory topology cst */
	struct hammer2_pfsmount	*pmp;		/* PFS mount */
	...
```

So topology state is on the inode, attribute state is the chain core's
`cst` seen under the name `attr_cst`, and data state has no placement.

## Source 4: what upstream used the lock for

This is the reading that corrects "the lock has no caller". Counted
2026-10-10 over the tree at `94491fa098^`:

| file | `ccms_` references |
|---|---|
| `hammer2_ccms.h` | 48 |
| `hammer2_ccms.c` | 44 |
| `hammer2_chain.c` | 19 |
| `hammer2_inode.c` | 18 |
| `hammer2_vnops.c` | 10 |
| `hammer2.h` | 7 |
| `hammer2_vfsops.c` | 5 |
| `hammer2_subr.c` | 3 |

`hammer2_ccms.c` was in the `SRCS` line of the DragonFly Makefile before
the deletion and absent after. The calls in the core are the ordinary
lock vocabulary:

```c
ccms_cst_init(&core->cst, chain);
ccms_thread_lock(&chain->core.cst, CCMS_STATE_SHARED);
ccms_thread_lock(&chain->core.cst, CCMS_STATE_EXCLUSIVE);
ostate = ccms_thread_lock_upgrade(&chain->core.cst);
ccms_thread_lock_downgrade(&chain->core.cst, ostate);
ccms_thread_unlock_upgraded(&chain->core.cst, ostate);
KKASSERT(ccms_thread_lock_owned(&parent->core.cst));
```

So the lock was the core's lock interface before the revamp, not a
coherency-only structure. `94491fa098` replaced it in the callers with
`hammer2_mtx_*` on the chain and inode, which is what upstream carries
today and what this port carries as a primitive of the shim. The
coherency half that sat on the same state record was never written. Both
halves share one struct, and that is the whole entanglement: carrying the
struct carries the local lock, and the local lock has a replacement here.

## The port's side, measured 2026-10-10

- `command grep` for `ccms_cst`, `ccms_lock`, `ccms_domain`,
  `CCMS_STATE` and `CCMS_TYPE` over `src/` returns lines in exactly
  `src/sys/fs/hammer2/hammer2_ccms.c` and
  `src/sys/fs/hammer2/hammer2_ccms.h`, 46 of them, and no line elsewhere.
- `ccms_thread_lock()` is called only by `ccms_thread_lock_upgrade()` in
  the same file. Nothing outside the file calls any `ccms_` function.
- The carried files are 323 and 177 lines; `hammer2-y` in
  `src/sys/fs/hammer2/Makefile` names `hammer2_ccms.o`; the origin table
  in `doc/README.status.md` carries both rows and the three `XXX` marks.
- `hammer2_synchro.c` and `hammer2_ccms.c` are the only two cluster files
  that need no transport. `hammer2_iocom.c` and `hammer2_msgops.c` gate
  the message layer.

## The project rules that bear on this

From `proposals/hammer2-completion-handoff/HAMMER2_AGENT_HANDOFF.md`,
which is the plan this work is being done against. It is untracked in
this repository, so the rules that bind CCMS work are quoted here rather
than cited by path alone.

Rule 11, which is why a lease or any other modern replacement is not a
live alternative:

> Do not use a modern algorithm merely because it is fashionable. For
> example, do not replace HAMMER2's quorum/MESI mechanisms with Raft
> without first implementing and validating the original semantics. A
> modern control-plane model can be an H2X enhancement after the original
> protocol is faithfully reproduced.

Section 6.1, the CCMS carry:

> Port the MESI cache-coherency state machine with minimal semantic
> change. Do not rewrite it into an unrelated Linux cache architecture.
> [...] Required deliverables: source provenance record; build cleanly
> under the normal and invariant configurations; lockdep-clean tests;
> deterministic state-machine tests; no transport dependency; explicit
> state transition documentation.

Rule 12, the classification an unfinished behavior must carry:

> No feature is allowed to remain an undocumented `TODO`. Every
> incomplete behavior must be classified as `implemented`, `limited`,
> `deferred-with-trigger`, or `unavailable-with-reason`.

The CCMS exit criterion, from `HAMMER2_TEST_AND_VERIFICATION_PLAN.md`:

> Exit only after every state transition has: explicit preconditions;
> explicit postconditions; negative transition test; lockdep-clean
> concurrency tests.

And from `HAMMER2_COMPLETION_SPEC.md`, the two rows that place this work:
"Quorum protocol | masters vote / resolve conflicts | complete
faithfully" and "Cache coherency | MESI subtree cache state |
carry/complete CCMS".

## What each source does not answer

- The quorum protocol's body. The design document marks it "under
  development" and no tree here or upstream implements it. The cache
  layer runs under it, so this is the dependency, and it is P8.
- The data-state container. Neither the design document nor any revision
  places it; only `ccms_domain_init()`'s comment describes the RB tree
  over the offset space.
- Which administrative rights a leaf may hold, and who grants them. The
  design document calls this administrative and gives no policy.
- What happens to an unreachable MASTER holding exclusive state. The
  proxy rules cover leaves; a master falls under the quorum protocol,
  which is unwritten.

## The quorum and the cache layer, in the document's own words

"Runs under the Quorum protocol" is easy to read as "a quorum votes on
every cache grant." The document's `QUORUM OPERATIONS` section says what
it actually means, and the distinction matters because it decides whether
a per-grant vote is even on the table.

What the quorum does:

> Masters handle quorum confirmation amongst themselves and do not rely
> on the client for that purpose.

> Masters will run a 2-phase commit amongst themselves, often concurrent
> with other non-conflicting transactions, and will serialize operations
> and/or enforce synchronization points for 2-phase completion on
> serialized transactions from the same client or when cache state
> ownership is shifted from one client to another.

What the client does with cache state:

> A client can connect to one or more masters regardless of the size of
> the quorum and can submit modifying operations to a single master if
> desired. The master will take care of the rest.
>
> A client must still validate the quorum (and obtain MESI cache states)
> when doing read-only operations in order to present the correct data to
> the user process for the VOP.

And the ordering constraint between the two:

> Clients will usually allow operations to run asynchronously and return
> from system calls more or less ASAP once they own the necessary cache
> coherency locks.

So the quorum votes on *commits*, amongst the masters, with the client
excluded from that path by an explicit argument ("Apart from the reliance
being unsafe, the client could also lose contact with one or more masters
during the transaction and leave one or more masters out-of-sync without
the master(s) knowing they are out of sync"). Cache state is *obtained*
by the client and *shifted* between clients under the masters'
serialization, which is the same 2-phase machinery. A cache grant is
therefore not itself a quorum vote; it is a state transfer that the
commit protocol orders.

That is the same shape as the systems in the survey below: the vote is
for commit and leadership, and the cache grant is served by an authority
per object or subtree. A per-grant quorum vote would be a design no
production system of this class uses, and the document does not ask for
one.

## Where the design meets the practice: a survey of comparable systems

Researched 2026-10-10 by a delegated agent, whose primary sources are
captured beside this file. This section exists because the note's first
version treated "who grants cache state" as an open design question; the
survey shows the question is settled in the same way across the field,
and that HAMMER2's answer is the field's answer.

| system | who holds coherence authority | what the vote is for |
|---|---|---|
| GFS | the master grants a lease to one replica (the primary) per chunk | nothing; the master is the single arbiter |
| Lustre LDLM | the resource's own server is its lock master | nothing; per-resource authority |
| Ceph | the auth MDS per inode, with dynamic subtree partitioning | monitors vote only on the cluster map and membership |
| NFSv4 | the server, by recallable delegation with a lease | nothing; revoke-on-timeout |
| SMB2/3 | the server, by lease, broken by the server | nothing; server-initiated break |
| GPFS | one global token manager per filesystem | nothing; tokens amortize lock acquisition |
| Spanner | a per-Paxos-group leader, holding a quorum-granted lease | the quorum votes for *leadership*, not per object |

The pattern: coherence authority is per object or per subtree, and the
quorum is reserved for leadership and commit. Spanner is the closest
thing to a per-grant vote, and its own microbenchmarks put the cost of
the quorum round at about 9 ms against about 1.3 ms for the same
operation without it, which is the cost of voting even with a leader
amortizing votes across many operations. The survey's conclusion is
explicit: no production system of this class attempts a per-object
quorum vote for ordinary cache state.

### What the field pairs with a grant, and why it matters here

Each of these systems defends a grant with a mechanism that makes a
*paused holder's late write* detectable rather than merely unlikely. This
is the failure the note called S7, and the techniques are:

- **A monotonic generation number carried on every operation.** SMB2's
  `Lease.Epoch` is incremented by the server on every state change, and
  the client must purge cached data when it sees a gap. Chubby's
  sequencer and GFS's chunk version number are the same device.
- **Fencing the holder at the device.** GPFS invokes disk-subsystem
  primitives "to stop accepting I/O requests from the other nodes"
  before starting recovery; the SCSI-3 persistent-reservation form of
  this removes a node's registration key so the device itself rejects
  its I/O.
- **Release only after the old holder's possible writes are reconciled.**
  GPFS: "After log recovery is complete, the token manager releases
  tokens held by the failed node," so metadata the failed node had not
  written back is unreachable until it is known consistent.
- **A relative reference-count guard on the holder side.** Lustre's
  blocking-AST handler refuses to cancel a lock with live I/O, and
  prolongs the eviction timeout while I/O is in flight, so a slow-but-
  alive client is not evicted from under its own write.

The survey states the corresponding caveat plainly: no reviewed system
relies on lease expiry alone to make a paused holder safe. Each either
fences the holder, requires a generation the receiver can reject, or
delays release until reconciliation. That is the pattern HAMMER2's
"cache state ownership is shifted" sentence describes, and it is the
evidence behind the note's position that a lease is not the mechanism
this design needs.

### The clock question, which the design avoids

The one place a grant needs a clock is expiry, and the field's answer is
that bounded *drift* is required, not synchronized clocks. NFSv4 grants
the lease as a delta to avoid needing shared clocks; Chubby requires
that the server clock advance no faster than a known constant factor
faster than the client's; Spanner replaces the assumption with a
measured interval from GPS and atomic clocks. HAMMER2's design takes a
fourth route and needs no clock at all for this purpose: an
administrative-rights policy lets the cluster downgrade a leaf
preemptively, which is a decision rather than a timeout.

Primary sources captured in `doc/research/primary/`: `GFS-sosp2003.txt`,
`Spanner-osdi2012.txt`, `Chubby-osdi06.txt`. The remaining citations in
this section (Lustre internals, Ceph OSDI 2006, RFC 8881, MS-SMB2, GPFS
FAST 2002, Pacemaker fencing, Red Hat SCSI-3 reservations) are URLs in
the survey's report and are not captured here; each is a stable
published document.
