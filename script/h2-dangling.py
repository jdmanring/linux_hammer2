#!/usr/bin/env python3
"""Names without inodes and inodes without names, per PFS, on media.

    python3 script/h2-dangling.py <image> [PFS ...]   (H2_HAMMER2 names show's binary)
    python3 script/h2-dangling.py --dump <file> [PFS ...]

Reads `hammer2 -v show`, run by h2-leafcount.py's show(), which reads its
exit status and keeps every HAMMER2_SHOW_ variable from it.  For each PFS
under the super-root (all when none is named) prints the count of inodes
indexed under its root and of directory entries, then every entry whose
inode number has no inode (dangling) and every inode no entry names
(orphan).  A PFS root's own inode is not indexed under itself and is not
counted.  An orphan that is a directory is the top of a subtree: the
entries under it name their own inodes, so those read as named, and the
count of inodes no walk from the PFS root reaches through entries is
printed beside it: what the orphans hold, and any detached set that no
entry outside it names, such as two directories naming each other.  A
directory's
entries are the dirent blockrefs nested under its inode in show's dump.
An inode is known by its blockref key, which is its number on media this
port and DragonFly 6.4 write; older media embed an inode in its
directory keyed by its name's hash, and each such inode would read as an
orphan, the alarm direction (no such image has been read).
H2_DANGLING_NAMES (comma separated) prints each entry of those names with
its inode number and whether that inode is present.

Exit 2 when show fails, when the dump holds no PFS (empty, or flattened),
when a blockref fails its check (show then lists only its direct children
and exits 0), when a named PFS is not found, or when an entry's name or
inode number does not parse, since a reading of nothing must not read as
clean; 1 when anything dangles, is orphaned or is not reached from the root;
0 otherwise.
"""
import importlib.util
import os
import re
import sys

BREF = re.compile(r"^( *)(inode|dirent|indirect|data|empty)\.\d+\s+[0-9a-f]{16} ([0-9a-f]{16})/\d+")


def leafcount():
    sys.dont_write_bytecode = True	# no __pycache__ beside the tools
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("h2leafcount", os.path.join(here, "h2-leafcount.py"))
    if spec is None or spec.loader is None:
        raise ValueError("h2-leafcount.py is not beside this tool")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def show(image):
    return "".join(leafcount().show(image, "-v"))


def parse(text):
    """{pfs: {"inodes": set, "dirents": [(name, inum, mod, parent)]}} and the
    count of entries whose fields did not parse.  parent is the inode number
    of the inode the entry is nested under, None for the PFS root."""
    pfs = {}
    cur = None		# (name, depth of the PFS root inode)
    pending = None	# ("pfsroot", depth), ("dirent", parent) or ("dirent", parent, name, mod)
    mod = None
    sroot_depth = None
    stack: list[tuple[int, int | None]] = []	# (depth, inode number) of the inodes enclosing this line in the PFS
    unread = 0
    for line in text.splitlines():
        m = BREF.match(line)
        if m:
            if pending and pending[0] == "dirent":
                unread += 1
            pending = None
            depth, typ, key = len(m.group(1)), m.group(2), int(m.group(3), 16)
            if cur and depth <= cur[1]:
                cur = None
            while stack and stack[-1][0] >= depth:
                stack.pop()
            if typ == "inode" and sroot_depth is None:
                sroot_depth = depth		# the super-root
            elif typ == "inode" and cur is None and sroot_depth is not None and depth > sroot_depth:
                pending = ("pfsroot", depth)
                stack[:] = [(depth, None)]
            elif cur and typ == "inode":
                pfs[cur[0]]["inodes"].add(key)
                stack.append((depth, key))
            elif cur and typ == "dirent":
                pending = ("dirent", stack[-1][1] if stack else None)
            continue
        s = line.strip()
        mm = re.search(r"(?:^| )mod=([0-9a-f]+)", s)
        if mm:
            mod = mm.group(1)
        if pending and pending[0] == "pfsroot" and s.startswith("filename "):
            cur = (s.split('"')[1], pending[1])
            pfs.setdefault(cur[0], {"inodes": set(), "dirents": []})
            pending = None
        elif pending and pending[0] == "dirent" and len(pending) == 2 and s.startswith("filename "):
            pending = ("dirent", pending[1], s.split('"')[1], mod)
        elif cur and pending and len(pending) == 4 and s.startswith("inum "):
            try:
                inum = int(s.split()[1], 16)
            except (IndexError, ValueError):
                continue		# left pending, so counted unread
            pfs[cur[0]]["dirents"].append((pending[2], inum, pending[3], pending[1]))
            pending = None
    if pending and pending[0] == "dirent":
        unread += 1
    return pfs, unread


