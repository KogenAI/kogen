# Build 8Bs51yZPDl4HH1djvfmhxQa9 failed at Review (2026-09-26)

Candidate stashed as `isolated-candidate-workspace-candidate-2026-09-26` (d1c4f00bb7).
- Cycle 1: check failed (a compile warning under --warnings-as-errors). Cycle 2: check and
  live-reviewer-rework passed; live-shape-to-build failed the Candidate-containment audit (path
  comparison). Cycle 3: **all three targets passed**.
- The Codex Reviewer returned rework with one real finding on `candidate-creation`: "The running owner
  record is created with an empty credential_bindings list. Credential bindings are persisted only after
  Kogen.Harness.open_roles/4 completes readiness, so the record does not satisfy the contract's
  requirement that it name bindings before any provider launch." (evidence: `Workspace.create/2` writes
  `[]`; `run_in_candidate/2` calls `open_roles` before `Workspace.bind/2`.)
- The verdict was invalid (four evidence paths were `/receipts/N …` pointers), so the Build stopped instead
  of routing rework. The Reviewer-verdict fix belongs to `build-reliability` (item E).
