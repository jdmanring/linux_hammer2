Documents
=========

Which file answers which question.

| question | file |
|---|---|
| What does the driver do today, and what read it? | `README.status.md` |
| What landed, in which commit, verified by what? | `../CHANGELOG.md` |
| What are the milestones, and where is the tree against them? | `README.roadmap.md` |
| How is each gate run, what does it need, what does a fleet script measure? | `README.testing.md` |
| Why was a port decision taken the way it was? | `README.porting.md` |
| What did Dillon design, and where does this port stand against each part of it? | `DESIGN.md` |
| How is the DragonFly source carried, and where is the shim boundary? | `ARCHITECTURE.md` |
| What does the DIO layer do on Linux, and which sizes are the format's? | `IO_MODEL.md` |
| What was the cache coherency protocol, and what would completing it have to prove? | `CCMS_DESIGN.md` |
| Where does each CCMS claim come from, and what does the original actually say? | `CCMS_REFERENCE.md` |
| What are the CCMS thread lock's transitions, with pre- and postconditions? | `CCMS_TRANSITIONS.md` |
| What does this port drop, disable or defer against DragonFly, and is each one a decision? | `DROPS_AND_DISABLES.md` |
| What does the port guarantee to something built above it? | `README.capabilities.md` |
| Why BSD style in a Linux tree, and what would a mainline submission change? | `README.kernel-style.md` |
| How is the carried core kept in step with upstream after a release? | `README.maintenance.md` |
| Where did each file under `src/` come from, and is it a byte-for-byte carry? | `provenance.csv` |
| What do the DIO layer, lock order, and cluster stages look like at a glance? | `ARCHITECTURE.md` (diagrams), `IO_MODEL.md` (DIO detail) |
| What is the short current status (one page, no history)? | `STATUS_SNAPSHOT.md` |
| What can an operator enable today, and what are the limits? | `CAPABILITIES_MATRIX.md` |
| What does the port guarantee against corruption, and how does clustering authenticate? | `SECURITY_MODEL.md` |
| How is the module packaged (DKMS, module order, initramfs)? | `PACKAGING_NOTES.md` |
| What performance should an operator expect, and how was it measured? | `PERFORMANCE.md` |
| How is a clean machine taken from stock Linux plus QEMU to green gates? | `REPRODUCIBILITY.md` |
| What is the release and tag policy, and where does upstream engagement stand? | `RELEASE_POLICY.md` |
| What is the style gate's baseline count? | `checkpatch-baseline.txt` |
| What did the lockdep report of the full-volume defect look like? | `enospc-lockdep.txt` |
| What was measured, when, with what, and what did it find? | `history/verification-record.md` |
| What is not verified, what is not measured, and what is missing before a root filesystem? | `readiness-audit-2026-09-25.md` |
| What was the history rewrite, and how does an old hash map to a new one? | `history/README.md` |
| What is staged for upstream, and where does each item stand against their head? | `upstream/README-provenance.md` |
| What did the port plan, API map, license and portability audits say before the import? | `research/README.md` |

The status file is the authority on what exists and what has been
verified. Where two documents disagree, the one with the gate behind it
is right, and the other is a defect to fix.
