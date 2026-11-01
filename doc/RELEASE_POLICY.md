# Releases

## Versions and tags

A version names a milestone on the roadmap, not a calendar release:
the first two numbers say how far along `doc/README.roadmap.md`'s ladder
the driver is, and the third is the point release inside it
(`CHANGELOG.md`, the header). Every row of `CHANGELOG.md` pins the
commit that delivered it and names the gate or run that verified it,
and `script/test-history.sh` checks that each pin resolves.

`v1.0.0` and `v1.0.4` are tagged (`git tag -l 'v*'` lists any since).
Other point releases are changelog rows, not tags. To evaluate a known state, check out the
commit the newest row pins rather than the branch head, which can be
ahead of every row.

## Upstream

Patches and reports for DragonFly BSD and for Tomohiro Kusumi's ports
and userland are drafted in `doc/upstream/`, each with a record of where
it stands at upstream's head and what was searched (`test-inventory.sh`
fails on one without it). They are filed by the maintainer;
`doc/UPSTREAM_ENGAGEMENT.md` has the rules.
