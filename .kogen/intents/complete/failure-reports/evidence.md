# Complete evidence: Write a failure report for every stopped Build

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `730a5e86f1f6581ca2cb1ed37253c916c2af2c43`
- Developer session id: `01a0e29a-e484-7a50-aeb7-42afaf282578`
- Reviewer session id: `01a0e331-b419-71b0-af55-67d0a60b1393`
- Outer resumptions used: 1
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T14:07:57.222Z`, session_id `01a0e29a-e484-7a50-aeb7-42afaf282578`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/OuHbanjrS64OSKKvtQR7gAwJ/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/OuHbanjrS64OSKKvtQR7gAwJ/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
