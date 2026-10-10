# Cache coherency: what CCMS was, and what completing it has to prove

The P3 design note. The completion plan's row reads "cache coherency
(CCMS): a design note before any code", and the roadmap's own rule says a
decision that would change distributed commit semantics stops here. This
document is that stop. It carries no code and proposes no patch: it fixes
what the original protocol is, what the port carries today, which parts of
the original are recoverable and which are not, and what each alternative
would have to prove before it is written.

Read against the DragonFly clone at `250a8b4` and the forge, on
2026-10-10.

## The finding that makes this note necessary

The plan's P3 asked for the MESI state machine in `hammer2_ccms.c` to be
ported. There is no state machine to port. DragonFly took the file out of
its build in `94491fa098` ("hammer2 - locking revamp", 2015-03-22), whose
message says the container "will be used again when we get cache coherent
in, but for now it isn't needed", and deleted the coherency half in the
same commit. The half that survives is a recursive shared/exclusive thread
lock with no caller in any of the four trees.

The deleted half is worse than absent. `ccms_rstate_get()`, the function
that was to resolve a local lock against remote grant state, has this body
in the version the commit removed:

    static void
    ccms_rstate_get(ccms_lock_t *lock, ccms_cst_t *cst, ccms_state_t state)
    {
            /* XXX */
            cst->state = state;
    }

It assigns the requested state to the granted state. A caller reading
`cst->state` after it gets back what it asked for. Dillon's own comment on
the function says it "can be used to upgrade or downgrade the state",
which the body does not do.

The front end that calls it is written, and this is the part worth
reproducing. `ccms_lock_get()` acquires the three local locks in a fixed
order, topology then attribute then data, and only then resolves each
against the remote state:

    if (lock->req_t)
            ccms_thread_lock(&cino->topo_cst, lock->req_t);
    if (lock->req_a)
            ccms_thread_lock(&cino->attr_cst, lock->req_a);
    if (lock->req_d)
            ccms_thread_lock(&cino->data_cst[0], lock->req_d);

    if (lock->req_t > cino->topo_cst.state)
            ccms_rstate_get(lock, &cino->topo_cst, lock->req_t);
    else if (cino->topo_cst.state == CCMS_STATE_INVALID)
            ccms_rstate_get(lock, &cino->topo_cst, CCMS_STATE_ALLOWED);
    ...

Its comment states the ordering rule and why: local locks first, then the
remote resolution, because "once the local locks are established the CST
grant state cannot be pulled out from under us". It also states the
deadlock contract, which is the design's most interesting sentence: if
`ccms_rstate_get()` blocks it "will release all local locks and set the
FAILED bit", the remote grants are still acquired, and because the local
locks were lost the caller must loop. `ccms_lock_get()` carries the
`goto again` for it and `ccms_lock_put()` releases the three in reverse.

So the front end is a specification, and the loop, the ordering and the
failure contract are all reproducible. What is missing is the one step it
delegates.

The whole block sits under `#if 0`, and it would not compile if the guard
were removed. `ccms_lock_get()` dereferences `lock->cino` as a
`ccms_inode_t *`, and no such type is defined anywhere in the tree at that
revision: `command grep` over `hammer2.h`, `hammer2_ccms.h` and the three
files that would use it finds the name only in the header's prose and in
these two functions. The `data_cst[0]` it indexes is likewise a member no
structure declares. What the revision does define is a `ccms_cst_t` named
`cst` inside `struct hammer2_chain_core`, and a `ccms_cst_t` named
`topo_cst` inside `struct hammer2_inode`, whose comment says the attribute
CST "is embedded in the chain (`chain.cst`) and aliased w/ `attr_cst`".
The front end was written against a shape the same revision does not have.

So the original protocol is not a specification that can be reproduced
whole. What the source holds is the vocabulary, the state names, the type
flags, the three-way split, and the front end's ordering and failure
contract. The remote grant step behind them was never written, in any
tree, at any revision.

