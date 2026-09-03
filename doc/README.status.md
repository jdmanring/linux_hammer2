Status
======

No module has been loaded, so nothing here has been observed running.
This file is the one to correct rather than to argue with: if a claim here
is stale, it is a defect.

## The build

The module builds, warning-clean, and has never been loaded. `make`
produces `src/sys/fs/hammer2/hammer2.ko`: thirteen objects, license
`Dual BSD/GPL`, alias `fs-hammer2`, no module dependencies. That is 0.3's
first criterion. Loading and unloading are the other two and need the
Linux guest `README.roadmap.md` describes.

It reached that state on 2026-09-02, in one day and two steps. The first
`make` ever run reported four undefined symbols out of modpost:
`hammer2_xop_strategy_read`, `hammer2_xop_strategy_write` and
`hammer2_dedup_clear`, which upstream defines in `hammer2_strategy.c`, and
`hammer2_vfs_sync_pmp`, which this port had declared and deliberately left
undefined. `hammer2_strategy.c` now exists with the dedup function carried
and both handlers as floors, and the sync is a floor too.

**Three of the module's entry points are floors**, and one of the three
is reachable: `hammer2_vfs_sync_pmp()` is called three times by
`hammer2_unmount()`, which `->kill_sb` reaches after a mount that
succeeds. The two strategy handlers are not, because no vnode operation
starts an XOP yet. Each floor warns once and fails; the `DEFER` ledger
below carries a row for each. A floor here is not a stub returning success:
`hammer2_vfs_sync_pmp()` is the one whose replacement was argued about,
because its two call sites discard the return value, so the warning is the
only channel it has. What the undefined symbol bought was a build nobody
could load; what the floor buys is a module that loads and says what it
cannot do.

The build was run against 7.1.9 with gcc 16.2.1, not against the kernel of
record. A link against 7.2 has not been performed, and the syntax gate is
the only thing that has ever seen 7.2.

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1354 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1198 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_admin.c` | 629 | FreeBSD port, carried byte-for-byte; the xop allocation zone is shimmed |
| `hammer2_freemap.c` | 1000 | FreeBSD port, carried byte-for-byte |
| `hammer2_xops.c` | 1449 | FreeBSD port, carried byte-for-byte |
| `hammer2_bulkfree.c` | 1239 | FreeBSD port, carried byte-for-byte; `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 4929 | FreeBSD port, carried byte-for-byte; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed |
| `hammer2_flush.c` | 1315 | FreeBSD port, carried; the device flush and the volume header write are the port decision below, marked `XXX` in place |
| `hammer2_cluster.c` | 188 | FreeBSD port, carried byte-for-byte; nothing in it touches the OS |
| `hammer2_subr.c` | 450 | FreeBSD port, carried; the timestamp, the signal check and the two `timespec64` signatures are marked `XXX` in place, and `hammer2_getnewfsid()` is not carried |
| `hammer2_inode.c` | 1619 | FreeBSD port; carried except the create path, which is `DEFER`red on the write path. `hammer2_igetv()` is this port's, written on `iget5_locked()` |
| `hammer2_vfsops.c` | 1973 | FreeBSD port; the PFS half and the recovery carried, the module entry, globals, mount path, mount helper, evict_inode, and sops this port's. A rewrite with a carried body, since Linux redistributes `hammer2_mount()` across four `fs_context` callbacks |
| `hammer2_strategy.c` | 132 | this port's; `hammer2_dedup_clear()` carried, both XOP handlers are floors |
| `hammer2_ondisk.c` | 881 | FreeBSD port; the volume-header verification half carried, the device half rewritten on `lookup_bdev()` and `bdev_file_open_by_path()`, and four functions not carried: `hammer2_lookup_device()` and the three GEOM access helpers |
| `hammer2_mount.h` | 58 | FreeBSD port, carried; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 944 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 699 | ours, the OS shim |
| `hammer2_compat.h` | 166 | ours, kernel look-alikes; the BSD `vtype` enum and the `MNT_WAIT` pair, which no Linux header has |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

