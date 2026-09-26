# Complete evidence: Harden Build reliability

- Route: `claude-dominant-adversarial-codex` (harness `claude`)
- Role harnesses: shaping `claude` (`claude-opus-5-5` at `medium`), developer `claude` (`claude-opus-5-5` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `10beab65a2daf63711bb56c5df8674b4f419db7c`
- Developer session id: `20fad836-27af-4797-97bc-cb6af74df617`
- Reviewer session id: `01a0df5a-8dc5-78c3-aa4c-443bd764982c`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T19:53:41.042Z`, session_id `20fad836-27af-4797-97bc-cb6af74df617`)
- `make live-shaping-smoke`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T19:56:34.386Z`, session_id `20fad836-27af-4797-97bc-cb6af74df617`)
- `make live-reviewer-rework`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T20:14:05.175Z`, session_id `20fad836-27af-4797-97bc-cb6af74df617`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/UZc1zoDkmeAI6n128GnekMhc/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/UZc1zoDkmeAI6n128GnekMhc/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
