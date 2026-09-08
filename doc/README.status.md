Status
======

The driver mounts DragonFly-written HAMMER2 media read-write on Linux
7.3 and newer, and every operation it carries has been read back by
DragonFly itself. The tree is at 0.9.17 in `CHANGELOG.md`; nothing is
tagged. What stands between it and 1.0 is the release shape and the
filings staged under `doc/upstream/`; the throughput reading is taken.

| what | state | read by |
|---|---|---|
| mount read-only by PFS label, list, read, symlinks, LZ4 and ZLIB blocks | every fixture file compares byte for byte with the tree it was made from, on `makefs` media and on media DragonFly wrote, including a DragonFly guest's installed root | `test-fixtures.sh` |
| media that fails its checks | a block whose check code does not match is refused on read; a volume header that fails its crc is not mounted | `fuzz-mount.sh` |
| mount read-write, every write operation from a byte written to a directory renamed | written here, read back and checked by DragonFly | `f4-roundtrip.sh` |
| a writer killed, a kernel panicked, the power cut, a header torn | each left a volume that both this port and the FreeBSD port recovered to the same tree | `crash-matrix.sh`, `cut-flush.sh` |
| remount from read-only to read-write | runs the same recovery the mount path runs; refused only when the device itself is write-protected | `doc/history/verification-record.md` |
| HAMMER2's ioctls | answer as Linux ioctls, so `hammer2-utils` drives the volume; a snapshot taken here mounts on DragonFly and reads back the tree as it stood | `pfs-domains.sh` |
| mmap and exec | files map and execute; a kernel has booted with a HAMMER2 root | `root-boot.sh` |
| a full volume | the fill is refused as the other trees refuse it, and the volume unmounts clean; the defects the fill found are in the record | `test-enospc.sh` |
| a million files, and a Nix closure of two hundred thousand | written through the write path, counted on both sides, identical on both, lockdep on throughout | `million-tree.sh`, `nix-closure.sh` |
| one large file | on the release build of the kernel of record, writes at twice the rate of ext4 and btrfs and reads at three times the rate of DragonFly's own kernel on the same volume, and at a third of btrfs, which is one reader's checksum and copy; every reading before 2026-09-07 was the debug kernel's | `throughput.sh` |
| space a remove does not free | the bulkfree scan frees it | `bulkfree.sh` |
| a device in error | `hpanic` marks the device and returns; the writer is told `EIO`, the mount goes read-only, the media stays at the last good sync | `hpanic-contain.sh` |

