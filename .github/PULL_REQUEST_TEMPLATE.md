## What this changes

## Which port did you follow?

FreeBSD / NetBSD / OpenBSD / DragonFly / none, and why. See CONTRIBUTING.md.

## How it was checked

- [ ] `bash script/test-inventory.sh`
- [ ] `bash script/test-citations.sh`
- [ ] `bash script/test-history.sh`
- [ ] `bash script/test-shim.sh`
- [ ] `bash script/test-syntax.sh`
- [ ] `bash script/test-checkpatch.sh`
- [ ] a gate that would have caught the bug this fixes, or a note saying why none is possible

The first three need no kernel and no network and take about a second. If
a gate returned exit 2, say which: that is the instrument failing to run,
not a pass, and it should not be ticked as one.

## Does this touch carried core files?

If yes, say why the change could not go in the OS shim.