This is the fact the rest of the note rests on, and it changes what P3
can be. "Reproduce the original protocol before weighing a modern
replacement" is a rule this tree keeps, and it is satisfiable here for
everything except the one function the design turns on. That function
cannot be reproduced; it has to be designed, and a design is a decision
the maintainer takes rather than one this document can settle by reading.

## What the original defines

Read from `hammer2_ccms.h` before `94491fa098`. The header is the whole of
the surviving specification.

### States

    CCMS_STATE_INVALID      0   unknown cache state
    CCMS_STATE_ALLOWED      1   allow subsystem (topology only)
    CCMS_STATE_SHARED       2   clean, shared, read-only
    CCMS_STATE_EXCLUSIVE    3   clean, exclusive, read-only

Four states, not four MESI letters. The header calls it "an extended MESI
model" and puts the extensions in the type flags rather than in the state
number, so the mapping is not one to one: there is no state for Modified,
and `ALLOWED` is a topology-only state with no MESI counterpart at all.

### Type flags

    CCMS_TYPE_INHERITED     0x01   state inherited, not granted by the controller
    CCMS_TYPE_MODIFIED      0x02   associated with EXCLUSIVE
    CCMS_TYPE_MASTER        0x04   EXCLUSIVE+MODIFIED, slaves may cache unsynced state
    CCMS_TYPE_SLAVE         0x08   SHARED, mastered elsewhere, not yet synchronized
    CCMS_TYPE_QSALVE        0x10   slaved data also present in a quorum of masters
    CCMS_TYPE_RECURSIVE     0x80

`QSALVE` is spelled that way in the header and in every revision of it.
The misspelling is carried rather than corrected here because it is the
name a reader of the upstream file will search for.

The flags carry what MESI's letters carry in a flat model, and two of them
carry more. `MASTER` says slaves may be holding state this node has not
synchronized, which is a statement about other nodes rather than about
this one's cache line. `QSALVE` says the data is in a quorum of masters,
which is a statement about the cluster's agreement rather than about any
cache. Neither is expressible as a MESI state, and both are load-bearing:
a node that cannot tell `SLAVE` from `QSALVE` cannot tell whether the copy
it holds has been agreed.

### The two lock layers

`ccms_cst` is the persistent cache state, one per object or per topology
range, holding `state`, `type`, a `count` whose sign selects shared
(positive) or exclusive (negative), an `upgrade` count, a `blocked` flag
and the owning thread. The comment requires high-level CST locks to be
obtained top-down, and permits the structural spin to be taken
bottom-up for race-to-root flag updates.

`ccms_lock` is the active front-end request, holding three CST pointers
(`topo_cst`, `attr_cst`, `data_cst`), the requested states `req_t`, `req_a`
and `req_d`, and an inclusive key range `key_beg` to `key_end` that
applies to the data state. So a single front-end operation resolves
against three separate cache states at three granularities: the topology
path to the object, the object's attributes, and a byte range of its data.

That three-way split is the part of the original worth keeping whatever
the agreement procedure turns out to be. It is what lets a read of one
range not conflict with a write of another, and it is the reason the
protocol needs a key range rather than a per-inode state.

### The topology requirement

The header states a precondition that is not a locking detail:

> To operate properly the VFS must maintain a complete directory topology
> leading to any given vnode/inode either open or cached by the system.
> The vnode/namecache subsystem does not have to implement this but the
> VFS (aka HAMMER2) does.

Coherency is granted over subtrees and inherited down them, so a node that
cannot name the path from the cluster root to an object cannot decide
which grant covers it. This port keeps a complete topology: `hammer2_chain`
holds every chain from the volume root down, and the inode and chain
structures carry the parent links the recursion needs. The requirement is
met, and it is met by the core rather than by anything added for
clustering.

## What the port carries today

Nothing of CCMS. `command grep` over `src/` for `ccms_cst`, `ccms_lock`,
`ccms_domain`, `CCMS_STATE` and `CCMS_TYPE` returns no line. The only
mention is a comment in `hammer2.h` recording that the FreeBSD port
deletes the layer and that this port follows it.

