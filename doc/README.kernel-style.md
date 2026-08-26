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
version CI fetches. A different copy of checkpatch moves these numbers on
unchanged code, so the version travels with them.

The pin was v6.15 until 2026-08-26, chosen to match the module's kernel
floor. That was the wrong thing to match: the tree compiles against the
latest release and the checker should be that release's, so the pin
follows the kernel of record and not the floor. Re-pinning moved exactly
one category, `Argument 'X' is not used in function-like macro`, from 18
to 15, and the total from 586 to 583; every other line is byte-identical.
That is also the signature this workstation's own 7.1 `checkpatch.pl`
produced against the old baseline, which the gate had been correctly
reporting as a version mismatch rather than a style regression.

| category | count | disposition |
|---|---|---|
| do not add new typedefs | 67 | required by the carried core; converts with the core |
| function argument without identifier name | 391 | BSD prototype style; mechanical |
| return is not a function, parentheses not required | 25 | BSD style; mechanical |
| return of an errno should be negative | 15 | **not a style issue.** Errnos are positive inside the module by the core's convention; the VFS boundary negates. See doc/README.porting.md |
| plain inline preferred over `__inline` | 9 | `hammer2.h` 6, `hammer2_io.c` 2, `hammer2_rb.h` 1, counted per file on 2026-08-26. The disposition here used to read "in vendored `sys/tree.h` and `sys/queue.h`", which no run supports: the gate's file list is `src/sys/fs/hammer2/*.c` and `*.h` and has never scanned `src/sys/sys/` at all. Carried style; converts with the core |
| spaces at the start of a line | 43 | continuation alignment in carried macros |
| misplaced or missing SPDX tag in line 1 | 6 | three files are byte-exact from Kusumi's ports and keep his header shape; ours are fixed |
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
