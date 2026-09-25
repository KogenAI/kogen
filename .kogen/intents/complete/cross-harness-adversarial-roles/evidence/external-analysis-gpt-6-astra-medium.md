> **Historical (pre-#1, main 2909f557).** Intent #1 `bounded-reviewer-evidence` (22a2db95) fixed
> everything this file diagnoses. Its function names and line numbers (`cited_bytes/2`,
> `snapshot_references/2`, `build.ex` ~909-990, `environment.ex` 421-453, the fixture under
> `.kogen/runtime`) are obsolete. Use the current anchors in `INTENT.md` "Current HEAD anchors
> for #1", and **do not re-implement #1**.

1. **Root causes, ranked**

   1. **Recursive tracking evidence is the largest amplifier.** `snapshot_references/2` base64-embeds every cited file, while `cited_bytes/2` substitutes the current tracking bytes when the cited path is `record.json` ([lib/kogen/build.ex:964](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build.ex:964), [lib/kogen/build.ex:986](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build.ex:986)). A Reviewer citing its own record therefore causes recursive growth across attempts. The retained diagnosis measured 706 KB record output and 1.84M input tokens in 18 commands ([reviewer-context-diagnosis:13-15](/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/evidence/reviewer-context-diagnosis-2026-09-25.md:13)).

   2. **The controller supplies an unbounded raw-record pointer.** Review receives only `tracking_path` plus section names ([lib/kogen/build.ex:909-926](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build.ex:909)), so the model must discover relevant evidence by shelling out. The Review launch itself adds no bounded evidence packet ([lib/kogen/build.ex:702-719](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build.ex:702)). This explains the repeated full-record dumps and most of the 16-minute exploration.

   3. **Codex’s output cap is implicit rather than controlled.** Codex does truncate by default, so that finding is directionally correct; the missing systemic control is that Kogen sets no `tool_output_token_limit` ([lib/kogen/codex/environment.ex:421-453](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/codex/environment.ex:421)). Since tool history is resent, repeated large outputs multiply input.

   4. **Workspace escape creates unnecessary search space and weakens isolation.** All Codex roles use `--dangerously-bypass-approvals-and-sandbox` ([lib/kogen/harness/codex.ex:10-14](/Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/harness/codex.ex:10)), and the fixture is created under the real checkout’s `.kogen/runtime` ([live_reviewer_rework_fixture.ex:48-59](/Users/almirsarajcic/Areas/Kogen/kogen/test/support/live_reviewer_rework_fixture.ex:48)). The observed outer-runtime `find` was avoidable, though probably smaller than the evidence cost.

   5. **Helper startup is a fixed latency floor.** The final Reviewer spent about 2.5 minutes on two Luna helpers ([reviewer-context-diagnosis:45-46](/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/evidence/reviewer-context-diagnosis-2026-09-25.md:45)). A complete packet should make those calls unnecessary in this fixture, without changing the Reviewer prompt.

2. **Systemic fix**

   The controller should build a bounded, immutable Reviewer evidence packet before launch: contract/scenario and risk text, current handoff, changed paths, receipts, open findings, and only controller-selected candidate files or retained snapshots. Give the Reviewer that packet path and an allowlisted workspace; remove the raw tracking-record locator from role context. Record citations should be metadata (path, hash, size, binding), with the tracking record explicitly non-citable or represented by a bounded section export. Large evidence must live in separate immutable artifacts, never recursively inside `record.json`.

   Make this a harness-neutral role-context contract: `workspace_root`, `evidence_packet`, `allowed_paths`, and read/write capability. Codex should receive a read-only sandbox and an explicit tool-output cap; Developer remains writable. Other harnesses should consume the same packet and capability fields through their adapters.

   Fixtures must create the project outside the source checkout (for example, a temporary directory), keep logs/evidence in a separate controlled directory, and pass that root to the child harness. Then the Reviewer cannot discover sibling live runs. With bounded evidence, no recursive record, and no helper-worthy discovery work, both Codex Reviews should be short enough for the existing 20-minute test—likely a few minutes total rather than 5 + 16—without increasing timeouts or weakening review.

3. **Scope and ordering**

   Use a **separate, narrow evidence-isolation Intent before cross-harness-adversarial-roles**. It is orthogonal to role routing, can be tested offline plus one focused live Reviewer run, and gives the already-approved route a usable baseline. Do not wait for `fortify-paid-verification`: its controller-owned verification and receipt reuse reduce repeated paid-target cost, but do not fix a single Reviewer’s context explosion. Main’s Stop controller currently reruns every selected paid target each cycle, so the evidence fix must pass under that controller and must not depend on target splitting or catalog changes. Build cross-harness next; do fortify afterward for verification-cost reduction and the planned two-step Stop removal.

4. **Next-build blockers**

   Update the cross-harness contract/risk to require this evidence and workspace boundary, or the same `cannot_comply` objection remains valid. Preserve the current 20-minute timeout. Avoid changing `Makefile` or the verification catalog while main rejects post-admission catalog changes. The retained failed Candidate and runtime record should remain untouched; start the next Build only after the new Intent is approved and the working tree is otherwise in the required admission state.