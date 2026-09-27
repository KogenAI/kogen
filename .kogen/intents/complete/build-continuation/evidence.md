# Complete evidence: Continue interrupted Builds with the same command

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `7df1d5c1601d07e670496ea232eccac466de4aa4`
- Developer session id: `01a0e47f-1372-7b60-81d4-c30c9b440c1c`
- Reviewer session id: `01a0e515-9cfe-7920-9595-f6002631b844`
- Outer resumptions used: 2
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-27T22:56:31.249Z`, session_id `01a0e47f-1372-7b60-81d4-c30c9b440c1c`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/Xo4Psph9TZWhf1JvX15Jh2cF/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/Xo4Psph9TZWhf1JvX15Jh2cF/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
