> **Historical (pre-#1, main 2909f557).** Intent #1 `bounded-reviewer-evidence` (22a2db95) fixed
> everything this file diagnoses. Its function names and line numbers (`cited_bytes/2`,
> `snapshot_references/2`, `build.ex` ~909-990, `environment.ex` 421-453, the fixture under
> `.kogen/runtime`) are obsolete. Use the current anchors in `INTENT.md` "Current HEAD anchors
> for #1", and **do not re-implement #1**.

## 1. Root causes, ranked

1. **Unbounded, self-referential evidence** is the largest amplifier. `snapshot_references/2` base64-embeds cited files, and `cited_bytes/2` returns the controller’s current record bytes when the cited path is `record.json` (`lib/kogen/build.ex:964-990`). Verdict snapshots are merged back into the attempt (`lib/kogen/build/tracking.ex:578-584`), so a record citation can recursively enlarge later records. The retained diagnosis measured a 706 KB record dump and 1.84M input tokens in the final Review (`evidence/reviewer-context-diagnosis-2026-09-25.md:13-15`, `23-29`).

2. **The Reviewer receives a locator, not a bounded evidence view.** The task packet supplies `tracking_path` and section names (`lib/kogen/build.ex:909-926`); `reviewer_context/1` adds only prose labels and Jev summaries (`lib/kogen/build.ex:934-947`). The prompt tells the Reviewer to read selected current fields, but does not provide a controller-built index or excerpts (`priv/kogen/prompts/reviewer.md:46-53`). Codex therefore explored and dumped records repeatedly.

3. **Codex history magnifies each large read.** Kogen sets no `tool_output_token_limit` in its Codex configuration arguments (`lib/kogen/codex/environment.ex:421-453`). The probe confirms that a lower limit reduces input, while the diagnosis correctly says Codex already truncates by default and that repeated history is the multiplier (`evidence/reviewer-context-diagnosis-2026-09-25.md:35-38`, `48-60`). This is a major multiplier, not the original source of the large context.

4. **Fixture workspace leakage is real.** All three live fixture families create roots under the checkout’s `.kogen/runtime` (`test/support/live_reviewer_rework_fixture.ex:52-59`, `test/kogen/live_shape_to_build_test.exs:115-125`, `test/kogen/live_test.exs:313-320`). With Codex’s common `--dangerously-bypass-approvals-and-sandbox` flags (`lib/kogen/harness/codex.ex:10-15`), the Reviewer can discover sibling and parent runtime data. The captured outer-repository `find` proves this (`evidence/reviewer-context-diagnosis-2026-09-25.md:39-44`). It adds noise and risks contamination; it is not itself responsible for all 16 minutes.

5. **Helpers added about 2.5 minutes**, according to the Developer’s retained notes (`evidence/reviewer-context-diagnosis-2026-09-25.md:45-46`). They are legitimate native helpers, so removing them or weakening the Reviewer is not the fix.

The timing attribution is inferred from one dissected Codex run; it is not an independently isolated causal experiment (`evidence/reviewer-context-diagnosis-2026-09-25.md:62-67`). High effort and the production prompt are not demonstrated root causes.

One important correction: the diagnosis says cycles 2 and 3 both timed out, but the retained `record.json` shows cycle 2 failed and cycle 3 passed in 494.2 seconds. The top-level Build still ended `cannot_comply` because the Developer/Jev handoff retained the earlier objection. That record/evidence inconsistency must be resolved before relying on timing claims.

## 2. Systemic fix

**Controller**

- Build an immutable, candidate-bound `review_packet` per attempt containing: the complete scenario/risk contract, current handoff, notes, open findings, receipts, changed-path manifest, target-evidence locators/digests, and a bounded list of relevant source paths/excerpts.
- Give the Reviewer the packet path and workspace root. Keep the full record for audit, but never require the Reviewer to discover it.
- Change reference retention so a citation of the live tracking record stores only path, digest, byte count, and version metadata. Put exact historical bytes in a separate sidecar owned by the controller. Never embed current `tracking.bytes` inside itself.

**Harness**

- Make `workspace_root` explicit in the launch context and run every role/helper from that directory.
- Apply a measured Codex tool-output cap centrally for all Codex roles, with offline tests proving that truncation preserves verdict completion. This is a transport bound, not a Reviewer-specific prompt.
- Preserve the existing safety flags and Reviewer contract. If stronger filesystem isolation is required, launch Review in a controller-created workspace view containing the Candidate, Approved package, packet, and declared evidence only.

**Fixtures**

- Create live fixtures in `System.tmp_dir!()` or another checkout-external root; retain logs by copying them out after completion.
- Update audits to assert the fixture root, packet, and retained evidence paths; add a regression that no sibling `.kogen/runtime` tree is part of the Review workspace.

This should reduce `live-reviewer-rework` to two focused Reviews over a small packet, rather than repeated multi-hundred-KB dumps. It should fit in a few minutes without changing the 1,200,000 ms test timeout (`test/kogen/live_reviewer_rework_test.exs:15-16`).

## 3. Scope and ordering

Recommend **(b) a separate small Intent before cross-harness**, then:

1. bounded review packet, self-reference fix, explicit workspace, and fixture relocation;
2. reshaped `fortify-paid-verification`;
3. reshaped and rebuilt `cross-harness-adversarial-roles`.

Do not combine all three. Main’s Stop runner executes every selected target each cycle (`.codex/hooks/stop_runner.py:156-187`), so a failed cross-harness cycle repeats expensive paid Reviews. Fortify’s intended reuse of passed paid receipts (`fortify-paid-verification/INTENT.md:57-62`) should land first, after the evidence/workspace fix. Neither Intent should change the catalog or Makefile while running under main; fortify explicitly records that main rejects such catalog changes (`fortify-paid-verification/INTENT.md:63-67`).

## 4. Other blockers

- `cross-harness-adversarial-roles` is reopened as a Draft (`INTENT.md:3-4`); `fortify-paid-verification` is also still `status: draft` (`intent.yaml:1-4`).
- The failed Build left an uncommitted Candidate. Restore or deliberately review that baseline before any new Build; do not start from this contaminated worktree.
- Repair the cycle/receipt versus `cannot_comply` inconsistency before the next acceptance run, or timing evidence will remain ambiguous.