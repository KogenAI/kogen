# Latest Build diagnosis and Draft repair — 2026-09-22

This is retained Shaping evidence, not a verification receipt. The Shaper asked
for Fable to diagnose the failed run and then cheaper subagents to repair this
Intent. Root authored the final Draft. No source/test/configuration edit, gate,
provider test or new Build was performed for this revision.

## Observed latest run

Build `181SwyyMv5aW2U838Wh8xXIt` ran approximately 11:11:36–12:32:33 UTC
(14:11–15:32 EAT), about 81 minutes. Main remained c1f08532; the implementation
and stashes remain available. Outer record:
`.kogen/runtime/scenario-tracking/181SwyyMv5aW2U838Wh8xXIt/record.json`.
Its terminal ignored-Draft guard failure masks the separate exhausted Stop
state at `verification/attempt-0-LDf3p6YIET0E-p--vpC8eGRQrQnsg0-_/state.json`
under that Build directory. Inspect projections, not private Developer logs.

| Cycle | Passed | Failure / unreached work |
| --- | --- | --- |
| 1 | Offline format/compile/lint and cleanup stages | `check`: commit-provenance fixture attempted Mix preparation without mix.exs; 341 of 342 tests passed, 9 excluded; no later targets |
| 2 | `check` (342 tests, 9 excluded), `cold-offline`, `live-native` | `live-reviewer-rework`: nested Build accepted, outer audit required missing legacy fixture-root history |
| 3 | `check` (342 tests, 9 excluded), `cold-offline`, `live-native` | `live-reviewer-rework`: nested Build accepted, outer audit required exactly one resumption although a valid handoff-correction path consumed a second |

`live-shape-to-build` and final outer independent Review were never reached.
These are observations on the run's successive Candidates, not verification of
later repairs. Developer focused commands were observed, but running the old
tests did not establish the missing producer/consumer assertions.

Offline receipts, respectively:

- `.kogen/runtime/offline-results/f58bf55ece281976212d87109208b930.json`
- `.kogen/runtime/offline-results/3dfb8253ac5b7695635a06814505630d.json`
- `.kogen/runtime/offline-results/92f6b045bdcb67a313097b66d9ff1fdb.json`

Nested records retained by the live owner:

- `.kogen/runtime/live-evidence/reviewer-rework-5062-3/scenario-tracking/ckZ-5K_vfUt9Z_c3n1a2YwHu/record.json`
- `.kogen/runtime/live-evidence/reviewer-rework-60268-6851/scenario-tracking/34d3hMoKngeHCim8Yr0LP9r1/record.json`

The latter has three attempts in one Developer session: expected Reviewer
rework, invalid handoff citing the control record as Candidate-relative, then
acceptance by a fresh Reviewer. Its record retains decoded state snapshots and
an artifact mapping whose old fixture paths are no longer sufficient after
fixture removal. Record presence alone does not prove those artifact bytes
survived. The unrelated Draft collision does not show that Developer edited
that Draft, and removing it alone would not cure verification exhaustion.

## Source-linked findings and integration

- `test/support/live_rework_audit.ex`: `unified_current_paths!/1` selects unified
  state, but `check_records!`, `current_pass!`, `passing_check_sequence!` still
  require legacy archives/fields. `developer_invocations!`, `developer_resume!`
  and native audit cardinality pin two attempts/captures. `audit_retained!`
  resolves summary first but checks acceptance without exercising the missing
  artifact history. Fix the whole chain, not only one resumption assertion.
- `lib/kogen/build/verification.ex`: unified per-attempt state/history is the
  schema authority. `lib/kogen/build.ex` retains state bytes and snapshots
  Candidate artifacts during publication. Inspect exact Build/attempt bindings,
  not whichever wildcard path sorts last. `lib/kogen/check.ex` has a separate
  Candidate-local Check history; do not confuse these two formats.
- `test/support/live_reviewer_rework_fixture.ex:preserve/3` and
  `test/kogen/live_shape_to_build_test.exs:preserve_tracking/3` copy tracking but
  not all referenced Candidate artifacts. Both real routines must be exercised
  through cleanup. Source-bound success needs the required bytes, not a mock
  independently constructing a correct archive.
