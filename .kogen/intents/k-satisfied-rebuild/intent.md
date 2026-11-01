# Finish already-satisfied Builds successfully

Slug: k-satisfied-rebuild
Model: .kogen/intents/k-satisfied-rebuild/model.qnt invariants=Safe seed=1 samples=10 steps=3
Acceptance:
- .kogen/intents/k-satisfied-rebuild/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Fix K-SATISFIED-REBUILD. After normal fresh verification and independent approval of the exact final candidate, if its implementation tree equals the Build's starting HEAD tree, finish successfully without attempting an empty commit. Report `already present`, exit 0, consume the exact approval as on successful delivery, and persist a successful terminal outcome `already_present` identifying the existing full HEAD. Do not claim to have created a commit. Inspect, list and checkout facts must agree: no current approval remains and no uncertain commit boundary or commit-failure blocker is reported for this successful run.

This does not bypass current approval/base checks after a rebase. A moved package still needs the existing fresh exact approval procedure before Build. Equality must use the actual implementation candidate, with existing exclusion rules, not merely a clean working-tree heuristic. Preserve unrelated staged Intent bytes/index. All normal verification, review, baseline and final-tree safety checks remain required. Nonempty candidates still produce exactly the normal reviewed commit; real commit failures keep their existing behavior. Add no command, flag, option, retry or recovery policy.

## Decisions
- Use a successful `already present` result and consume approval rather than leaving it current. (source: request)
- Keep building and committing behavior unchanged outside the verified empty implementation delta. (source: request)

## Source comparison
- addressed: request Need and Problem, `kogen intent build <slug>`, false exit 3 `environment/commit_failed`, `nothing to commit, working tree clean`, inspect's uncertain-boundary message and list's approval-current mismatch: replaced by the successful terminal outcome above and acceptance regression.
- addressed: approve card scenarios already passing: regression starts with already-satisfied acceptance, freshly approves the current HEAD and still runs fresh Build verification/review.
- addressed: outside rebase example: tests exercise an implementation already committed by outside work, retaining the existing fresh-base approval requirement rather than transferring stale approval.
- addressed: historical de2b21b / wt-b / clamp / d168514f, 30 Oct 2026 17:36:28Z: diagnostic provenance, reproduced deterministically in a local Git fixture rather than depending on private laptop logs.
- omitted: none of the requested behavior. Historical run identifiers are not runtime inputs. No new interface or unrelated commit behavior is authorized.

## Tests
- Already-satisfied Build succeeds truthfully and consumes approval: add TestSatisfiedRebuildAlreadyPresent using real CLI dispatch, temporary Git and the existing scripted local provider (regression)
- Fresh verification and independent review still run before completion: the same regression must observe executed acceptance/checks and the reviewer approval on the exact candidate, not merely exit zero (scenario)
- Inspection/list/facts agree with successful completion: the same regression invokes intent inspect, intent list and context after the Build and asserts terminal success without an unsafe boundary or current approval (integration)
- Unrelated staged Intent data survives a successful empty delta: add TestSatisfiedRebuildPreservesStagedIntent using existing stageOtherIntent fixture and byte/semantic index checks (integration)
- Nonempty commits and real rejecting hooks retain behavior: existing TestOtherIntentsStayOutOfTheCandidateAndTheCommit and TestACommitHookThatRejectsLeavesEditsAndRestoresTheStagedIntentIndex (existing)

Implementation test contract: add the two named tests in cli/build, reusing its real Git/scripted-provider env. TestSatisfiedRebuildAlreadyPresent must seed an outside commit already implementing the approved output, approve the exact current HEAD (acceptance passes now), finish the builder without edits and independently approve review. Assert Build exit 0, output contains `already present`, unchanged full HEAD/tree/commit count, clean implementation state, consumed approval, result outcome `already_present` with the existing HEAD, and the read-only discovery guarantees above. Assert checks/acceptance really executed and review really approved the final tree. TestSatisfiedRebuildPreservesStagedIntent repeats that successful route with a staged unrelated Intent and proves its contents and staged state are unchanged. Acceptance invokes these actual Go tests; absence or skipping is failure, not readiness. These tests remain ordinary editable implementation tests, not protected harness files.

## Feasibility
- Local code inspection: cli/build/commit.go currently always calls Repo.Commit after exact verification/review checks, and removes approval only after commit success. The fix can stay in unprotected native Build/state/facts code; no loop vendor edit is needed.
- Quint model typecheck and TypeScript run of Safe with seed 1, 10 samples and 3 steps passed (probe: exit 0, 0.6 s). The model covers the satisfied completion transition; existing nonempty/hook tests cover unchanged commit paths.
