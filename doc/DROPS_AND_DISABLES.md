# What this port drops, disables or defers, and why

Every behavior this port does not carry, compared with DragonFly's
HAMMER2, classified the way Rule 12 of the handoff requires: `implemented`,
`limited`, `deferred-with-trigger`, or `unavailable-with-reason`. A
behavior that is none of those is a defect in this document.

The rule that governs the classification: the mission is DragonFly parity
and then the original design. The three BSD ports are a reference for how
to map DragonFly onto an operating system. They are not a ceiling on what
to carry, and a file is carried or not on the mission, not on what the
ports chose for their own trees. That distinction is the reason this
document exists: the tree inherited several drops from the FreeBSD port
and recorded them in the ports' terms, which made a mapping choice look
like a scope decision.

## The cluster layer

| file | state | classification |
|---|---|---|
| `hammer2_synchro.c` | carried since 0.9.61, 1176 lines then, the origin table carrying the current count, measured by `cluster-sync.sh` and by `sync-empty-base.sh`, which reads the slave's cluster PFS against its master's | implemented |
| `hammer2_ccms.c` / `.h` | carried at 1.0.6, 323 and 177 lines then, the origin table carrying the current count with the lockdep exercise, building as `hammer2_ccms.o` | limited: the thread lock is carried and the coherency half is not written in any tree |
| `hammer2_iocom.c` | carried since 1.0.33 (P6), 387 lines then, the origin table carrying the current count; the span table and the `PROTO_2` admission are its stage 1 additions | implemented |
| `hammer2_msgops.c` | carried since 1.0.33 (P6), 87 lines then, the origin table carrying the current count | implemented |
| `kern_dmsg.c` | carried since 1.0.33 (P6), 2202 lines then, the origin table carrying the current count, with the socket transport, and since 1.0.44 the CRC check on a `PROTO_2` connection | implemented |
| the seven cluster ioctls | not implemented | deferred-with-trigger: P8, behind remote synchronization (P7); designed at `doc/CLUSTER_PROTOCOL_DESIGN.md` |
| `HAMMER2IOC_BULKFREE_ASYNC` | not implemented | deferred-with-trigger: its cancellation is unspecified; the synchronous scan is carried and measured |

The coherency half is the one place where "not written" is a fact about
the original rather than a decision of this port. `ccms_rstate_get()` was
to resolve a local lock against remote grant state and its body is one
assignment under `/* XXX */`. `doc/CCMS_DESIGN.md` records what is
reproducible and what is not, and `doc/CCMS_REFERENCE.md` holds the
sources. The design document puts the cache sub-protocol under the quorum
protocol, so the layer is a dependency of P8 and not of the transport
alone.

## The XOP thread pool

DragonFly runs XOPs on per-PFS worker threads: 27 references to
`hammer2_primary_xops_thread` and `xop_groups` across `hammer2_admin.c`
(12), `hammer2_vfsops.c` (13) and `hammer2.h` (2) at `250a8b4`. This port
has none: `hammer2_xop_start()` runs them
synchronously, which is what the FreeBSD port does and what
`README.porting.md` records as the mapping.

Classification: **deferred-with-trigger, and the trigger is multi-master.**
The pool is the mechanism that lets a cluster operation fan out to every
element concurrently and collect results through the FIFOs. Synchronous
XOPs serialize that, so a multi-master cluster pays the fan-out serially.
The ports substituted synchronous XOPs because their trees had no cluster
to fan out to; this port is building one. The decision is this project's
to make, and it is not made.

## Drops inherited from the ports, each with its own classification

| behavior | DragonFly | this port | classification |
|---|---|---|---|
| XOP thread pool | per-PFS worker threads | synchronous XOPs | deferred-with-trigger: multi-master |
| dirty-chain throttle and syncer | `hammer2_vfs_modifying()` before every modifying VOP | the wait called at the seven places a write can begin, `trigger_syncer()` as delayed work | implemented, differently: Linux has no such hook |
| `hammer2_lookup_device()` | three checks in one call | not carried; the Linux call already performs them | implemented, differently |
| `hammer2_gaccess_devvp()`, `hammer2_getw_devvp()`, `hammer2_putw_devvp()` | adjust a GEOM consumer's write count | not carried; Linux states the access once as a `blk_mode_t` | implemented, differently |
| `LOCKENTER` / `LOCKEXIT` | class CCMS's spin against the vnode locks | dropped; this port has no vnode lock in that sense | unavailable-with-reason: the annotation's subject does not exist here |
| `ccms_debug` | a dead `int` nobody reads, at line 52 of the deleted file | removed | implemented, differently |
| `panic()` | never returns | `hpanic()`, which marks the device in error and returns | implemented, differently; the two bad-state arms return after it |
| `->fallocate` | none | Linux-only, marked in place | implemented, differently |
| `->direct_IO` | none; `IO_DIRECT` means semi-synchronous | none; the open is refused with `EINVAL` | unavailable-with-reason: DragonFly has no direct path either, and the two systems differ in what they do with the flag |
| 32-bit and HIGHMEM | supported | refused by a `static_assert` | unavailable-with-reason: `hammer2_io_data()` hands the core a pointer it holds across sleeps |
| kernels older than 7.3 | supported | refused by an `#error` | unavailable-with-reason: the floor is the kernel of record and moves with the pin |

## What is not a drop

Worth stating because the ports' framing made it look like one. The
synchronous XOPs, the `mtx` in place of DragonFly's `mtx` word layout, the
`hpanic` in place of `panic`, and the seven call sites for the dirty-chain
wait are all *mappings*: DragonFly's behavior carried onto Linux
primitives. They are not absences. The distinction is whether the
behavior exists here in some form, and it does.

## What this document does not settle

- Whether the XOP thread pool is carried before or after multi-master.
  The dependency runs one way: multi-master needs the fan-out. Whether
  the pool is rebuilt as DragonFly has it or as something Linux-shaped is
  a design question, and it stops at a design note under the roadmap's
  rule.
- Whether `hammer2_iocom.c` and `hammer2_msgops.c` are carried as
  DragonFly has them or behind a transport-neutral message API. The
  handoff's work package 8 says to port `kern_dmsg` carefully and to
  define its boundary rather than paste a large DragonFly subsystem into
  Linux. That is a design question too.
- Whether the coherency half is written before the quorum protocol. The
  design document puts it under the quorum, and the quorum is P8, so the
  honest order is the quorum first.