All ten gates pass, and since 2026-08-26 they pass with no environment
variables set on a machine that has the kernel of record installed: the
syntax gate finds that tree, and the style gate finds its `checkpatch.pl`.
What that unattended style run can say is narrower than it looks, and the
narrow half is the useful one: the found checker's `sha256` does not match
the baseline's, so an unchanged set is reportable and a moved set is not.
The gate exits 2 rather than charge a move to the code, which means the
one run that matters, the run after a carried file lands, needs
`CHECKPATCH` pointed at the checker the baseline names. That happened
twice on 2026-08-26. ArtNix's delegator, which runs these same gates from another
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
  turned out to be compiled by a gate in ArtNix, which no search of this
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
headers of a 7.2 tree with both clang 22 and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, which is why the section above records what `make` does instead.
The module has not been loaded and there is no fsck integration, so
nothing here has been observed running. The VFS layer and the mount path
exist: `hammer2_get_tree()` probes the device, reads the super-root,
builds a root dentry and returns success. It refuses a read-write mount,
and refuses the read-write remount too: upstream's recovery is carried and
called, but it writes and has never been run, which is what
`DEFER(recovery is exercised on a device)` names.

## The version floor, and how it was established

`BLK_MAX_BLOCK_SIZE` is the binding constraint, at **6.15**. Each symbol
was dated by reading the header at the tag rather than from memory:

| symbol | absent at | present at |
|---|---|---|
| `bdev_file_open_by_path` | | v6.10 |
| three-argument `kvrealloc` | v6.11 | v6.12 |
| `folio_mark_dirty_lock` | v6.12 | v6.13 |
| `BLK_MAX_BLOCK_SIZE` | v6.14 | v6.15 |

6.15 is the floor the code requires, not a floor that has been exercised.
The kernel of record is a different claim: this tree compiles against the
latest Linux, pinned in `script/test-syntax.sh` as `KERNEL_REF` and bumped
when a release ships.

Until 2026-08-26 this file said "the gates run on 7.2" and nothing checked
it. They did not. The newest kernel tree on the workstation was 7.1.9, with
no 7.2 in `/lib/modules`, `/usr/src` or the store, and the gate has always
printed the kernel it used in its header line while nobody compared that
string to the rule. A verdict is read off "0 failed". The gate now refuses a
tree that is not the kernel of record, with COULD-NOT-RUN rather than a
pass.

What has actually been compiled, measured rather than assumed, on
2026-08-26 under the deliberate `H2_KERNEL_REF` override:

| kernel tree | result |
|---|---|
| **7.2.0-cachyos**, the kernel of record | **7 checks, 0 failed, both compilers, no override** |
| 7.1.9-artix1-2 | 7 checks, 0 failed, both compilers, under the override |
| 6.18.46-1-lts | 7 checks, 0 failed, both compilers, under the override |

A 7.2 version string can be present with no 7.2 build tree behind it. Where
`linux-api-headers 7.2-1` is installed, `/usr/include/linux/version.h` reads
`LINUX_VERSION_MAJOR 7` and `LINUX_VERSION_PATCHLEVEL 2` beside no build tree
at all: UAPI headers, no `Makefile`, nothing to compile a module against. Anything answering "is 7.2 here" by grepping for a version string
finds that and is wrong. `script/test-syntax.sh` reads `VERSION` and
`PATCHLEVEL` from the build tree's own `Makefile` instead.

**The port type-checks against its kernel of record**, measured 2026-08-26
after the chaotic 7.2.0-cachyos `dev` output was substituted into the store
(679 MB, `sil5r7r2a25nsshkqpd5jjjd0g7ywyi7`). The gate's own line, quoted
rather than summarized:

    hammer2 against 7.2.0-cachyos via the store, matching the kernel of record,
      dialect -fms-extensions, with clang version 22.1.8, matching the tree's own:
    syntax: 7 check(s), 0 failed against the kernel of record (7.2)

