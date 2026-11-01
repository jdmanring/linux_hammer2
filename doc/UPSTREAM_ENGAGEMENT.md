# Upstream Engagement

How work found here goes back to the trees it came from.

## Who

- **DragonFly BSD**, Matthew Dillon's HAMMER2: the core, the on-disk
  format and the cluster design this port is completing.
- **Tomohiro Kusumi**: the FreeBSD, NetBSD and OpenBSD ports this port's
  shape is copied from, and `hammer2-utils`, the Linux userland it uses.
  All four repositories have issues disabled and no pull requests, so
  silence there is not evidence of anything.

## Rules

- The carried core stays readable as DragonFly's. A line the port
  changes in a carried file is marked `/* Linux */`, and `XXX` where it
  is a compromise rather than a translation, so a patch can be lifted
  out and offered upstream in the form upstream wrote.
- Every draft under `doc/upstream/` is named by a document beside it
  saying whether the code is still that way at upstream's head and how
  that was checked, what was searched for, and what could not be
  searched; `test-inventory.sh` fails on a draft without one.
  DragonFly's tracker is behind a proof of work and is searched by hand.
- A format change is an extension, named as one, with a written design,
  a compatibility plan and what an old reader does with it, before any
  code (`doc/README.roadmap.md`, "The completion plan").
- The maintainer files every draft; nothing here is filed upstream by
  automation.

## Mainline Linux

In-tree submission is deferred past qualification
(`doc/README.roadmap.md`, "Open decisions"). The style conversion in
`doc/README.kernel-style.md` happens then, for the whole tree at once,
or not at all.
