# Give the Reviewer bounded, Candidate-bound evidence

ROADMAP order 1 (ID 33): bounded Reviewer evidence and fixture isolation.
Features BLD-09 and BLD-11. It builds first in the 2026-09-25 batch. It is a
precondition for `cross-harness-adversarial-roles`, whose last Build
(`kdUszVF4Gw71QsxsppvSKc2b`) stopped on a Codex Reviewer that spent 16 minutes
and 1.84M input tokens dumping tracking records.

## Problem

Evidence: `evidence/diagnosis.md`, which summarises
`cross-harness-adversarial-roles/evidence/reviewer-context-diagnosis-2026-09-25.md`,
the GPT-6 Sol-high and Astra-medium analyses, and this Shaping session's own
measurements.

1. **The record embeds itself.** `snapshot_references/2` / `cited_bytes/2`
   (`lib/kogen/build.ex:931-963`) store base64 bytes of every cited path. When
   a role cites the Build's own `record.json`, the record stores a full copy of
   its current bytes, so it grows with each citation and each attempt
   (195 KB copies inside a 2 MB record in `kdUszVF4…`).
2. **The Reviewer gets only a locator to the raw record.** `task_context/3`
   and `reviewer_context/1` (`build.ex:876-915`) give the Reviewer
   `tracking_path` and section names. The Reviewer then has to find the handoff,
   notes, receipts and findings inside a multi-megabyte JSON file. Claude Code
   caps a Bash result at about 10-16 KB. Codex's tool history is re-sent every
   step, so each dump is paid for again and again.
3. **Kogen sets no Codex tool-output limit.** `config_args/5`
   (`lib/kogen/codex/environment.ex:415-452`) sets none. The Shaping probe
   showed that Codex 0.156.1 accepts `tool_output_token_limit` and that it
   reduces input tokens.
4. **The live Reviewer-rework fixture lives inside the checkout**
   (`test/support/live_reviewer_rework_fixture.ex:52`,
   `.kogen/runtime/live-reviewer-rework/fixture-*`). A Reviewer in the
   fixture can find, and did search, the outer checkout's `.kogen/runtime`.
5. **A stale objection discarded a verified Candidate.** In `kdUszVF4…` the
   Developer wrote its final notes after Stop cycle 2 failed on
   `live-reviewer-rework`. Those notes carried a contract objection. Stop
   cycle 3 then passed every target on the same Candidate. Jev still read the
   objection at confidence 1.00, and `settle_outcome/7` (`build.ex:403-421`)
   stopped with `cannot_comply` before Review.

## Outcome

- The tracking record never contains a copy of itself. A citation of the
  Build's own record is kept as metadata (path, sha256, byte count,
  `controller_record_version` binding) plus an immutable sidecar file that
  holds those exact historical bytes, next to the record. That preserves
  provenance without letting the record grow recursively. Records written
  before this change stay readable (`Kogen.Build.Evidence.resolve/2` and the
  tests that read the old inline form).
- Before each Review, the controller writes one immutable **review packet**
  per attempt. It is JSON, bound to the attempt token and the Candidate id,
  and no larger than 64 KiB (65,536 bytes). It holds the scenario and risk
  ids, the controller handoff report, the Developer notes, a summary of each
  receipt (target, status, Candidate, digest, and a bounded tail of the
  output), the open findings with their prior dispositions, any superseded
  objection, and locators with digests for everything it truncated or left
  out. The Reviewer's `KOGEN_TASK_CONTEXT` names the packet as its evidence
  source. The full record stays listed only as an audit locator, with its
  byte count. `priv/kogen/prompts/reviewer.md` tells the Reviewer to start
  from the packet and never to dump the whole record. The Reviewer can still
  read any Candidate file and run read-only commands. Nothing narrows its
  inspection of the Candidate.
- Every Codex role and helper launch carries one central
  `tool_output_token_limit` of 4000 tokens, roughly Claude Code's Bash result
  cap. The limit is set in `config_args`, not per prompt.
- The live Reviewer-rework fixture creates its project in a canonical
  (symlink-resolved) directory outside the checkout. Retained evidence still
  lands under the owned log directory (`.kogen/runtime/live-evidence/…` or
  `KOGEN_LIVE_LOG_DIR`). The fixture's own audit asserts that the fixture root
  is outside the checkout.
- An objection is **superseded** when all of these hold: Jev reads a
  confident objection, the attempt's settled verification `passed`, and an
  earlier Stop cycle of the same attempt failed. A superseded objection no
  longer stops the Build. The attempt records it (items, confidences, the
  failed cycle sequences and the passing cycle sequence), and the Reviewer
  sees it in the packet as a labelled advisory item. The Reviewer still judges
  every scenario. Any other confident objection stops the Build with
  `cannot_comply` exactly as today. That covers an objection when verification
  did not pass, and one where no earlier cycle failed.

