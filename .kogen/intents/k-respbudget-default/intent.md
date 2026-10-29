# Lower provider response budgets to ten minutes

Slug: k-respbudget-default
Model: not applicable — this wires an existing budget without changing its state machine
Acceptance:
- .kogen/intents/k-respbudget-default/acceptance.feature
- features/steps/k_pin_knobs_steps.js

Set `research.Current.Client.ResponseBudget` in `cli/internal/research/research.go` to `10 * time.Minute`, retaining one tunable source line through the landed K-PIN-KNOBS struct. Cover every provider-backed Kogen entry: Shape, Refine, native Build, independent Review, provider probes, associated workers and bootstrap calls. Record the effective budget once per run, including unavailable runs. No CLI, environment or project.yaml setting is added. No other timeout, limit, retry policy, provider route or request bytes change.

Kogen-visible expiry must name `10 minutes`, retaining provider/unavailable classification and existing retry behavior. The pinned library currently renders explicit budgets as `10m0s`; normalize this at the Kogen diagnostic boundary without changing other durations or the library's independent thirty-minute default. Preserve explicit all-zero compatibility coverage but update assertions requiring the production source to stay entirely zero.

## Decisions
- Share ten minutes across all provider-backed roles through one research-tunable line. (source: request)
- Log once per run and name `10 minutes` on expiry without changing retry policy. (source: request)
- Installed-sha research confirmation remains a separate after-install gate. (source: request)

## Source comparison
- Addressed: What to build and Depends on use the landed `research.Current.Client.ResponseBudget`; this complete contract covers shape, refine, build, review and provider probes, not just one role.
- Addressed: Must stay and Acceptance require actual client observations, stalled-provider expiry, retry, log cardinality and byte-identical requests in the executable contract test described below; no CLI/project.yaml key or other timeout/limit/retry change is authorized.
- Addressed: Why cites C2 at `outputs/_internal/LOOP-KNOBS-STEP0.md`, 28 Oct 2026: 23,368 completed responses, max 274.8 s, review p99 128 s; three stalls at 847–901 s retried in 4–9 s. These are supplied rationale, not independently verified results or new thresholds. This lowers thirty minutes to ten minutes only.
- Addressed: Gate (research, after install) requires a confirmation on the installed sha with no provider/unavailable endings above baseline. Deterministic acceptance does not claim this research gate passed; retain this separate handoff after install, without paid sweeps.
- Addressed: Host safety governs tests and implementation: temp fixture directories only, no synthetic CPU load, never stop processes by name or pattern, terminate only owned pids.
- Superseded: current zero-valued production budget selects thirty minutes and explicit budgets render Go syntax. Only Kogen's production default and ten-minute visible expiry diagnostic change; library zero/default behavior stays intact.
- Omitted: no product behavior; historical research is rationale rather than fabricated executable measurement.

The executable gate is a new `TestResponseBudgetDefaultContract` in package main under `cli`. Reuse current fixtures in `cli/loop_knobs_test.go`, `cli/shape/loop_knobs_test.go`, `cli/build/loop_knobs_test.go` and pinned provider budget tests. Package-local supporting tests may observe real clients; the main gate must execute those tests with exact execution/pass checks so missing tests cannot silently pass. Test every role without replacing the production default. Exercise a real Kogen entry with a local stalled fake provider and the existing controllable clock, advancing beyond ten minutes rather than waiting ten wall-clock minutes; then answer the existing retry. Preserve retry termination rules, and do not invent retry on entries that currently do not retry. Observe unavailable classification, the ten-minute diagnostic, retry outcome and once-per-run logging for both successful and unavailable runs, including repeated provider calls. Compare serialized requests for fixed inputs under zero/default and ten-minute configurations and check other research values stay unchanged. Distinguish the old default and a Shape-only patch. No production abstraction solely for mocking.

## Tests
- Every provider-backed role receives ten minutes: add TestResponseBudgetDefaultContract with real role client observations (integration)
- Effective budget appears once per run: add success and unavailable run-log assertions to TestResponseBudgetDefaultContract (integration)
- Stalls expire unavailable naming ten minutes and preserve retry: add fake-clock local stalled-provider and successful retry coverage to TestResponseBudgetDefaultContract (integration)
- Requests and all other settings remain unchanged: compare fixed serialized requests and other settings in TestResponseBudgetDefaultContract and preserve zero compatibility coverage (regression)
- All configured checks pass: run unchanged format, compile, test, go-test, spec and cucumber checks (existing)

## Feasibility
- Landed K-PIN-KNOBS source, ApplyClient and role wiring/tests were inspected. The local pinned provider accepts explicit budgets from one second to thirty minutes; no external protocol change is involved.
- Command availability probe: `cd cli && go test -race -count=1 -v -run '^TestResponseBudgetDefaultContract$' .` exited 0 in 3.7 seconds, reporting `testing: warning: no tests to run`. The existing acceptance step requires the named PASS marker, so this is not feature success.
