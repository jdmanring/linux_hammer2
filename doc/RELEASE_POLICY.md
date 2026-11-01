# Release and Upstream Engagement Policy

## 1. Release & Tag Posture
- **Versioning**: The repository follows a milestone roadmap rather than standard semantic versioning for release distribution. The version string (e.g., `1.0.72`) indicates position on the roadmap.
- **Tags**: The sole upstream tag (`v1.0.4`) marks the historical baseline; intermediate point releases are tracked via `CHANGELOG.md` and commit hashes. 
- **Evaluation Points**: Cautious testers should evaluate against the commit hash pinned in the newest `CHANGELOG.md` row rather than expecting stable tarball tags.

## 2. Upstream Engagement Plan
- **Staging (`doc/upstream/`)**: Patches and findings are drafted and proven locally, then checked against upstream DragonFly repository state before submission.
- **Coordination**: Matthew Dillon (DragonFly BSD) and Tomohiro Kusumi (BSD ports / Linux userland `hammer2-utils`) are the primary upstream targets. Each staged filing in `doc/upstream/` records what was searched and whether upstream has already addressed the sibling defect.