What the port does carry, and what a coherency layer would sit on:

- `hammer2_cluster.c`, 480 lines, with `hammer2_cluster_check()` restored
  from DragonFly's. It decides a cluster's validity from the PFS's master
  count, and its quorum logic is upstream's rather than the FreeBSD port's
  reduced version.
- `hammer2_synchro.c`, 1176 lines, carried. It drives the core over
  `kprintf`, `KKASSERT`, `tsleep`, `wakeup`, `kmalloc` and `kfree` and
  calls no `kdmsg` function, so it runs with no transport. Measured by
  `script/cluster-sync.sh`, which keeps a SLAVE on a second local device
  in step with its MASTER, and `script/cluster-quorum.sh`, which reaches
  the quorum a two-MASTER cluster is decided by.
- The node types. `pfs-create` takes the five types a cluster element can
  be, and `hammer2_cluster_check()` reads them. The state model's six
  roles are the original's; the port's ioctl accepts five, which is the
  set the three BSD ports and DragonFly agree on.

So the port has the topology, the node types, the local quorum decision
and the synchronization thread. It has no cache state, no grant, and no
way to ask another node for one.

## What "completing CCMS" has to decide

Four decisions, in the order they constrain each other. Each is the
maintainer's, and each names what it blocks.

### 1. What the grant is granted over

The original answers this, and the answer is not one placement but three.
The revision before `94491fa098` puts a `ccms_cst_t` named `topo_cst` in
`struct hammer2_inode`, and a `ccms_cst_t` named `cst` in
`struct hammer2_chain_core`, and its comment on the inode says the
attribute CST "is embedded in the chain (`chain.cst`) and aliased w/
`attr_cst`". So topology state lives on the inode, attribute state on the
chain, and the two are the same storage seen under two names.

The data state is the one the revision does not place. `ccms_lock_get()`
indexes `cino->data_cst[0]`, an array member no structure in that revision
declares, and the `ccms_inode_t` it reaches through is undefined. The
header's key range, `key_beg` to `key_end`, is on the lock rather than on
the CST, which is consistent with one CST per range and settles nothing:
the array's shape is not written down anywhere, and the `[0]` index is the
only use of it in the tree. What would settle it is a revision that
defines `ccms_inode_t`, and there is none.

What that leaves here is a real decision, and it is narrower than it first
looked. The topology and attribute halves have a placement the original
chose, and a port can follow it. The data half has none, and the port's
`hammer2_chain` is the structure that already covers a key range and
already has a parent, so it is where a range state would go. That is the
larger change of the two: it puts a state field on a structure the core
allocates and frees on every block, and the chain is the hottest structure
in the driver. The churn reading the roadmap records (twenty thousand
files under a hundred directories, four writers, create 12 to 13 s) is
the control that would move if the field cost anything.

### 2. Where the agreement procedure lives

This is the decision the original does not make for us, because it never
made it. Three positions, each with a different cost.

In the cluster controller, as the header's language assumes: a node asks
the controller for a state and the controller arbitrates. This needs the
transport, so it cannot be built before P5 and P6, and it makes the
controller a single point whose loss stops grants. The original's
`QSALVE` flag says the controller was expected to know which masters hold
a copy, which is a quorum question, so this position couples CCMS to the
quorum protocol rather than to the transport alone.

In the masters, by a quorum vote per grant, which is what the state
model's S6 invariant ("exclusive ownership cannot exist simultaneously at
two authoritative nodes") requires. No controller, so no single point,
and every grant costs a round trip to a quorum. The original's `MASTER`
and `SLAVE` flags describe this shape.

By lease, where a node holds exclusive state for a bounded time and the
state expires if it cannot renew. This is the only one of the three that
satisfies the state model's S7 invariant ("lost communication must
eventually invalidate ownership that can block the rest of the cluster")
without a separate mechanism, because expiry is what a lease does. It
also needs a clock whose disagreement between nodes is bounded, which is
a new requirement on the cluster and is not in the original at all.

