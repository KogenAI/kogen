# Complete evidence: Keep Build evidence out of oversized commits

[Compact Build summary](build-summary.json) preserves the original Build identities, all three attempts, settled target results, scenario outcomes, finding dispositions and accepting independent Review. It was projected from the exact original record during the user-authorized publication repair on 2026-09-14; this repair is not a new Build or verification run.

- Accepted Candidate: `d1116f8c7bf6abb60575765f9727d5b5dbd20b6a`
- Developer session: `01a0a106-1320-7272-84ba-52de5a6b7227`
- Reviewer session: `01a0a134-0678-7250-b0d3-cb316b2635bd`
- Original final verification: `check` and `live` passed; independent Review accepted.

## Exact local evidence

Full record, resolved from the checkout root: `.kogen/runtime/scenario-tracking/HZU4sg___WucrVGC1djwh35g/record.json`.

- SHA-256: `bb1cc05d9fd3064588c95ef4fcf2ddd79407aa576412a6a7c3e22aaae847311c`
- Exact bytes: `83623869`
- Format: `kogen-scenario-tracking-record`, schema version 1.

Verify from the checkout root:

```sh
shasum -a 256 .kogen/runtime/scenario-tracking/HZU4sg___WucrVGC1djwh35g/record.json
wc -c < .kogen/runtime/scenario-tracking/HZU4sg___WucrVGC1djwh35g/record.json
```

Compare both values with the summary before inspecting the archive. The exact record retains original claims, receipts, snapshots, failed attempts and Review evidence. The original generated evidence page is also retained locally at `.kogen/runtime/scenario-tracking/HZU4sg___WucrVGC1djwh35g/publication-repair/original-evidence.md`.

A fresh clone contains the contract and concise results only. If the local archive is removed, exact evidence is unavailable; neither this summary nor a different Build replaces it. A matching digest identifies bytes, not semantic inspection. This evidence is not a recovery checkpoint.

## Publication repair

The original unpublished commit `9a8e7eba8db4d5ff63ca90c60744c119821b5ad0` was produced by the already-running older controller and included its full 83,623,869-byte record. The user explicitly authorized repair in this conversation. The repair replaces that tracked copy with the compact projection, retains its byte-identical ignored runtime archive, and amends only this commit's Complete evidence/navigation. Implementation, tests, configuration, original Intent requirements and historical Build results remain unchanged.
