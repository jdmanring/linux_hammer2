#!/usr/bin/env python3
"""H1's first task: the HAMMER2 provenance graph, generated rather than written.

Why this exists
---------------
`HAMMER2_LICENSE_AUDIT.md` says the machine-readable provenance table "is
produced as hammer2-provenance.csv at H1's start by a script that re-runs the
scan, so the table cannot drift from the trees". This is that script. The
import rule it serves, from the port plan: NO FILE ENTERS
`~/Projects/linux_hammer2/src/` WITHOUT A ROW HERE.

Scope: the kernel core only. DragonFly `sys/vfs/hammer2` and the three
ports' `src/sys/fs/hammer2`, including the vendored `xxhash/` and `zlib/`
subdirectories. The userland trees (`sbin/hammer2`, makefs, libhammer2,
hammer2-utils) are packaged separately by `scripts/hammer2-toolchain.nix`
and their audit lives in the license audit's own tables.
DEFER(a userland file is imported into the module tree): widen TREES.

Every column is measured from the trees at the revision the CSV records:

  original_path       path inside the tree
  current_project     which clone: dragonfly | freebsd | netbsd | openbsd
  commit_or_tag       `git rev-parse --short HEAD` of that clone
  copyright_holder    every `Copyright (c) ... <holder>` in the first 100
                      lines, `;`-joined; "derived from" contributors are
                      credited in a separate column because they are not
                      holders (the audit names Srinivas and Broukhis)
  license_expression  classified from the license TEXT, not from any tag:
                      BSD-3-Clause needs the "Neither the name" clause,
                      BSD-2-Clause has clauses 1 and 2 without it, zlib is
                      the "as-is" notice or a reference to zlib.h, NONE is a
                      file with no notice at all
  SPDX_identifier     the file's own `SPDX-License-Identifier:` line, or
                      empty. Kept beside the classification so a file whose
                      tag and text DISAGREE is visible (the audit found two
                      in sbin; the importer's rule is that the text governs)
  port_status         DragonFly file: which ports carry a file of that name,
                      or `dropped`. Port file: `port-only` if DragonFly has
                      no such file, else `port`
  modified_by_port    DragonFly file: the FreeBSD ratio by the portability
                      audit's method (changed lines both sides over the sum
                      of both lengths), so this column can be checked against
                      that document's table by eye. Empty for port files
  ArtNix_candidate_use
      drop            dropped by every port (the clustering layer, H7)
      stock-kernel    xxhash/ and zlib/: H0 proved the kernel's own copies
                      are the same code (H0_VENDORED_LIBRARIES.md), and
                      hammer2_lz4.c's decompressor likewise; its compressor
                      is HAMMER2's own and is H2's, so lz4 is `carry`
      carry           ratio at or under the audit's OS-SPECIFIC line (15%)
                      or named PORTABLE-WITH-ADAPTER by the audit: enters
                      through the shim
      rewrite         over the line: OS-facing, written against Linux's VFS
      reference       a port file: read for its OS-facing rewrite, never
                      imported as code
      docs            CHANGES, DESIGN, FREEMAP, TODO, Makefile
  derived_from        the "derived from software contributed by" names

The 15% line is the audit's, quoted not chosen here, and the audit itself
overrides it by intent for `hammer2_disk.h` and the six algorithm files; the
override list below is copied from its Classification section and is the one
hand-written input, marked as such.

Selftest: `--selftest` builds a five-file tree in a temp directory covering
each license class plus a NEGATIVE CONTROL, a BSD-3 file whose SPDX tag says
BSD-2, and asserts the classifier reports the disagreement rather than the
tag. Prints its population.
"""

from __future__ import annotations

import argparse
import csv
import io
import pathlib
import re
import subprocess
import sys
import tempfile