measured at `ca4c07a`. The revision matters because this tree is a live
checkout another repository reads while work is being committed to it:
ArtNix's delegator once saw 6 gates where it expected 7, having walked the
tree mid-commit, which is indistinguishable from broken unless the revision
is printed beside the count.

The compiler is a pin too, and the tree says which one instead of this
repository asserting one. kbuild records what built the kernel in
`CONFIG_CC_VERSION_TEXT`, which reads `clang version 22.1.8` here, and this
workstation's clang is byte-identical to it. So that version is the
matching one rather than an old one, and the gate prints the comparison on
every run - against the 6.18 and 7.1.9 trees it says `NOT the tree's own,
which is "gcc (GCC) 16.2.1 20260810"`.

Every syntax result recorded before that timestamp was measured against
7.1.9 and read as 7.2. An overridden run now says so in its own summary
line: until that day it printed `syntax: 7 check(s), 0 failed`, identical
to what a real reading prints, and the override is a loosened threshold
whose hiding place was that line.

**It is 7.2.0-cachyos and not mainline 7.2.** `EXTRAVERSION` is set by a
`sed` in the derivation's `postPatch`, so the release string is the
distribution's by recipe. "Against the kernel of record (7.2)" is what the
gate says and is true; "against mainline 7.2" would not be, and the two are
one word apart.

Two properties of a nixpkgs kernel `dev` output that any later measurement
has to know. Its `source/` directory is pruned hard: the recipe rsyncs the
tree, deletes `drivers` wholesale, deletes unused arches, then deletes every
file it did not mark read-only. Measured here: 10,944 headers, 81 `.c` files,
no `drivers` directory. A grep of that tree for implementation code measures
the prune, not the kernel, so absence there is the normal case and not
evidence. And `checkpatch.pl` lives under `source/scripts`; `build/scripts`
holds gdb helpers.

That checker is not mainline's: its `sha256` differs from the one the
baseline records. Run against this tree it has twice produced the deviation
set unchanged, at 764 hits on 2026-08-26 and at 856 after `hammer2_ondisk.c`
landed the same day, so cachyos's patches do not move this tree's style
figures. Both readings are of the tree as it stood, not of a constant. The
gate says the hash does not match while accepting the version its own tree
reports, and prints the two halves separately.

The first run against the real tree failed, and the guard was wrong rather
than the tree. A nix dev output's `build/Makefile` is a three-line stub
that sets `KBUILD_OUTPUT` and includes the real Makefile from the `source`
directory beside it, so `VERSION` and `PATCHLEVEL` are not in the file the
gate was reading. It follows the `include` line the stub itself names now,
which is derived from the artifact rather than assuming a sibling
directory, and `linux-api-headers` still fails because it has no `Makefile`
at all to follow.

## What is not here

`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c`,
`hammer2_vnops.c`. All four are the OS-facing ones and all four are
rewrites. That is what makes them the remaining four; it is not a claim
that nothing in them can be read off a BSD port. `hammer2_strategy.c` in
particular has chain logic around its buffer handling, and how much of
that carries is a question for the file, not for this list.

The carried set is eight files at 11,204 lines, measured against all three BSD
ports: `hammer2_chain.c`, `hammer2_flush.c`, `hammer2_freemap.c`,
`hammer2_bulkfree.c`, `hammer2_xops.c`, `hammer2_admin.c`,
`hammer2_cluster.c` and `hammer2_subr.c`. `hammer2_ondisk.c` landed on
2026-08-26 and is not in it: half of it is carried and the device half is
this port's, which is what `doc/provenance.csv` records as `derived`.
Whether `hammer2_inode.c` joins the carried set is what that same carry
column will say.
`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c` and
`hammer2_vnops.c` are the OS-facing ones and are rewrites.

