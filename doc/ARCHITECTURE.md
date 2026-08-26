# Architecture

How the DragonFly source is carried on Linux: what is vendored unchanged,
what is shimmed, and where the boundary is. Written for handoff section 37
item 2. `doc/IO_MODEL.md` covers the I/O layer specifically; this is the
shape around it.

## The rule the whole port turns on

The filesystem core is DragonFly's and is kept readable as DragonFly's. The
Linux work lives in a shim beneath it, so that a diff against upstream shows
the port and not a rewrite, and so Kusumi can take a fix in either
direction.

Concretely: a change to `hammer2_chain.c` that upstream would not recognize
is a defect here even when it works. Where Linux and DragonFly disagree, the
shim absorbs it. Where the shim cannot, the site is marked `/* Linux */` on
the line and `XXX` if it is a compromise rather than a translation.

## Layers

    src/sys/fs/hammer2/     the filesystem, DragonFly's, minimally touched
    src/sys/fs/hammer2/hammer2_os.h      OS primitives: locks, malloc, print
    src/sys/fs/hammer2/hammer2_compat.h  kernel look-alikes: KKASSERT, atomics
    src/sys/sys/{queue,tree}.h           vendored BSD data structures

The two-file shim split is Kusumi's, from the FreeBSD and NetBSD ports, and
it is followed here rather than invented: `hammer2_compat.h` holds things
that look like DragonFly kernel facilities and are implemented on Linux
primitives, `hammer2_os.h` holds the primitives themselves. Section order
inside `hammer2_os.h` follows the other ports exactly, so the three read
side by side.

## The vendored headers must not collide with the kernel's

`src/sys/sys/queue.h` and `tree.h` are BSD's, and the kernel has its own
macros with the same names. Any collision is latent rather than loud:
`hammer2_io.c` includes four kernel headers after the vendored ones, so a
BSD definition is live for the rest of the translation unit and the break
appears somewhere unrelated to either file.

Two were found on 2026-08-25 by compiling with a second compiler and a
`W=1`-class warning set: `LIST_HEAD` and `RB_ROOT`, both real kernel macro
names, both actually used. They are `BSD_LIST_HEAD` and `BSD_RB_ROOT` now.
An earlier instance, `__unused`, had already been found the same way.

The rule this leaves: nothing in `src/sys/sys/` may define a name the kernel
defines. `script/test-syntax.sh` compiles with both compilers and fails on
any warning in a file under `src/`, which is what keeps the class closed.

## Object and lifetime model

Three objects matter and only one of them is ours.

`hammer2_chain` is the core's, unchanged, and its lifetime is DragonFly's.

`hammer2_io` is the boundary object. It wraps one 64 KiB physical buffer and
is the only place the filesystem meets Linux memory. See `doc/IO_MODEL.md`
for its lifetime, which is where the port's real design decisions are.

`hammer2_dev` holds the per-mount state, including the device `struct file`
and the dio hash. There is no mount path yet, so its Linux lifetime is not
yet written; it is the first thing the mount work defines.

## Locking

`hammer2_mtx_t` is a `struct rw_semaphore_wrapper`: a `rw_semaphore` plus a
reference count and an owner pointer. The wrapper exists because DragonFly's
`mtx` interface answers questions Linux's does not, `hammer2_mtx_owned()`
above all, and the core asks them.

`hammer2_mtx_upgrade_try()` returns `hammer2_mtx_owned(p) ? 0 : 1` and is
marked `XXX`: it is a translation that satisfies the callers rather than an
implementation of the DragonFly semantics. It is the sharpest open item in
the shim.

Recursive acquisition is NOT provided. NetBSD's port handles the two call
sites that would need it individually, and this port follows that rather
than carrying a recursion counter nothing else wants.

## Build knobs

`HAMMER2_INVARIANTS` turns on `KKASSERT` and `KASSERTMSG`.
`HAMMER2_MALLOC` turns on the allocation leak counters.
`HAMMER2_ATIME` turns on atime updates.

All three are Kusumi's names from the other ports. Do not add a knob that
none of them has without saying why in the same commit.

## What does not exist yet

No mount path, no `file_system_type`, no superblock. The device layer in
`hammer2_ondisk.c` opens and sizes block devices and is called by a
`hammer2_vfsops.c` that does not exist yet, so nothing in this tree has an
entry point. The gates therefore compile and type-check; nothing here has ever been loaded into a kernel, and the first
kbuild compile is a decision rather than a task. `doc/README.status.md` is
the authority on what is done.