## Quality control

The existing planted-defect Reviewer tests must keep passing unchanged in
intent: `test/kogen/reviewer_mutation_test.exs`,
`test/kogen/scenario_semantic_test.exs` (the rehearsal for `live-general`'s
incomplete-fixture Review) and `test/kogen/two_outer_resumptions_test.exs`
(the rehearsal for `live-reviewer-rework`). The bounded packet must not stop a
Reviewer from finding a planted defect in the Candidate.

## Verification

`check` plus one paid target, `live-reviewer-rework`: the real Reviewer on
`default_route` (`claude` on main) reads the packet. This Intent edits the
fixture that target owns, and an edited live test always runs (DIRECTION D8).
Every other boundary has offline proof. The Codex limit is proved offline
(argument construction for every Codex role and helper) together with the
Shaping probe that the pinned runtime accepts the key. Its real use by a Codex
Reviewer is exercised by `cross-harness-adversarial-roles` (`live-native`,
`live-reviewer-rework` on the adversarial route), which builds next.

## Why this is one Intent

All five parts are links in one failure chain, seen in `kdUszVF4…`. The record
bloat and the missing packet made the Reviewer slow. The in-checkout fixture
widened what it searched. The missing Codex limit multiplied the cost. The
stale objection then discarded the Candidate that finally passed. The ROADMAP
row groups them so that one paid `live-reviewer-rework` run proves the Review
path once.

## Non-goals

- Changing the Reviewer route or harness, or the default route (that is
  `cross-harness-adversarial-roles`).
- Relocating the other live fixtures (`test/kogen/live_shape_to_build_test.exs`,
  `test/kogen/live_test.exs`). Editing them would force two more paid targets
  under D8. Their relocation belongs to `isolated-candidate-workspace`.
- A read-only Codex sandbox for the Reviewer. The bypass flags stay as they
  are, and filesystem confinement belongs to `isolated-candidate-workspace`.
- Controller-owned verification, receipt reuse, the Review ledger and Stop
  removal (`fortify-paid-verification` and ROADMAP order 10).
- Any change to the Makefile, `priv/kogen/verification_targets.yaml` or the
  Stop scripts. Main's controller byte-freezes the catalog and runs the Stop
  scripts (DIRECTION D9).
- Raising any timeout, or lowering Reviewer effort.

## Self-hosting and where proof comes from

This Build runs under main's controller, which has already loaded the old
`Kogen.Build`. The parent Build's own record and Review therefore still use
today's behaviour. That is expected, and it is not an acceptance claim. The new
behaviour is proved in two places. `check` compiles and tests the Candidate's
code through the fake lifecycle. The `live-reviewer-rework` fixture rsyncs and
precompiles the Candidate and runs a nested `mix kogen.build` with the
Candidate's controller. This Build changes nothing that main's controller reads
during the Build: not the catalog, not the Makefile, not the Stop hook. New
proof selectors (`review_packet_test.exs`, `review_packet_audit_test.exs`,
`superseded_objection_test.exs`) are created by the Developer; a missing one is
unfinished work. Editing a cataloged
test requires refreshing `priv/kogen/test-reliability.yaml`
(`python3 scripts/check/refresh_test_reliability_sources.py`), so that file is
guarded.

## Retry after Build qWusXkQn (2026-09-25)

The first Build passed verification (`check`, `live-reviewer-rework`), but it stopped
because the Reviewer's otherwise accepting verdict omitted `codex-tool-output-limit`
(`evidence/build-failure-qWusXkQn.md`). This revision adds one requirement: a
completeness step at the end of `reviewer.md`, in scenario `bounded-review-packet`. The
reviewed Candidate from that Build is stashed as
`bounded-reviewer-evidence-candidate-2026-09-25`. The Developer may read it with
`git stash list` and `git stash show -p <that stash>` as a **reference only**. Never apply,
pop or drop it. The new Candidate must stand on its own and passes full verification and
Review.

## Approval

See `approval.md`.

## Audit record

- GPT-6 Sol (high) and GPT-6 Astra (medium) audited this Draft read-only
  through the Kogen-managed Codex runtime. The audits are in
  `evidence/audit-sol-high.md` and `evidence/audit-astra-medium.md`. Jev's
  per-scenario checks are in `evidence/jev-scenario-audit*.json`. Their
  dispositions are in `evidence/audit-dispositions.md`.
