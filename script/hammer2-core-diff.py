#!/usr/bin/env python3
"""H1 reading 3: how many lines of the HAMMER2 core a port actually carries.

Why this exists
---------------
`HAMMER2_PORTABILITY_AUDIT.md` measures each port against DragonFly with a
raw `diff`, and says in its own method section that the ratio counts comment
and whitespace churn as change, so it overstates and never understates. That
is the right conservative choice for the audit's question, which is which
files face the operating system.

H1's question is different and needs the other bound: to size the port, you
want the lines that genuinely differ, with the mechanical churn removed. The
gap between the two numbers is the estimate's error bar, so both are worth
having and neither replaces the other.

What is normalised, and why each is mechanical
----------------------------------------------
* the licence and copyright block, which every port rewrites wholesale
* `#include` lines, which name each kernel's own headers
* comments and blank lines
* statement reflow: DragonFly wraps prototypes with named parameters,
  FreeBSD's style(9) wraps them unnamed and compact, so the same declaration
  spans a different number of lines in each. Joining inside unbalanced
  parentheses collapses both to one line and compares the declaration itself.
* a storage-class keyword alone on a line, DragonFly's `static\nint\nfoo(...)`
  against FreeBSD's `static int\nfoo(...)`
* the shim's renames, discovered by token-frequency difference over the five
  algorithm files rather than guessed: kprintf/panic/kmalloc/kfree/krealloc
  and the two sleep primitives.

What is NOT normalised, deliberately: anything that could hide a semantic
change. No token is dropped, only renamed; no statement is reordered.
"""

from __future__ import annotations

import difflib
import pathlib
import re
import sys

RENAMES = {
    "kprintf": "hprintf",
    "krateprintf": "hprintf",
    "panic": "hpanic",
    "kmalloc": "hmalloc",
    "kfree": "hfree",
    "krealloc": "hrealloc",
    "kstrdup": "hstrdup",
    "kstrfree": "hstrfree",
    "wakeup": "hammer2_lkc_wakeup",
    "tsleep": "hammer2_lkc_sleep",
}
RENAME_RE = re.compile(r'\b(' + '|'.join(RENAMES) + r')\b')

# style(9) writes a space between a keyword and its parenthesis where
# DragonFly does not, and spells the BSD short integer aliases out. Both are
# cosmetic by definition: the compiler cannot tell the two forms apart.
# Sampled before this existed, they were most of what was left in
# hammer2_chain.c after the reflow and rename passes.
KEYWORD_SPACE = re.compile(r'\b(return|switch|if|while|for|do)\(')
# style(9) parenthesises a return value; DragonFly does not. Cosmetic.
RETURN_PAREN = re.compile(r'^return\s*\((.*)\)\s*;$')
TYPE_ALIAS = {
    "u_int": "unsigned int", "u_char": "unsigned char",
    "u_short": "unsigned short", "u_long": "unsigned long",
    "__debugvar": "__diagused",
}
TYPE_ALIAS_RE = re.compile(r'\b(' + '|'.join(TYPE_ALIAS) + r')\b')

STORAGE = {"static", "extern", "inline", "__inline", "static __inline"}

BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
LINE_COMMENT = re.compile(r'//.*')
INCLUDE = re.compile(r'^\s*#\s*include\b')
STRING = re.compile(r'"(?:\\\\.|[^"\\\\])*"' + r"|'(?:\\\\.|[^'\\\\])*'")


def _depth(s: str) -> int:
    """Parenthesis depth of a pending statement, blind to string literals."""
    bare = STRING.sub('', s)
    return bare.count('(') - bare.count(')')


PROTO = re.compile(r'^((?:[A-Za-z_][\w]*[\s\*]+)+[A-Za-z_]\w*)\s*\((.*)\)\s*;$')


