# Complete evidence: Wait for the fake provider on timeout and Stop

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `dee1a18962107af687c1a325343c8f5f28193823`
- Developer session id: `01a0e284-42bc-7be0-898d-fc3921706932`
- Reviewer session id: `01a0e296-77e1-7961-91f8-aac97a1a5f21`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T11:18:23.946Z`, session_id `01a0e284-42bc-7be0-898d-fc3921706932`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/3hl6cGDJ1eb-qtvkUgJBvE4O/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/3hl6cGDJ1eb-qtvkUgJBvE4O/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
