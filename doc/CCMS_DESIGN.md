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
`cst->state` after it gets back what it asked for. The function is under
`#if 0`, so it never ran, and `ccms_lock_get()` and `ccms_lock_put()`,
which were to drive it, are absent from the file entirely: the header
declares them and no definition exists in the version that was deleted.
Dillon's own comment on the function says it "can be used to upgrade or
downgrade the state", which the body does not do.

So the original protocol is not a specification that can be reproduced
from the source. What the source holds is the vocabulary, the state names,
the type flags and the intended shape of the call sites. The agreement
procedure behind them was never written, in any tree, at any revision.

This is the fact the rest of the note rests on, and it changes what P3
can be. "Reproduce the original protocol before weighing a modern
replacement" is a rule this tree keeps, and it is satisfiable here only
for the part of the protocol that exists. The part that does not exist
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

The original grants over a topology subtree plus an inclusive key range.
Two shapes are available here.

A per-object state on the inode, which is what the header's "embeds
CCMS_CST structures in its internal inode representation" describes. One
state per inode, no range, so a write to one range of a file conflicts
with a read of another range of the same file. Simpler to place, and it
is what the surviving header's `ccms_cst` fields actually support: the
key range lives on the lock, not on the CST, in the deleted version too.

A per-range state on the chain, which is what the key range implies. A
`hammer2_chain` already covers a key range and already has a parent, so
the CST's natural home is the chain, and the topology recursion the
header requires is the chain's own parent walk. This is the shape that
makes the three-way split mean something.

The second is the one the format's own structure suggests, and it is the
larger change: it puts a state field on a structure the core allocates
and frees on every block, and the chain is the hottest structure in the
driver. The first is smaller and gives up range granularity.

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
already read here: a cluster is PFS roots sharing a `pfs_clid`, and the
node type is a `pfs_type` on the PFS root. Both are read by
`hammer2_cluster_check()` today. So a coherency layer adds no field to
the media, and an old reader of this port's media sees what it sees now.

The one place that could change is if a grant had to be durable across a
crash, which would put it in the format. The original does not do that
and this note does not propose it. If a later step needs it, that step
stops at a design note of its own under the same rule.

## What this note does not settle

- Which of the three agreement positions is taken. That is the
  maintainer's, and it is the decision the whole layer turns on.
- Whether the state lives on the inode or the chain.
- Whether the layer is built before the transport. The transport is P5
  and the message core P6; a grant needs both, and the roadmap's
  dependency order puts P4 between this step and them for the reason its
  row gives.
- Whether the surviving thread lock is carried at all. Alternative A
  argues it should not be, and the argument is a provenance one rather
  than a performance one.

## Provenance

- The pre-`94491fa098` `hammer2_ccms.c` and `hammer2_ccms.h`, read from
  the DragonFly clone at `250a8b4` by `git show 94491fa098^:...`. The
  clone is shallow, so the commit is read from the object store rather
  than from history.
- The surviving `hammer2_ccms.c`, 311 lines, and `hammer2_ccms.h`, 194
  lines, at `250a8b4`.
- `94491fa098` ("hammer2 - locking revamp", 2015-03-22), whose message
  states the intent to return the container when cache coherency lands.
- The port's own state: `command grep` over `src/` for the CCMS names,
  and the origin table in `doc/README.status.md`.
- The state model's invariants S6, S7 and the scenario list, from
  `proposals/hammer2-completion-handoff/HAMMER2_CLUSTER_STATE_MODEL.md`.
- The roadmap's rules and the P3 row, in `doc/README.roadmap.md`.
