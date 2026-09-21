# Implement whole-suite test reliability repairs

## The problem

Kogen's tests and verification code can report the wrong result or hide the useful result:

1. An isolated ExUnit child can exit zero before its selected test completes, and the parent can accept false success.
2. `scripts/check/offline.py` collapses independent stages into one failure and does not retain safe per-stage results for attribution and invalidation.
3. Provider tests conflate authentication, installation, compatibility, routing, intermediate output, final output, timeout, cancellation, cleanup, and malformed evidence. Later failures can erase the initiating cause.
4. Rehearsals and tests can pass from file, symbol, source-string, fixture, transcript, count, or schema shape without proving the real production consumer accepted correct authority and rejected wrong authority.
5. Filesystem, environment, cache, Git, process, and scheduling state is not consistently owned and cleaned up, allowing cross-test influence and evidence loss.
6. Retry, resumption, Review, publication, and rollback do not uniformly bind success to exact Candidate bytes, attempt identity, target plan, toolchain, and evidence owner.
7. Git publication/admission, configuration/support, Shape-to-Build, Reviewer rework, general Review, shaping evaluation, and cold-cache tests can prove substitutes instead of their real consumers.
8. The suite lacks a trustworthy declaration-level account of which tests prove public behavior, duplicate or contradict coverage, require production repairs, or genuinely need provider execution.

The failed 2026-09-20 Build exposed another defect: it changed a small infrastructure subset, generated more than 4,000 ledger lines, marked all 257 declarations `keep`, reused existing test files as positive/wrong/failure evidence, and named unchanged production files as implementation. That is inventory generation, not whole-suite repair.

## Required solution

Inspect every maintained test declaration with its complete setup, teardown, fixtures, called support code, production consumer, authority boundary, and retained failures. Then implement all repairs below. Generate the catalog from completed repairs; catalog generation is never itself a repair.

### Fix isolated execution

Change `test/support/isolated_case.ex`, `test/support/isolated_process.py`, and their tests so success requires one fresh, atomically published, versioned completion receipt bound to invocation, canonical source, module/test identity, selector, and completed descendant cleanup. Reject raw zero exit, forged stdout, stale receipt, symlink/path alias, partial/replaced frame, schema downgrade, mismatched test, exit-code collision, and completion/cleanup races. Preserve initiating and cleanup failures. Keep safe overlap; suite serialization is forbidden.

### Fix offline stages

Change `scripts/check/offline.py` and Build verification consumers so format, compile, Credo, Boundary, ExUnit, and rehearsal each retain command identity, status, discriminating signature, bounded log, duration, and cleanup result. The initiating failure remains primary. Reuse success only when bound to exact Candidate blobs, source/dependency/toolchain inputs, catalog generation, target plan, provider-denial state, and verification attempt. Tests inject a distinct failure into every stage and prove attribution and invalidation through the production consumer.

Receipt binding must work in both the Git-backed checkout and the intentionally Gitless tree used by `cold-offline`. The Gitless child receives source revision and Candidate identity from its outer owner and verifies a deterministic manifest of the exact copied inputs it consumes; it never invents identity or invokes `git rev-parse` inside a tree copied without `.git`. Candidate identity includes added and untracked consumed files, not only `git diff HEAD`. If neither verified local Git provenance nor explicit owner-provided provenance is available, binding fails closed before expensive stages. A binding failure atomically settles as an attributable failure without erasing already completed stages, the initiating failure, or cleanup disposition.

### Fix provider outcomes

Change Codex compatibility/native/helper routes and harness consumers so login failure, missing runtime, incompatibility, helper-routing error, intermediate schema-shaped output, valid final output, later provider failure, timeout, cancellation, malformed evidence, and cleanup failure remain distinct outcomes. Only final bound evidence succeeds. Cleanup never overwrites the provider cause. Offline tests cover normalization; `live-native` proves the installed authenticated runtime, compatibility lifecycle, and helper routing.

### Replace shape-only assertions

For every test relying on source strings, transcript fragments, symbol/file existence, counts, fixture self-validation, or schema shape, rewrite it to drive the real production consumer with a valid input and a one-field-at-a-time invalid input, or delete it only after naming equivalent retained coverage. Apply this to rehearsals, configuration/support, prompts/hooks, Git admission/publication, Shape-to-Build, Reviewer rework, general Review, shaping evaluation, and cold-offline setup. A fake that merely resembles accepted evidence must fail.

