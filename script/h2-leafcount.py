#!/usr/bin/env python3
"""Is a blockref's leaf_count exact on media, read from `hammer2 -q show`.

leaf_count is maintained by hammer2_base_insert() and hammer2_base_delete()
(hammer2_chain.c) when a flush writes a parent's blockmap, and nothing in
the kernel reads it: the chain flag the delete sets on saturation,
HAMMER2_CHAIN_HINT_LEAF_COUNT, is read nowhere.  A SEEK_HOLE that skipped
an indirect block because its leaf_count says the range is full of data
would answer from a field no reader has ever depended on, so this reads
what media actually carries.

The rule, from the insert: each child INODE or DIRENT counts 1; a DATA
child counts 1 plus its own leaf_count; an INDIRECT child counts its
leaf_count; the sum saturates at 65535 (HAMMER2_BLOCKREF_LEAF_MAX).  Every
INODE and INDIRECT line with children printed under it is checked against
that sum.  The volume header's own blockref is not maintained and is
skipped.

For each INDIRECT whose subtree holds file data it also reads the lever's
predicate, leaf_count == 2^(keybits - 16) (one 64 KiB block per slot of
its key range), against the truth from the leaves: the bytes the data
leaves under it cover (2^keybits each) equal 2^keybits of the indirect.
"says full, has a hole" is the case a skip would answer wrongly.

    hammer2 -q show <image> > dump; python3 script/h2-leafcount.py dump

Prints one summary line per category and the first mismatches.  Exit 2
when the dump holds no blockref line at all or a line naming a blockref
type does not parse, since a reading of nothing must not read as exact.
"""
import re
import sys

LEAF_MAX = 65535
TYPES = ("volume", "inode", "indirect", "data", "dirent", "empty",
         "freemap", "freemap_node", "freemap_leaf")
LINE = re.compile(r"^( *)([a-z_]+)\.(\d+)\s+([0-9a-f]{16})\s+([0-9a-f]{16})/(\d+)\s.*?\bleafcnt=(\d+)")
HEAD = re.compile(r"^ *(%s)\.\d+\s" % "|".join(TYPES))


class Node:
    __slots__ = ("depth", "type", "key", "keybits", "leafcnt", "children",
                 "line")

    def __init__(self, depth, typ, key, keybits, leafcnt, line):
        self.depth, self.type, self.key = depth, typ, key
        self.keybits, self.leafcnt, self.line = keybits, leafcnt, line
        self.children = []


def parse(lines):
    """The blockref tree from a quiet dump; raises ValueError on a bad line."""
    roots, stack = [], []
    for no, raw in enumerate(lines, 1):
        raw = raw.rstrip("\n")
        m = LINE.match(raw)
        if not m:
            if HEAD.match(raw):
                raise ValueError("line %d names a blockref and does not parse: %r" % (no, raw))
            continue
        depth = len(m.group(1))
        n = Node(depth, m.group(2), int(m.group(5), 16), int(m.group(6)),
                 int(m.group(7)), no)
        while stack and stack[-1].depth >= depth:
            stack.pop()
        (stack[-1].children if stack else roots).append(n)
        stack.append(n)
    return roots


def counted(n):
    s = 0
    for c in n.children:
        if c.type in ("inode", "dirent"):
            s += 1
        elif c.type == "data":
            s += 1 + c.leafcnt
        elif c.type == "indirect":
            s += c.leafcnt
    return min(s, LEAF_MAX)


def covered(n):
    """(bytes covered by data leaves, any data below) under n."""
    b, any_data = 0, False
    for c in n.children:
        if c.type == "data":
            b += 1 << c.keybits
            any_data = True
        elif c.type == "indirect":
            cb, cd = covered(c)
            b += cb
            any_data = any_data or cd
    return b, any_data


def walk(roots):
    for r in roots:
        yield r
        yield from walk(r.children)


def measure(roots):
    r = {"nodes": 0, "parents": 0, "exact": 0, "mismatch": [], "saturated": 0,
         "data_indirects": 0, "full_full": 0, "full_hole": [], "short_full": 0,
         "short_hole": 0, "too_wide": 0}
    for n in walk(roots):
        r["nodes"] += 1
        if n.type not in ("inode", "indirect") or not n.children:
            continue
        r["parents"] += 1
        if n.leafcnt == LEAF_MAX:
            r["saturated"] += 1
        want = counted(n)
        if want == n.leafcnt:
            r["exact"] += 1
        else:
            r["mismatch"].append((n, want))
        if n.type != "indirect":
            continue
        b, any_data = covered(n)
        if not any_data:
            continue
        r["data_indirects"] += 1
        if n.keybits - 16 >= 16:	# 2^16 slots or more cannot be told from saturation
            r["too_wide"] += 1
            continue
        says = n.leafcnt == (1 << (n.keybits - 16))
        full = b == (1 << n.keybits)
        if says and full:
            r["full_full"] += 1
        elif says:
            r["full_hole"].append((n, b))
        elif full:
            r["short_full"] += 1
        else:
            r["short_hole"] += 1
    return r


