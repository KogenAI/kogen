# Complete evidence: Isolate git test fixtures from global ignores

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `186af7d06b58085863975ad19e9a66a225ab43da`
- Developer session id: `01a0dfe7-45e7-7541-8dc2-bdd12793622d`
- Reviewer session id: `01a0dff2-dd57-76f2-9889-ded62ccd5fa6`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 2, finished_at `2026-09-26T23:00:27.531Z`, session_id `01a0dfe7-45e7-7541-8dc2-bdd12793622d`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/ty_YGXjk8wwIOaHL2fgALQBw/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/ty_YGXjk8wwIOaHL2fgALQBw/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