### Fix state ownership and cleanup

Give every created repository, cache, receipt, runtime fixture, environment override, process tree, Git index/ref, and generated file an explicit owner and lifetime. Use private disposable state where isolation is required. Tests prove concurrent overlap, cancellation, failure cleanup, and diagnostic preservation. No test depends on order, a warm prior run, undeclared state, or credentials outside the selected Kogen account.

### Fix Build lifecycle binding

Change verification, retry/resumption, handoff, Review, commit, and rollback so every receipt is bound to Candidate bytes, attempt token, target plan, relevant environment/toolchain, and evidence owner. Stop retries and outer resumptions remain separate. Stale handoffs and receipts cannot authorize Review or publication. Failed publication restores owned prior Git/Intent state while retaining initiating failure and provenance.

Each lifecycle target must also work when invoked alone. Shared lifecycle setup belongs in maintained support code, not in another ExUnit test module whose availability depends on the selected file list. Before any provider call, a provider-denied preflight must construct and validate the exact fixture the live route will consume: Approved directory placement, `intent.yaml`, nonempty schema-valid `scenarios.yaml`, referenced risks, verification targets, guarded paths, Git state, and required support files. Missing or invalid fixture input must fail locally without spending a provider call. The retained negative controls include both failures from the 2026-09-20 Build: an undefined helper because `live-reviewer-rework` depended on `live_shape_to_build_test.exs` being loaded, and a later launch whose fixture reported `scenarios.yaml missing or invalid`.

### Repair and run tests incrementally

Do not postpone focused execution until the final Check or Stop-owned verification cycle. Begin with the currently known failure and run its exact file by itself:

`mix test --only live test/kogen/live_reviewer_rework_test.exs`

Its fixture currently emits a scenario without the required `proof` map; repair the fixture generator and add a provider-denied contract test that rejects this malformed fixture before provider dispatch. Rerun that exact file until it passes before proceeding.

The complete current list and exact command for all 69 maintained files is owned by this Intent in `test-file-execution.yaml`; the Developer does not discover or choose the initial scope. Execute that manifest in ordinal order, one file at a time. Run affected support and production tests immediately after each repair. When any invocation fails, diagnose and repair its test, fixture, support, orchestration, or production cause; its consecutive-pass count returns to zero.

After incremental repairs, run the manifest as a final immutable-Candidate sweep. Every listed command must pass three consecutive times before advancing to the next ordinal. A failure resets that file's streak to zero. Any source, test, fixture, support, prompt, hook, configuration, or manifest mutation invalidates every prior final-sweep result and restarts the complete sweep at ordinal 1. Each run retains command, ordinal, attempt 1/2/3, exact Candidate identity, exit result, failure signature, and live/provider outcome where applicable.

Before handoff, compare the manifest with final-Candidate discovery. Any test file added, renamed, or removed during implementation must be reconciled explicitly; every final maintained `test/**/*_test.exs` file must have exactly one manifest entry and three consecutive passing runs. Only then may implementation hand off to the Stop-owned aggregate verification plan. Individual execution does not replace `check` or paid targets, weaken their assertions, authorize retry-until-green, or treat provider nondeterminism as success.

### Repair failures reproduced by the 69-file triple-run audit

The 2026-09-20 audit ran every manifest command three times under deliberate 69-way contention, after which Fable inspected the failing logs and current source. Before the immutable-Candidate sweep, implement these repairs:

1. Align `Kogen.IsolatedCase` parent and child budgets. Untagged tests currently retain ExUnit's 60-second parent timeout while the child may own 120 seconds plus cleanup. Derive the parent budget from child/cleanup budgets, reject contradictory explicit budgets, and retain child output plus exit 124 through the harness-owned timeout path. A blanket timeout increase is not a repair.
2. Separate process launch from readiness. Add an explicit launch marker/budget; begin readiness timing only after launch; retain distinct launch, readiness, and collection outcomes; keep deliberately tiny negative-control deadlines.
3. Make cancellation and cleanup controls real. Give the cancellation probe its readiness variable, prove the descendant is alive immediately before owner cancellation and dead afterward, and never pass because the child crashed first. Overlap awaits use the harness-owned budget.
4. Repair hook-fixture parity. `unified_state_admission_test.exs` includes `environment.py` with `check.sh` and `stop_runner.py`, explicitly exercises restore-marker-set and marker-unset branches, and consumes one canonical hook fixture list.
5. Repair reviewer-rework fixture generation. Its scenario contains the installed `proof` map and passes `Contract.load` plus verification-plan validation in a provider-denied preflight. A shared writer/control prevents any hand-written scenario fixture from omitting current required fields.
6. Make cold-offline supervision and receipts truthful. The test owns the gate process group and terminates it before fixture cleanup; its budget derives from the stage plan; broken output pipes cannot omit a stage; and a receipt cannot say `passed` unless every planned stage completed successfully. Its deliberately Gitless copied tree consumes outer-owner source revision and Candidate identity plus a verified digest of the copied inputs. Controls prove Git-backed binding, Gitless binding, missing-provenance failure, untracked-input invalidation, and preservation of an earlier stage or cleanup failure when binding also fails.
7. Reduce repeated boot work without weakening coverage. Consolidate `shape_task_test` diagnostics around direct production readers with representative end-to-end pre-launch controls. Keep one persistent length-delimited parser per shaping-evaluation driver invocation rather than booting an Elixir parser for every document, retaining exact compiled-path and failure-classification assertions.
8. Derive live commands from declared target ownership, not source-text matches. Ordinal 57 is the plain command `mix test test/kogen/selective_verification_targets_test.exs`. A validator proves each `--only live` entry is an actual live-target owner and every actual live-target owner is flagged.
9. Harden managed-scope contamination handling. `State.validate_scope!/1` remains fail-closed on foreign `plugins/` residue but names the offending entry, likely foreign-CLI origin, and recovery action. Managed shell execution prevents a foreign `codex` binary from silently writing into Kogen's selected scope while compatibility receipts still see the selected `CODEX_HOME`. Live tests continue using the real authenticated scope; fake private credentials are forbidden.
10. Preserve launch causes through Shape/live drivers. Early child exit retains first stderr cause in suite/transport evidence instead of degrading into generic startup/readiness timeout. Scope contamination, authentication failure, invalid fixture, provider failure, and timeout remain distinct.

Every live test has an end-to-end ExUnit timeout of at least 1,200,000 milliseconds (20 minutes). This minimum applies to compatibility, native, helper, cold-offline, general Review, reviewer rework, Shape-to-Build, and shaping-quality tests. Internal launch, readiness, provider, collection, and cleanup phases remain bounded and independently classified, but their combined worst-case plan plus cleanup slack must fit inside the outer live-test budget. A timeout owns and terminates the complete process tree and retains partial output, phase identity, and the initiating cause. Raising a timeout alone cannot satisfy any reproduced repair.

The current `plugins/` residue is external prerequisite state created by foreign audit workers, not evidence about the intended provider behavior. Build must not silently delete or normalize it. Live confirmation starts only from an explicitly validated clean managed scope; contamination fails locally with the actionable diagnostic and no provider inference.

### Repair the three failures from the uncontended sequential sweep

The 2026-09-21 sweep ran all 69 manifest commands sequentially three times against the current Candidate. Sixty-six files passed 3/3. These three files did not and must be repaired before another aggregate verification attempt:

1. `test/kogen/codex_compatibility_test.exs` passed twice in 359 and 343 seconds, then failed in 49 seconds with `interactive_shaping_failed`, marker present, status 1, and cleanup false. In `priv/kogen/codex/compatibility/pty_driver.py`, cleanup stops reading the PTY master while waiting for the session leader. On macOS, unread terminal output can block process exit in terminal drain until the master closes. Drain the master throughout cleanup, hang it up before declaring cleanup timeout or escalating, and treat zero-signal `killpg` EPERM as no signalable live group member while retaining the primary ps/zombie check. Apply the same drain-before-wait ordering to `test/support/terminal_probe.py` and `test/support/codex_login_terminal_driver.py`. A flooding-child offline control must reliably reproduce the old stall and prove cleanup completes quickly independent of the timeout budget; increasing `CLEANUP_SECONDS` alone is forbidden.
2. `test/kogen/live_reviewer_rework_test.exs` failed 3/3 in 4–5 seconds before provider dispatch because its valid grouped Make rule was invisible to two duplicated single-target regex parsers. Create one Makefile target inventory implementation shared by `Kogen.Check` and `Kogen.Build.VerificationPlan`; it recognizes all names on grouped target rules, ignores `.PHONY`-only declarations and variable assignments, and rejects unsupported double-colon or pattern rules explicitly. Generate fixture Makefiles from `priv/kogen/verification_targets.yaml` instead of maintaining divergent hard-coded target lists. Offline positive and omission/phony/assignment negative controls must validate every embedded live fixture before provider use.
3. `test/kogen/live_shape_to_build_test.exs` failed 3/3 in 167–201 seconds after successful paid Shape because the fixture overwrote the copied Makefile with a `check`-only version while retaining a seven-target catalog. Derive this fixture Makefile from the catalog and run `VerificationPlan.load/1` plus plan construction before the paid Build. Tighten proof-selector admission: non-rehearsal selectors must be actual test-pattern files or directories under configured test paths; reject `Makefile`, `lib/**`, and other arbitrary existing files. The Shape probe directive names an acceptable focused test selector or cataloged rehearsal.

