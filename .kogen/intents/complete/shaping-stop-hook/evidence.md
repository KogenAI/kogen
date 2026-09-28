# Complete evidence: Audit every Codex Shaping stop

- Route: `claude-dominant-adversarial-codex` (harness `claude`)
- Role harnesses: shaping `claude` (`claude-opus-5-5` at `medium`), developer `claude` (`claude-opus-5-5` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `12de38578b1ff982d1c70999fa07cb9d7165bc5a`
- Developer session id: `f6f7cbac-830d-4ad9-aa9c-6e54c45b7c03`
- Reviewer session id: `01a0e693-bfaf-7a22-93c7-8227a37975fe`
- Outer resumptions used: 0
## Verification receipts (controller-owned, bound to this Candidate)

Exact output remains in the full local record and its retained logs.

- `make check`: `passed` (exit_code `0`, cycle 1, finished_at `2026-09-28T05:53:50.846Z`, session_id `f6f7cbac-830d-4ad9-aa9c-6e54c45b7c03`)


## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/LF8Vfh2PeWc8MweUthQepInL/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/LF8Vfh2PeWc8MweUthQepInL/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