HOME = pathlib.Path.home() / "Projects"
TREES = {
    "dragonfly": (HOME / "dragonfly-hammer2-upstream", "sys/vfs/hammer2"),
    "freebsd": (HOME / "freebsd-hammer2-upstream", "src/sys/fs/hammer2"),
    "netbsd": (HOME / "netbsd-hammer2-upstream", "src/sys/fs/hammer2"),
    "openbsd": (HOME / "openbsd-hammer2-upstream", "src/sys/fs/hammer2"),
    # Not a HAMMER2 tree: the BSD macro headers the core is written against
    # (RB_* from sys/tree.h, TAILQ_*/LIST_* from sys/queue.h), which Linux
    # does not have and every BSD does.  A sparse clone at a release tag;
    # only the files VENDORED names below get rows.
    "freebsd-src": (HOME / "freebsd-src-upstream", "sys/sys"),
}
PORTS = ("freebsd", "netbsd", "openbsd")
VENDORED = {"freebsd-src": {"tree.h", "queue.h"}}
# Port-only files the Linux port carries anyway.  hammer2_rb.h is FreeBSD's
# copy of the RB_SCAN family, which DragonFly's own sys/tree.h provides
# natively and FreeBSD's does not; Linux is in FreeBSD's position.
CARRY_PORT_ONLY = {"hammer2_rb.h"}
OUT = pathlib.Path(__file__).resolve().parent.parent / "research/hammer2-linux/legal/hammer2-provenance.csv"

# The audit's OS-SPECIFIC line, and its by-intent overrides. Hand-written
# input, copied from HAMMER2_PORTABILITY_AUDIT.md "Classification".
OS_SPECIFIC_RATIO = 0.15
CARRY_BY_INTENT = {
    "hammer2_disk.h", "hammer2_flush.c", "hammer2_xops.c", "hammer2_chain.c",
    "hammer2_bulkfree.c", "hammer2_freemap.c", "hammer2_inode.c",
}
DOCS = {"CHANGES", "DESIGN", "FREEMAP", "TODO", "Makefile", "Makefile.inc"}

COLUMNS = [
    "original_path", "current_project", "commit_or_tag", "copyright_holder",
    "derived_from", "license_expression", "SPDX_identifier", "port_status",
    "modified_by_port", "ArtNix_candidate_use",
]

# Anchored at the start of the stripped line and requiring a year, so the
# "copyright notice, this list of conditions" clause text and zlib's "see
# copyright notice in zlib.h" cannot match: the first run of this script
# credited both as holders.
COPYRIGHT = re.compile(r"^Copyright\s*(?:\(c\)|\xa9)?\s*[\d][\d,\s\-]*,?\s*(?:by\s+)?([^*\n]+?)\.?\s*(?:All rights reserved\.?)?\s*$", re.I)
SPDX = re.compile(r"SPDX-License-Identifier:\s*([^\s*]+)")


def head(path: pathlib.Path, n: int = 100) -> str:
    try:
        with path.open(errors="replace") as fh:
            return "".join(fh.readline() for _ in range(n))
    except OSError:
        return ""


def classify(text: str) -> str:
    """License from the TEXT. Order matters: BSD-3 is BSD-2 plus a clause."""
    if "Neither the name" in text:
        return "BSD-3-Clause"
    if re.search(r"Redistributions of source code must retain", text):
        return "BSD-2-Clause"
    if "BSD 2-Clause License" in text:                  # Collet's LZ4/xxHash form
        return "BSD-2-Clause"
    if "provided 'as-is'" in text or "see copyright notice in zlib.h" in text:
        return "Zlib"
    return "NONE"


def holders(text: str) -> str:
    """A notice whose holder is on the NEXT line ("Copyright (c) 1991, 1993 /
    The Regents of ...", queue.h's Berkeley form) matches with the last year
    digit as the holder; that is detected and the next line taken."""
    out = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = COPYRIGHT.search(line.strip(" *\t/"))
        if m:
            h = m.group(1).strip()
            if h.isdigit() and i + 1 < len(lines):
                h = lines[i + 1].strip(" *\t/")
                h = re.sub(r"\.?\s*All rights reserved\.?\s*$", "", h, flags=re.I)
            h = re.sub(r"\s*<[^>]*>", "", h)             # drop the email
            if h and h not in out:
                out.append(h)
    return ";".join(out)