def report(pfs, want, out):
    """Prints the reading; returns the exit status."""
    look = {x for x in os.environ.get("H2_DANGLING_NAMES", "").split(",") if x}
    for n in sorted(pfs, key=lambda k: (len(k), k)) if look else []:
        for name, inum, mod, _ in pfs[n]["dirents"]:
            if name in look:
                print("look  %s %s inum %#x dirent mod %s inode %s"
                      % (n, name, inum, mod, "present" if inum in pfs[n]["inodes"] else "ABSENT"), file=out)
    names = sorted(want or pfs)
    missing = [n for n in names if n not in pfs]
    if not names or missing:
        print("dangling: COULD-NOT-READ: no PFS %s; found %s" % (missing, sorted(pfs)), file=out)
        return 2
    bad = 0
    for n in names:
        d = pfs[n]
        lost = [x for x in d["dirents"] if x[1] not in d["inodes"]]
        orph = sorted(d["inodes"] - {x[1] for x in d["dirents"]})
        under = {}
        for name, inum, mod, parent in d["dirents"]:
            under.setdefault(parent, []).append(inum)
        seen, todo = set(), [None]
        while todo:
            for inum in under.get(todo.pop(), []):
                if inum in d["inodes"] and inum not in seen:
                    seen.add(inum)
                    todo.append(inum)
        held = len(d["inodes"] - seen) - len(orph)
        bad += len(lost) + len(orph) + held
        print("%s: %d inode(s), %d dirent(s), %d without an inode, %d inode(s) no entry names, "
              "%d more no walk from the root reaches"
              % (n, len(d["inodes"]), len(d["dirents"]), len(lost), len(orph), held), file=out)
        for name, inum, mod, _ in lost[:20]:
            print("  dangling  %s inum %#x dirent mod %s" % (name, inum, mod), file=out)
        for inum in orph[:20]:
            print("  orphan    inum %#x, %d entr%s under it" % (
                inum, len(under.get(inum, [])), "y" if len(under.get(inum, [])) == 1 else "ies"), file=out)
    return 1 if bad else 0


def main(argv, out=sys.stdout):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        if argv[1] == "--dump":
            with open(argv[2]) as f:
                text = f.read()
            argv = argv[1:]
        else:
            text = show(argv[1])
        nfail = len(leafcount().CHECKFAIL.findall(text))
    except (OSError, IndexError, ValueError) as e:
        print("dangling: COULD-NOT-READ: %s" % e, file=out)
        return 2
    if nfail:
        print("dangling: COULD-NOT-READ: %d blockref(s) fail their check, and show lists "
              "only their direct children" % nfail, file=out)
        return 2
    pfs, unread = parse(text)
    if unread:
        print("dangling: COULD-NOT-READ: %d entr%s without a name and an inode number"
              % (unread, "y" if unread == 1 else "ies"), file=out)
        return 2
    return report(pfs, set(argv[2:]), out)


