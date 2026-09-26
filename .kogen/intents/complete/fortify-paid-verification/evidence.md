# Complete evidence: Own verification in the Build controller with Candidate-bound receipts

- Route: `claude-dominant-adversarial-codex` (harness `claude`)
- Role harnesses: shaping `claude` (`claude-opus-5-5` at `medium`), developer `claude` (`claude-opus-5-5` at `medium`), reviewer `codex` (`gpt-6-sol` at `high`), expert `codex` (`gpt-6-sol` at `high`)
- Candidate id: `fe4c269ced7db9ef4adfa9ce1feebfb75c3680a7`
- Developer session id: `c6bdec6e-273b-47ea-817f-2500e49a46a5`
- Reviewer session id: `01a0db2b-dfc4-7290-bed1-3f9ee59dfeb4`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-26T00:38:06Z`
- session_id: `c6bdec6e-273b-47ea-817f-2500e49a46a5`

## Declared targets (beyond `check`)

- `make live-native`: settled (exact output remains in the full local record)
- `make live-shape-to-build`: settled (exact output remains in the full local record)
## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/zHsp56EtL99NjugOzL5vYhjA/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/zHsp56EtL99NjugOzL5vYhjA/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