def report(r, out, limit=10):
    print("leafcount: %d blockref(s), %d parent(s) checked, %d exact, %d mismatched, %d saturated"
          % (r["nodes"], r["parents"], r["exact"], len(r["mismatch"]), r["saturated"]), file=out)
    for n, want in r["mismatch"][:limit]:
        print("  mismatch  line %d %s %016x/%d leafcnt=%d counted %d"
              % (n.line, n.type, n.key, n.keybits, n.leafcnt, want), file=out)
    print("leafcount: %d indirect(s) over file data: says full and is %d, says full with a hole %d, "
          "says short and is full %d, short with a hole %d, range too wide to read %d"
          % (r["data_indirects"], r["full_full"], len(r["full_hole"]), r["short_full"],
             r["short_hole"], r["too_wide"]), file=out)
    for n, b in r["full_hole"][:limit]:
        print("  unsafe    line %d indirect %016x/%d leafcnt=%d covers %d of %d bytes"
              % (n.line, n.key, n.keybits, n.leafcnt, b, 1 << n.keybits), file=out)


def main(argv):
    if len(argv) != 2:
        print("usage: h2-leafcount.py <quiet show dump> | --selftest", file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        try:
            roots = parse(f)
        except ValueError as e:
            print("leafcount: COULD-NOT-READ: %s" % e, file=sys.stderr)
            return 2
    r = measure(roots)
    if r["nodes"] == 0:
        print("leafcount: COULD-NOT-READ: no blockref line in %s" % argv[1], file=sys.stderr)
        return 2
    report(r, sys.stdout)
    return 0


def selftest():
    import io

    def dump(rows):
        return ["%s%s.0   %016x %016x/%d vol=0 mir=0 mod=0 leafcnt=%d \n"
                % ("  " * d, t, 0, k, kb, lc) for d, t, k, kb, lc in rows]

    fails = 0

    def expect(cond, what):
        nonlocal fails
        print("  %s  %s" % ("ok  " if cond else "FAIL", what))
        fails += 0 if cond else 1

    # A file: inode over an indirect /17 holding two 64 KiB blocks (full),
    # and an indirect /18 holding three of four (a hole).
    full = dump([(0, "volume", 0, 0, 0), (1, "inode", 0, 0, 5),
                 (2, "indirect", 0, 17, 2), (3, "data", 0, 16, 0), (3, "data", 1 << 16, 16, 0),
                 (2, "indirect", 1 << 18, 18, 3), (3, "data", 1 << 18, 16, 0),
                 (3, "data", 5 << 16, 16, 0), (3, "data", 6 << 16, 16, 0)])
    r = measure(parse(full))
    expect(len(r["mismatch"]) == 0 and r["parents"] == 3, "an exact tree reads exact over every parent")
    expect(r["full_full"] == 1 and r["short_hole"] == 1 and not r["full_hole"],
           "a full indirect says full and a holed one says short")
    # The planted defect: the holed /18 claims four leaves.
    bad = [l.replace("leafcnt=3", "leafcnt=4") for l in full]
    r = measure(parse(bad))
    got = sorted((n.type, n.leafcnt, w) for n, w in r["mismatch"])
    expect(got == [("indirect", 4, 3), ("inode", 5, 6)],
           "a leafcnt one above its children is a mismatch, and so is its parent's sum")
    expect(len(r["full_hole"]) == 1, "and its claim of full over a hole is the unsafe case")
    # Saturation: a parent counted past 65535 must read 65535.
    sat = dump([(0, "inode", 0, 0, LEAF_MAX)] + [(1, "indirect", i << 40, 40, 30000) for i in range(3)])
    r = measure(parse(sat))
    expect(r["saturated"] == 1 and not r["mismatch"], "a sum past 65535 reads saturated and exact")
    # Nothing to read must not read as exact.
    expect(main(["x", "/dev/null"]) == 2, "an empty dump exits 2")
    try:
        parse(["    data.0   zzzz\n"])
        expect(False, "a malformed blockref line is refused")
    except ValueError:
        expect(True, "a malformed blockref line is refused")
    buf = io.StringIO()
    report(measure(parse(bad)), buf)
    expect("unsafe    line" in buf.getvalue(), "the report names the unsafe indirect")
    print("leafcount selftest: %d failed" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    sys.exit(main(sys.argv))
