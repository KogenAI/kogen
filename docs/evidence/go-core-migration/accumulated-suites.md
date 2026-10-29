# Accumulated Intent suites on the Go program

## Current external completion, 24 October 2026

The current candidate follows signed caching `828dfa5d`, reconciling the reference
`76109e1a` implementation. Runtime archive `dev+5c71ebe7` has SHA-256
`eaa60cc4383f25180542bf97f572b653a773dbc46538a48f816e519c0b76beee`.

The final compatibility run executed **421 scenarios across 39 maintained contracts**:
405 remain required and 16 are the exact rows already superseded by the migration
contract's caching, open-model and version-2 checkpoint rules. Of the required
cases, 401 passed in that run. Four observers were corrected and passed focused
reruns: two still required Refine's replaced bulk index, one assumed index mode
0644 under a private 077 umask, and one still required the removed private ChatGPT
session header. Complete mandatory/original/proposed bytes, actual focused reads,
index bytes/mode preservation and exact wire controls remain asserted. The entire
compact-context feature, both selective Shape/Refine rows, the mapped deterministic
case and the ChatGPT compatibility case passed; observer mutation controls also
passed. No production Go code changed during those observer corrections.

The whole deterministic run passed specification/model checks, live-helper checks,
and **223 public scenarios / 2970 steps**. Eight Go packages passed its uncached
race run. The verify package exposed one test that assumed KOGEN_NODE was absent
although the installed harness supplies it. That negative fixture now explicitly
clears the binding; the complete verify package passes with race detection and
count=1 under umask 077 and an inherited Node binding (296 test/subtest passes).
The original aggregate run remains recorded as red; these are composable current
proofs on the unchanged runtime, not a claim that its historical exit was zero.

The one-time full migration gate took 3336.8 seconds; its whole deterministic layer
took 516.8 seconds under concurrent local work. These are measured scopes, not
ordinary per-feature promises or permission to repeat all layers after every edit.
Local execution records retain exact input hashes, raw reports, targeted reruns,
review conditions and source authorship. The final commit/install receipt binds
them to the signed source and official package. Linux runtime remains unqualified.

| Current required suite | Scenarios covered |
| --- | ---: |
| all-provider-cache-reuse | 29 |
| approval-card-recovery | 9 |
| bounded-tool-results | 4 |
| build-continuity | 9 |
| build-diagnostic-context | 7 |
| build-unblocking-recovery | 17 |
| bundled-zip-safety | 3 |
| checkout-cli-dx | 10 |
| claude-api-key-provider | 41 |
| clean-candidate-verification | 4 |
| clean-readiness-parity | 9 |
| compact-ack-guidance | 2 |
| compact-shaping-context | 4 |
| deterministic-check-gate | 2 |
| documentation-lookup-evidence | 5 |
| fail-fast-verification | 6 |
| faster-shaping | 34 |
| legacy-usage-coverage | 8 |
| native-image-evidence | 10 |
| opencode-go-subscription | 23 |
| prompt-cache-reuse-and-usage | 4 |
| provider-wait-boundary | 16 |
| reopen-blocked-review | 7 |
| resume-failed-builds | 21 |
| reuse-ready-evidence-v2 | 7 |
| review-refine-working-room | 10 |
| reviewer-style-discipline | 1 |
| shape-context-index | 4 |
| shape-working-context | 9 |
| shape-working-summary | 4 |
| shaping-evidence-quality | 6 |
| shaping-technical-discovery | 9 |
| spec-vocabulary-integrity | 1 |
| staged-intent-builds | 10 |
| supergrok-subscription-20261022 | 5 |
| terminal-protocol-compatibility | 15 |
| terminal-validation-evidence | 3 |
| transient-stream-retry | 33 |
| usable-check-protection | 4 |
| **Total** | **405** |

## Earlier owner runs — historical evidence

Every `.kogen/intents/*` acceptance suite except `go-core-migration`, run one at a time with
`NODE_PATH=$PWD/test/acceptance/node_modules node test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js --strict --require 'features/steps/*.js' .kogen/intents/<slug>/acceptance.feature`
under `mise exec --`, against an archive packaged by `sh packaging/package.sh` (`KOGEN_ARCHIVE` names it).
Final-run archive: `dist/kogen-dev+243fe75c-darwin-arm64.tar.gz`.

Reopen-blocked-review needs a retained Elixir release for its two retained-checkpoint scenarios (see below):
`KOGEN_REOPEN_OLD_BIN=<prefix>/bin/kogen KOGEN_REOPEN_OLD_VERSION='kogen dev\+<hash> '`.

