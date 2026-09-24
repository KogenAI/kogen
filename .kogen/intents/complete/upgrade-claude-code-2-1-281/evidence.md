# Complete evidence: Upgrade managed Claude Code runtime to 2.1.281

- Route: `claude` (harness `claude`)
- Candidate id: `269240a896ffd732723f1256101996dfc88fc03d`
- Developer session id: `888f7342-8227-4a14-a3a8-401c18ed371d`
- Reviewer session id: `44a3e818-fcab-4c23-8ed9-d54584e5f8f5`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-24T10:38:02Z`
- session_id: `888f7342-8227-4a14-a3a8-401c18ed371d`

## Declared targets (beyond `check`)

- `make live-general`: settled (exact output remains in the full local record)
- `make live-reviewer-rework`: settled (exact output remains in the full local record)
- `make live-shape-to-build`: settled (exact output remains in the full local record)
## Reviewer Verdict

- Reviewer verdict: accept
- Reviewer findings: (none)

## Exact evidence

[Compact Build summary](build-summary.json) contains concise results. The full controller record remains local at `.kogen/runtime/scenario-tracking/DXMmwMNnRlr-eAgLZz1849hz/record.json` and is not committed. From the checkout root, verify it with `shasum -a 256 .kogen/runtime/scenario-tracking/DXMmwMNnRlr-eAgLZz1849hz/record.json` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.