The roadmap's rule that the original protocol is reproduced before a
modern replacement is weighed applies to this decision and cannot be
satisfied as written, for the reason the first section gives. What can be
reproduced is the vocabulary and the three-way split; what has to be
chosen is the procedure. The honest statement is that this is new design
at a boundary the original left open, not a port.

### 3. What a grant is checked against locally

The surviving thread lock resolves a local lock against `cst->state`, and
the deleted `ccms_rstate_get()` was to set that field. Whatever replaces
it has to answer, for a request, whether the locally held state covers it
and what has to be asked for if it does not. The port has no such check
today, and the four states plus six flags are the vocabulary it would be
written in.

The one property that must hold and is easy to get wrong: a grant that is
inherited (`CCMS_TYPE_INHERITED`) is not a grant this node made, so it
cannot be downgraded by this node's own decision. The header says grants
"can be recursively inherited, minimizing protocol overhead", and the
inheritance is exactly where a node would wrongly believe it owns
something.

### 4. What happens to a grant when its holder goes away

The state model's S7 again, and the scenario list names it directly as
"MESI holder disconnects". The original has no answer: `ccms_cst_uninit()`
in the surviving version is a `KKASSERT` and an empty `if` whose body is
`/* XXX */`.

Three answers are available and they are not equivalent. A grant is
released on an orderly disconnect and held until an epoch change on an
abrupt one, which is safe and can block the cluster until the node
returns. A grant expires on a lease, which is what S7 asks for. A grant
is revoked by a quorum that agrees the holder is gone, which needs the
quorum protocol to be able to decide a member is gone, which is P8.

## Alternatives, and what each would have to prove

The rule the roadmap sets is that a decision changing distributed commit
semantics stops at a design note "with alternatives and what each would
have to prove". This section is that.

### A. Carry the surviving `hammer2_ccms.c` and add the coherency half

What it is: port the 311-line thread lock, then write the agreement
procedure behind it.

What it would have to prove: that the thread lock has a caller. It has
none in any of the four trees, and the port already has a recursive
exclusive hold, a shared re-lock and a shared-to-exclusive upgrade on
DragonFly's `mtx`, carried as a primitive of the shim's own and judged on
the churn reading the roadmap records. Carrying a second recursive lock
to sit under a coherency layer that does not exist yet is code upstream
does not compile, which this tree's provenance rule treats as a defect.
The thread lock would have to earn its place against the `mtx` already
here, and on the evidence it does not.

### B. Put the state on the chain and the procedure in the masters

What it is: a `ccms_cst`-shaped field on `hammer2_chain`, the four states
and six flags as the vocabulary, and grants decided by a quorum of
masters over the transport.

What it would have to prove: that a state field on the chain does not
cost the paths that never cluster. The chain is allocated and freed on
every block, and the churn reading the roadmap records (twenty thousand
files under a hundred directories, four writers, create 12 to 13 s) is
the control that would move if the field did. It would also have to prove
that a per-grant quorum round trip is affordable on the write path, and
that the `MASTER` flag's claim about unsynchronized state held by slaves
stays true across a synchronization pass, which is what
`hammer2_synchro.c` does and what `cluster-sync.sh` measures.

### C. Lease-based ownership, no controller

What it is: exclusive state held for a bounded time, renewed while the
holder is live, expiring otherwise, with the four states kept as the
local vocabulary and the six flags kept as the description of what the
cluster believes.

What it would have to prove: that clock disagreement between nodes is
bounded below the lease, which is a property no instrument here can
measure because there is no second host. It would also have to prove
that expiry cannot revoke a grant whose holder is alive and mid-write,
which is the failure that turns a lease into data loss rather than a
liveness fix.

### D. Do not build it, and say so

What it is: record that CCMS is unavailable, name the reason, and stop.

What it would have to prove: nothing, and that is the point. The state
model's S6 and S7 are properties of a cluster, and this port has no
second host: `cluster-sync.sh` and `cluster-quorum.sh` put both volumes
on one machine, and the roadmap's own row for P8 says "a quorum that
cannot be met is not" measured. A coherency layer whose invariants cannot
be exercised is a layer whose invariants are not known to hold, and the
capability table's rule is that the port is never reported as providing a
guarantee it cannot provide.

