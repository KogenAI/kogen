# Recovery Quarantine Session

## Developer

- Implemented durable `reconciliation_required` recovery dossiers.
- Added queue/direct pre-claim quarantine and post-claim restore ownership.
- Corrected quarantine ordering: only dependency-selectable slugs are assessed.
- Preserved dirty operator-edit materialization before any recovery quarantine.
- Ran focused recovery, queue-drain, and loop task suites.

## Reviewer

- Independent review found and verified fixes for dependency ordering and operator-edit ownership.

## Curator

- Updated `context/loop.md`, `context/loop-queue-drain.md`, and `PROJECT_CONTEXT.md`.