def strip_param_names(stmt: str) -> str:
    """Reduce a PROTOTYPE's parameters to their types.

    style(9) writes prototypes with unnamed parameters where DragonFly names
    them, so the same declaration differs on every line of its parameter list.
    This is the largest single class in the leftover diff: measured before it
    existed, paired prototypes were most of what the characteriser could only
    file as "other". Definitions are untouched, because a definition does not
    end in `);` and its parameter names are used by its body.
    """
    m = PROTO.match(stmt)
    if not m or '=' in stmt:
        return stmt
    head, params = m.group(1), m.group(2)
    if params.count('(') != params.count(')'):
        return stmt              # a function-pointer parameter; leave it alone
    out = []
    for raw in params.split(','):
        toks = raw.split()
        if len(toks) > 1:
            last = toks[-1]
            toks[-1] = '*' * last.count('*') if '*' in last else ''
        out.append(' '.join(t for t in toks if t))
    return f"{head}({', '.join(out)});"


def strip_header(text: str) -> str:
    """Drop the leading licence block, which every port rewrites wholesale."""
    m = re.search(r'^\s*#\s*include', text, re.M)
    return text[m.start():] if m else text


def normalise(text: str) -> list[str]:
    text = strip_header(text)
    text = BLOCK_COMMENT.sub(' ', text)
    text = LINE_COMMENT.sub(' ', text)

    out, buf, depth = [], "", 0
    for raw in text.splitlines():
        if INCLUDE.match(raw):
            continue
        line = raw.strip()
        if not line:
            continue
        line = RENAME_RE.sub(lambda m: RENAMES[m.group(1)], line)
        line = TYPE_ALIAS_RE.sub(lambda m: TYPE_ALIAS[m.group(1)], line)
        line = KEYWORD_SPACE.sub(lambda m: m.group(1) + ' (', line)
        # a storage-class keyword alone on a line joins the next
        if not buf and line in STORAGE:
            buf = line
            continue
        buf = (buf + " " + line).strip() if buf else line
        # Count over the WHOLE pending statement by assignment, never by
        # increment: buf already holds every line joined so far, so `+=`
        # counts each paren once per line and the depth never returns to
        # zero. Measured: one open paren swallowed the rest of the file
        # and hammer2_chain.c reported 1 statement out of 5848 lines.
        depth = _depth(buf)
        if depth > 0:                 # statement continues onto the next line
            continue
        stmt = strip_param_names(re.sub(r'\s+', ' ', buf))
        rp = RETURN_PAREN.match(stmt)
        if rp and rp.group(1).count('(') == rp.group(1).count(')'):
            stmt = f"return {rp.group(1)};"
        out.append(stmt)
        buf = ""
    if buf:
        out.append(strip_param_names(re.sub(r'\s+', ' ', buf)))
    return out


def compare(a: pathlib.Path, b: pathlib.Path):
    na, nb = normalise(a.read_text(errors='replace')), normalise(b.read_text(errors='replace'))
    sm = difflib.SequenceMatcher(None, na, nb, autojunk=False)
    same = sum(bl.size for bl in sm.get_matching_blocks())
    changed = (len(na) - same) + (len(nb) - same)
    return len(na), len(nb), same, changed


FILES = ["hammer2_chain.c", "hammer2_flush.c", "hammer2_freemap.c",
         "hammer2_bulkfree.c", "hammer2_inode.c", "hammer2_xops.c",
         "hammer2_admin.c", "hammer2_io.c", "hammer2_strategy.c",
         "hammer2_vfsops.c", "hammer2_vnops.c", "hammer2_ondisk.c",
         "hammer2_subr.c", "hammer2_ioctl.c"]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: hammer2-core-diff.py <dragonfly dir> <port dir>",
              file=sys.stderr)
        return 2
    df, port = (pathlib.Path(p).expanduser() for p in argv)
    rows, missing = [], []
    for name in FILES:
        a, b = df / name, port / name
        if not a.is_file() or not b.is_file():
            missing.append(name)
            continue
        rows.append((name,) + compare(a, b))

    print(f"POPULATION: {len(FILES)} core file(s) asked for; {len(rows)} "
          f"compared, {len(missing)} absent from one side")
    if missing:
        print(f"  absent (dropped by the port, or renamed): {', '.join(missing)}")
    print()
    print(f"{'file':<22}{'DF':>7}{'port':>7}{'carried':>9}{'changed':>9}{'ratio':>8}")
    tot_a = tot_b = tot_same = 0
    for name, la, lb, same, changed in sorted(rows, key=lambda r: -(r[4] / max(r[1] + r[2], 1))):
        ratio = changed / max(la + lb, 1)
        print(f"{name:<22}{la:>7}{lb:>7}{same:>9}{changed:>9}{ratio:>7.1%}")
        tot_a, tot_b, tot_same = tot_a + la, tot_b + lb, tot_same + same
    tot_changed = (tot_a - tot_same) + (tot_b - tot_same)
    print(f"{'TOTAL':<22}{tot_a:>7}{tot_b:>7}{tot_same:>9}{tot_changed:>9}"
          f"{tot_changed / max(tot_a + tot_b, 1):>7.1%}")
    print()
    print("'carried' is normalised statements identical on both sides. The raw")
    print("diff in HAMMER2_PORTABILITY_AUDIT.md is the upper bound on change;")
    print("this is the lower one. A port's real cost sits between them.")
    return 0