This alternative is the one that costs nothing and is honest, and it is
the one that should be taken unless the maintainer decides the design is
worth writing ahead of the transport. The two are not exclusive: the
vocabulary, the three-way split and the four decisions above can be
recorded now, as this document records them, and the code can wait for
the instrument that would judge it.

## The compatibility and versioning position

The roadmap's rule is that a change to on-disk meaning is an extension
with a written design, a compatibility and versioning plan, and what an
old reader does with it.

Nothing in this note changes on-disk meaning, and the reason is
structural rather than a promise. CCMS state is cache state: it describes
what a node believes about data that is already on the media, and it is
reconstructed rather than read back. The original says so in the
header's first paragraph, "persistent cache management state", where
persistent means it survives a mount rather than that it is stored in the
format. A node that loses its state asks for it again; a node that never
had it asks for it for the first time.

The format's own cluster vocabulary is already on the media and is
already read here: a cluster is PFS roots sharing a `pfs_clid`, which the
mount path matches on (`hammer2_vfsops.c`, where a volume whose PFS root
carries the same `pfs_clid` joins the mount), and the node type is a
`pfs_types[]` entry on the PFS root, which `hammer2_cluster_check()` reads
to count masters for its quorum. So a coherency layer adds no field to
the media, and an old reader of this port's media sees what it sees now.

The one place that could change is if a grant had to be durable across a
crash, which would put it in the format. The original does not do that
and this note does not propose it. If a later step needs it, that step
stops at a design note of its own under the same rule.

## What this note does not settle

- Which of the three agreement positions is taken. That is the
  maintainer's, and it is the decision the whole layer turns on.
- Where the data state lives. The topology and attribute placements are
  the original's and are recorded above; the data half has no placement in
  any revision, and the chain is where a range state would go.
- Whether the layer is built before the transport. The transport is P5
  and the message core P6; a grant needs both, and the roadmap's
  dependency order puts P4 between this step and them for the reason its
  row gives.
- Whether the surviving thread lock is carried at all. Alternative A
  argues it should not be, and the argument is a provenance one rather
  than a performance one.
- Whether `ccms_lock_get()`'s ordering and failure contract are carried as
  they stand. They are the part of the original that is written down, so
  the default is to keep them; the `goto again` loop is only meaningful
  once the step it retries exists.

## Provenance

- The pre-`94491fa098` `hammer2_ccms.c` and `hammer2_ccms.h`, read from
  the DragonFly clone at `250a8b4` by `git show 94491fa098^:...`. The
  clone is shallow, so the commit is read from the object store rather
  than from history.
- The `ccms_cst_t` placements, from the same revision's `hammer2.h`:
  `topo_cst` in `struct hammer2_inode` and `cst` in
  `struct hammer2_chain_core`.
- The surviving `hammer2_ccms.c`, 311 lines, and `hammer2_ccms.h`, 194
  lines, at `250a8b4`.
- `94491fa098` ("hammer2 - locking revamp", 2015-03-22), whose message
  states the intent to return the container when cache coherency lands.
- The port's own state: `command grep` over `src/` for the CCMS names,
  and the origin table in `doc/README.status.md`.
- The state model's invariants S6, S7 and the scenario list, from
  `proposals/hammer2-completion-handoff/HAMMER2_CLUSTER_STATE_MODEL.md`.
- The roadmap's rules and the P3 row, in `doc/README.roadmap.md`.

An earlier version of this note said `ccms_lock_get()` and
`ccms_lock_put()` had no definition in any revision, which was wrong:
both are defined in the version `94491fa098` deleted, at lines 98 and 160,
inside the `#if 0` block that also holds `ccms_rstate_get()`. The claim
was written from the header's declarations without reading the body, and
the body is the more useful finding, so it is recorded here rather than
quietly replaced.
