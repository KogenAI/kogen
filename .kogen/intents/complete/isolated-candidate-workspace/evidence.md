# Complete evidence: Isolate each Build in its own Candidate worktree and harness home

- Route: `claude-dominant-adversarial-codex` (harness `claude`)
- Role harnesses: shaping `claude` (`claude-opus-5-5` at `medium`), developer `claude` (`claude-opus-5-5` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `934d18b3f1a765538424ea48367de3d7c1a0bc5a`
- Developer session id: `b6803a9c-1f1b-4d23-a30c-d8f843e9b859`
- Reviewer session id: `01a0dc92-ee79-76a1-b6d9-e73b5dc99852`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T07:03:40.497Z`, session_id `b6803a9c-1f1b-4d23-a30c-d8f843e9b859`)
- `make live-reviewer-rework`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T07:12:53.301Z`, session_id `b6803a9c-1f1b-4d23-a30c-d8f843e9b859`)
- `make live-shape-to-build`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-26T07:16:49.314Z`, session_id `b6803a9c-1f1b-4d23-a30c-d8f843e9b859`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/Mka6arFhvEgJ_mrDmTzsdaz9/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/Mka6arFhvEgJ_mrDmTzsdaz9/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
