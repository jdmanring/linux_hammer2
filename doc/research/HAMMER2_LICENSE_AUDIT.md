# HAMMER2 license and provenance audit (H0 deliverable)

Part of the archaeology work package (`proposals/saxum_filesystem/`, document
02 sections 3 and 14, document 07 section 3). Measured 2026-08-25 by the
specification session over the nine trees on this disk, per file, from the
first hundred lines of each source file: SPDX identifier, copyright lines, the
first distinguishing line of the license text, and the clause count. The
proposal's rule governs this document: "BSD licensed, therefore safe" is not a
finding; a per-file table is.

## Provenance records

| tree | remote | revision | date |
|---|---|---|---|
| dragonfly-hammer2-upstream | github.com/DragonFlyBSD/DragonFlyBSD (blobless partial clone) | `22b0532` | 2026-08-18 |
| freebsd-hammer2-upstream | github.com/kusumi/freebsd_hammer2 | `3df307f` | 2025-08-22 |
| netbsd-hammer2-upstream | github.com/kusumi/netbsd_hammer2 | `64095c3` | 2025-08-22 |
| openbsd-hammer2-upstream | github.com/kusumi/openbsd_hammer2 | `a3747df` | 2025-08-22 |
| hammer2-upstream | github.com/kusumi/hammer2 | `3187d8f` | 2024-10-17 |
| libhammer2-upstream | github.com/kusumi/libhammer2 | `e0b88b9` | 2026-07-01 |
| hammer2-fuse-upstream | github.com/kusumi/hammer2-fuse | `b92433c` | 2026-07-01 |
| hammer2-utils-upstream | github.com/kusumi/hammer2-utils | `359b25b` | 2026-07-01 |
| makefs-upstream | github.com/kusumi/makefs | `6074496` | 2026-04-30 |

Two facts about the trees themselves. `hammer2-upstream` is not a code
repository: it holds a README and one patch (the original read-only FreeBSD
port), no license file, and sits twenty-one months behind the others. And the
DragonFly clone is blobless and does not carry `sys/libkern`, so the
DragonFly-side helpers the core includes are not audited here; the ports'
copies are.

## The kernel core (DragonFly `sys/vfs/hammer2`, `sbin/*hammer2`, `lib/libdmsg`)

No SPDX identifier on any file. Groups:

| files | holder | license |
|---|---|---|
| 54 | The DragonFly Project | BSD-3-Clause (three clauses, "Neither the name") |
| 10 | The DragonFly Project and Tomohiro Kusumi | BSD-3-Clause |
| 2 | The DragonFly Project | BSD-2-Clause: `sbin/hammer2/cmd_cleanup.c`, `cmd_destroy.c` |
| 8 | Yann Collet | BSD-2-Clause (LZ4, xxHash) |
| 28 | zlib (Adler, Gailly) | zlib license, full text only in `hammer2_zlib.h`; the rest refer to it |
| 4 | none | none: `zlib/hammer2_zlib_inffixed.h`, `zlib/hammer2_zlib_trees.h`, in both the kernel and sbin copies |

Named contributors beyond Dillon and Kusumi: **Venkatesh Srinivas**, in the
"derived from software contributed by" line of 29 files including
`hammer2_chain.c`, `hammer2_flush.c`, `hammer2_inode.c`, `hammer2_vnops.c`,
`hammer2_disk.h` and all of `libdmsg`; and Leonid Broukhis, cited as the
origin of code in `sbin/hammer2/zlib/hammer2_zlib_deflate.c`. Neither is a
copyright holder; both must be carried in attribution.

## The three BSD ports

Each carries an identical root `COPYRIGHT`: Kusumi 2022 to 2025 and The
DragonFly Project 2011 to 2025, derived-from-Dillon, BSD-3-Clause. Per file,
identical across the three except where noted:

| files (FB / NB / OB) | SPDX | holder | license |
|---|---|---|---|
| 47 / 47 / 47 | BSD-3-Clause | DragonFly and Kusumi | BSD-3 |
| 2 / 2 / 2 | BSD-3-Clause tag, two-clause text | DragonFly and Kusumi | the same `cmd_cleanup.c`, `cmd_destroy.c` anomaly, with a tag that does not match the text |
| 5 / 5 / 5 | none | Yann Collet | BSD-2 (LZ4, xxHash) |
| 2 / 0 / 0 | BSD-3-Clause | Regents of the University of California | `lib/libutil/mntopts.{c,h}`, FreeBSD only |
| 1 / 2 / 1 | BSD-3-Clause | DragonFly, Kusumi, Regents | `mount_hammer2.{c,h}` |
| 1 / 1 / 1 | none | Gary S. Brown | `sys/libkern/icrc32.c`: a 1986 permission sentence, no license grant |
| 9 / 9 / 10 | none | none | Makefiles and install scripts |

The ports carry no zlib. The one source file with no license grant,
`icrc32.c`, is a CRC table whose header says "you may use this program, or
code or tables extracted from it, as desired without restriction", which is a
permission statement and not an OSI license; it is also in `makefs`.

## The Rust userspace stack (libhammer2, hammer2-fuse, hammer2-utils)

- No `LICENSE` file in any of the three; each has a root `COPYRIGHT` (Kusumi
  2025 to 2026, The DragonFly Project 2011 to 2025, BSD-3-Clause).