def derived(text: str) -> str:
    """The lines after "derived from software contributed to", each opening
    with `by` or `and`, up to the blank comment line. hammer2_xops.c has
    three consecutive `by` lines; hammer2_chain.c has `by ... and ...`."""
    out = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "derived from software contributed" not in line:
            continue
        for nxt in lines[i + 1:]:
            body = nxt.strip(" *\t/")
            m = re.match(r"(?:by|and)\s+(.+)", body)
            if not m:
                break
            name = re.sub(r"\s*<[^>]*>|\s*\(.*\)", "", m.group(1)).strip(" .")
            if name and name not in out:
                out.append(name)
        break
    return ";".join(out)


# Pinned WIDTH, and `--short` alone is what made this gate fail on a tree that
# had not changed. Git's default `core.abbrev=auto` derives the prefix length
# from the clone's OBJECT COUNT, not from actual ambiguity, so the same commit
# abbreviates differently depending on how the clone was fetched. Measured
# 2026-08-25, all four at the same HEADs the committed CSV already recorded:
#
#     dragonfly  250,615 objects -> 22b053204  (9)
#     freebsd         91 objects -> 3df307f    (7)
#     netbsd          87 objects -> 64095c3    (7)
#     openbsd         89 objects -> a3747df    (7)
#
# The dragonfly clone had been deepened or re-fetched; `22b0532` is still a
# correct and UNAMBIGUOUS prefix (one object in that db matches it). So the
# byte-compare failed on the environment, and regenerating would have written
# an unstable value into a published legal record instead of pinning it.
ABBREV = 12