## Results

| Suite | Scenarios | Passed | Failed | Reason |
|---|---|---|---|---|
| build-continuity | 9 | 9 | 0 |  |
| build-diagnostic-context | 7 | 7 | 0 |  |
| bundled-zip-safety | 3 | 3 | 0 |  |
| cache-capability-fallback | 23 | 23 | 0 |  |
| checkout-cli-dx | 10 | 10 | 0 |  |
| clean-candidate-verification | 4 | 4 | 0 |  |
| clean-readiness-parity | 9 | 9 | 0 |  |
| compact-ack-guidance | 2 | 2 | 0 |  |
| compact-shaping-context | 4 | 4 | 0 |  |
| fail-fast-verification | 6 | 6 | 0 |  |
| faster-shaping | 34 | 34 | 0 |  |
| legacy-usage-coverage | 8 | 8 | 0 |  |
| native-image-evidence | 12 | 12 | 0 |  |
| prompt-cache-reuse-and-usage | 9 | 9 | 0 |  |
| provider-wait-boundary | 16 | 16 | 0 |  |
| reopen-blocked-review | 9 | 9 | 0 | two retained scenarios use a stand-in Elixir release (see below) |
| resume-failed-builds | 21 | 21 | 0 |  |
| reuse-ready-evidence-v2 | 7 | 7 | 0 |  |
| reviewer-style-discipline | 1 | 1 | 0 |  |
| shaping-evidence-quality | 6 | 6 | 0 |  |
| spec-vocabulary-integrity | 1 | 1 | 0 | digest/scenario-count pins adapted (see below) |
| terminal-protocol-compatibility | 15 | 15 | 0 |  |
| terminal-validation-evidence | 3 | 3 | 0 |  |
| usable-check-protection | 4 | 4 | 0 |  |
| supergrok-subscription-20261022 | 5 | 0 | 5 | all five fail on engine defects 1 and 2 below (user-agent `kogen/`, no `Connection` header); everything else those scenarios check passes (credential file, pacing, replay, refresh, usage) |
| **total** | 228 | 223 | 5 | |


## Engine defects found (user-visible differences from the Elixir Kogen)

1. SuperGrok `User-Agent` is `kogen/` (no version). Scenario(s): supergrok-subscription-20261022, "device login ...",
   "refused logins", "workflow", "limits" (identity_honest, wire_exact, refusals, limits). Expected `kogen/<second word of lib/VERSION>`
   (for example `kogen/dev+f05b2284`); actual `kogen/`. Cause: `provider.Client.userAgent()` (cli/provider/client.go:85) takes the second
   word of `Client.Version`, but `cli/native.go:47` and `cli/engine.go:32` pass `versionID(versionLine(root))`, which is already
   the single word, so the lookup fails; `cli/shape/shape.go:141` and `cli/shape/refine.go:249` pass `""`. Elixir behaviour:
   `main-cur/lib/kogen/super_grok.ex` / `chatgpt.ex` send `kogen/<version id>` on every SuperGrok device, token and Responses request.
2. The provider HTTP requests carry no `Connection` header (Elixir's `:httpc` sent one). Scenario(s): supergrok-subscription
   ("chatgpt_headers_same", "wire_exact", `--control good`). The suites pin the exact header-name set
   `accept, authorization, connection, content-length, content-type, host` (plus `user-agent` for SuperGrok); the Go client sends the same
   set without `connection`. Elixir code: `main-cur/lib/kogen/chatgpt.ex` `stream_request/3` (httpc defaults). Low severity, but a provider
   request difference.

Both were left visible (the driver was not changed to hide them). The five SuperGrok scenarios fail on them.

## Pre-existing staleness (the old drivers fail the same way on the Elixir main)

These were confirmed by running the (fixed) drivers against an Elixir archive built from `main-cur`; they are not Go defects and are
fixed in the drivers:

- Fixture Intents lacked the now-required `## Source comparison` section (readiness lint): reuse-ready-evidence-v2,
  clean-candidate-verification, clean-readiness-parity, compact-ack-guidance, compact-shaping-context, fail-fast-verification, faster-shaping,
  shaping-evidence-quality, usable-check-protection.
- Provider requests carry the first message as typed text blocks and the policy as a developer message (for models with prompt
  caching); drivers read `content` strings only: build-diagnostic-context, compact-shaping-context, faster-shaping, reviewer-style-discipline,
  usable-check-protection.
- `known_usage` now has the cache-write categories (`null` when unreported): provider-wait-boundary, terminal-protocol-compatibility,
  terminal-validation-evidence compare only the reported categories.
- Failed provider attempts record `error: "provider_failure"` only, not structured predicates: terminal-validation-evidence derives each
  response's predicates by sending that response on its own as a final rejected attempt.
- Checks run in a clean copy of the candidate and `acceptance` runs before checks (fail fast): resume-failed-builds keeps the check log outside
  the checkout and lets the acceptance step accept the `broken` text so the check still runs on every state.
- `effective_model` / `effective_effort` live in the provider attempt record, not the call's top-level fields (faster-shaping; its fake workers now
  report the served model).
