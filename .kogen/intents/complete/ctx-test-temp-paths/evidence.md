# Complete evidence: Give kogen-ctx tests collision-free temp paths

- Route: `codex` (harness `codex`)
- Role harnesses: shaping `codex` (`gpt-6-sol` at `medium`), developer `codex` (`gpt-6-sol` at `high`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `222f99f0697219c8288d0dc304918413fe116ce4`
- Developer session id: `01a0e42b-22a6-77c3-b7fd-006986200daf`
- Reviewer session id: `01a0e43f-37e5-7d62-8745-fa3c3f405a12`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 2, finished_at `2026-09-27T19:02:19.911Z`, session_id `01a0e42b-22a6-77c3-b7fd-006986200daf`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/ljzua_wGnMPdlS_9Wyurnrwc/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/ljzua_wGnMPdlS_9Wyurnrwc/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