- **No `license` field in any `Cargo.toml`** (each declares only name,
  version 0.5.0, edition 2024).
- **No per-file copyright or SPDX line in any of the 60 `.rs` files**
  (16, 4 and 40). The license exists only at the repository root.

This is a provenance gap by the proposal's rule, not a licensing problem: the
root file is unambiguous, but a file copied out of these trees carries
nothing with it. For the toolchain this system already packages, the
derivation's `meta.license` is where that is repaired, and the upstream fix
(a `license = "BSD-3-Clause"` field and headers) is a one-line contribution
per crate worth sending before anything else.

## makefs

Root `COPYRIGHT`: Kusumi 2022 to 2026 and **The FreeBSD Project** 1992 to
2026 (not DragonFly), BSD. It is a large mixed-provenance tree (110 `.c`,
73 `.h`) and the audit's one real outlier:

- **GPL-2.0 code is vendored**: 35 files under `src/gpl/github.com/relan/exfat/`
  (Andrew Nayenko's exFAT library and mkfs, plus one Endless OS Foundation
  file) and `src/usr.sbin/makefs/exfat_gpl.c`, with the GPLv2 text at
  `src/gpl/.../COPYING`. The root `COPYRIGHT` does not mention it.
- BSD-4-Clause files with the advertising clause: Wolfgang Solfrank / TooLs
  GmbH (10), Wasabi Systems (7), plus compound expressions on two files.
- The Regents of the University of California on 36 files; NetBSD Foundation,
  Christos Zoulas, Manuel Bouyer, Kamp and Smørgrav, Moestl, Moolenaar,
  Nordier, Provos, SRI, Richardson, Networks Associates and Wemm under
  BSD-2; MIT-style permission notices from Todd C. Miller and MIT; zlib by
  reference; Collet's LZ4 and xxHash; Brown's CRC.
- Seven files with no copyright at all, two of them the same zlib tables.

Consequence, checked against the build rather than assumed: the exFAT code
is compiled only under `USE_EXFAT=1` (`src/usr.sbin/makefs/Makefile:6`), and
`scripts/hammer2-toolchain.nix` runs `make -C src` without it, so the
packaged binary carries no GPL code and is BSD as its root file says. Two
corrections still follow for the toolchain package: its `meta.license` is
`bsd2` where the HAMMER2 and root headers are BSD-3-Clause, and a future
`USE_EXFAT=1` would make the binary GPL-2.0 with no change to any header,
which is worth a comment beside the flag. For the kernel tree the rule is
unchanged: take only `src/usr.sbin/makefs/hammer2/`, with its headers, and
never the exFAT code.

## The provenance graph

The machine-readable table the proposal requires (`original_path`,
`current_project`, `commit_or_tag`, `copyright_holder`, `license_expression`,
`SPDX_identifier`, `port_status`, `modified_by_port`, `Saxum_candidate_use`)
is derivable from the scan above plus `HAMMER2_PORTABILITY_AUDIT.md`, and is
produced as `hammer2-provenance.csv` at H1's start by a script that re-runs
the scan, so the table cannot drift from the trees. It is not hand-written
here because a hand-written copy of a measurement is the thing this project's
rules forbid.

Produced 2026-08-25: `scripts/hammer2-provenance.py --write` generates
`legal/hammer2-provenance.csv` over the kernel core of the four trees, at
the revisions the CSV's own `commit_or_tag` column records; `--check` is a
gate in `local_ci.py` that regenerates and fails if the committed file has
drifted from the trees. Two columns beyond the nine above: `derived_from`,
because Srinivas and Flores are contributors and not holders and the two
must not share a cell, and the license is classified from the TEXT with the
file's own SPDX tag beside it, so a tag disagreeing with its text is a row
anyone can grep for (zero in the kernel core; the two the audit found are
in `sbin`, outside the CSV's scope). The `modified_by_port` column uses
this audit's own instrument, GNU `diff`, and reproduces the table above to
the third digit. The userland trees are out of scope until a userland file
is imported, and the script says so in a DEFER.

## What an importer must do, from this audit

1. Carry every header unchanged; add SPDX identifiers only where a file has
   none and the license is established by the tree (the Rust files, the zlib
   tables), and record where each tag came from.
2. Treat `cmd_cleanup.c` and `cmd_destroy.c` as BSD-2 (the text governs, not
   the port's tag) and note the discrepancy in the graph.
3. Keep `icrc32.c` out of the Linux kernel tree; Linux has its own CRC32 and
   the file's permission statement is not a license a kernel maintainer will
   accept.
4. Take nothing from `makefs` except the HAMMER2 subtree, with its headers,
   and never the exFAT code.
5. Attribute Srinivas and Broukhis wherever the derived-from lines say so.
6. The clustering files the ports drop (`ccms`, `iocom`, `msgops`,
   `synchro`) are BSD-3 like the rest and are not imported for H1 to H6.

## Open

- The DragonFly `sys/libkern` helpers the core includes: audit from a full
  clone before H1 imports anything that references them.
- Whether the vendored LZ4, xxHash and zlib copies are unmodified against
  their upstreams: a diff against the upstream releases, needing the network,
  before H1 decides whether to use Linux's in-kernel LZ4, xxHash and zlib
  instead of carrying copies, which is the right answer if they are
  unmodified.
