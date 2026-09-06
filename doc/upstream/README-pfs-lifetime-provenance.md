# What is already known upstream about PFS lifetime at unmount

This sits beside
`dragonfly-hammer2_vfsops-pfsfree-clear-surviving-chain-pmp.patch` and
`ports-hammer2_vfsops-pfsfree-clear-surviving-chain-pmp.patch`, and it exists because those patches were written
before anyone checked what upstream had already done. They are not a
report of something nobody has seen.

## The hazard is known, and has been fixed once

DragonFly commit `1dc6036f`, 2023-06-20, `usr.sbin/makefs/hammer2: Fix
use-after-free caused by unmodified inode`:

> Unlike regular makefs usage for image creation, ioctl commands don't
> always modify all in-memory inodes. These unmodified inodes get freed
> in makefs vflush() via hammer2_inode_drop() on unmount before PFS sync,
> but they need to outlive chains.
>
> Add per-PFS reclaim list to keep all inodes intact during unmount
> process until PFS is ready to be freed.

That is the same family: an object released during the unmount sequence
while something the teardown still walks refers to it. It was found in
makefs, which is the userspace half, and the remedy was to extend the
object's lifetime until the PFS is ready to go.

The instance these patches address is the kernel half and the other way
around. A chain outlives its PFS rather than an inode being outlived by
chains: `hammer2_pfsfree_scan()` takes the PFS root chain out of the root
inode's cluster and drops it, the drop does not free it while a reference
remains, and the sync the same pass runs next reads `chain->pmp->mp`
through it.

## Two upstream idioms point different ways

`1dc6036f` keeps the referent alive. The function these patches touch
does the opposite for the same hazard a few lines further down, clearing
`hmp->vchain.pmp` and `hmp->fchain.pmp` by hand when the PFS being freed
is the super-root's. The patches follow the second because it is local
and in the same function, and because a NULL `pmp` is a state the chain
code already expects and tests for at every read. A reclaim list is the
more conservative shape and is what upstream chose the last time, and
whoever files this should expect that preference.

## What a maintainer will ask first, answered

**Does clearing the pointer create a NULL dereference somewhere else?**
No. Every read through a chain's `pmp` in the tree tests it first:
`hammer2_flush.c:769` sits inside `if (chain->pmp)`, both reads at
`hammer2_chain.c:1306` and `:1311` carry `chain->pmp &&` in their own
condition, and the three `chain->pmp && chain->pmp->mp` guards in the
flush are the site in question. A NULL `pmp` is also not a novel state:
`hammer2_chain_alloc()` sets it for every chain of the super-root
topology.

**What changes for a chain whose `pmp` is now NULL?** The guard it fails
is the one that decides whether the flush recurses through a PFS root,
and upstream's own comment there says what NULL means: "If the PFS has
not been mounted there may not be anything monitoring its chains and its
up to us to flush it". During a teardown that is true rather than a
convenient reading. The PFS is going away, nothing else is monitoring
its chains, and the flush that finds it is the one responsible for it.
The same function puts `hmp->vchain` and `hmp->fchain` into exactly that
state a few lines later.

**What is not claimed.** That this is the shape upstream would choose.
`1dc6036f` above solved the sibling by extending lifetime, and a
reviewer may prefer a reclaim list here for consistency with it. The
argument for this shape is that it is local, that it matches what the
same function already does, and that it needs no new structure; the
argument against is that it makes a chain's PFS unreachable at a point
where a future reader might want it.

## What could not be checked

Kusumi's three port repositories have issues disabled and carry no pull
requests, so there is no tracker to search on the FreeBSD, NetBSD or
OpenBSD side, and nothing there can be read as an absence of reports.

DragonFly's tracker at `bugs.dragonflybsd.org` is behind an
Anubis proof of work that refuses automated fetches, including through a
reader proxy. A search for `hammer2 unmount` was read by hand and
returned 29 results, of which the relevant ones are `1dc6036f` above,
bug 3352 on a broken `HAMMER2IOC_DESTROY`, and the open bug this project
filed on the HAMMER2 syncer wedging under a rapid newfs and cpdup loop.
That last one is a wedge in the syncer under repeated PFS creation, not
a page fault on unmounting a filled volume, so it is a different report
and not one to append to.

No search was run for the terms that would settle it directly, such as
`pfsfree` or `ENOSPC unmount`, so this is not a claim that the kernel
instance is unreported. It is a record of what was looked at.

## State of the change here

Measured in this port: four runs of a debug build after the change with
no fault, against five faults in the seven runs before it, then ten runs
of the shipping build with no debug knob set, all ten writing 583 files
to `ENOSPC`, none faulting, and the module unloading on every one. The
fixture gate ran clean afterwards because the change touches the
teardown of every unmount rather than only a full one. A held lock
freed report seen twice before this change has not recurred in the
fourteen runs since and is not explained, so the reproducer is not yet a
gate.
