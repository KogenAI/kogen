# Complete evidence: Refuse Builds that keep failing the same way

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `484dde080806eabc7bb04863a0f6e9fc5c91556a`
- Developer session id: `01a0e36f-c537-70d2-a7f8-13f5145ac4f6`
- Reviewer session id: `01a0e3af-576d-7661-9f67-a4971a74d19c`
- Outer resumptions used: 1
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T16:25:11.535Z`, session_id `01a0e36f-c537-70d2-a7f8-13f5145ac4f6`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/UuwUrdE1OjBqEZLUzn8hafup/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/UuwUrdE1OjBqEZLUzn8hafup/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