def rev(tree: pathlib.Path) -> str:
    r = subprocess.run(["git", "-C", str(tree), "rev-parse",
                        "--short=%d" % ABBREV, "HEAD"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"COULD-NOT-RUN: {tree} is not a git tree: {r.stderr.strip()}"); sys.exit(2)
    return r.stdout.strip()


def ratio(a: pathlib.Path, b: pathlib.Path) -> str:
    """The portability audit's method, with the audit's INSTRUMENT: GNU
    `diff | grep -cE '^[<>]'` over the sum of both lengths. difflib.ndiff
    aligns differently and read hammer2_vnops.c as 0.702 against the audit's
    0.627, so the column would not have been checkable against that table."""
    r = subprocess.run(["diff", str(a), str(b)], capture_output=True, text=True)
    if r.returncode not in (0, 1):
        print(f"COULD-NOT-RUN: diff failed on {a}: {r.stderr.strip()}"); sys.exit(2)
    changed = sum(1 for l in r.stdout.splitlines() if l[:1] in "<>")
    la = a.read_text(errors="replace").splitlines()
    lb = b.read_text(errors="replace").splitlines()
    denom = len(la) + len(lb)
    return f"{changed / denom:.3f}" if denom else ""


def files_in(root: pathlib.Path):
    return sorted(p for p in root.rglob("*") if p.is_file())


def candidate(name: str, rel: str, status: str, r: str) -> str:
    if name in DOCS:
        return "docs"
    if rel.startswith(("xxhash/", "zlib/")):
        return "stock-kernel"      # before `dropped`: every port drops zlib/
    if status == "dropped":
        return "drop"
    if name in CARRY_BY_INTENT:
        return "carry"
    if r and float(r) > OS_SPECIFIC_RATIO:
        return "rewrite"
    return "carry"


def port_candidate(tree: str, name: str, rel: str, status: str, r: str) -> str:
    if tree == "dragonfly":
        return candidate(name, rel, status, r)
    if tree in VENDORED:
        return "carry"
    if name in DOCS:
        return "docs"
    if tree == "freebsd" and status == "port-only" and name in CARRY_PORT_ONLY:
        return "carry"                  # FreeBSD's copy is the one carried
    return "reference"


def generate(trees=TREES) -> list[dict]:
    rows = []
    roots = {k: t / sub for k, (t, sub) in trees.items()}
    for k, root in roots.items():
        if not root.is_dir():
            print(f"COULD-NOT-RUN: {root} missing; clone the tree first"); sys.exit(2)
    revs = {k: rev(t) for k, (t, _) in trees.items()}
    df_root = roots["dragonfly"]
    df_names = {p.relative_to(df_root).as_posix() for p in files_in(df_root)}

    for k, root in roots.items():
        for p in files_in(root):
            rel = p.relative_to(root).as_posix()
            if k in VENDORED and rel not in VENDORED[k]:
                continue
            text = head(p)
            if k in VENDORED:
                status, r = "vendored", ""
            elif k == "dragonfly":
                carriers = [q for q in PORTS if (roots[q] / rel).is_file()]
                status = "+".join(carriers) if carriers else "dropped"
                r = ratio(p, roots["freebsd"] / rel) if "freebsd" in carriers else ""
            else:
                status = "port" if rel in df_names else "port-only"
                r = ""
            rows.append({
                "original_path": f"{trees[k][1]}/{rel}",
                "current_project": k,
                "commit_or_tag": revs[k],
                "copyright_holder": holders(text),
                "derived_from": derived(text),
                "license_expression": classify(text),
                "SPDX_identifier": (SPDX.search(text) or [None, ""])[1],
                "port_status": status,
                "modified_by_port": r,
                "ArtNix_candidate_use": port_candidate(k, p.name, rel, status, r),
            })
    return rows


def render(rows: list[dict]) -> str:
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=COLUMNS, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue()


BSD3 = """/*
 * Copyright (c) 2011-2020 The DragonFly Project.  All rights reserved.
 *
 * This code is derived from software contributed to The DragonFly Project
 * by Matthew Dillon <dillon@dragonflybsd.org>
 * and Venkatesh Srinivas <vsrinivas@dragonflybsd.org>
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 3. Neither the name of The DragonFly Project nor the names of its
 */
"""
BSD2 = """/*
 * Copyright (c) 2019 Someone Else
 * 1. Redistributions of source code must retain the above copyright
 * 2. Redistributions in binary form must reproduce the above copyright
 */
"""
BERKELEY = "/*\n * Copyright (c) 1991, 1993\n *\tThe Regents of the University of California.  All rights reserved.\n *\n * 3. Neither the name of the University\n */\n"
ZLIB = "/* adler32.c\n * Copyright (C) 1995-2011 Mark Adler\n * For conditions of distribution and use, see copyright notice in zlib.h\n */\n"
NONE = "/* inffixed.h -- generated */\n"
MISTAGGED = "/*\n * SPDX-License-Identifier: BSD-2-Clause\n" + BSD3[2:]


def selftest() -> int:
    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td)
        trees = {}
        for k, (_, sub) in TREES.items():
            t = base / k
            (t / sub).mkdir(parents=True)
            subprocess.run(["git", "-C", str(t), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(t), "-c", "user.name=t", "-c", "user.email=t@t",
                            "commit", "-q", "--allow-empty", "-m", "x"], check=True)
            trees[k] = (t, sub)
        df = base / "dragonfly" / TREES["dragonfly"][1]
        (df / "a.c").write_text(BSD3 + "int a;\n")
        (df / "b.c").write_text(BSD2 + "int b;\n")
        (df / "zlib").mkdir()
        (df / "zlib/z.c").write_text(ZLIB)
        (df / "zlib/n.h").write_text(NONE)
        (df / "m.c").write_text(MISTAGGED + "int m;\n")
        (df / "gone.c").write_text(BSD3)
        fb = base / "freebsd" / TREES["freebsd"][1]
        (fb / "a.c").write_text(BSD3 + "int a;\n")                   # identical
        (fb / "b.c").write_text(BSD2 + "int b;\nint c;\nint d;\n")  # 2 of 8 lines
        (fb / "m.c").write_text(MISTAGGED + "int m;\n")
        (fb / "only.c").write_text(BSD3)
        (fb / "hammer2_rb.h").write_text(BSD3)                       # port-only, carried
        vs = base / "freebsd-src" / TREES["freebsd-src"][1]
        (vs / "tree.h").write_text(BSD2)
        (vs / "queue.h").write_text(BERKELEY)
        (vs / "other.h").write_text(BSD2)                            # not vendored: no row

        rows = {r["original_path"].split("/")[-1] + "@" + r["current_project"]: r
                for r in generate(trees)}
        cases = [
            ("BSD-3 from text", rows["a.c@dragonfly"]["license_expression"] == "BSD-3-Clause"),
            ("BSD-2 from text", rows["b.c@dragonfly"]["license_expression"] == "BSD-2-Clause"),
            ("zlib by reference", rows["z.c@dragonfly"]["license_expression"] == "Zlib"),
            ("no notice is NONE", rows["n.h@dragonfly"]["license_expression"] == "NONE"),
            ("holder parsed, clause text not a holder",
             rows["a.c@dragonfly"]["copyright_holder"] == "The DragonFly Project"),
            ("zlib reference line not a holder", rows["z.c@dragonfly"]["copyright_holder"] == "Mark Adler"),
            ("derived-from parsed", rows["a.c@dragonfly"]["derived_from"] == "Matthew Dillon;Venkatesh Srinivas"),
            ("NEGATIVE CONTROL: text beats tag", rows["m.c@dragonfly"]["license_expression"] == "BSD-3-Clause"
             and rows["m.c@dragonfly"]["SPDX_identifier"] == "BSD-2-Clause"),
            ("dropped detected", rows["gone.c@dragonfly"]["port_status"] == "dropped"
             and rows["gone.c@dragonfly"]["ArtNix_candidate_use"] == "drop"),
            ("carrier set", rows["a.c@dragonfly"]["port_status"] == "freebsd"),
            ("identical ratio 0", rows["a.c@dragonfly"]["modified_by_port"] == "0.000"),
            ("ratio is audit's method", rows["b.c@dragonfly"]["modified_by_port"] == f"{2/(6+8):.3f}"),
            ("stock-kernel for zlib/", rows["z.c@dragonfly"]["ArtNix_candidate_use"] == "stock-kernel"),
            ("port-only detected", rows["only.c@freebsd"]["port_status"] == "port-only"),
            ("port file is reference", rows["a.c@freebsd"]["ArtNix_candidate_use"] == "reference"),
            ("port-only file named in CARRY_PORT_ONLY is carry",
             rows["hammer2_rb.h@freebsd"]["port_status"] == "port-only"
             and rows["hammer2_rb.h@freebsd"]["ArtNix_candidate_use"] == "carry"),
            ("vendored file is carry", rows["tree.h@freebsd-src"]["port_status"] == "vendored"
             and rows["tree.h@freebsd-src"]["ArtNix_candidate_use"] == "carry"),
            ("holder on the line after the years (Berkeley form)",
             rows["queue.h@freebsd-src"]["copyright_holder"] == "The Regents of the University of California"),
            ("port-only carry is FreeBSD's copy only",
             rows["hammer2_rb.h@freebsd"]["ArtNix_candidate_use"] == "carry"
             and all(rows.get(f"hammer2_rb.h@{q}", {}).get("ArtNix_candidate_use", "reference") == "reference"
                     for q in ("netbsd", "openbsd"))),
            ("NEGATIVE CONTROL: unlisted file in a vendored tree gets no row",
             "other.h@freebsd-src" not in rows),
        ]
    bad = [n for n, ok in cases if not ok]
    for n, ok in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {n}")
    print(f"hammer2-provenance selftest: {len(cases)} case(s), {len(bad)} failed")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="regenerate and fail if it differs from the committed CSV")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    rows = generate()
    text = render(rows)
    uses = {}
    for r in rows:
        uses[r["ArtNix_candidate_use"]] = uses.get(r["ArtNix_candidate_use"], 0) + 1
    print(f"hammer2-provenance: {len(rows)} file(s) over {len(TREES)} tree(s); "
          + ", ".join(f"{k}={v}" for k, v in sorted(uses.items())))
    disagree = [r for r in rows if r["SPDX_identifier"]
                and r["SPDX_identifier"] != r["license_expression"]]
    print(f"  SPDX tag disagreeing with license text: {len(disagree)}")
    for r in disagree:
        print(f"    {r['current_project']}:{r['original_path']} tag={r['SPDX_identifier']} text={r['license_expression']}")
    if a.write:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(text)
        print(f"  wrote {OUT}")
    if a.check:
        if not OUT.is_file():
            print(f"FAIL: {OUT} missing; run --write")
            return 1
        if OUT.read_text() != text:
            print("FAIL: committed CSV differs from the trees; run --write and read the diff")
            return 1
        print("  committed CSV matches the trees")
    return 0


if __name__ == "__main__":
    sys.exit(main())
