# Complete evidence: Add the kogen-ctx MCP stdio server

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `6b6d88c3fca799db365374853cedfb5ac9b66d25`
- Developer session id: `01a0e2fa-85c8-7391-a302-6957ee78a7ab`
- Reviewer session id: `01a0e323-3010-7cb0-8c09-c2faf42791bf`
- Outer resumptions used: 1
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T13:52:05.468Z`, session_id `01a0e2fa-85c8-7391-a302-6957ee78a7ab`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/KHrfm5y1RfxTXb1ZIfEkKEKZ/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/KHrfm5y1RfxTXb1ZIfEkKEKZ/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
