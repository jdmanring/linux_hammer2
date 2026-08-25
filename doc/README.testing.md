Testing
=======

Two gates run today, both cheap, both with controls.

    $ bash script/test-shim.sh      # needs only a C compiler
    $ bash script/test-syntax.sh    # needs kernel headers and clang

`test-shim.sh` compiles `hammer2_os.h` and `hammer2_compat.h` against the
stubs in `test/stub`, in both positions of the `HAMMER2_INVARIANTS` knob,
plus a negative control: the header is broken on a copy and the compile
must fail. Without that control a gate whose healthy signature is silence
cannot be told from a gate that never opened the file.

`test-syntax.sh` compiles `hammer2.h` and `hammer2_io.c` against the real
kernel headers, and carries two more controls: a wrong folio call that the
same headers must refuse, and the 64KB ceiling guard, which must fire when
the ceiling is shrunk. Set `KDIR` to test against a tree other than the
running kernel's.

Neither runs anything. `-fsyntax-only` compiles nothing and links nothing,
which is the honest limit of what can be checked before a module builds.

Exit 2 from either means the instrument could not run (no compiler, no
kernel headers). That is not a verdict on the code, and it should not be
recorded as a failure.

## What the real test will be

A volume created by DragonFly's `newfs_hammer2`, mounted here, compared
file by file; then the reverse. HAMMER2 writes an XXH64 digest into every
blockref and every implementation verifies it, so a subtly wrong port
produces volumes that read as corrupt on DragonFly rather than as buggy.
The cross-implementation round trip is the only test that catches that,
and no amount of self-consistency substitutes for it.