The Developer's post-fix order is deterministic. First run every provider-denied focused control for all three live routes and for offline receipt/cold-fixture binding. In particular, `mix test test/kogen/offline_stage_results_test.exs test/kogen/cold_offline_contract_test.exs` must reject the exact historical defect in which receipt settlement calls `git rev-parse HEAD` inside the intentionally Gitless cold copy. No provider-backed command may start while any required focused control fails or lacks its positive and passing-but-wrong case. Then run reviewer-rework three times because it fails cheaply, Shape-to-Build three times after that, and compatibility preparation controls plus live compatibility three times last. A failed run resets that file's streak to zero; any Candidate mutation invalidates all three files' prior streaks and requires all provider-denied focused controls to pass again before another provider call. When all three exact commands have three consecutive passes against the same unchanged Candidate, the Developer stops the turn and submits the structured handoff. The Developer does not run the complete 69-file sweep or aggregate Make targets. The trusted controller/Stop verification phase runs `check`, then `cold-offline`, then paid targets in catalog cost order; no paid Stop target runs unless both offline targets passed on the same Candidate. A focused success cannot authorize publication without that independent complete verification.

### Repair every declaration

For each maintained declaration, implement exactly one source-supported disposition:

- `keep`: a declaration-specific public outcome plus a distinct passing-but-wrong implementation is exercised through the real consumer, and the current test rejects it;
- `rewrite`, `split`, or `repair`: change the relevant test/control and the defective fixture, support, orchestration, prompt, hook, or production code;
- `delete`: name an existing retained test proving equivalent behavior.

Do not infer dispositions, consumers, equivalence keys, or controls from filenames or line numbers. Do not copy one rationale across unrelated declarations. Do not reuse one unchanged file for positive, wrong, and failure/recovery roles. Resolve all 81 passing-wrong obligations and 38 provisional inspections against current source.

### Produce evidence after repairs

After implementation, generate `priv/kogen/test-reliability.yaml` and `priv/kogen/test-reliability-remediation.yaml` from the final Candidate. Validators rediscover declarations, support inputs, consumers, boundaries, targets, guarded paths, and scenarios; compare claimed repair paths with actual changed blobs; and reject:

- the original five-file Candidate;
- the failed 2026-09-20 generated-catalog Candidate;
- all declarations defaulted to `keep`;
- copied generic rationales or controls;
- filename-guessed consumers;
- line/location hashes used as behavioral equivalence;
- unchanged files claimed as repaired implementation;
- one file repeated for all evidence roles;
- inventory-only, planned, deferred, or provisional rows.

These deterministic controls pass before any paid target runs.

## Completion

Completion requires the actual repairs above, declaration-specific behavioral proof for every maintained test, claimed implementation paths matching changed Candidate blobs or explicit preservation proof, focused offline controls, and only the named provider observations from selected paid targets. A large ledger, green catalog validator, or broad list of unchanged paths is not completion.

If the work cannot fit the configured Build allowance, Build fails incomplete. It must not substitute an audit, inventory, recommendation, phased plan, or partial infrastructure patch.

## Non-goals

- No weakening, skipping, quarantining, retry-until-green, longer-timeout-as-fix, or blanket serialization.
- No invented historical flakiness without comparable runs sharing a behavioral equivalence key.
- No claim that offline fixtures establish external provider behavior.
- No unrelated product feature.
