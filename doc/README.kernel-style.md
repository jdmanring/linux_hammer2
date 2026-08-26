Kernel style, and the path to mainline
======================================

The kernel's own `LICENSES/preferred/` lists `BSD-3-Clause`, so this
tree's license is no barrier to inclusion; it sits in the same category as
MIT. The module will carry `MODULE_LICENSE("Dual BSD/GPL")` when it
builds, which keeps `EXPORT_SYMBOL_GPL` symbols reachable. Measured
against a 7.2 tree, every page cache symbol the DIO layer calls today is a
plain `EXPORT_SYMBOL`, but the kernel-wide ratio is 18,117 GPL-only to
12,853 plain, so the VFS layer will very likely need one.

Style is the real gap, and it is deliberate. This tree is BSD style
because it carries DragonFly code and tracks Kusumi's three BSD ports:
`return (x);`, typedef'd lock types, prototype lists without argument
names. Converting it now would produce a large diff against the trees this
port is meant to stay readable beside, and would buy nothing until an
actual submission, which converts everything in one mechanical pass
anyway.

So the gate is not silence. `script/test-checkpatch.sh` records the
deviation set in `doc/checkpatch-baseline.txt` and fails when it grows or
a new category appears. The barrier to mainline is unbounded style debt,
not the presence of BSD idioms, and a bounded set can be converted by a
script on the day it matters.

## The recorded deviations, and which are convertible

Counts below are what `checkpatch.pl` from linux **v7.2** reports, which is
the version `doc/checkpatch-baseline.txt` names in its first line and the
version CI fetches. Its second line records that checker's `sha256`, which
is the identity the file answers for itself: a version read off the tree a
checker was cut from does not survive the checker being copied out of that
tree, and the pinned copy always lives outside one. `checkpatch.pl`'s own
`my $V` is no help, reading `0.32` in v6.15, v7.2 and a 7.1 distribution
copy alike. A different copy of checkpatch moves these numbers on
unchanged code, so the version travels with them.

The pin was v6.15 until 2026-08-26, chosen to match the module's kernel
floor. That was the wrong thing to match: the tree compiles against the
latest release and the checker should be that release's, so the pin
follows the kernel of record and not the floor. Re-pinning moved exactly
one category, `Argument 'X' is not used in function-like macro`, from 18
to 15, and the total from 586 to 583; every other line was byte-identical.
The totals moved again on 2026-08-26 when 0.2's carried files landed: 583
to 649 over roughly 4,300 added lines of DragonFly code, then 649 to 745
when `hammer2_chain.c` added 4,929 more. That is the deviation density of
the carried core rather than of anything this port wrote: 66 hits over the
first 4,300 lines and 96 over the next 4,929, so roughly one hit per 55
lines of carried DragonFly either way. Four categories are new with
`hammer2_chain.c` and each is one or two hits: a repeated word, a brace
around a single statement, a static initialised to 0, and an `else` after
a `return`. None is a new KIND of debt -- they are the same BSD idioms the
open rows already describe, appearing for the first time because this is
the first carried file long enough to contain them.

745 to 760 on 2026-08-26 when `hammer2_flush.c` closed the carried set,
1,315 lines for 15 hits, one per 88 lines and the sparsest of the three.
Fourteen of the fifteen fall in categories already open. The fifteenth is
`Consider removing the code enclosed by this #if 0 and its #endif`, which
is upstream's `#if 0` around the disabled assert in
`hammer2_trans_assert_strategy`, carried from the FreeBSD tree; deleting it would be an edit to a carried file to
satisfy a checker, which is the trade this port does not make. The new
baseline was produced by the checker the old one records, fetched and
verified by `sha256` against that first line rather than by the copy on
any workstation, because a differently-sourced v7.2 checker moves these
numbers on unchanged code and that is the whole reason the hash is there.

760 to 764 when `hammer2_cluster.c` was carried: 188 lines for 4 hits, one
per 47 and the densest batch so far, which is what a short file of small
functions looks like once the SPDX pair is counted per file rather than
per line. Two of the four are exactly that pair, and the other two are
`return (x);`. No new category.

764 to 782 when `hammer2_subr.c` was carried: 452 lines for 18 hits, one
per 25 and denser again, for the same reason plus nine `return (x);` in a
file that is mostly small switch statements. Two categories are new and
both are upstream's own lines rather than this port's: `Prefer 'unsigned
int' to bare use of 'unsigned'` in `hammer2_timespec_to_time`, and
`Statements terminations use 1 semicolon` in the iostat printer. A third,
`Block comments use a trailing */ on a separate line`, appeared with three
hits in the port's own `XXX` blocks and was fixed rather than baselined:
a checker complaint about a comment this port wrote is not a carried idiom
and has no claim on the exception the BSD style gets here.

One more row is a deliberate port decision rather than a carried idiom:
`Avoid logging continuation uses where feasible`, at one hit, is
`pr_cont` in `hammer2_os.h`. checkpatch is right that new code should not
use it. The core builds one log line out of several calls, which is what
a BSD kernel `printf` does and what `pr_info` cannot do, so the choice is
between a continuation and splitting every such line in two while
dropping the second half's prefix. It carries a `DEFER` naming its
upgrade: build the line in a buffer and emit it once, which is a core
edit and waits for a reason.
It is also the signature a 7.1 distribution `checkpatch.pl` produced against
the old baseline, which the gate reported as a version mismatch rather than a
style regression.

| category | count | disposition |
|---|---|---|
| do not add new typedefs | 72 | required by the carried core; converts with the core |
| function argument without identifier name | 391 | BSD prototype style; mechanical |
| return is not a function, parentheses not required | 38 | BSD style; mechanical |
| return of an errno should be negative | 15 | **not a style issue.** Errnos are positive inside the module by the core's convention; the VFS boundary negates. See doc/README.porting.md |
| plain inline preferred over `__inline` | 11 | `hammer2.h` 6, `hammer2_io.c` 2, `hammer2_rb.h` 1, counted per file on 2026-08-26. The disposition here used to read "in vendored `sys/tree.h` and `sys/queue.h`", which no run supports: the gate's file list is `src/sys/fs/hammer2/*.c` and `*.h` and has never scanned `src/sys/sys/` at all. Carried style; converts with the core |
| spaces at the start of a line | 64 | continuation alignment in carried macros |
| misplaced or missing SPDX tag in line 1 | 8 misplaced, 8 missing | every file carried byte-for-byte from Kusumi's ports keeps his header shape, which puts the tag after the copyright block; the files this port wrote have it on line 1. The count tracks the number of carried files and rose with 0.2's imports |
| everything else | 1 to 15 each | carried code |

## What this gate does not see

`checkpatch.pl` demotes AVOID_BUG, "do not crash the kernel", from WARNING
to CHECK when it is run with `--file`, which is the mode this gate runs
(`$msg_level = \&CHK if ($file);`, read at v6.15 line 4810 and again at v7.2 line 4915). CHECK messages need `--strict`, which
the gate does not pass, so the eight `BUG_ON` and four `panic()` sites in
`src/` produce no hits and the baseline has no row for them. That is a
blind spot in the instrument and not a clean result: the reviewer who
raises it will be reading the source, not the baseline. The decision
itself is recorded in `doc/README.porting.md`; new OS-half code uses
`WARN_ONCE` plus recovery, which is what the demoted message asks for.

The one that will not convert is the errno sign, and it is the one to
raise first with any reviewer: making errnos negative inside the module
means editing the carried core in hundreds of places, which is the
opposite of what every port of this filesystem has chosen to do.
