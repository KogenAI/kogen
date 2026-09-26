# Required repair order for the saved implementation

This is the current implementation instruction, not a statement that the code
has been repaired. Continue all 41 exact retained source inputs described in
`developer-recovery.md`, including the latest failed run's repairs. Keep the original admitted controller,
same-session rework and configured allowances. Do not submit the unchanged
checkpoint as completed work just because the existing tests pass.

## 1. Make evidence usable across the two roots

The controller must distinguish a file's physical origin from a role's usable
citation. Candidate files use Candidate-relative references. For controller
verification/context/state evidence, use the existing exact absolute
`tracking_path` plus a locator into the current attempt's retained, hash-bound
bytes. Populate the generated task locator packet/record with that concrete
citation, identifying any physical origin as provenance, not a Candidate-relative
reference. Do not tell a role to cite an advertised path the validator rejects.

Preserve the narrow authority: no blanket allowance for absolute paths, no
search in the other root after a missing Candidate path, no symlink back to
control, and no copying writable verification state into Candidate. The existing
record already retains the settled state bytes. Review must inspect the specific
decoded artifact and cite its record section/digest; naming the record alone is
not semantic evidence. Static role prompts and hooks remain unchanged.

At publication, rewrite usable locators for retired Candidate-only artifacts to
their retained record snapshots and precise artifact selectors. Keep original
Candidate paths only as explicitly labeled provenance; a raw snapshot-map key
pointing into a deleted worktree is not a usable Complete citation. Source-file
references that survive in the published tree remain repository-relative.

Add a production-path regression that follows generated context/retained state
through Developer handoff, fresh Reviewer verdict validation, reference snapshot
retention, later controller updates, and post-Candidate-cleanup inspection. The
fake roles must use the advertised citation, not a separately hard-coded working
path. Include Candidate/control sentinels, foreign record, stale attempt,
missing/tampered snapshot, raw relative control path, unauthorized absolute state
path, and symlink/traversal negatives. Legitimate controller appends preserve the
cited historical version; external edits do not. Selectors:
`scenario_tracking_test.exs`, `scenario_lifecycle_test.exs`,
`developer_handoff_test.exs`, `reviewer_mutation_test.exs` (all under test/kogen).

## 2. Rehearse both real evidence-retention consumers

Keep the existing published locator contract: Complete's compact
`full_record.path` and evidence instructions resolve relative to the control
checkout root after publication, never to a removed Candidate or a machine's
absolute home path. Runtime role locators may be absolute; published locators
have a different lifetime.

Fix both `LiveReviewerReworkFixture.preserve/3` and the connected owner's
`preserve_tracking/3`, preferably with a shared internal implementation.
Recognize exact owned absolute and control-relative fixture input references;
reject foreign/traversing/symlinked, absent, wrong-Build and digest/size-mismatched
records. Preserve the newer four-line normalization as useful starting work,
not as proof of these controls. Copy exact bytes and rewrite only the retained
summary locator to its owned archive before deleting the fixture.

The offline tests must call the real owner preparation and retention routines,
not merely construct an already-correct audit archive. For each owner, use its
own fresh child and declared loader chain. Exercise preparation, fixture-only
fake execution/summary production, actual retention, owned fixture deletion,
and the real retained-evidence audit. Deny real provider dispatch throughout.
Retain existing pre-Shape test-only admission versus post-Shape real-contract
admission; a fabricated package does not establish real Shape output.
Selectors: `test/kogen/live_rework_audit_test.exs`,
`test/kogen/lifecycle_test.exs`. Both live targets remain independently required.

### Complete the audit migration, not only its first failing assertion

Resolve the exact accepted Build through its production compact summary and
hash/size-bound record. Select attempts and verification by recorded identity,
number and token, never lexically last wildcard history. Unified `state.json`
and `state-history.jsonl` are not legacy flat Check records. Decode the retained
per-attempt state with its digest; consume `terminal_state`, `candidate_id`,
`developer_session_id`, cycles and receipts according to their real schema.
Bind the final state to its actual retained history where history is inspected.
Do not feed it to legacy predicates for top-level `status/target/session_id`.
Preserve exact attempt context/history bytes when the audit needs them; their
old origin pathname is provenance, not proof they remain present.

