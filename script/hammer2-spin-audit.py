#!/usr/bin/env python3
"""H1 reading 1: which hammer2_spin_* regions could not become a Linux lock.

Why this exists
---------------
`research/hammer2-linux/HAMMER2_LINUX_PORT_PLAN.md` puts three readings in
H1's first week, before any estimate is written. This is the first: the
per-site audit of the spin regions, asking whether Linux may use a
`rw_semaphore` (sleepable, the plan's default) at every site or must use a
`spinlock_t` somewhere.

The question has two directions and only one of them is the hazard here.
A region that SLEEPS under the lock forbids `spinlock_t`; FreeBSD already
proves that is fine, because `hammer2_os.h` maps the whole family onto `sx`
locks, which sleep. A region entered from ATOMIC context forbids
`rw_semaphore`, and that is the one Linux introduces: `submit_bio`
completions run in softirq unless the driver defers them.

So this script answers the first direction mechanically and reports the
second as a population to hand-read, because reachability from a completion
callback is a call-graph question a line scanner cannot answer.

Reading the output
------------------
It prints its POPULATION and its UNRESOLVED set before any verdict. A
region whose release is not found is NOT a clean region; it is unread, and
the two are indistinguishable from a count alone.
"""

from __future__ import annotations

import pathlib
import re
import sys

ACQ = re.compile(r'\bhammer2_spin_(ex|sh)\s*\(\s*([^;]+?)\s*\)\s*;')
REL = re.compile(r'\bhammer2_spin_un(ex|sh)\s*\(\s*([^;]+?)\s*\)\s*;')

# Calls that sleep or block in the BSD kernels. Deliberately over-broad: a
# false positive costs one hand-read, a false negative costs the finding.
SLEEPY = re.compile(
    r'\b(kmalloc|kfree|lockmgr|tsleep|msleep|'
    r'hammer2_mtx_(?:ex|sh|unlock|ex_try|sh_try)|'
    r'hammer2_lk_\w+|vn_lock|vput|vrele|vget|'
    r'hammer2_io_(?:get|getblk|bread|new|newnz)|getblk|bread|'
    r'bawrite|bwrite|brelse|bufdone|'
    r'hammer2_chain_lock|hammer2_inode_lock)\s*\(')

FUNC_END = re.compile(r'^\}')

# Dropped by every BSD port (HAMMER2_PORTABILITY_AUDIT.md), so its sites are
# not part of what a Linux port carries. Counted, then excluded, out loud.
NOT_PORTED = {"hammer2_ccms.c"}


def norm(expr: str) -> str:
    """Normalise a lock expression so `&x->spin` and `& x -> spin` match."""
    return re.sub(r'\s+', '', expr).lstrip('&')


def audit(tree: pathlib.Path):
    resolved, unresolved = [], []
    for path in sorted(tree.glob('*.c')):
        lines = path.read_text(errors='replace').splitlines()
        for i, line in enumerate(lines):
            m = ACQ.search(line)
            if not m:
                continue
            kind, lock = m.group(1), norm(m.group(2))
            body, j, found = [], i + 1, False
            while j < len(lines):
                if FUNC_END.match(lines[j]):
                    break               # left the function without a release
                r = REL.search(lines[j])
                if r and norm(r.group(2)) == lock:
                    found = True
                    break
                body.append(lines[j])
                j += 1
            sleeps = sorted({x.group(0).rstrip('(').strip()
                             for x in SLEEPY.finditer("\n".join(body))})
            rec = (path.name, i + 1, kind, lock, j - i, sleeps)
            (resolved if found else unresolved).append(rec)
    return resolved, unresolved


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: hammer2-spin-audit.py <path to a hammer2 source dir>",
              file=sys.stderr)
        return 2
    tree = pathlib.Path(argv[0]).expanduser()
    if not tree.is_dir():
        print(f"not a directory: {tree}", file=sys.stderr)
        return 2

    resolved, unresolved = audit(tree)
    total = len(resolved) + len(unresolved)
    if total == 0:
        print(f"POPULATION: 0 acquire sites under {tree}. That is a reading "
              f"about this directory, not about HAMMER2: check the path.")
        return 1

    dropped = [r for r in resolved + unresolved if r[0] in NOT_PORTED]
    print(f"POPULATION: {total} acquire site(s) under {tree}")
    print(f"  resolved to a release of the same lock in the same function: "
          f"{len(resolved)}")
    print(f"  UNRESOLVED, released on another path or by a helper, hand-read: "
          f"{len(unresolved)}")
    print(f"  in files no BSD port carries ({', '.join(sorted(NOT_PORTED))}): "
          f"{len(dropped)}, so {total - len(dropped)} are port-relevant")

    sleepers = [r for r in resolved if r[5]]
    print(f"  resolved regions naming a sleeping call: {len(sleepers)}")
    print()
    for r in sorted(sleepers, key=lambda r: -r[4]):
        print(f"  CANDIDATE {r[0]}:{r[1]} spin_{r[2]}({r[3]}) span={r[4]}"
              f" -> {', '.join(r[5])}")
    print()
    print("UNRESOLVED sites, each needing a hand-read:")
    for r in unresolved:
        print(f"  {r[0]}:{r[1]} spin_{r[2]}({r[3]})")
    print()
    print("A CANDIDATE is not a finding. A loop that drops the lock, sleeps, "
          "then re-acquires\nat the tail puts the sleeping call textually "
          "after the acquire with the lock held\nnowhere: read the drop site "
          "before believing any row above.")
    return 0


def selftest() -> int:
    """Falsify the matcher in both directions, on text built for the purpose."""
    import tempfile
    cases = [
        # (source, expect_resolved, expect_unresolved, expect_sleepers)
        ("void f(void)\n{\n\themmer2_nothing();\n}\n", 0, 0, 0),
        ("void f(void)\n{\n\thammer2_spin_ex(&a->spin);\n"
         "\thammer2_spin_unex(&a->spin);\n}\n", 1, 0, 0),
        # sleeps under the lock: must be flagged
        ("void f(void)\n{\n\thammer2_spin_ex(&a->spin);\n"
         "\tvput(vp);\n\thammer2_spin_unex(&a->spin);\n}\n", 1, 0, 1),
        # released for a DIFFERENT lock: must not count as resolved
        ("void f(void)\n{\n\thammer2_spin_ex(&a->spin);\n"
         "\thammer2_spin_unex(&b->spin);\n}\n", 0, 1, 0),
        # whitespace and & variation must still match
        ("void f(void)\n{\n\thammer2_spin_sh( & a -> spin );\n"
         "\thammer2_spin_unsh(&a->spin);\n}\n", 1, 0, 0),
    ]
    bad = 0
    for n, (src, er, eu, es) in enumerate(cases):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "t.c").write_text(src)
            res, unres = audit(p)
            sl = len([r for r in res if r[5]])
            got, want = (len(res), len(unres), sl), (er, eu, es)
            if got != want:
                print(f"case {n}: got {got}, want {want}")
                bad += 1
    print(f"selftest: {len(cases)} case(s), {bad} failure(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