Every row above was measured, and the measurements are in
`doc/history/verification-record.md`, section by section in the order
they were taken, with the instrument, the date and the defects each one
found. `CHANGELOG.md` is the enumeration of what landed. This file is the
one to correct rather than to argue with: if a claim here is stale, it is
a defect.

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1402 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1205 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_admin.c` | 634 | FreeBSD port, carried with two `XXX` lines: the XOP inode dependency wait no longer sets the PFS-wide waiting flag and its retire wakes unconditionally, since the flag was cleared by a retire on another index and a writeback worker slept for good; the xop allocation zone is shimmed |
| `hammer2_freemap.c` | 1030 | FreeBSD port, carried with three `XXX`: the allocation refusal the debug build takes from `fail_alloc_after`, the print of what a refusal saw, and the return after `hpanic` |
| `hammer2_xops.c` | 1453 | FreeBSD port, carried byte-for-byte but two `XXX` lines, the lock level of the inode chain the detached create makes and the subclass of the entry the rename holds detached |
| `hammer2_ioctl.c` | 1164 | FreeBSD port, carried with fifteen `XXX`: the seek ioctls and GEOM dropped, the read-only test and the copy-out on Linux primitives, growfs clearing headers through the DIO layer, the mount-wide sync through the kernel's, an unrecognized command answered ENOTTY rather than EOPNOTSUPP, and the snapshot's lock order corrected under lockdep |
| `hammer2_bulkfree.c` | 1239 | FreeBSD port, carried byte-for-byte; `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 5157 | FreeBSD port, carried byte-for-byte but the `XXX` lines below, the debug build's list of every chain and the print of what is left at the unload, the lockdep class set where a chain lock is initialized, the nesting level handed to the shim where a chain is first placed under its parent or created under one, the level below for the children an indirect block takes over, the new block's own first lock recording no order, the caller's chain left alone when an indirect block cannot be created, the last drop of a chain naming the caller that still holds its lock, and the way out after each of its `hpanic` sites; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed |
| `hammer2_flush.c` | 1354 | FreeBSD port, carried; the device flush and the volume header write are the port decision below, marked `XXX` in place, the header write reads the device-in-error bit, and the three `hpanic` sites record their error |
| `hammer2_cluster.c` | 189 | FreeBSD port, carried byte-for-byte but the one `XXX` after its `hpanic`; nothing in it touches the OS |
| `hammer2_subr.c` | 450 | FreeBSD port, carried; the timestamp, the signal check and the two `timespec64` signatures are marked `XXX` in place, and `hammer2_getnewfsid()` is not carried |
| `hammer2_inode.c` | 1914 | FreeBSD port; carried, `hammer2_inode_create_normal()` with the owner rule written against the idmap. `hammer2_igetv()` is this port's, written on `iget5_locked()` |
| `hammer2_vfsops.c` | 3276 | FreeBSD port; the PFS half and the recovery carried, the module entry, globals, mount path, mount helper, evict_inode, and sops this port's. A rewrite with a carried body, since Linux redistributes `hammer2_mount()` across four `fs_context` callbacks |
| `hammer2_strategy.c` | 1458 | this port's; `hammer2_dedup_clear()` carried, both XOP handlers are floors |
| `hammer2_vnops.c` | 1526 | this port's; `->lookup` is upstream's `hammer2_lookup()` with the dcache's own cases and the nameiop pre-checks dropped, and the four operations tables have no BSD counterpart, a vnode taking its vop vector from the mount rather than from its type |
| `hammer2_ondisk.c` | 1043 | FreeBSD port; the volume-header verification half carried, the device half rewritten on `lookup_bdev()` and `bdev_file_open_by_path()`, and four functions not carried: `hammer2_lookup_device()` and the three GEOM access helpers |
| `hammer2_mount.h` | 58 | FreeBSD port, carried; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 1228 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 1235 | ours, the OS shim |
| `hammer2_compat.h` | 198 | ours, kernel look-alikes; the BSD `vtype` enum and the `MNT_WAIT` pair, which no Linux header has |
| `hammer2_rb.h` | 207 | FreeBSD port's `RB_SCAN`, carried, with DragonFly's scan bookkeeping over the vendored tree |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

### Upstream heads, as last read

Read from the forge on 2026-09-07, the check `doc/README.maintenance.md`
names: the FreeBSD, NetBSD and OpenBSD ports are all at v1.2.13, which
is what the snapshots beside this repository hold (`3df307f`, `64095c3`,
`a3747df`). DragonFly's newest commit under `sys/vfs/hammer2` is
`40e5c5625` of 2026-09-02, which puts the unmount chain dump under
`#if 0` in `hammer2_vfsops.c`; the two before it touch `hammer2_vnops.c`
and `hammer2.h`. None of the three touches a file in the carried set,
so nothing starts a sync.

## What has been verified

Eleven of the thirteen gates pass with no environment variables set on a
machine that has the kernel of record installed, as they have since
2026-08-26: the syntax gate finds that tree, and the style gate finds its
`checkpatch.pl`. The other two, `test-fixtures.sh` and `test-enospc.sh`,
report COULD-NOT-RUN there and on every machine without a guest, a set of
fixture images and a `KDIR` matching the guest's kernel, which is most of
them and all of CI.
What that unattended style run can say is narrower than it looks, and the
narrow half is the useful one: the found checker's `sha256` does not match
the baseline's, so an unchanged set is reportable and a moved set is not.
The gate exits 2 rather than charge a move to the code, which means the
one run that matters, the run after a carried file lands, needs
`CHECKPATCH` pointed at the checker the baseline names. That happened
twice on 2026-08-26. Saxum's delegator, which runs these same gates from another
repository, enumerates `script/test-*.sh` instead of naming them, so a gate
added here is picked up there without an edit. Each gate prints its own
count, and the gates are the authority; the dated figures below are snapshots
of one run.

`test-checkpatch.sh` is the one that commonly cannot run. It needs
`checkpatch.pl`, which no kernel headers package ships, so it exits 2 unless
`CHECKPATCH` or `KDIR` points at a full source tree. That is could-not-run,
not a pass.

- `script/test-shim.sh` and `script/test-syntax.sh`: 6 and 28 on 2026-08-26,
  two of the thirty-four being controls that must fail and do. The shim
  gate's sixth check is the one that reads its own coverage: an inline the
  driver never calls is barely checked by the compile, and the count says
  whether any are missed.