Legacy Candidate-local Check history, when needed by the connected failed-then-
passed control, must be retained through the controller's content-bound
`workspace.artifacts` mapping (currently `candidate-artifacts/verification-history.jsonl`),
not read from a retired Candidate or assumed at the fixture/control root.
Retain the required artifact bytes as well as the tracking JSON before owned
fixture deletion. Keep tracking bytes unchanged; an owner archive manifest may
map original artifact locators to retained copies and hashes. The post-cleanup
audit must actually read and validate those copies, not merely assert that the
record says `accepted`. Missing or tampered history/artifacts fail closed.
Current live execution cannot fall back to a legacy-only synthetic fixture.

The rework protocol requires one actionable Reviewer rework and a later fresh
accepting Reviewer, with the same Developer throughout. It does not redefine
ordinary invalid-handoff correction: the existing controller increments the
outer attempt and consumes one outer resumption for that correction. Audit
all attempts and their fresh tokens/schemas/final-output bytes; require the
reported outer resumptions to equal `length(record["attempts"]) - 1` and stay
within configuration. These are outer attempt records selected by number/token,
not verification cycles or raw stream events.
Do not hard-code exactly two Developer attempts/captures in every successful
run, invent a correction counter, increase the allowance, or tolerate missing
attempt evidence. Verification cycles are a different counter. Each attempted
handoff must have current passed verification before its validation/Review.

Use two deterministic controls through the real controller:

- Initial Developer -> first Reviewer rework -> same Developer resume -> fresh
  accepting Reviewer: two attempts, one resumption.
- The same route with one intentionally invalid resumed handoff -> a second
  exact-session resume -> fresh accepting Reviewer: three attempts, two
  resumptions. The injected failure is test input, not a production citation
  regression being excused. Also reject an over-budget next attempt.

Audit Reviewer ordering, all Developer invocations, native receipt cardinality
and root-profile coverage against the actual attempt/session sequence. Reject
replacement Developer, reused Reviewer, duplicated/stale token or schema,
missing capture, wrong Candidate, reordered receipts, and a fabricated reason
for an unreviewed attempt. Distinct attempt tokens do not prove distinct
Developer sessions. Do not blindly change one count from 1 to 2 and leave the
remaining exact-two assumptions behind.

Verify the initial omission and final exact file contents against their bound
Candidate trees while the owning fixture Git database exists. Retain the
hash-bound inspected tree/file observations needed by later audit before
deleting it; after cleanup do not attempt `git show` in a removed repository.
The live outer driver owns real provider streams and historical sequence;
independent Review is not required to reconstruct unavailable interactions.
Offline synthetic streams exercise the audit but never establish native access.

The connected owner must similarly derive Developer/native capture counts from
its permitted actual attempts, consume the retained current-format verification
route, and prove failed Check then passed Check in the same Developer session
before the first handoff. It must use shared real fixture preparation. Rehearse
both owners independently in fresh provider-denied children through their own
preparation, fake execution, production summary, real retention, cleanup and
actual retained audit. The connected offline route uses clearly synthetic
Shape output; only the selected live target proves real Shape and approval.

Implement the citation repair in section 1 before interpreting a permitted
extra attempt as healthy recovery: a fake must consume generated citation
fields, with a positive current-record citation and a negative raw controller-
relative origin. Do not hard-code a separately working path in the fake.

## 3. Implement real seed isolation and incremental reuse

Remove blanket symlink rejection and fixture-side dereferencing (`cp -cRL`).
Both live owners and offline controls use the same admitted fixture preparation
entrypoint. Real Mix relative `priv` links must survive as links and resolve
inside the final Candidate tree, including while clones use staging paths.
Absolute/dangling/escaping/runtime-targeting/retargeted links still fail.

`cp -c` is NOT clone-or-fail on this host. Use an actual fail-closed native
cloning primitive, with no byte-copy fallback; `clonefile(2)` was probed directly.
A successful `cp -c`, matching bytes, distinct inodes or fast timing cannot prove
native cloning. Preflight the actual source/destination filesystem relationship
and space, recheck the admitted source manifest, and retain ownership-safe partial
cleanup. An optional narrow Python native-call helper is guarded at
`priv/kogen/clone_tree.py`; its normal tracked source is not a generated runtime
authority. Internal packaging remains Developer choice.

