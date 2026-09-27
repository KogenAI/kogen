# Complete evidence: Report Builds whose controller died

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `088344f3d60e29a122412a86e175490d90936270`
- Developer session id: `01a0e443-2c77-7f21-8677-9a284485e8cc`
- Reviewer session id: `01a0e459-1b5e-7a33-8f65-ba6369694eff`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T19:30:36.830Z`, session_id `01a0e443-2c77-7f21-8677-9a284485e8cc`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/qqsi2kBQ4BWw_dtR24RdJj6D/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/qqsi2kBQ4BWw_dtR24RdJj6D/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