- The connected owner also reads obsolete fixture-root verification history and
  hard-codes one Developer native capture despite permitting outer resumptions.
  It has not yet passed paid execution and must not be described as proven.
- `lib/kogen/build.ex:task_context/3` exposes a tracking locator without the
  complete usable artifact citation required by repair-plan section 1. The
  existing exact-record allowance in `Contract.with_reference_root/3` remains
  narrow; do not broaden it. Test fake roles consuming actual advertised
  citations, not independently choosing the one working path.
- `workspace_dependency_test.exs` still tests an environment map, and
  `commit_failure_rollback_test.exs` accepts either success or failure. Required
  incremental compilation, unconditional positive publication and journal-reader
  fault-injection controls remain implementation work. A green catalog of those
  old assertions cannot establish the new outcome.

## Advisory review and corrections

The requested Fable-high final report is retained in `fable-latest-review.md`;
runner metadata in `fable-latest-run.json` identifies `claude-fable-5-1`. It was
read-only, approximately 498 seconds and 33 turns, with no helper launches.
The requested advisory size bound was <=20 tool calls and 1800 words; 33 turns
is the runner's reported unit, not a verified tool-call count. Its
reported $4.95 is only that Fable invocation, not complete-task cost or savings.
No private reasoning, raw Codex transcript or engine session ID is copied.

The cheaper reader was native explorer `gpt-5.6-luna`, low effort, task
`audit_contract_luna`. A second requested reader could not start because of the
native thread limit; root did that work instead, without substituting a model.
Exact combined root/helper token usage is unavailable and is not zero.

Accepted: complete schema/lifetime migration, actual owner-route offline
controls, valid bounded handoff correction, preserved provider-only proof,
latest-source availability and accurate installation branch semantics.

Corrected rather than adopted blindly:

- Luna initially recommended retaining exactly two attempts and treating
  correction as intra-attempt events. README, `Build.rework/4` and the retained
  actual sequence disprove that; Luna corrected its recommendation after root
  follow-up. No new correction-event counter or product choice is introduced.
- Luna initially described summary-first retention as legacy-primary; corrected
  against actual source. Legacy fixture tests are not current live proof.
- Fable proposed a new Git checkpoint to preserve latest work. Source/ref writes
  are outside this Shaping task. The package-only source snapshot provides the
  exact bytes after clean start without those mutations.
- Fable's additional rejection rule for any advertised-path handoff failure is
  not a new general runtime restriction. Dedicated generated-citation tests
  must expose the producer bug while ordinary correction semantics remain.
- Fake native streams prove the consumer rejects malformed sequences; they do
  not establish actual native sessions. Live outer drivers own that observation.
- Luna's final check suggested changing the cold target's paid_reason prefix to
  offline-expensive. That would violate the actual supplied proof schema, so
  root retained its required provider-required prefix and explicit no-provider,
  offline-expensive classification. Target names/selection are unchanged.
- Root made the resumption predicate explicit as outer record attempts minus
  one; Stop cycles and stream events are separately checked, never conflated.

## Source retention and validation limits

`latest-implementation.json` and its 41 inert `.gz.base64` payloads retain the
entire current changed/new source set, 977,362 decoded bytes. Each payload was
decoded and checked against its SHA-256, length and actual dirty source bytes.
The snapshot excludes other Drafts, runtime data, logs, caches and credentials.
No source, Git objects/index/refs, stash or historical checkpoint was changed.

Capture mechanics: a proposed textual overlay diff exceeded the tool output
limit and was rejected before any artifact write. Complete compressed file
inputs replaced that approach. The first Ruby equality check incorrectly
compared gzip UTF-8 strings with binary strings for two non-ASCII files; sizes
and SHA-256 were identical. The corrected binary-string comparison passed all
41 files. This was a probe bug, not evidence that source changed or a Build pass.

The original shaping and shaped-against blocks and all three continuation
entries are preserved. The existing visit appears once, not once per save.
YamlElixir is used after every package save. Final structural validation checks
scenario/target selection, guard coverage, input hashes/modes and package size;
none of these checks proves implementation correctness. The revised package
remains Draft and unapproved. No guarantee of the next run or its duration is made.