Exercise an actual small Mix project, not a fabricated environment map. The
seed and Candidate must use compatible effective build layouts; mapping a
normal `_build/dev` seed to an unrelated flat build path would silently cold
compile. Prove unchanged inputs reuse outputs, then source/config/dependency/
toolchain-or-environment changes invalidate the right outputs and change the
observable runtime value. Check seed bytes remain unchanged. Native success,
unsupported/cross-filesystem refusal, missing seeds, excluded state, races,
ENOSPC and owned partial cleanup remain required.
Selectors: `test/kogen/build_workspace_test.exs`,
`test/kogen/workspace_dependency_test.exs`, `test/kogen/lifecycle_test.exs`.

## 4. Finish existing publication and reliability requirements

The rejecting-hook positive case must unconditionally publish successfully;
accepting either success or failure is not a positive control. Implement the
already-required identity-bearing lock and journal reader/recovery path, not
only journal writes. Inject pre-ref, post-ref/pre-sync and post-sync/pre-cleanup
failures; a matching owner can finish the already-published exact result and a
foreign/stale/ambiguous journal cannot. This does not resume an exhausted
Developer Build or add the parked continuation feature.
Selectors: `test/kogen/commit_failure_rollback_test.exs`,
`test/kogen/worktree_publication_recovery_test.exs`.

Catalog generation must be admitted data, not a hard-coded SHA shortcut. Compare
the whole baseline-to-Candidate delta (including committed/untracked work), not
only dirty status. The Gitless consumer uses a bound outer-owned generation/input
snapshot; a failed Git command must not pretend every implementation changed.
Preserve clean, changed-row, stale-generation and intentionally Gitless negatives.
Register every added/changed test and its real consumer in the existing catalog.
Selectors: `test/kogen/test_reliability_catalog_test.exs`,
`test/kogen/whole_suite_remediation_test.exs`,
`test/kogen/cold_offline_contract_test.exs`.

## 5. Preserve the actual failure and diagnose the terminal control

When an ordinary guard violation and settled verification exhaustion coexist,
retain the valid settled cycles/receipts and both causes; exhaustion is primary.
Do not proceed to handoff, Review or publication. Integrity corruption still fails
closed: do not invent settlement from unreadable or tampered state. This fixes
the future controller; it cannot hot-patch the installing c1 controller.
Selectors: `test/kogen/verification_ownership_lifecycle_test.exs`,
`test/kogen/guarded_paths_test.exs`.

The terminal-process failure's cause is NOT known. The test discarded captured
stdout/stderr, so the next pass did not diagnose it. Add the captured message to
failure assertions and require the intentionally failing child to fail for its
intended reason while descendants are gone. Run the focused test with its
negative controls, inspect any real failure, and repair a demonstrated in-scope
cause; do not increase deadlines/retries or weaken cleanup without evidence.
The guard addition for `test/kogen/terminal_probe_test.exs` permits these
diagnostic/assertion repairs. An unrelated new production defect may still
require return to Shaping; no package can pre-guarantee unknown failures.

## Before yielding to Stop

Implement the behavioral controls above, exercise their disconfirming inputs,
and run the affected focused selectors during the same Developer conversation.
A green preexisting suite without these assertions is not completion. This
instruction adds no command-attestation record and gives Developer observations
no gate authority. Stop still runs the full `check`, `cold-offline`,
`live-native`, `live-reviewer-rework`, and `live-shape-to-build`; fresh Review
independently inspects the complete contract and assertions. Do not add retries,
remove targets, or substitute a test-name checklist for behavior.

## Installing this feature without another Draft collision

The admitted c1 controller runs in its invoking checkout and snapshots ignored
Draft files. During this one installation, other work must not edit files in
that checkout while Build runs, including unrelated Drafts; other Shaping work
may continue in a separate checkout. Alternatively the human may prepare a clean
separate installing checkout as already permitted. This is an existing bootstrap
constraint, not a new concurrency feature or a compulsory separate-worktree rule.
Do not broaden guards to the other Draft, suppress the check, or delete its work.
Do not use the WIP checkpoint as trusted HEAD. Main and all saved work remain
unchanged until the normal successful Build publishes.

A next-run pass and duration cannot be guaranteed. The latest run spent about
81 minutes without reaching live-shape-to-build or final outer Review. These
focused controls address known avoidable paid failures, not provider reliability.