- `script/test-checkpatch.sh`: holds the style deviation set at its recorded
  856 hits under the checkpatch.pl the baseline names, and under the kernel
  of record's own patched copy, which differs by sha256 and produces an
  identical set. Neither figure travels without the checker that produced it;
  856 quoted bare reads as a mainline number and is not one. With no baseline
  present the gate refuses rather than writing one.
- `script/test-history.sh`: resolves every commit the roadmap's history
  table pins and checks its subject still matches, then prints how many
  commits touching `src/` or `script/` have landed since the newest row.
  That second half never fails, since whether a commit deserves a version row
  is a judgment.
- `script/test-inventory.sh`: the directory is the population, and three
  hand-maintained lists claim to cover it: the origin table in this file, the
  Makefile's `hammer2-y`, and the filenames `script/test-syntax.sh` names one
  by one. A `.c` missing from the second is dead code; missing from the third
  is a file no compiler ever sees while every check reports passing. It also
  checks the origin table's line count against the file, which is the column
  that rots on an ordinary edit, and two rows had drifted before the check
  existed. A count column that is not a number is left alone.

  `test/` is a second population, added 2026-08-26 after two vector files
  were found tracked and named in no document here. Every file there is now
  either named by a gate or listed in `README.testing.md`. Both vector files
  turned out to be compiled by a gate in Saxum, which no search of this
  repository could have said, so that table records a contract with a
  consumer this tree does not reference.

- `script/test-citations.sh`: every `file:line` citation in a `doc/` table
  resolves, and where the row names a symbol, that symbol is on the line. The
  64 KiB inventory is thirteen such rows and nothing had ever read them. A
  line number rots on the next edit while still looking like a citation, and
  the 0.2 import edits exactly those files. It compares against the source
  line, never a stored baseline, and a row naming no symbol is reported as
  unanchored rather than dropped.

That the gates pass means the shim is valid C in both knob positions, and
that `hammer2.h` and `hammer2_io.c` type-check against the real kernel
headers of the kernel of record with both clang and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, which is why `doc/history/verification-record.md` records what
`make` does, and everything observed running from the first mount on,
with the instrument that observed it. The shipped build mounts read-write and remounts read-write from
read-only, and upstream's recovery is carried and runs on both paths.

## What is not here

`hammer2_strategy.c`, `hammer2_vfsops.c` and `hammer2_vnops.c`. All
three are OS-facing and all three are rewrites. That is what makes them
the remaining three; it is not a claim that nothing in them can be read
off a BSD port. `hammer2_strategy.c` in particular has chain logic
around its buffer handling, and how much of that carries is a question
for the file, not for this list.

`hammer2_ioctl.c` was in this list until 0.7.0 and is not a rewrite: it
came from the FreeBSD port whole and carries fifteen `XXX`, which is
where the OS shows through rather than a reimplementation.

The carried set is eight files at 11,204 lines, measured against all three BSD
ports: `hammer2_chain.c`, `hammer2_flush.c`, `hammer2_freemap.c`,
`hammer2_bulkfree.c`, `hammer2_xops.c`, `hammer2_admin.c`,
`hammer2_cluster.c` and `hammer2_subr.c`. `hammer2_ondisk.c` landed on
2026-08-26 and is not in it: half of it is carried and the device half is
this port's, which is what `doc/provenance.csv` records as `derived`.
Whether `hammer2_inode.c` joins the carried set is what that same carry
column will say.

### Logging

Every line `hprintf` prints names the module, and a line the core builds
out of several calls stays one line. Neither was true before 2026-08-26,
and neither is visible in a compile, so `test-shim.sh` reads both out of
the preprocessor's own output rather than taking a comment's word.

Linux's native mechanism for the first is `#define pr_fmt` at the top of
every `.c` file, ahead of the first kernel header. That is unavailable to
the files that do most of the logging here: they are carried
byte-for-byte, and adding a line to one is the edit this tree exists to
avoid. Measured with only `hammer2_io.c` carrying the define, five
carried files held every other call site and printed anonymously. The
name now lives in `hprintf` itself, which is this port's macro, so there
is one copy of it and no file has to remember anything.

**The literal prefix is `hammer2: `**, and a gate matching dmesg from 0.3
on should match that. It is `KBUILD_MODNAME`, which kbuild derives from
`obj-m += hammer2.o` in `src/sys/fs/hammer2/Makefile`, so it cannot drift
without the module's own filename drifting with it. Under
`HAMMER2_INVARIANTS` the function name, command and pid follow it; without
the knob, the function name alone. Both shapes start with `hammer2: `.

