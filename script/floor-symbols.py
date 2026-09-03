#!/usr/bin/env python3
"""Every kernel symbol this module calls, resolved against a floor tree.

The module declares a version floor and calls the kernel through it. Nothing
checked that the calls exist at the floor, and two did not: inode_state_read_once()
needs 6.19 and kzalloc_obj() needs 7.0, against a floor of 6.15. Both failed as
implicit declarations in the middle of a CI build rather than at the #error that
exists to say a kernel is too old, and the second was found only because the first
was fixed.

    python3 script/floor-symbols.py /path/to/linux-6.15/include

WHAT IT SEES AND WHAT IT DOES NOT. It resolves a NAME. A function whose signature
changed while keeping its name is invisible here, and so is a macro whose meaning
moved. Absence is the half that produces implicit-declaration failures, which is
the half that has bitten.

This is not a gate. It needs a floor tree, which is a 150MB download rather than
something CI or a workstation has lying around, so it is run deliberately when the
floor moves or a file lands. CI builds at 6.17 on every push and is the continuous
instrument; this one is the exhaustive one.
"""
import os
import re
import sys
import glob

SRC = "src/sys/fs/hammer2"


def strip(s):
    """Comments and string bodies are prose, and prose is not a call."""
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return re.sub(r'"(\\.|[^"\\])*"', '""', s)


def own_names(files):
    """Names the tree defines itself, which are not the kernel's to provide.

    The prototype pattern requires a line with no '=' in it. Without that it
    also matches an assignment whose right-hand side is a call, and the first
    run of this sweep classified `ctx = kzalloc_obj(...);` as a prototype and
    reported one finding where there were two.
    """
    own = set()
    for f in files:
        s = strip(open(f, errors="replace").read())
        own |= set(re.findall(r"^\s*#\s*define\s+([a-z_][a-z0-9_]*)", s, re.M))
        own |= set(re.findall(r"^([a-z_][a-z0-9_]*)\(", s, re.M))
        for line in s.split("\n"):
            if "=" in line or not line.rstrip().endswith(");"):
                continue
            m = re.findall(r"\b([a-z_][a-z0-9_]*)\s*\(", line)
            if m:
                own.add(m[0])
    return own


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    inc = sys.argv[1]
    if not os.path.isdir(inc):
        sys.exit(f"floor-symbols: {inc} is not a directory, so nothing was read")

    src = glob.glob(f"{SRC}/*.c") + glob.glob(f"{SRC}/*.h")
    if not src:
        sys.exit(f"floor-symbols: no sources under {SRC}, so nothing was read")
    text = "".join(strip(open(f, errors="replace").read()) for f in src)
    used = set(re.findall(r"\b([a-z_][a-z0-9_]{3,})\s*\(", text))
    cand = sorted(used - own_names(src + glob.glob("src/sys/sys/*.h")))

    kern = set()
    for root, _, files in os.walk(inc):
        for fn in files:
            if fn.endswith(".h"):
                s = open(os.path.join(root, fn), errors="replace").read()
                kern |= set(re.findall(r"\b([a-z_][a-z0-9_]{3,})\b", s))
    if not kern:
        sys.exit(f"floor-symbols: no symbols read out of {inc}, so every "
                 "candidate would look absent")

    # The control plants a name no kernel has ever defined. Without it, a
    # sweep whose candidate extraction has stopped working reports the same
    # clean result as one that ran.
    sentinel = "hammer2_symbol_that_no_kernel_defines"
    if sentinel in kern:
        sys.exit("floor-symbols: the control's sentinel is in the tree read, "
                 "so absence proves nothing")
    missing = [c for c in cand + [sentinel] if c not in kern]
    if sentinel not in missing:
        sys.exit("floor-symbols: the control did not surface, so the "
                 "resolution below would pass anything")
    missing.remove(sentinel)

    print(f"floor-symbols: {len(cand)} call-shaped name(s) not defined by this "
          f"tree, {len(missing)} absent from {inc}")
    for m in missing:
        print(f"  absent  {m}")
    print("floor-symbols: compiler builtins and names the extraction could not "
          "attribute appear here too; read each one")


main()
