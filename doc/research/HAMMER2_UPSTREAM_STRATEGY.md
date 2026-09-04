# HAMMER2 upstream strategy (H0 deliverable)

Part of the archaeology work package (`proposals/saxum_filesystem/`, documents
02 section 3 and 9, 07 section 7). Written 2026-08-25 by the specification
session. Filing anything with anyone is James's; this document says what to
file, to whom, in what order, and what must be true first.

## The shape of the port, and why that decides the strategy

Every existing port of HAMMER2 off DragonFly carries every core file and
rewrites the ones that face the operating system (`HAMMER2_PORTABILITY_AUDIT.md`,
measured per file): the on-disk format and the algorithm files port with
renamed primitives, `vnops`, `vfsops`, `io`, `strategy`, `admin` and
`ioctl` are rewritten, and the clustering subsystems are dropped. The three
BSD ports differ from each other by a few lines per file, so that rewrite is
one design applied three times. That is Tomohiro Kusumi's method, and it is
also how OpenZFS ships on Linux: a portable core, an OS layer, an out-of-tree
module built against the running kernel. A Linux port is the same rewrite a
fourth time against an operating system further from DragonFly than the BSDs
are from each other; the two deep concerns are the VFS entry and
buffer/cluster I/O, and the rest of the port surface is renamed primitives.
So the strategy is: carry the format and algorithm files, rewrite the same
files the ports rewrite, and send back upstream only what makes the carried
files easier to carry.

## The people, and what is known about them

- **Matthew Dillon**, DragonFly BSD, the author of HAMMER2. The core is his;
  the on-disk format and its invariants are his to confirm.
- **Tomohiro Kusumi**, author of the FreeBSD, NetBSD and OpenBSD kernel ports
  and of the Linux userspace stack (`libhammer2`, `hammer2-fuse`,
  `hammer2-utils`, `makefs` with HAMMER2). His README lists Linux as "TBD"
  under the kernel ports. The FreeBSD port's changelog shows read-only first
  (v1.0.x), writes from v1.1.5, and it is at v1.2.13.

No public statement on this disk or in the proposal says either has
committed to a Linux kernel port. The proposal's rule stands: collaboration is
an outreach opportunity, never a dependency, and no assumption of availability
is made without a public reply.

## Order of engagement

1. **Nothing is sent before H0 is complete.** A question to a maintainer
   that the source answers wastes the one thing that cannot be recovered,
   their attention. The fifteen research questions in document 02 section 9
   are answered from the trees first; what survives that reading is what is
   asked.
2. **First contact is a technical question set, not an announcement.** To
   Kusumi, about the ports: which shim decisions he would make differently
   now, which DragonFly assumptions bit hardest, what his Linux "TBD" was
   waiting on, and whether an out-of-tree Linux module carrying his port
   layout would be welcome as a sibling repository. To Dillon, about the
   format: the root checkpoint and durability ordering (questions 1 to 3),
   reserved fields (14), and whether the on-disk format is stable enough that
   a second kernel implementation should track a version.
3. **The port lives out of tree first**, as the OpenZFS module does, built
   against our kernel from a `linuxPackages.hammer2` derivation. The BSD
   license permits in-tree submission later, which OpenZFS's CDDL does not,
   and that is an asset to spend only when the port passes the flagship
   qualification gate, because a mainline submission of an immature
   filesystem driver is refused and remembered.
