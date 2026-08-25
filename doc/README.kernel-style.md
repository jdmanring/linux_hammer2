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

| category | count at import | disposition |
|---|---|---|
| do not add new typedefs | 67 | required by the carried core; converts with the core |
| function argument without identifier name | 391 | BSD prototype style; mechanical |
| return is not a function, parentheses not required | 22 | BSD style; mechanical |
| return of an errno should be negative | 17 | **not a style issue.** Errnos are positive inside the module by the core's convention; the VFS boundary negates. See doc/README.porting.md |
| plain inline preferred over `__inline` | 9 | in vendored `sys/tree.h` and `sys/queue.h`; leave, they track freebsd-src |
| spaces at the start of a line | 43 | continuation alignment in carried macros |
| misplaced or missing SPDX tag in line 1 | 6 | three files are byte-exact from Kusumi's ports and keep his header shape; ours are fixed |
| everything else | 1 to 15 each | carried code |

The one that will not convert is the errno sign, and it is the one to
raise first with any reviewer: making errnos negative inside the module
means editing the carried core in hundreds of places, which is the
opposite of what every port of this filesystem has chosen to do.
