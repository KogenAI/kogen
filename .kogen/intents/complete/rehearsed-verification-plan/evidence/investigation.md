# Shaping investigation

Baseline: clean `main` at `05133eff307ece43794d2cfc02e227ee119970eb`. The superseded `split-live-verification-targets` Draft directory exists but contains no files, so it supplied no inheritable contract text.

## Observed source boundaries

- `lib/kogen/build/contract.ex` currently flattens `verified_by` in scenario order and validates only declared Make target names; it has no cost, dependency, rehearsal, or proof-selector model.
- `lib/kogen/build/verification.ex` freezes `check` followed by de-duplicated supplied targets in context. `.codex/hooks/stop_runner.py` consumes that order serially, short-circuits on the first failure, and binds receipts to Candidate/session/attempt/cycle. The hook can remain unchanged if Build freezes the new order before context creation.
- `lib/kogen/verification_policy.ex` unconditionally adds `live` to Developer policy even when scenarios do not select it. `.codex/hooks/verification_policy.py` blocks configured Make goals and direct Stop invocation only; it permits underlying Mix commands. A new fail-closed scoped-readiness classifier cannot be obtained from prompt wording, and registering Candidate-resident policy elsewhere would not establish immutable authority. The Draft therefore defers that mechanical enforcement instead of adding a hook.
- `scripts/check/offline.py` already starts its stage list with `mix format --check-formatted` and never formats the Candidate. It currently runs full compile, Credo, and non-live tests after preparation.
- `Makefile` declares `check`, narrow but multi-owner `live`, `live-shaping-quality`, `live-native`, and `cold-offline`. `test/kogen/selective_verification_targets_test.exs` owns the source-visible target matrix. `live_shape_to_build_test.exs` contains separate `Kogen.LiveShapeToBuildTest` and `Kogen.LiveReviewerReworkTest` modules, while `live_test.exs` owns the independent semantic Reviewer challenge; these map directly to the three Shaper-selected replacement targets.
- Existing useful production-path controls include `verification_ownership_lifecycle_test.exs`, `selective_verification_targets_test.exs`, `codex_compatibility_preparation_test.exs`, `live_native_receipt_audit_test.exs`, scenario contract/lifecycle/tracking suites, and the Shaping evaluation's provider-denied driver rehearsal.

## Historical challenge

The retained failed Build ran `check` first in all three cycles. Cycles one and two then failed within `live-native` for different deterministic/fixture-facing reasons; cycle three passed `live-native` and failed `live` because the receipt audit expected one Developer capture but observed launch plus repair resume. Candidate IDs changed between cycles. A superficial repeated-error implementation that compares only target name would conflate distinct failures; a raw-output comparison would miss normalized repeats and grow without bound.

The clean-main investigation established that the capture-count failure was Candidate-specific behavior drift, not a clean-main defect. The Draft therefore requires a provider-denied launch-plus-repair disconfirming fixture and source-bound consumer path, not a hard-coded change from one expected capture to two.

## Scope reconciliation

The requested feature is large but coherent because all four scenarios install and consume one future-Build verification plan. Controller-owned execution, Stop removal, worktrees, containment, probabilistic triage, retry redesign, provider recovery, and immutable scoped-command enforcement remain separate roadmap Intents. The Shaper resolved target naming with no aggregate: retire `live`, split its three owners, and require explicit catalog expansion for any complete-set controller operation.

Current Git source can supply a controller-owned guarded-path comparison after the Developer invocation: `Kogen.Git.candidate_id/0` already uses a private index and rejects index-blinding flags, while raw NUL-delimited Git diffs can preserve status, modes, and both rename paths. Current source cannot safely enforce a scoped readiness allowlist during the Developer turn because the registered policy path resolves inside the shared Candidate checkout. The contract now distinguishes those boundaries explicitly.