- Shaped provenance is bound to the contract, so a changed baseline refuses before readiness: reuse-ready-evidence-v2 "baseline" removes provenance.
- `docs/testing-rules.md` now says "automatic" in both Shape and Refine: compact-shaping-context dropped that one clause.
- `.kogen/local/` must be ignored for readiness not to see changed files: bundled-zip-safety fixture adds a `.gitignore`.
- Checkpoint version constants: build-diagnostic-context compares versions to the original checkpoint's version (Elixir main writes 3; the Go program
  writes 4); supergrok legacy now expects 4.

## Contract tension to rule on (not an engine defect)

- spec-vocabulary-integrity pins `spec/check.sh` by SHA-256 and by `scenarios 146`. The migration legitimately changed `spec/check.sh` (two
  `CoreCrash` lines became `InternalError`) and added scenarios. The step accepts the migrated digest only after checking that the file equals the
  pinned original apart from that rename, and treats `scenarios N` as a minimum (`requirements 102` stays exact). The feature file is untouched.
- reopen-blocked-review "Reopen a real retained signed C3 checkpoint" needs `<home>/Areas/Kogen/studio-work/kogen-dev/failfast-c3ee2a8e/bin/kogen`,
  which is not on this machine. The step honours `KOGEN_REOPEN_OLD_BIN` (already supported) and, new, `KOGEN_REOPEN_OLD_VERSION`; the two scenarios were run with an
  Elixir release built from `main-cur` standing in for the retained executable (the Go program resumed its version-3 checkpoint in both modes).
  Without that variable they fail with "retained C3 qualification input missing".
- `--retained-evidence` checks of native-image-evidence and supergrok read files under `<home>/Areas/Kogen/studio-work/...`, absent here; they are
  evidence commands, not acceptance scenarios, and were not run.

## Driver changes

All new shared code is `features/steps/go_driver_support.js` (no steps): installs the archive into a private prefix, a scripted local provider
(the old `FakeProvider`), project/run/start helpers, and `goDriver`, a tiny Go program in a module outside the repository that replaces `kogen` by `<repo>/cli`
(used only where no user-visible form exists: `build.Diagnostic.Validate`, `agent.Tools`/`ReplayItem`/`Measure`, `provider.Client.Respond` with `shape.Evidence`,
`shape.BuildContextIndex`, `project.ParseConfig`, synthetic checkpoints via `build.Run.PublishCheckpoint`).

Rewritten from Elixir ExUnit/`mix run` drivers to Node (installed `kogen`, files, fake provider): build-continuity, build-diagnostic-context, checkout-cli-dx,
clean-candidate-verification, clean-readiness-parity, compact-ack-guidance, fail-fast-verification, shaping-evidence-quality, supergrok-subscription (fake server and
device reference client in Node), reviewer-style-discipline, prompt-cache-usage (native modes), terminal-protocol-compatibility (native modes), terminal-validation-evidence (native mode).
Rewritten to a Go driver for the internal call: cache-capability-fallback, provider-wait-boundary, native-image-evidence (control and validation), compact-shaping-context (renderer),
build-continuity (control, measure), build-diagnostic-context (protocol mode), supergrok (control, configuration facts), terminal-protocol/validation (HTTP stream modes).
Packaging/ERL_FLAGS/core wrapper removed only: faster-shaping, resume-failed-builds, reopen-blocked-review, reuse-ready-evidence-v2.
Unchanged: legacy-usage-coverage, usable-check-protection (typed-block text and Source comparison only).

Mode adaptations (no separate core exists): checkout-cli-dx `core-crash` terminates the one program with SIGTERM (exit 143) and asserts the same stopped-owner facts;
resume-failed-builds and the like kill the program's process group instead of the core; build-diagnostic-context `protocol` runs the typed validator in Go instead of
bridge frames (wrong-JSON-shape cases are unrepresentable in the typed API and count as rejected).