`hammer2_chain.c` landed on 2026-08-26 and the lock recursion it forced is
decided, following the NetBSD port: there is no recursive lock. A Linux
`rw_semaphore` deadlocks against its own holder exactly as a NetBSD
`krwlock` does, so `hammer2_mtx_init_recurse()` is a plain init in the
shim and the one path that recursed is closed instead of accommodated.
That path is `hammer2_chain_lookup()` reaching `chain->lock` again for an
inode in DIRECTDATA mode; NetBSD closes it by never setting
`HAMMER2_OPFLAG_DIRECTDATA`, which costs a data block for a tiny file and
costs no correctness. This port sets the flag nowhere at all, because its
only setter was in `hammer2_inode_create_normal()`, which is not carried.

That closes the creation half. It does not close the reading half, and
the wording here said otherwise until 2026-08-26: the flag lives in the
on-disk inode, so a filesystem written by DragonFly or by a BSD port has
DIRECTDATA inodes in it whoever mounts them, and the lookup reads the flag
off the media. Reading a small file on a foreign filesystem is therefore
an open question for the read-only mount at 0.4.
`doc/README.porting.md` has the reading it rests on, which is a reading
and not a run.

`hammer2_flush.c` landed on 2026-08-26 and took the port decision it needed
rather than a shim. Its OS-dependent surface is one function,
`hammer2_xop_inode_flush`, and everything else in the file is chain logic
that carried unchanged. Three edits, each marked `XXX` in place:

The device cache flush. DragonFly hands a zero-length `BUF_CMD_FLUSH` buf to
`vn_strategy()`, FreeBSD allocates a GEOM bio carrying `BIO_FLUSH`, and
NetBSD and OpenBSD both collapse it to one `VOP_IOCTL(DIOCCACHESYNC)`.
Linux has that single call, `blkdev_issue_flush()`, so this follows the two
ports that agree rather than the one this tree otherwise carries.

The per-device `VOP_FSYNC`, which writes back a device vnode's dirty
buffers. Linux writes back a block device's dirty pages with
`sync_blockdev()`, which needs no lock from the caller, so the
`vn_lock`/`VOP_UNLOCK` pair around it went with it.

The volume header write. FreeBSD uses `getblk`/`bwrite` on the buffer
cache; this port keeps the device's pages in the DIO layer, so it goes
through `hammer2_io_bread` and `hammer2_io_bwrite` instead. The DIO layer
does not export the read-skipping form of `getblk`, so the block is read
before all 64 KiB of it is overwritten. The write is the same size either
way, and the path does not execute until the write milestone.

