# H1 reading 3: which lines of the core a port actually carries

The third of the three readings `HAMMER2_LINUX_PORT_PLAN.md` puts before
any H1 estimate. Measured 2026-08-25 with `scripts/hammer2-core-diff.py`,
which normalizes the mechanical differences between DragonFly and a port
and then compares statements. Twelve selftest cases, each falsifying one
normalization in both directions: a cosmetic difference must vanish and a
real one beside it must survive.

## What is normalized, and why the audit does not do this

`HAMMER2_PORTABILITY_AUDIT.md` measures a raw `diff` and says so: the
ratio counts comment and whitespace churn as change, so it overstates and
never understates. That is correct for its question, which is which files
face the operating system.

Sizing a port wants the other bound. Six passes, each provably cosmetic
and each with a selftest: the license block, `#include` lines, comments,
statement reflow across parentheses, a storage-class keyword alone on a
line, the shim's renames (`kprintf`, `panic`, `kmalloc`, `kfree` and the
two sleep primitives, discovered by token-frequency difference rather
than guessed), prototype parameter names, style(9) keyword spacing, the
BSD short integer aliases, and the parenthesised return value.

Each pass moves the total by about a point and the passes are converging
rather than terminating, so the figures below are an upper bound on
semantic change that is still a little high. Two numbers bracket the
truth and neither is the truth.

## DragonFly against the ports: the ports agree with each other

| file | FreeBSD | NetBSD | OpenBSD |
|---|---|---|---|
| hammer2_chain.c | 18.2% | 18.3% | 18.5% |
| hammer2_bulkfree.c | 19.8% | 19.8% | 19.8% |
| hammer2_freemap.c | 21.8% | 21.6% | 21.6% |
| hammer2_flush.c | 22.6% | 21.5% | 21.5% |
| hammer2_inode.c | 27.2% | 26.9% | 25.1% |
| whole core | 34.0% | 34.5% | 34.5% |

Every port makes the same edits, to within a third of a point on every
file. That is the audit's "one design applied three times" seen from the
other side, and it means the DragonFly-to-port transition is a property
of the transition rather than of any BSD.

## The number that sizes a Linux port

The transition above is already paid. A Linux port starts from a port,
not from DragonFly, so its analog is one port against another:

FreeBSD's tree against NetBSD's, both already ported, normalized:

| file | changed |
|---|---|
| hammer2_freemap.c | 0.0% |
| hammer2_bulkfree.c | 0.0% |
| hammer2_xops.c | 0.0% |
| hammer2_chain.c | 0.2% |
| hammer2_admin.c | 0.5% |
| hammer2_flush.c | 2.0% |
| hammer2_ioctl.c | 2.4% |
| hammer2_subr.c | 3.7% |
| hammer2_strategy.c | 4.6% |
| hammer2_io.c | 6.3% |
| hammer2_inode.c | 6.6% |
| hammer2_vfsops.c | 15.9% |
| hammer2_ondisk.c | 16.7% |
| hammer2_vnops.c | 28.0% |
| whole core | 8.0% |

The algorithm core is nearly free, and "free" is the word to watch: this
is a sibling comparison, and the errata entry written the same day says
what those measure. `freemap`, `bulkfree` and `xops` are
identical after normalization; `chain` differs by 10 statements out of
2412. Three of the five files the plan names as carried have literally
nothing in them that a second port had to touch.

Every changed line concentrates in the OS-facing set, which is the same
set reading 1 found the locking questions in and the same set the audit
classified as OS-SPECIFIC. Three independent measurements over three
different properties agree on the boundary, which is what makes it worth
building a package layout around.

## The budget, in lines of the tree we would start from

From the FreeBSD port, 26,302 lines of `.c` and `.h`:

- 10,556 lines carried at 0 to 2% between ports: `chain`, `flush`,
  `freemap`, `bulkfree`, `xops`, `admin`.
- 9,321 lines in the rewrite zone: `vnops`, `vfsops`, `ondisk`, `io`,
  `strategy`, `inode`.
- 611 lines of shim, `hammer2_os.h` and `hammer2_compat.h`, which is what
  a Linux port writes a fourth version of.
- the remainder is headers, the vendored LZ4, xxHash and zlib copies, and
  `ioctl.c`, whose interface is redesigned rather than ported.

## The floor, said out loud

8% is a floor for Linux and not an estimate. FreeBSD and NetBSD share VFS
ancestry: a vnode, a `struct buf`, the same lock idioms. Linux shares
none of it, so the files where the 8% concentrates are exactly the files
that stop being a diff and become a rewrite. `hammer2_vnops.c` at 28%
between two BSDs is 100% against Linux.

What the number does establish, and what no reasoning from first
principles could, is that the algorithm core is OS-agnostic in practice
and not merely in intent. A second port changed ten statements in
`hammer2_chain.c` and none at all in the freemap or the bulkfree
allocator. That is the half of the work a Linux port does not do, and it
is the larger half by line count.
