# Complete evidence: Add kogen-ctx index and search

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `1077c53b032955b0bf600ce47794c32a8d4af3df`
- Developer session id: `01a0e299-3198-7d73-952a-f609b355cf5e`
- Reviewer session id: `01a0e2b6-ee30-7a91-a2d1-34673771d9ef`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 2, finished_at `2026-09-27T11:53:50.893Z`, session_id `01a0e299-3198-7d73-952a-f609b355cf5e`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/zQUJIoS0M6p3ccsWT3yqTx-J/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/zQUJIoS0M6p3ccsWT3yqTx-J/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