None of the three is exercised. The whole core type-checks under both
compilers with warnings as failures, which is what 0.2 claims and all it
claims; nothing here has run.

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
| `hammer2_os.h`, at `hpanic` | `DEFER(the VFS layer lands, giving a super_block to mark)` | `hpanic()` calls `panic()` where Linux would mark the filesystem dead and refuse further I/O. Reasoning in `README.porting.md` |
| `hammer2_os.h`, at the print macros | `DEFER(a message is seen interleaved in a real mount)` | `pr_cont` is not the right mapping at both kinds of site; the table above measures the trade. The fix is a line buffer, which is a core edit |
| `hammer2_inode.c`, where `hammer2_inode_create_normal()` would be | `DEFER(the write path is written, after hammer2_vnops.c)` | the create path, which is `struct vattr`, `struct ucred`, `VNOVAL`, `groupmember()` and `priv_check_cred()`, and which carries NetBSD's `#if 0` around the `DIRECTDATA` assignment when it lands |
| `hammer2_vfsops.c`, at three sites: the read-write refusal in `hammer2_get_tree()`, `hammer2_reconfigure()`, and the recovery call before `hammer2_update_pmps()` | `DEFER(recovery is exercised on a device)` | upstream's `hammer2_recovery()`, `hammer2_recovery_scan()` and `hammer2_fixup_pfses()` are carried and called where upstream calls them, so the code exists. What has not happened is running them: they WRITE, through `hammer2_freemap_adjust()` with `DORECOVER`, `hammer2_chain_modify()` and `hammer2_flush()`, and nothing has been loaded. Until they are exercised on a device carrying an interrupted flush, both refusals stay: `hammer2_get_tree()` returns `EROFS` before the device is opened, and `hammer2_reconfigure()` returns it for the remount that would otherwise arrive at the same state sideways, since `reconfigure_super()` applies `SB_RDONLY` whether or not the operation is present. All three sites lift together. The real `->reconfigure` is upstream's `hammer2_remount_impl()`, which is not carried and which runs these two a second time on the read-only to read-write transition |
| `script/hammer2-provenance.py`, in the scope note | `DEFER(a userland file is imported into the module tree)` | the CSV generator walks the kernel core only. `sbin/hammer2`, makefs, libhammer2 and hammer2-utils are packaged separately and audited in the license audit's own tables, so `TREES` widens the day one of their files is carried into `src/` |
| `hammer2_vfsops.c`, at `hammer2_vfs_sync_pmp()` | `DEFER(->sync_fs lands)` | the floor warns once and returns `EOPNOTSUPP`, and both call sites discard the value. It replaced a symbol deliberately left undefined, which made the absence visible at link time and also made the module unloadable. An unmount that does not sync loses nothing while nothing can be written; on the day the write path lands this is a data-loss bug rather than a deferral |
| `hammer2_strategy.c`, at `hammer2_xop_strategy_read()` | `DEFER(the read path lands, with ->read_folio)` | the body is upstream's handler down to `hammer2_xop_collect()`, then a completion copying into `xop->folio`: the embedded-inode case, the three `HAMMER2_DEC_COMP()` cases on the kernel's own LZ4 and zlib, and `hammer2_dedup_record()` for the on-media case |
| `hammer2_strategy.c`, at `hammer2_xop_strategy_write()` | `DEFER(the write path lands: 0.5)` | the body is upstream's handler and the six statics beneath it, `hammer2_assign_physical()` through `hammer2_write_bp()`, plus `hammer2_dedup_record()` and `hammer2_dedup_lookup()`. Deferred because a read-only milestone that can write is not one |
| `src/sys/fs/hammer2/Makefile`, at `CARRIED_CFLAGS` | `DEFER(the tree is prepared for submission)` | kbuild's `-Wimplicit-fallthrough=5` reads only the `fallthrough` attribute and upstream marks its switches with a `/* fall through */` comment, and kbuild's `-Wunused` sees `hammer2_inode_lock_temp_release()` and `_restore()`, whose only caller in either upstream is `hammer2_igetv()`, the one function this port rewrote on `iget5_locked()`, where the dance they perform has nothing to race against. They have no caller here and are not expected to gain one; they stay because deleting two functions from a carried file is a core edit. Both are suppressed on the carried files rather than edited into Linux spelling, because converting either early splits the core into two dialects. They become edits in the single conversion that also settles BSD style |
| `hammer2_vfsops.c`, at the module parameters | `DEFER(a second filesystem-wide knob wants a per-mount value)` | the tunables are `module_param_named()` under `/sys/module/hammer2/parameters/`, one value for every mount on the machine, which is what `sysctl` gave upstream too. A per-mount knob needs `/sys/fs/hammer2/`, where ext4 and btrfs put theirs |

The middle column is the marker as it is spelled in the source, because
that is what the gate matches on: a reworded trigger in either place is a
failure rather than a drift.

Five of the seven lift with the read-side VFS entry, which is the next
move on the roadmap. The `enum vtype` row's trigger was re-checked when
`hammer2_inode.c` landed and was found to name a file rather than the
thing that fires it: the BSDs convert in `hammer2_vinit()`, in
`hammer2_vnops.c`, but they reach it from `hammer2_igetv()`, and on Linux
that is one call. The trigger now names the function, which is true
whichever file the replacement ends up in. The gate below matches marker
text and cannot check a trigger's truth, so that is checked by hand at
each import.

### `XXX` marks: how much of the core is not a carry

0.2's fourth exit criterion asks for this count. An `XXX` is the BSD ports'
mark for a mapping that is not mechanical, so the number says how many places
a reader should distrust. Counting raw occurrences answers the wrong
question, the carried files arriving with upstream's own. Measured 2026-08-26
against the FreeBSD port at
`3df307f` (v1.2.13), by file, ours minus upstream's:

