# Complete evidence: Wait for the fake provider before READY

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `3527affd732274611abf87bccd59e81d6ac080b5`
- Developer session id: `01a0e180-6804-77d0-af4e-039300ba8514`
- Reviewer session id: `01a0e18c-5548-7f70-a6d8-c21a2f0ab0df`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T06:27:43.500Z`, session_id `01a0e180-6804-77d0-af4e-039300ba8514`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/LvK9U5fLdCBvC58fIqzm2ikT/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/LvK9U5fLdCBvC58fIqzm2ikT/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
