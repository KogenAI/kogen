# Shaping notes: harden-developer-handoff

## Recount of handoff failures (23 September, at 5af11273)

A read-only worker (`kogen-worker`, claude-sonnet-5) and a root cross-check
scanned all 198 retained `record.json` files: 103 in
`.kogen/runtime/scenario-tracking/` and 95 under `live-evidence/**`. An attempt
counted when its `failure` began with a handoff label. There are three label
generations:

- The current `Developer handoff structure invalid:` and `... semantic invalid:`
  labels, on 14 attempts.
- The older `Developer handoff invalid:` label, on 5 attempts (tanBMHWR #0,
  2xt-TMNZ #1, hIhZhNA3 #1, x5lRcYWR #1, ruW964DB #0).
- Terminal `stopped after 2 outer resumptions ...: Developer handoff ...`
  entries (hIhZhNA3 #2, 8_JWkER4 #2, dEkBAojD #2), and one
  `scenario proof selector is still missing at Developer handoff` (4Hd6wOXc #0).

The result broadly confirms the brief's table. There are 9 honest
`incomplete` attempts. Path rejections cover a nonexistent file, `path:line`,
a directory (`deps`), a file never created (`reviewer-notes.md`) and the
controller's tracking record cited with a path relative to the probe
Candidate. There are 4 attempts with risk-link mismatches, 4 older coverage-ID
failures, 1 prose-before-JSON on Claude, 1 blocked finding and 1 missing
selector. Most rejections were on Codex, even though Codex already had a
schema. That is consistent with "the schema checks shape, not meaning".

A naive substring search produced 52 false positives from source diffs inside
test output. They were discarded.

How the new design handles each kind:

| Failure kind | New handling |
| --- | --- |
| Cited path rejected | Impossible. Code picks the paths. |
| Risk links, coverage IDs | Impossible. Code copies them from the contract. |
| Prose before JSON / malformed | Impossible. No Kogen code parses the message. |
| Honest `incomplete` | Jev notes "the Developer says X is unfinished" as advice. The Reviewer decides. |
| Deliberate objection (Bg1qobsC #1) | Jev `cannot_comply` at 0.8 or higher stops the Build and returns it to Shaping (calibrated). |
| Blocked finding | The same objection path, applied to the finding. |
| Missing proof selector | Unfinished work, detected deterministically, leading to rework. |

## Outcome walkthrough

This starts from a clean branch at HEAD with an Approved Intent, the
configured route installed and logged in, and the Keychain item
`ai.typesafe.api` present.

1. Build freezes the contract, issues token T and launches the Developer
   without a schema.
2. The Developer implements the Intent and ends with free prose. The prose
   names any unfinished item and states any contract objection plainly.
3. Stop verification runs as today.
4. Build runs the existing post-turn integrity checks and settles
   verification.
5. Build sends one Jev request: the notes plus the item IDs, with
   `unfinished` and `cannot_comply` questions. It retains the request and the
   response.
6. If any `cannot_comply` answer is at 0.8 or higher, the Build stops and
   returns to Shaping, quoting the notes and the confidence. This happens even
   when verification was exhausted.
7. If verification was exhausted, the Build stops as today.
8. If a declared selector is missing, the Build counts it as unfinished work
   and resumes the same Developer, which uses the outer allowance.
9. Otherwise Build writes the controller report and runs the declared
   targets. It hands the report, the notes and Jev's advisory answers (or
   "Jev unavailable") to a fresh Reviewer.
10. Review accepts, which leads to publication as today, or returns findings,
    which resume the same Developer.

## Challenge: plausible wrong implementations

- **Keeps parsing the message.** It derives the report correctly but keeps
  the harness schema on resumed turns, or keeps parsing the message. The
  `schema-free-developer-turns` and `controller-built-report` scenarios catch
  this.
- **Treats Jev failure as "no objection".** It treats a Jev failure as "no
  objection" without telling the Reviewer, or uses answers from a partially
  valid response. `jev-unavailable-goes-to-review` catches this.
- **Routes "unfinished" to rework.** It routes Jev "unfinished" straight to
  rework, repeating the waste this Intent removes. `reviewer-owns-completeness`
  forbids this.
- **Lets the key leak.** The key reaches the record or the logs.
  `jev-reads-developer-notes` uses a sentinel key to catch this.
- **Leaves the live fixtures stale.** The live fixtures still ask for, or
  assert, a structured handoff or the removed schema. The two paid scenarios
  cover this.

## Evidence ownership

- Build tests and the rehearsal are owned by Stop verification (`check`), and
  Review inspects their receipts.
- The real Jev calls in the paid targets are retained in the tracking
  record, which Review can inspect.
- The live stream sequences are observed and audited only by the outer
  `live-reviewer-rework` and `live-shape-to-build` drivers. Review assesses the retained receipts and the
  Candidate, and does not reconstruct the streams.
- The Stop-terminal probe (`stop-terminal-probe.md`) is Shaping feasibility
  evidence only.
