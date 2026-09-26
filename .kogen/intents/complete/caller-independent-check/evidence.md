# Complete evidence: Make the offline suite independent of the caller's KOGEN_LIVE_LOG_DIR

- Route: `claude-dominant-adversarial-codex` (harness `claude`)
- Role harnesses: shaping `claude` (`claude-opus-5-5` at `medium`), developer `claude` (`claude-opus-5-5` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `4585c05113647f3c2d2a380fbb0ddbb739f7cfeb`
- Developer session id: `c3db1a60-8afd-4508-8eed-f94d4ca755a5`
- Reviewer session id: `01a0dde9-f6f1-76d0-bf91-ff8affbf1039`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T13:31:26.007Z`, session_id `c3db1a60-8afd-4508-8eed-f94d4ca755a5`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/QT_Njj22lxXfQ-4mwgbtXLkr/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/QT_Njj22lxXfQ-4mwgbtXLkr/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
