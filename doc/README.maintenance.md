# Keeping the carried core current

The port carries DragonFly's HAMMER2 core in the shape of Tomohiro
Kusumi's three BSD ports, and the roadmap's 1.0 bar asks for a credible
plan to keep it that way after the first release. This is that plan: what
is pinned, how movement upstream is noticed, how a carried file is brought
forward, what has to pass before the result is a driver again, and how a
defect found here reaches the trees it came from. Each step names the
instrument that checks it, because a plan that rests on somebody
remembering is not one.

## What is pinned

`doc/provenance.csv` has a row for every file under `src/`: the tree it
came from, the commit of that tree it was taken at, its license, and
whether the carry is `identical`, `derived` or `ours`.
`script/test-provenance.sh` reads that file on every push and every CI
run, asserts that every file has a row, and compares each `identical` row
byte for byte against the origin clone when the clone is present. A
carried file that drifts from its origin without its row being changed
fails the gate; a row changed to `derived` has to say what the port
edited, and the `XXX` marks in the file itself are the second record of
the same edits, counted by `script/test-inventory.sh` against the table
in `doc/README.status.md`.

The origin of every carried file is the FreeBSD port at one commit, and
the commit is in the CSV rather than here so that it cannot go stale in
a summary; the NetBSD and OpenBSD ports and DragonFly itself are the
trees a port decision is read against, not origins. The four clones
live beside this repository under `~/Projects/` as single-commit
snapshots, which is enough for `cmp` and not enough for history; history
is read through the forge.

## Noticing that upstream moved

Nothing here polls upstream on its own, and nothing should: a sync is a
deliberate act with a full gate run behind it. The check is one forge
call per tree, made at every point release and before every tagged one,
and its result is recorded in `doc/README.status.md` beside the origin
table with the date and the head it read:

    gh api repos/kusumi/freebsd_hammer2/tags --jq '.[0].name'
    gh api repos/kusumi/netbsd_hammer2/tags --jq '.[0].name'
    gh api repos/kusumi/openbsd_hammer2/tags --jq '.[0].name'
    gh api 'repos/DragonFlyBSD/DragonFlyBSD/commits?path=sys/vfs/hammer2&per_page=5' \
        --jq '.[] | "\(.sha[0:9]) \(.commit.author.date[0:10]) \(.commit.message | split("\n")[0])"'

A tag on the FreeBSD port, a change in the other two ports to a function this tree has staged a patch against, or a DragonFly commit under
`sys/vfs/hammer2` that touches a file in the carried set, is what
starts a sync. DragonFly's tracker sits behind a proof of work and is
read by hand; the three port repositories have issues disabled and no
pull requests, so silence there means nothing.

## Bringing a carried file forward

The port's rule is that a carried file reads as DragonFly's, with every
edit of the port's marked `XXX` in place. That rule is what makes a sync
mechanical rather than a rewrite:

1. Fetch the origin clone to the new tag and record the new commit.
2. For every `identical` row, copy the file in. There is nothing of the
   port's in it to preserve, and `test-provenance.sh` confirms the copy.
3. For every `derived` row, merge three ways with the origin at the old
   pin as the base, the origin at the new pin as theirs, and the file
   here as ours: `git merge-file` on the three does it, and every
   conflict lands on an `XXX` block or a `/* Linux */` line, which are
   the only places the port's text and upstream's can both have moved.
   `script/hammer2-core-diff.py` sizes the port's part of any carried
   file with the mechanical churn removed, which is the reading to take
   before a merge that looks large.
4. Update the row's commit in `doc/provenance.csv`, the line count in
   the origin table, and the `XXX` table's total column, which
   `test-inventory.sh` checks; the "upstream's" column is a subtraction
   against the new origin tree and carries its date.
5. Read every staged patch in `doc/upstream/` against the new tree. One
   that upstream has taken is retired and its entry in
   `README-provenance.md` says so; one upstream has answered another way
   is re-read against the answer.

A file the port wrote from nothing (`ours`) is not synced, but it is
re-read against whatever the sync changed in the interfaces it serves,
which is what the syntax gate's two compilers and the shim's parse gate
catch first.

## What has to pass before the result is a driver

The thirteen gates listed in `README.md`, then the fleet scripts in
`doc/README.testing.md` that exercise what the sync touched, and at
least these three on every sync regardless: `f4-roundtrip.sh`, which
has DragonFly read what the port wrote and back; `fuzz-mount.sh`, which
puts mutated images through the mount path; and `nix-closure.sh`, the
port's largest real write. `test-enospc.sh` runs on every push already.
Nothing in a sync is claimed on the gates' silence: the negative
controls in the syntax and shim gates must still fail, and a gate that
reports could-not-run is neither pass nor fail.

The kernel of record is a pin of the same kind on the other side, moved
when a release ships and never left to age, with the gate reporting
could-not-run against any other kernel; the reasoning is in
`doc/README.porting.md`.

## Sending a defect back

A defect found here in carried code is a defect in every tree that
carries it, and the port's rule for those has three parts. The fix is
applied here first, marked `XXX`, so that the port does not wait on
anyone. A patch against the origin is staged in `doc/upstream/`, one
for DragonFly and one for the three ports when both apply, generated
against the upstream file at its head rather than against the copy here.
An entry in `doc/upstream/README-provenance.md` records whether the
code is still that way at upstream's head, how that was read, what was
searched and what could not be; `test-inventory.sh` fails on a staged
file with no such entry, because a patch with no record invites the
reader to assume nobody has looked. The maintainer files them, and the
filing's state is recorded beside the patch whether it is taken,
refused or unanswered.

## Cadence

Upstream is read at every point release and before every tagged one,
and a sync is made at every tag of the three ports, at most one tag
behind. A DragonFly change to the core is synced when a port takes it,
since the ports are what this tree is shaped after and are where a
DragonFly change arrives in this tree's layout; a DragonFly
fix to a defect this tree has staged is the exception and is taken
directly. A sync that fails a gate is not merged until the gate passes,
and a sync that has waited more than one release is a problem to record
in `doc/README.status.md`, not a reason to skip the gates.
