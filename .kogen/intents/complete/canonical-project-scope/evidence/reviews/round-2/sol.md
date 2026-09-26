## Findings

- [BLOCKING] The proof never exercises the required shared `Workspace.canonical/1` implementation. Scenario 1 only calls the three `project_id/1` functions, so a Developer could duplicate the new algorithm in `ProjectScope` while leaving `Workspace.canonical/1` with its old fallback behavior; missing workspace paths could still change after creation. — `scenarios.yaml:7-18`, `INTENT.md:13-16`, `lib/kogen/build/workspace.ex:90-101` — Add offline assertions that `Workspace.canonical/1` delegates to the shared function and remains stable for symlinked paths and missing children before/after creation.

- [ADVISORY] The cited roadmap row still prescribes expand-then-contract and fallback to the old selector, conflicting with the Intent’s no-migration design and DIRECTION rule 44. This can mislead implementation or review despite the current Intent being explicit. — `references.yaml:2`, `plan/ROADMAP.md:83`, `plan/DIRECTION.md:181` — Annotate the reference as superseded or update the roadmap citation to rule 44.

## Verdict: not ready