| file | `XXX` | upstream's | this port's |
|---|---|---|---|
| `hammer2_chain.c` | 18 | 18 | 0 |
| `hammer2_freemap.c` | 6 | 6 | 0 |
| `hammer2_bulkfree.c` | 4 | 4 | 0 |
| `hammer2_xops.c` | 1 | 1 | 0 |
| `hammer2_io.c` | 4 | 2 | 2 |
| `hammer2_os.h` | 7 | 0 | 7 |
| `hammer2_flush.c` | 13 | 8 | 5 |
| `hammer2_subr.c` | 7 | 0 | 7 |
| `hammer2_cluster.c` | 0 | 0 | 0 |
| `hammer2_ondisk.c` | 19 | 1 | 18 |
| `hammer2_inode.c` | 23 | 6 | 17 |
| `hammer2_vfsops.c` | 23 | 7 | 16 |
| `hammer2_strategy.c` | 1 | 0 | 1 |
| `hammer2.h` | 7 | 3 | 4 |
| `hammer2_disk.h` | 1 | 1 | 0 |
| `hammer2_admin.c` | 0 | 0 | 0 |
| `hammer2_compat.h` | 0 | 0 | 0 |
| `hammer2_ioctl.h` | 0 | 0 | 0 |
| `hammer2_mount.h` | 0 | 0 | 0 |
| `hammer2_rb.h` | 0 | 0 | 0 |
| `hammer2_xxhash.h` | 0 | 0 | 0 |
| `sys/tree.h` | 1 | 1 | 0 |

Seventy-seven are this port's, the right-hand column summed, and they
fall in nine files: eighteen in `hammer2_ondisk.c`, seventeen in
`hammer2_inode.c`, sixteen in `hammer2_vfsops.c`, seven in
`hammer2_subr.c`, seven in `hammer2_os.h`, five in `hammer2_flush.c`,
four in `hammer2.h`, two in `hammer2_io.c` and one in
`hammer2_strategy.c`. That is the whole of them, and it is the only place
in this file that adds up to the column.

Four of those nine files are then walked mark by mark below:
`hammer2_ondisk.c`, `hammer2_vfsops.c`, and the two files this port wrote
from nothing taken together. Forty-three of the seventy-seven are in those
paragraphs. The other thirty-four are not enumerated anywhere and do not
need to be: `hammer2_inode.c`'s seventeen, `hammer2_subr.c`'s seven,
`hammer2_flush.c`'s five and `hammer2.h`'s four are one-line
substitutions in carried files, which is what the `XXX` mark is for and
what a reviewer reads at the mark rather than here, and
`hammer2_strategy.c`'s one is the block at its two floors, which the
`DEFER` ledger already carries a row for. **Do not read the
paragraphs below as a decomposition of the count.** They were read that
way once, and the sentence that invited it said "the three largest sets"
while skipping the second largest.

Sixty-four sit in a file that holds upstream text. The other nine are
the two files this port wrote from nothing: seven in `hammer2_os.h`, and
two of `hammer2_io.c`'s four.

`hammer2.h` has a row for the first time. It is a carried header this port
edits in place rather than a file it wrote, so its two marks are counted
where the other carried files' are.

`hammer2_admin.c`, `hammer2_freemap.c`,
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
read as an inventory. Neither omission moved the count, which was fifty-two when this was measured. Both marks are
their authors': `hammer2_disk.h`'s is Dillon's note on the reserved area,
present in the FreeBSD commit above, and `tree.h`'s is FreeBSD's own
`XXXLAS`, which the vendoring left alone. The two remaining columns are a
subtraction against a tree that is not on most machines, so they are not
gated and carry their measurement date instead.

`hammer2_flush.c`'s five are the three port decisions above and the two
local variables those decisions changed the type of, all inside one
function. `hammer2_subr.c`'s seven are the densest set in the tree and the
file is the smallest carried one, which is what a file of small
OS-touching helpers looks like: two are the `timespec64` signatures the
carried `hammer2.h` had already chosen, one is the include line, one the
timestamp call, one the signal check, one the pair of functions that are
not carried at all, and one the local variable the timestamp changed.