The second is `printf`, which on a BSD kernel appends to the open line;
`hammer2_bulkfree.c` prints a range with `hprintf` and no newline and
finishes it with `printf`. `pr_info` closes a record per call, so that
mapping turned one line into two and dropped the second's prefix.
`pr_cont` is Linux's name for the semantics the core is written against.

It is not free. `pr_cont` deliberately does not apply `pr_fmt`, so a `printf`
that opens a line prints without the module name. Every plain
`printf` in the carried core was classified by hand on 2026-08-26, all
thirteen of them:

| where | sites | kind | under `pr_cont` |
|---|---|---|---|
| `hammer2_bulkfree.c` | 7 | continuations of an `hprintf` that opened the line | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 2 | continuations | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 4 | line starts | correct line structure, no module name |

So four lines in the tree print anonymously, all four inside one debug
tree dumper, and no status or error path is among them. The alternative
mapping reverses that trade: `pr_info` names those four and splits the
other nine into eighteen lines, half of them unprefixed anyway. Neither
macro can be right at both kinds of site, since the discriminator is whether
the previous call ended in a newline, which is a runtime fact.
The `DEFER` in `hammer2_os.h` names the only mapping that is right at
both: build the line in a buffer and emit it once, which is a core edit.

checkpatch flags `pr_cont` deliberately and by name, and the deviation is
recorded in `README.kernel-style.md`.

### `DEFER` markers: the deliberate floors and what lifts each one

An `XXX` marks a mapping a reader should distrust. A `DEFER` marks
something this port chose not to build yet, and the rule the tree follows
is that a deferral without a named trigger is rot rather than pragmatism,
so each one carries the condition that lifts it. `test-inventory.sh`
checks that every `DEFER(` in `src/` appears in this table and that the
table has no row for a marker that is gone, because a ledger nothing reads
against the source is the same shape as an empty one.

| where | marker, verbatim | what is deferred |
|---|---|---|
| `hammer2_os.h`, at the print macros | `DEFER(a message is seen interleaved in a real mount)` | `pr_cont` is not the right mapping at both kinds of site; the table above measures the trade. The fix is a line buffer, which is a core edit |
| `script/hammer2-provenance.py`, in the scope note | `DEFER(a userland file is imported into the module tree)` | the CSV generator walks the kernel core only. `sbin/hammer2`, makefs, libhammer2 and hammer2-utils are packaged separately and audited in the license audit's own tables, so `TREES` widens the day one of their files is carried into `src/` |
| `src/sys/fs/hammer2/Makefile`, at `CARRIED_CFLAGS` | `DEFER(the tree is prepared for submission)` | kbuild's `-Wimplicit-fallthrough=5` reads only the `fallthrough` attribute and upstream marks its switches with a `/* fall through */` comment, and kbuild's `-Wunused` sees `hammer2_inode_lock_temp_release()` and `_restore()`, whose only caller in either upstream is `hammer2_igetv()`, the one function this port rewrote on `iget5_locked()`, where the dance they perform has nothing to race against. They have no caller here and are not expected to gain one; they stay because deleting two functions from a carried file is a core edit. Both are suppressed on the carried files rather than edited into Linux spelling, because converting either early splits the core into two dialects. They become edits in the single conversion that also settles BSD style |
| `hammer2_vfsops.c`, at the module parameters | `DEFER(a second filesystem-wide knob wants a per-mount value)` | the tunables are `module_param_named()` under `/sys/module/hammer2/parameters/`, one value for every mount on the machine, which is what `sysctl` gave upstream too. A per-mount knob needs `/sys/fs/hammer2/`, where ext4 and btrfs put theirs |

The middle column is the marker as it is spelled in the source, because
that is what the gate matches on: a reworded trigger in either place is a
failure rather than a drift.

Lifted 2026-09-07: `DEFER(every hpanic site has an error its caller
propagates)`, at `hpanic` in `hammer2_os.h`. Its trigger was the
reading `README.porting.md` names, a fault fired from
`hammer2_base_insert` with the writer told `EIO`, the mount read-only,
`umount` and `rmmod` returning and the device byte-identical to the
last good sync, and `script/hpanic-contain.sh` with `H2_KNOB=3` read
it that day against its control.

### `XXX` marks: how much of the core is not a carry

