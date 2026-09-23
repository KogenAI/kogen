# Complete evidence: Run Kogen on Claude Code through a pluggable harness

Manual Build: run by Claude Opus 5.5 in Claude Code as the controller, outside
the regular Kogen flow because ChatGPT tokens ran out, following Kogen's Build
procedure (Developer and Reviewer prompts rendered by `Kogen.Build`, handoff
validated by `Kogen.Build.Contract.handoff`, controller-run Stop verification).

- Candidate id: `80aeaced9a4769daeb58e36c96a01ce9b71a2b5b`
- Developer session id: `5f99e885-b25e-4218-bb8a-355271aff72e` (Claude Code, `claude-opus-5-5`, medium)
- Reviewer session id: `f113f1d8-17f5-4eb6-b871-daaeed77ab40` (fresh Claude Code, `claude-opus-5-5`, medium, editing tools disabled, `--json-schema` verdict)
- Verification retries used: 2 of 2
- Outer resumptions used: 0

## Stop verification history

1. `make check` failed: 2 offline tests (reliability-catalog changed-path basis; a Codex fixture read the new config).
2. `make check` passed; `make live-general` failed (the live audit selected Codex session storage from inside the fixture directory).
3. Settled: `make check` passed; `make live-general`, `make live-reviewer-rework` and `make live-shape-to-build` passed against the real provider on `harness: claude`, using the Kogen-owned shared login scope.

## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results and the
SHA-256 digest and byte count of each retained receipt. The receipts remain local
under `.kogen/runtime/manual-build/` and are not committed. A fresh clone
contains the contract and concise results only; a digest identifies bytes, it
does not prove semantic inspection.