4. **Upstream contributions, in order of likelihood of acceptance:** fixes to
   the core found by the Linux port that also affect the BSD ports (to
   Kusumi's repositories, or DragonFly if they are core defects); shim
   improvements that reduce DragonFly-specific assumptions in the core (to
   DragonFly, framed as portability); the Linux module itself, to a
   repository of ours that mirrors Kusumi's layout so a future merge is a
   directory move.
5. **Linux side**: `linux-fsdevel` is engaged only when there is a
   reviewable driver with the fixture suite passing, and the first message is
   an RFC that states what the driver does not do. Before that, the relevant
   prior art to have read is how the out-of-tree filesystems that later went
   in (and the ones that did not) handled the buffer-cache and VFS
   transitions, which is the H1 design's reading list and is not repeated
   here.

## What must be true before anything is filed

- The provenance graph and per-file license audit exist and show every file
  in the Linux tree with its origin, copyright and license, and no file with
  an unknown one. The proposal forbids treating "BSD licensed" as a
  substitute for that table, and so does this document.
- The Linux port carries the upstream copyright notices unchanged and its
  own additions under the same license as the core, so that a merge in any
  direction is possible.
- Every claim in a filing is one this repository can show: a fixture, a
  test, a measurement. The hostile-audit rule for outward-facing artifacts
  applies to each filing as it does to any other.

## Findings staged for upstream, answered from source rather than asked

Each is a draft James files, after the hostile audit every filing gets; none
is a question, because the source answered it. Step 1 above is satisfied
for both: H0 is complete.

- **DragonFly `hammer2_chain_repchange()` takes `reptrack->spin` and
  releases it on no path** (`sys/vfs/hammer2/hammer2_chain.c:2324` at
  `22b0532`; the only `unex` of that lock in `sys/vfs/hammer2/` is the
  waiter's own at `:2271`). Reading 1 found it and parked it as a question
  for Dillon; investigated instead on 2026-08-25. It is in the commit that
  introduced the reptrack mechanism,
  `68b321c1c2fcb76069594715a2a617f08aeb59ec` (2018-03-16, subject exactly
  "hammer2 - More involved refactoring of chain_repparent, cleanup"),
  whose `hammer2_chain.c` hunks add the reptrack structure. `22b0532` is
  not merely byte-identical to master: `git ls-remote origin master` on
  2026-08-25 returns `22b0532`, so it IS the current head. The same lock sequence is in Kusumi's
  FreeBSD (`:2019`), NetBSD (`:2038`) and OpenBSD (`:2019`) ports, with no
  release in any of them. Two consequences on DragonFly, both from its own
  headers. The waiter in `hammer2_chain_repparent()` (`:2268`) takes the
  lock after following a re-parented chain and never returns; DragonFly's
  exclusive `spin_lock` (`kern_spinlock.c`, `indefinite_init(..., 'S')`)
  panics after sixty seconds of contested wait in every kernel, INVARIANTS
  or not, after a `(N secs)!` line each second before it
  (`sys/sys/indefinite2.h`, the `secs == 60` check outside the
  `INVARIANTS` block), and the panic reads `spin_lock_ex:
  hammer2_chain_repparent, indefinite wait!`, the ident being the caller's
  `__func__` because `struct spinlock` stores no name. And the DELETER is
  damaged whether or not a waiter ever arrives: `_spin_lock_quick` did
  `crit_enter_raw` and `++gd->gd_spinlocks` for `reptrack->spin` and
  nothing undoes them, so an INVARIANTS kernel panics in the deleting
  thread at its next blocking point (`lwkt_thread.c:650`, "still holding
  %d exclusive spinlocks!"), and a production kernel leaves that CPU's
  `gd_spinlocks` non-zero for good, so `lwkt_yield()` and
  `lwkt_user_yield()` return without yielding there (`lwkt_thread.c:1157`,
  `:1225`), and leaves the deleting thread's `td_critcount` elevated, so it
  is never preempted again (`:973`; `lwkt_preempt` itself tests
  `gd_spinlocks` only under INVARIANTS, `:1006`). With no waiter, an
  INVARIANTS kernel would have panicked; a production kernel only prints
  `hammer2: debug repchange` on every pass through the path (`:2333`). No
  issue on bugs.dragonflybsd.org mentions `repchange` or
  `hammer2_chain_repparent` (searched 2026-08-25 for the strings
  `repchange` and `hammer2_chain_repparent`, both zero results; the
  mailing-list archives were not searched, so this is a negative about
  the issue tracker and not about the project). The callers say
  why it is rare: `:4099` and `:4228`, both in
  `hammer2_chain_indirect_maintenance()`, an emptied indirect block and
  one collapsed into its parent, reached from the flush code only
  (`hammer2_flush.c:1040`, gated on `HAMMER2_BREF_TYPE_INDIRECT`; the
  flush code runs from the sync path (VFS_SYNC, fsync, the PFS create and
  snapshot ioctls, through `hammer2_xop_inode_flush`), unmount,
  mount-time recovery and fixup, and a chain's last drop, so the deleting
  thread can be a user thread), with a concurrent
  slow-path `repparent` holding a reptrack on that block.
  The first reply to expect is that the lock dies with the object it
  guards, and it does not: the reptrack is the waiter's own stack
  object (`struct hammer2_reptrack reptrack` at `:2205`, a local in
  `hammer2_chain_repparent()`), not state owned by the chain. It outlives
  the deleted chain by construction, `repchange` re-lists it on the new
  parent at `:2325-2328` rather than freeing it, and the waiter locks it
  at `:2268` afterwards. There
  is no deallocation that could release the lock implicitly.
  On the three ports
  the lock is a sleep lock (FreeBSD `sx`
  without `SX_RECURSE`, NetBSD `krwlock_t`, OpenBSD `rwlock`), so the
  DragonFly panic argument does not transfer and the observable there is a
  thread asleep forever in `sx_xlock` or `rw_enter`; the filing to Kusumi
  says that and not this. The fix is one release of `reptrack->spin`
  after the four field updates, first and in reverse acquisition order,
  before the chain and parent spins are released; the harness in
  `reptrack/` runs both functions' lock sequence as two threads and
  deadlocks stock, completes fixed. Whether a workload reaches the path
  is what the port's F3 and F5 runs will show, and that measurement goes
  in the filing.
- **libhammer2 0.5.0 (`e0b88b9`, upstream HEAD on 2026-08-25) panics in
  `Drop` after any `mount()` failure past `init_vchain()`**: `Drop` tests
  `cmap`, which the volume and freemap chains already fill, and calls
  `unmount()`, whose assertions (`src/hammer2.rs:1203-1206`) assume a
  completed mount. The reproduced instance is a PFS label the volume does
  not carry (`hammer2-fuse image mnt` on a DragonFly-installed root, whose
  PFS is `ROOT` and not the default `DATA`): the `:1206` assertion,
  exit 101. Run as `hammer2-fuse -d image mnt` the `ENOENT` line precedes
  it on the terminal; without `-d` the process daemonizes and its log goes
  to `$HAMMER2_HOME/.hammer2-fuse.log`, or to syslog when that path is
  unavailable, so the plain invocation shows the panic alone. That code is
  in the SEPARATE hammer2-fuse repository, v0.5.0 at `b92433c`
  (`src/main.rs:204` sets `use_daemon = !opt_present("d")`, `:219-228`
  chooses the logger), not in libhammer2, which is where every other line
  number in this finding points. The sibling `super-root not
  found` return is derived from source to fail at `:1205` the same way and
  has no reproducer here, which the filing states rather than presenting
  it beside the reproduced one. The staged patch makes `Drop` test the
  PFS root inode, Kusumi's own guard shape one field over; the alternative
  the filing offers him is `mount()` unwinding before returning `Err`.
  Nothing OS-visible leaks either way: the `Volume` owns a `File`, closed
  on drop. Reproduced with the packaged binary and with cargo builds stock
  against patched (`patches/README.md` at the repository root); the fixture plan's last section
  has the image.

### How the DragonFly citations above were read

The local DragonFly clone is a partial clone (`blob:none`), so the files
carrying the consequence citations were never fetched into the working
tree and a reader checking them there finds nothing. They were read from
the pack, which serves objects on demand, at `HEAD=22b0532` on 2026-08-25:
`git show 22b0532:<path>` for each. Confirmed that way, and each is quoted
above at the line given: `sys/sys/indefinite2.h:183-186` (the `secs == 60`
check, outside the `INVARIANTS` block, panicking `"%s: %s, indefinite
wait!"`), `:167-168` (the per-second `"(%d secs)!"` line), `:145-146`
(`'S'` maps to `"spin_lock_ex"`); `sys/kern/kern_spinlock.c:216`
(`indefinite_init(..., 'S')` on the exclusive contested path);
`sys/sys/spinlock2.h:58` (`spin_lock` passes `__func__`, which is why the
ident reads `hammer2_chain_repparent`) and `:111-112` (`_spin_lock_quick`
does `crit_enter_raw` and `++gd->gd_spinlocks`); `sys/kern/lwkt_thread.c`
at `:650`, `:973`, `:1006`, `:1157` and `:1225`.

An absent file in a partial clone is not an absent file upstream, and the
two look identical from the working tree. Any later reader re-checking
these should read them the same way rather than concluding the citations
are wrong.

## What is deliberately not in this strategy

A timeline. The proposal's H stages have exit criteria, not dates, and the
flagship qualification gate (document 07 section 8) is what ends the track.
Any statement to a maintainer about when something will exist is a promise
this project has not measured its ability to keep.
