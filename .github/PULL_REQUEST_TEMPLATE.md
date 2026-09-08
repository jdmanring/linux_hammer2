## What this changes

## Which port did you follow?

FreeBSD / NetBSD / OpenBSD / DragonFly / none, and why. See CONTRIBUTING.md.

## How it was checked

- [ ] every `script/test-*.sh`, with the exit status of each
- [ ] a gate that would have caught the bug this fixes, or a note saying why none is possible

The repository gates need no kernel and no network and take about a
second; `doc/README.testing.md` says what each needs. If a gate returned
exit 2, say which: that is the instrument failing to run,
not a pass, and it should not be ticked as one.

## Does this touch carried core files?

If yes, say why the change could not go in the OS shim.
