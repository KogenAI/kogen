# Reuse safely closed Build baselines

Slug: k-baseline-per-base
Model: .kogen/intents/k-baseline-per-base/model.qnt invariants=SafeReuse seed=1 samples=100 steps=20
Acceptance:
- .kogen/intents/k-baseline-per-base/acceptance.feature
- features/steps/baseline_per_base_steps.js

Replace unconditional cross-Build repetition of eligible starting-tree checks with machine-local reuse. This is deliberately a limited safe first delivery, not a promise to accelerate arbitrary shell suites. Only the exact command `:` is eligible: execute this closed no-op directly in Kogen (status 0, empty output, no filesystem, environment, clock, shell or external executable reads). This is a real first evaluation, not a prepopulated pass. Do not classify other commands, including whitespace variants, shell wrappers, scripts, `true`, or compound commands, as closed. Execute all other configured commands normally on every Build. Keep normal final verification fresh; this cache is for starting baselines only. No new command, flag, configuration field or option.

Cache identity includes repository identity shared by its worktrees, starting content identity, complete ordered configured check names and command bytes, the Kogen executable identity and inherited environment identity. Hash sensitive inputs without retaining their values. Include tracked and untracked content, including ignored content visible to checks, path names, modes and symlink targets; do not follow symlinks to claim closure. Git administrative data and Kogen's own private run/cache custody are excluded because the eligible evaluator cannot observe them. If identity cannot be established consistently, execute fresh and do not publish reusable evidence. A one-byte source change must miss even though this evaluator does not read source. Conservative misses are allowed, but ordinary second Builds sharing a base and unchanged environment must hit. Internal per-process/run bookkeeping is not inherited environment drift.

Store completed baseline evidence privately outside versioned content, shared across worktrees of the same repository on this machine, with atomic publication. A missing, malformed, partial or incompatible entry is a miss. Reuse only completed passing eligible results for an exact identity. Never claim cache evidence for an execution error or interruption. Parallel readers must never consume incomplete evidence; duplicate fresh evaluation during a race is permitted. Do not persist raw secret environment values.

Retain each check's actual name, command, status and output in the existing CheckBaseline and before/after comparison, in configured order. Add a `baseline_reuse` run event for each hit with check name, identity digest and original evidence reference; a hit must not be represented as a new command execution. Normal command and command_result events remain evidence of actual execution/evaluation. A known-failing arbitrary-shell baseline remains a recorded Build input exactly as in 029e83b, never a waiver and never silently green. This first eligibility set contains no failing checks; failures therefore run fresh. Setup, acceptance/model, fixers, independent review, approval, resume safety and exact-final-tree verification are not cached or weakened.

## Decisions
- Keep the agreed CLI unchanged; no command, flag or option (source: request)
- Unknown result-affecting inputs force real execution; do not substitute a fingerprint of arbitrary shell dependencies for proof of closure (source: answer 1)
- Demonstrate reuse with an eligible deterministic fixture; existing Kogen/Studio arbitrary-shell suites may receive no speedup in this delivery (source: answer 1)

## Source comparison
- addressed: request Need and Acceptance evidence through the closed-evaluator eligibility, exact-content identity, durable hit event and shipped-binary three-Build regression below. Same main, second hit, and third one-byte miss remain mandatory, not a helper-only demonstration.
- addressed: request unknown tree/untracked, command, toolchain and environment differences through conservative complete identity plus a closed evaluator. All external toolchains, services, time and undeclared external data remain ineligible, not assumed stable.
- addressed: request 029e83b failing baseline and nothing-else-changes requirements through preserved baseline rows, fresh failures and unchanged final gates.
- superseded: the implied acceleration of the cited real suites is explicitly relaxed by the latest answer 1; the absolute safety boundary from the earlier answer 1 remains. K-BASELINEONCE is shelved, not a required within-Build cache or prohibition on this cross-Build cache.
- addressed as historical motivation, not performance thresholds: main d42f6cc; k-silent-progress, k-silence-revert, k-review-resume; Studio s-pycache, s-auth-harden, s-migration-unique; 470–499 s and 696–1158 s mix test; 16–39 min duplicate work; 9–26% intra-Build cost; research profile ~/Scratch.noindex/kogen-lanes-private/codex-helpers/buildprof/last.md and 4.8 ks versus 0 s. No private profile access or reproduction of historical timings is required. Executable acceptance reproduces the three-Build shape rather than asserting those historical numbers.
- omitted: no requested behavior is intentionally omitted beyond the explicitly accepted limited eligibility. No changes to provider caching, paused work, unrelated Studio corrections or protected configuration.

## Tests
- Same-base reuse followed by one-byte invalidation: TestBaselinePerBaseInstalled runs three real Builds through the packaged installed binary with deterministic provider fixtures (regression)
- Complete input identity and unknown-input fallback: TestBaselinePerBaseIdentity exercises real temporary Git worktrees, tracked/untracked/ignored changes, command bytes, environment and executable identity (integration)
- Durable evidence and partial-publication safety: TestBaselinePerBaseCustody exercises same-machine cross-process/worktree reuse and incomplete/malformed cache misses (integration)
- Failing baselines and final verification remain unchanged: TestBaselinePerBaseFailures preserves failed status/output/order and demonstrates fresh final gates despite a baseline hit (integration)
- Exact closed-command eligibility and no external dependencies: TestBaselinePerBaseEligibility tests `:` versus wrappers, whitespace, true, scripts and time/service-dependent commands (unit)

## Feasibility
- The small cache-state model typechecked and ran 100 samples of 20 steps with SafeReuse, seed 1, TypeScript backend (probe: exit 0, 0.4 s). An earlier parenthesization error was corrected before this result. A preliminary nonexistent-file invocation proved nothing.
- Documentation searches returned irrelevant results and did not discover a relevant source. Direct Open Group Issue 8 retrieval at https://pubs.opengroup.org/onlinepubs/9799919799/utilities/colon.html returned a special-builtins redirect; retrieval of https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html returned partial shell-language material, not a complete closure proof. These untrusted responses do not establish arbitrary-shell hermeticity. Eligibility instead uses the explicitly specified internal closed evaluator, not a claim about installed shells.
