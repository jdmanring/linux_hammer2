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
| How is the DragonFly source carried, and where is the shim boundary? | `ARCHITECTURE.md` |
| What does the DIO layer do on Linux, and which sizes are the format's? | `IO_MODEL.md` |
| What does the port guarantee to something built above it? | `README.capabilities.md` |
| Why BSD style in a Linux tree, and what would a mainline submission change? | `README.kernel-style.md` |
| How is the carried core kept in step with upstream after a release? | `README.maintenance.md` |
| Where did each file under `src/` come from, and is it a byte-for-byte carry? | `provenance.csv` |
| What is the style gate's baseline count? | `checkpatch-baseline.txt` |
| What did the lockdep report of the full-volume defect look like? | `enospc-lockdep.txt` |
| What was measured, when, with what, and what did it find? | `history/verification-record.md` |
| What was the history rewrite, and how does an old hash map to a new one? | `history/README.md` |
| What is staged for upstream, and where does each item stand against their head? | `upstream/README-provenance.md` |
| What did the port plan, API map, license and portability audits say before the import? | `research/README.md` |

The status file is the authority on what exists and what has been
verified. Where two documents disagree, the one with the gate behind it
is right, and the other is a defect to fix.
