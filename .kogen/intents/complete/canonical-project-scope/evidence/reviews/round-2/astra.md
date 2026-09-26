## Findings

- [ADVISORY] `references.yaml` cites `ORCHESTRATOR.md` and “ROADMAP row 5c,” but no `ORCHESTRATOR.md` exists in the Draft repository, so that evidence reference cannot be followed or independently verified. — [references.yaml:2](/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/canonical-project-scope/references.yaml:2) — Replace it with an existing, line-addressable roadmap or direction reference.

- [ADVISORY] The Draft relies on `test/kogen/project_scope_test.exs` to prove the new shared module and Boundary wiring, but that file does not exist at the shaped commit and is the only test listed for the symlink scenario. The eventual test must exercise all three public paths (`ClaudeCode.project_id/1`, `Codex.State.project_id/1`, and `Build.Workspace.project_id/1`) and compile-time Boundary checks. — [scenarios.yaml:15-18](/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/canonical-project-scope/scenarios.yaml:15) — Specify those assertions explicitly in the scenario or affected test contract.

The prior blocking issues are resolved: `Workspace.canonical/1` is retained, the fixture stays within the per-Build temp boundary, missing-tail canonicalization is specified, and the legacy-selector behavior is removed from scope. Existing callers and current `project_id/1` call sites are accounted for in the guarded paths.

## Verdict: ready