0.2's fourth exit criterion asks for this count. An `XXX` is the BSD ports'
mark for a mapping that is not mechanical, so the number says how many places
a reader should distrust. Counting raw occurrences answers the wrong
question, the carried files arriving with upstream's own. Measured 2026-08-26
against the FreeBSD port at
`3df307f` (v1.2.13), by file, ours minus upstream's; the first column
re-read 2026-09-07 after every `hpanic` site got its way out and
`hpanic` returned, seventy lines in eight files, each a mark:

| file | `XXX` | upstream's | this port's |
|---|---|---|---|
| `hammer2_chain.c` | 85 | 18 | 67 |
| `hammer2_freemap.c` | 9 | 6 | 3 |
| `hammer2_bulkfree.c` | 4 | 4 | 0 |
| `hammer2_xops.c` | 3 | 1 | 2 |
| `hammer2_io.c` | 12 | 2 | 10 |
| `hammer2_os.h` | 4 | 0 | 4 |
| `hammer2_flush.c` | 19 | 8 | 11 |
| `hammer2_subr.c` | 7 | 0 | 7 |
| `hammer2_cluster.c` | 1 | 0 | 1 |
| `hammer2_ondisk.c` | 22 | 1 | 21 |
| `hammer2_inode.c` | 29 | 6 | 23 |
| `hammer2_vfsops.c` | 48 | 7 | 40 |
| `hammer2_ioctl.c` | 18 | 3 | 15 |
| `hammer2_strategy.c` | 26 | 0 | 26 |
| `hammer2_vnops.c` | 2 | 0 | 2 |
| `hammer2.h` | 10 | 3 | 7 |
| `hammer2_disk.h` | 2 | 1 | 1 |
| `hammer2_admin.c` | 2 | 0 | 2 |
| `hammer2_compat.h` | 0 | 0 | 0 |
| `hammer2_ioctl.h` | 0 | 0 | 0 |
| `hammer2_mount.h` | 0 | 0 | 0 |
| `hammer2_rb.h` | 3 | 0 | 3 |
| `hammer2_xxhash.h` | 0 | 0 | 0 |
| `sys/tree.h` | 1 | 1 | 0 |

One hundred and seventy-four are this port's, the right-hand column
summed, and they fall in seventeen files: forty in `hammer2_vfsops.c`, twenty-three in `hammer2_inode.c`, twenty in `hammer2_ondisk.c`, twenty in `hammer2_chain.c`, nineteen in `hammer2_strategy.c`, fifteen in `hammer2_ioctl.c`, seven in `hammer2_subr.c`, seven in `hammer2_flush.c`, seven in `hammer2.h`, three in `hammer2_os.h`, three in `hammer2_rb.h`, two in `hammer2_xops.c`, two in `hammer2_admin.c`, two in `hammer2_io.c`, one in `hammer2_disk.h`, one in `hammer2_freemap.c`, and two in `hammer2_vnops.c`. That is the whole of them, and
it is the only place in this file that adds up to the column. The count
is prose because `test-inventory.sh` checks the total column only.

`hammer2_admin.c`,
`hammer2_xops.c`, `hammer2_bulkfree.c`, `hammer2_chain.c`,
`hammer2_cluster.c` and `hammer2_mount.h` are still byte-identical to that
upstream commit under `cmp`, so most of the carried core has no port edit
of any kind, marked or unmarked.

The table covers every `.c` and `.h` under `src/sys/fs/hammer2/` whatever
its count, and any file elsewhere under `src/` that holds a mark, so
`src/sys/sys/queue.h` is absent by the rule rather than missing from it
while its sibling `tree.h` has a row;
`test-inventory.sh` checks the total column against `grep -c` and both
directions of that population. It did not until 2026-08-26, and had
drifted in the way an ungated count does: `hammer2_disk.h` and
`src/sys/sys/tree.h` were missing while both carry a mark, and
`hammer2_cluster.c` was listed at zero, which is what made a partial table
read as an inventory. Neither omission moved the count, which was fifty-two when this was measured. The two marks that prompted this
are their authors': `hammer2_disk.h`'s first is Dillon's note on the
reserved area, present in the FreeBSD commit above, and `tree.h`'s is
FreeBSD's own `XXXLAS`, which the vendoring left alone. `hammer2_disk.h`
gained a second, this port's, when `->statfs` landed and needed an
`f_type`: `<uapi/linux/magic.h>` carries no entry for this filesystem, so
the constant is the high half of the volume identifier, which spells HAM2. The two remaining columns are a
subtraction against a tree that is not on most machines, so they are not
gated and carry their measurement date instead.