def selftest() -> int:
    import tempfile
    cases = [
        # (dragonfly text, port text, expect_changed)
        ("#include <a.h>\nint f(void)\n{\n\treturn 1;\n}\n",
         "#include <b.h>\nint f(void)\n{\n\treturn 1;\n}\n", 0),
        # a rename must normalise to zero change
        ("#include <a.h>\nvoid f(void)\n{\n\tkprintf(\"x\");\n}\n",
         "#include <a.h>\nvoid f(void)\n{\n\thprintf(\"x\");\n}\n", 0),
        # prototype reflow must normalise to zero change
        ("#include <a.h>\nstatic int g(int a,\n\t\tint b);\n",
         "#include <a.h>\nstatic int g(int a, int b);\n", 0),
        # storage class on its own line must normalise
        ("#include <a.h>\nstatic\nint\nh(void)\n{\n\treturn 0;\n}\n",
         "#include <a.h>\nstatic int\nh(void)\n{\n\treturn 0;\n}\n", 0),
        # a multi-line call must close and let the NEXT statement through;
        # without this case a join that never closes still scores clean
        ("#include <a.h>\nvoid f(void)\n{\n\tg(1,\n\t  2);\n\treturn;\n}\n",
         "#include <a.h>\nvoid f(void)\n{\n\tg(1, 2);\n\treturn;\n}\n", 0),
        # a paren inside a string literal must not open a statement
        ("#include <a.h>\nvoid f(void)\n{\n\thprintf(\"a(b\");\n\treturn;\n}\n",
         "#include <a.h>\nvoid f(void)\n{\n\thprintf(\"a(b\");\n\treturn;\n}\n", 0),
        # a prototype's parameter NAMES are style(9) churn; its types are not
        ("#include <a.h>\nstatic int g(int a, char *b);\n",
         "#include <a.h>\nstatic int g(int, char *);\n", 0),
        # but a changed parameter TYPE must still show
        ("#include <a.h>\nstatic int g(int a, char *b);\n",
         "#include <a.h>\nstatic int g(long, char *);\n", 2),
        # style(9) keyword spacing and the BSD integer aliases are cosmetic
        ("#include <a.h>\nint f(void)\n{\n\tu_int n;\n\treturn(n);\n}\n",
         "#include <a.h>\nint f(void)\n{\n\tunsigned int n;\n\treturn (n);\n}\n", 0),
        # a parenthesised return value is style(9), not a change
        ("#include <a.h>\nint f(void)\n{\n\treturn err;\n}\n",
         "#include <a.h>\nint f(void)\n{\n\treturn (err);\n}\n", 0),
        # a REAL change must survive: the normaliser must not hide it
        ("#include <a.h>\nint f(void)\n{\n\treturn 1;\n}\n",
         "#include <a.h>\nint f(void)\n{\n\treturn 2;\n}\n", 2),
        # a comment-only difference is not a change
        ("#include <a.h>\n/* one */\nint f(void)\n{\n\treturn 1;\n}\n",
         "#include <a.h>\n/* two */\nint f(void)\n{\n\treturn 1;\n}\n", 0),
    ]
    bad = 0
    for n, (x, y, want) in enumerate(cases):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "a.c").write_text(x)
            (p / "b.c").write_text(y)
            got = compare(p / "a.c", p / "b.c")[3]
            if got != want:
                print(f"case {n}: changed={got}, want {want}")
                bad += 1
    print(f"selftest: {len(cases)} case(s), {bad} failure(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