def selftest():
    import io
    import tempfile
    fails = 0

    def expect(cond, what):
        nonlocal fails
        print("  %s  %s" % ("ok  " if cond else "FAIL", what))
        fails += 0 if cond else 1

    def bref(d, t, k):
        return "%s%s.0      0000000000000000 %016x/0  \n%s vol=0 mod=%016x lfcnt=0 {\n" % (
            "  " * d, t, k, "  " * d + "             ", k)

    def dirent(d, name, inum):
        return bref(d, "dirent", 0x8000 + inum) + "%sfilename \"%s\"\n%sinum 0x%016x\n%s} (dirent.0)\n" % (
            "  " * (d + 1), name, "  " * (d + 1), inum, "  " * d)

    def inode(d, inum, name=None):
        return bref(d, "inode", inum) + "%sfilename \"%s\"\n" % ("  " * (d + 1), name or "%#x" % inum)

    # The super-root, a PFS root named A, its index holding a directory and
    # a file, the root's entry for the directory and the directory's for
    # the file, which is the shape `hammer2 -v show` prints.
    clean = (inode(1, 0) + inode(2, 1, "A") + bref(3, "indirect", 0)
             + inode(4, 0x400) + dirent(5, "f", 0x401) + inode(4, 0x401)
             + dirent(3, "d", 0x400))

    def run(text, *want):
        buf = io.StringIO()
        with tempfile.NamedTemporaryFile("w", suffix=".dump") as f:
            f.write(text)
            f.flush()
            rc = main(["x", "--dump", f.name] + list(want), buf)
        return rc, buf.getvalue()

    rc, o = run(clean)
    expect(rc == 0 and "A: 2 inode(s), 2 dirent(s), 0 without an inode, 0 inode(s) no entry names, 0 more" in o,
           "a clean PFS reads 0 and 0, and the walk from its root reaches both inodes")
    rc, o = run(clean.replace("inum 0x0000000000000401", "inum 0x0000000000000405"))
    expect(rc == 1 and "dangling  f inum 0x405" in o and "orphan    inum 0x401" in o,
           "an entry moved to a missing inode reads one dangling and one orphan")
    rc, o = run(clean + inode(4, 0x402))
    expect(rc == 1 and "orphan    inum 0x402" in o and "0 without an inode, 1" in o,
           "an inode no entry names reads as an orphan alone")
    rc, o = run("")
    expect(rc == 2, "an empty dump is refused")
    rc, o = run("".join(l.lstrip() + "\n" for l in clean.splitlines()))
    expect(rc == 2, "a flattened dump is refused")
    rc, o = run(clean, "B")
    expect(rc == 2, "a named PFS not found is refused")
    rc, o = run(clean.replace('filename "f"\n', ""))
    expect(rc == 2 and "1 entry without" in o, "an entry whose name does not parse is refused")
    rc, o = run(clean.replace('filename "d"\n', ""))
    expect(rc == 2 and "1 entry without" in o, "a nameless entry last in the dump is refused")
    rc, o = run(clean.replace("inum 0x0000000000000401", "inum 0xzz"))
    expect(rc == 2 and "1 entry without" in o, "an entry whose inode number does not parse is refused")
    rc, o = run(clean.replace(" lfcnt=0 {", " (xxh xxhash64|none:default 0000000000000001/0000000000000002 failed) {", 1))
    expect(rc == 2 and "fail their check" in o, "a blockref that fails its check is refused")
    buf = io.StringIO()
    expect(main(["x", "--dump", "/nonexistent/h2-dangling.dump"], buf) == 2
           and "COULD-NOT-READ" in buf.getvalue(), "a dump file that cannot be read is refused")
    # Two PFSes: B holds the inode A's entry for g names, which A lacks, so
    # A's entry dangles only if A ends where B begins.
    two = (clean + dirent(3, "g", 0x405) + inode(2, 1, "B") + bref(3, "indirect", 0)
           + inode(4, 0x405) + dirent(3, "g", 0x405))
    rc, o = run(two)
    expect(rc == 1 and "dangling  g inum 0x405" in o and "B: 1 inode(s), 1 dirent(s), 0 without an inode, 0" in o,
           "a PFS ends where the next begins: an inode in B does not answer A's entry")
    # A directory no entry names, holding a file: one orphan, and the file
    # under it is the one more no walk reaches.
    rc, o = run(clean + inode(4, 0x402) + dirent(5, "h", 0x403) + inode(4, 0x403))
    expect(rc == 1 and "1 inode(s) no entry names, 1 more no walk" in o and "0x402, 1 entry under it" in o,
           "an orphan directory's contents count as unreached, not as named")
    # Two directories naming each other and nothing naming either: no
    # orphan, and both unreached.
    rc, o = run(clean + inode(4, 0x406) + dirent(5, "y", 0x407) + inode(4, 0x407) + dirent(5, "z", 0x406))
    expect(rc == 1 and "0 inode(s) no entry names, 2 more no walk" in o,
           "a detached cycle no entry outside it names is unreached, and fails")
    # A small PFS whose root's blockset holds an inode beside a root entry:
    # the entry is the root's, not the inode's at the same depth.
    rc, o = run(inode(1, 0) + inode(2, 1, "C") + inode(3, 0x500) + dirent(3, "x", 0x500))
    expect(rc == 0 and "C: 1 inode(s), 1 dirent(s), 0 without an inode, 0 inode(s) no entry names, 0 more" in o,
           "an entry beside an inode at its own depth belongs to the root")
    print("dangling selftest: %d failed" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    sys.exit(main(sys.argv))