`hammer2_ondisk.c`'s eighteen are the port's largest set and split ten
to eight, counted mark by mark on 2026-08-26 and listed here so the
number can be checked rather than taken. Ten are on the device
side, which is the half this port wrote: the file's opening comment; in
`hammer2_open_devvp()`, the `g_vfs_open()` mapping and the logical-size
comparison; the `g_vfs_close()` mapping in `hammer2_close_devvp()`; in
`hammer2_init_devvp()`, the unused superblock argument, the `strlcpy`
rename, and the `namei()` mapping onto `lookup_bdev()`; the `vrele()`
mapping in `hammer2_cleanup_devvp()`; and in
`hammer2_access_devvp()`, the `VOP_ACCESS()` mapping and the trace
through `blk_to_file_flags()` and `OPEN_FMODE()` that replaced a `DEFER`
once `block/bdev.c` was read at the tag the kernel of record is pinned
to. The other eight are in the carried half, and
every one of them is a one-line substitution rather than a change of
logic: four in `hammer2_verify_volumes_common()` (the GEOM consumer local,
the media size read off the block device, the `devvp` field name, and the
uuid comparison the kernel has no formatter for), two signature lines in
`hammer2_init_volumes()`, the read call in `hammer2_read_volume_header()`,
and the formatter in `hammer2_print_uuid_mismatch()`. That is the property
worth checking: no carried function here had its control flow edited, and
a reviewer can confirm it one mark at a time.

The other nine are in the two files this port writes: two in
`hammer2_io.c` and seven in `hammer2_os.h`, one of them the non-recursive
lock above, one the `M_WAITOK` contract and one `hstrdup()`, which was
allocating outside that contract until the mount path dereferenced it.
The `hammer2_os.h` count read six until 2026-08-26, written before the
two shim edits `hammer2_inode.c` needed, and seven for the few hours
before `M_WAITOK` was fixed.

`hammer2_vfsops.c`'s sixteen are the largest set in the tree after
`hammer2_ondisk.c`'s, and the file is the fastest-moving in it, so they
are listed by site rather than counted: the file's opening comment; the
`sysctl(9)` block that became module parameters; the two `hashinit(9)`
substitutions and the helper they name; the `hashdestroy(9)` mark; the
`__maybe_unused` rename; the `desiredvnodes` derivation in
`hammer2_init_limits()`; the mount options; four in `hammer2_get_tree()`
for the `"from"` option, the `MNAMELEN` buffer, the device match and the
`vfs_mountedon()` check Linux answers at the open; the `void` return of
`->kill_sb`; `uma_zcreate(9)` being infallible where
`kmem_cache_create()` is not; and `hammer2_reconfigure()` being the
read-write refusal alone rather than FreeBSD's `MNT_UPDATE` branch. The read to make against that list is that
none of them is inside a carried function: the four in
`hammer2_get_tree()` are in the Linux entry point, not in the PFS body
it will call. This paragraph read "five" from 2026-08-26 until the
device half landed the same day, having been written when the file held
seven marks and not revisited as it tripled, and then read "fourteen"
while enumerating fifteen sites.

The other seven are upstream's own: two inside `hammer2_pfsalloc()`,
four `hprintf` strings in `hammer2_unmount_helper()`, and the one on the
unhandled error from the recovery call, all of which upstream already
spells `XXX`. The opening comment makes a deliberately
weaker claim than `hammer2_ondisk.c`'s: statements carry there and the
control flow does not move, but here the function boundary itself moves,
because Linux redistributes FreeBSD's `hammer2_mount()` across
`->init_fs_context`, `->parse_param`, `->get_tree` and a fill-super, with
`MNT_UPDATE` splitting off to `->reconfigure`. Claiming the reviewability
property `hammer2_ondisk.c` has would be false here at four times the
size.

