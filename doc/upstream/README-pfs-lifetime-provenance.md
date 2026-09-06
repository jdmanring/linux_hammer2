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

Measured in this port: four runs of the reproducer after the change with
no fault, against five faults in the seven runs before it, and the
fixture gate clean afterwards because the change touches the teardown of
every unmount rather than only a full one. Four runs is not many.
