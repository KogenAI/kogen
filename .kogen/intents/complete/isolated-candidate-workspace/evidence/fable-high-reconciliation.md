# Fable-high reconciliation — 2026-09-22

The Shaper requested Fable at high effort after Build
`IBs1pJmboiW9BAGHIDd_ee4O` failed. The CLI requested `--model fable --effort high`;
runner metadata identifies `claude-fable-5-1`, completed successfully, no permission
denials or subagents. Tools were restricted to Read/Glob/Grep. Its final report
and run metadata are retained alongside this note; no private reasoning or raw
Developer conversation is evidence. The native Luna-low reader independently
traced reference validation and the terminal-test diagnostic. Root integrated
the findings and ran the bounded citation and cloning probes below.

## Findings reconciled into the same Draft

1. **Confirmed missing operational citation contract.** `build.ex` emits
   `verification_state.path` relative to control (settlement, around line 540),
   but `Contract` resolves relative paths in Candidate and allows only the exact
   absolute tracking record. The failed Reviewer copied that advertised path.
   The record already contains the exact state bytes. The accepted repair uses
   an explicit current-record citation and artifact locator; it does NOT widen
   validation to every advertised absolute path as Fable proposed. Otherwise an
   added field could accidentally grant authority. The source-linked probe
   confirms both valid controls and both broken spellings.
2. **Confirmed two retention consumers.** Only reviewer-rework normalization was
   changed. The connected `preserve_tracking/3` still indexes relative keys with
   an absolute summary path. Preserve the documented control-relative published
   locator contract and exercise both actual retention functions with owned
   absolute/relative inputs and post-cleanup audits. This is internal compatibility
   repair, not new output scope.
3. **Confirmed seed/setup and missing behavioral assertions.** Production still
   rejects every link; `CompiledFixture.prepare_build!/2` uses `cp -cRL` and hides
   that mismatch. The connected owner does not use the same preparation route.
   Dependency tests still inspect a made-up environment map; the rejecting-hook
   positive case accepts failure; the lock/journal recovery is unfinished.
   These are violations of existing requirements, not newly discovered product
   choices. `repair-plan.md` gives the required order and concrete controls.
4. **Clone assumption corrected, not merely restated.** The local manual and an
   actual HFS+ disk-image control prove `cp -c` falls back. Direct native cloning
   succeeded on the source filesystem and failed without creating a destination
   on HFS+ and across filesystems. Require a fail-closed primitive; retain the old
   probe's observed byte/isolation facts but withdraw its clone-guarantee inference.
5. **Failure precedence confirmed.** Guard checking before settlement hides
   exhaustion in the outer record. Preserve valid settled verification and both
   causes in the future controller, without admitting handoff/Review after either.
   The installing c1 controller cannot acquire this fix during its own run.
6. **Terminal cause unresolved, diagnostic defect confirmed.** The test discards
   the captured message. Add only its test path to guards and proof selectors for
   diagnostic/intended-cause controls. No timeout/cleanup cause or general flakiness
   is established, and no arbitrary production repair is authorized.

Fable proposed a generic required/forbidden test-name registry. Not adopted:
name presence is not behavioral proof and adding that registry is not necessary
for isolation. The Developer must add the causal assertions to existing focused
selectors and register them in the existing reliability catalog; Review must
inspect those assertions. Neither that instruction nor a name registry guarantees
a future Developer follows it. No new readiness attestation or trust in Developer
test claims is introduced.

Fable called the terminal test guard and installing checkout arrangement human
choices. The former is ordinary engineering within existing failure-preservation
scope; it does not change product behavior. The Shaper already allowed either
the original clean-start checkout or an optional separate one. Preserve that
choice, state the old controller's no-simultaneous-edits precondition explicitly,
and do not silently require a separate worktree. No new product decision was
needed, and future parallel/resume/integration briefs remain parked.

## Latest run: actual results, not assurance

| Cycle | check | cold-offline | live-native | live-reviewer-rework | live-shape-to-build |
| --- | --- | --- | --- | --- | --- |
| 1 | passed, 342/342 (9 excluded) | passed | passed | failed: summary retention KeyError after nested acceptance | not reached |
| 2 | failed, 341/342: terminal descendant test | not reached | not reached | not reached | not reached |
| 3 | passed, 342/342 (9 excluded) | passed | passed | failed: uncitable controller state path | not reached |

Final outer Review never ran. Main remained
`c1f085324f78d5030c8d3d7b6efc2df248ff01c2`. The terminal outer error named concurrent
changes to the other ignored Draft; it does not establish that the Developer
edited that Draft and does not erase the separately exhausted verification.

Read-only comparison of all 38 checkpoint blobs found 37 unchanged; only
`test/support/live_reviewer_rework_fixture.ex` differs, from
`20791f464adc7d7184b45c2925aa12b473adde34` to
`f9c7a333167abf3a914094d7b673302f24b8728c` (four added normalization lines).
Preserve that newer work as well as checkpoint `913ba174`. No source/test/config
file was edited by this review.

Evidence owners/locators:

- Outer Stop: `.kogen/runtime/scenario-tracking/IBs1pJmboiW9BAGHIDd_ee4O/verification/attempt-0-lELCwRn-OjriG9oxD_tYKHHkt_Bu4lWG/state.json` contains all three cycles.
- Outer controller: the same Build directory's `record.json` retains the guard
  failure, but not the masked cycles.
- Cycle 1 live owner: `.kogen/runtime/live-evidence/reviewer-rework-57439-9/`,
  nested record `scenario-tracking/wTDgcuxX2tcC0RIMkmhAru97/record.json`.
- Cycle 2 offline owner: `.kogen/runtime/offline-results/76f8cad74ed083bfc0da3b82f79ad9fb.json`.
- Cycle 3 live owner: `.kogen/runtime/live-evidence/reviewer-rework-33147-4742/`,
  nested record `scenario-tracking/sC1u-Kn76sopTvdvL_NbUfm9/record.json`; current
  attempt retains state bytes and the invalid verdict.
- Root Shaping: `controller-citation-probe.md`, `clone-capability-probe.md`,
  and the advisory Fable report. These diagnose boundaries; they are not Build
  receipts or provider-route passes.

## Historical Draft-state readiness note before current approval

The following records the state at the end of the Fable-high reconciliation.
Later explicit approval is maintained in `../approval.md`; it does not change
the test results or evidence limits below.

This revision is an unapproved Draft. It repairs the brief and test map; it does
not repair the Candidate in a Shaping session. No full gate or live target was
rerun. Past native/cold successes remain source-bound observations, not current
acceptance. The unreached connected route still requires real verification, and
no next-run guarantee or speed promise is justified.

## Historical package checks after integration, before current approval

The repository's actual `YamlElixir.read_from_file/1` parsed every package YAML.
`Kogen.Intent.read/2`, `Kogen.Build.Contract.load/1`, and
`Kogen.Build.VerificationPlan.load/0` plus `build/3` accepted seven scenarios,
five risks and 27 focused selectors. The ordered plan remains check,
cold-offline, live-native, live-reviewer-rework, live-shape-to-build. All linked
reference paths existed at this check. These are read-only structural checks,
not verification gates or semantic proof.

Original `shaping`, `shaped_against`, and the entire `shaping_continuations`
blocks were byte-compared with the pre-review package and are unchanged. Exactly
one continuation entry has this visit's supplied start time. Current approval
metadata is absent; the prior approval is preserved under historical approvals.
The package exists only in Draft. Main remains c1f08532 and the final 38-file
comparison still differs from checkpoint only by the preexisting four-line
fixture patch; this review made no application/source/test/configuration edits.
