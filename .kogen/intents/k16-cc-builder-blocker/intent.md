# Let Claude Code builders report a blocker

Slug: k16-cc-builder-blocker
Model: not applicable — the change is protocol wiring between an adapter and the Build; the existing Build state machine is reused unchanged.
Acceptance:
- .kogen/intents/k16-cc-builder-blocker/acceptance.feature
- features/steps/k16_cc_builder_blocker_steps.js
- features/steps/k16_cc_builder_blocker_driver.go

A Claude Code builder can stop a Build with the same BUILDER-REPORTED `candidate/build_blocked` result the native builder produces with `report_blocker`, so `kogen intent recover` → Refine → fresh approval is available instead of burning rounds on a protected-fixture defect.

Channel. The Build role of the Claude Code executor now runs with a `--json-schema` on every round (as Shape and Review already do). The schema is an object with optional `summary` (string) and optional `blocker` (object with required `paths` (array of strings), `reason` (string), `evidence` (string), no other properties); `additionalProperties` false. The final success result's `structured_output` is the channel. A finish without `structured_output`, or without a `blocker` key (or `blocker: null`), is exactly today's finish: the claim is the result text. When the Build role's `structured_output` has a non-null `blocker`, the adapter returns `Ending: executor.EndBlocker`, the bounded result text as `Claim`, and `Blocker: &executor.BlockerClaim{Paths, Reason, Evidence}`; a blocker object that does not decode into exactly those typed fields (wrong types, missing or extra keys) is returned as an empty `BlockerClaim`, which Kogen refuses. Shape and Review roles are unchanged and never produce EndBlocker. The Claude Code descriptor sets `Capabilities.Blocker` and the Build role's `RoleCapabilities.Blocker` to true; Shape and Review stay false.

Build side (cli/build). `afterExternalRound` accepts `EndBlocker` only from an executor whose descriptor declares Blocker for the build role; otherwise it keeps today's `executor/protocol` failure. For a declaring executor the claim is turned into the native `report_blocker` arguments (`paths`, `reason`, `evidence`) and goes through the SAME code as native: the shared validation (`validBlocker`: nonempty unique paths all in the current protected baseline, nonblank reason and evidence), the `BaselineIntact` and `headIntact` checks, `b.Blocker` with classification `BUILDER-REPORTED`, `Track`, the `builder_blocker` event, and the same `candidate/build_blocked` error with the same lines. Factor the post-validation part of `reportBlocker` out so native and external share it; native behaviour and messages do not change. An invalid claim (for example a non-protected path) is refused as native refuses it: nothing is recorded, nothing is granted, the round is treated as an ordinary finish claim (fixers, verification), and the feedback sent to the next round starts with the native message `invalid blocker: supply exactly nonempty unique current protected paths, reason and observed evidence strings; no write permission is granted; continue ordinary implementation repairs`. HEAD moved or protected bytes changed is already refused by the guarded round (`candidate/head_moved`, `candidate/baseline_changed`) before the claim is considered. The stop is checkpointed like the native one, so `kogen intent recover <id> --output <dir>` works on it unchanged. No new round, retry or limit; the round cap still applies.

Constraints. `claudecode.Constraints` (build role only) gains the native builder prompt's blocker words (cli/agent/prompts/builder.md), with `report_blocker` replaced by the `blocker` field of the structured final result: when observed evidence demonstrates that current protected files contradict the approved behavior or contain a fixture defect, report a blocker with their exact protected paths, a concrete reason and observed command/step/error evidence; do not change production semantics solely to accommodate a demonstrated bad fixture; a valid report stops as BUILDER-REPORTED build_blocked with candidate/index/approval preserved, is not independently proven and grants no protected edits, automatic refinement or approval; plain blocked text does not stop the Build. The sentences quoted in the acceptance steps must appear verbatim. Shape and Review constraints do not change.

Must stay: native route unchanged; conformance scripts of other executors unchanged; Shape and Review roles cannot report blockers. Existing tests that assert the Build argv has no `--json-schema` (claudecode lineup_test "build keeps its claim and no schema", adapter_test argv expectations) and that the Claude descriptor has `Blocker: false` for build, and the build test that an EndBlocker from a non-declaring executor is a protocol failure (that last one must stay true for a descriptor with Blocker false), are updated for the changed behaviour.

## Decisions
- The blocker travels in the Build final result's structured_output via a `--json-schema`, with the same three fields as `report_blocker` (source: request)
- Invalid claims are refused like native: feedback, no stop, no grant (source: request)
- A malformed blocker object is carried as an empty claim that Kogen refuses (source: request)

## Source comparison
- Claude Code executor supports the blocker ending for build with paths, reason, evidence and native validation, descriptor Blocker true: addressed (intent: Channel; scenarios 1, 5).
- executor_external.go accepts EndBlocker from a declaring executor with the native result and recover record; non-declaring keeps protocol failure: addressed (Build side; scenarios 1, 4).
- Constraints use the native builder-prompt words, grant no edits, plain text does not stop: addressed, with `report_blocker` adapted to the structured field (Constraints; scenario 5).
- Native route, rounds/limits, review/shape roles, other conformance scripts unchanged: addressed (Must stay; scenario 5 checks shape/review descriptors).
- Acceptance: protected step file stops with candidate, index, approval preserved and recover works (scenario 1); non-protected path or moved HEAD refused (scenarios 2, 3); Blocker false still protocol (scenario 4); all configured checks pass (the Build's normal gate). Host safety: the scenarios use only a shell fake `claude`, never the real binary, no process killing.

## Tests
- Adapter turns a Build structured_output blocker into EndBlocker with the claim, passes `--json-schema` for build, leaves plain finish unchanged, and Shape/Review never yield EndBlocker: update cli/executor/claudecode adapter_test.go and lineup_test.go (unit)
- Descriptor declares Blocker for the Claude build role and not shape/review: update lineup_test.go/adapter_test.go descriptor expectations (unit)
- Constraints carry the native wording: add a claudecode test (unit)
- Build accepts EndBlocker from a declaring executor with the native result, refuses non-protected paths, HEAD moved and changed protected bytes, and recover works: add cli/build tests with the fake executor declaring Blocker (integration)
- A non-declaring executor still gets executor/protocol: keep TestExternalUnsupportedEndingsAreProtocolFailures for a descriptor with Blocker false (existing)
- End to end through the real adapter and a fake claude: the acceptance scenarios (scenario)

## Feasibility
- evidence: {"id":"k16-observer","kind":"observer","inputs":["features/steps/k16_cc_builder_blocker_driver.go"],"observers":["features/steps/k16_cc_builder_blocker_steps.js","features/steps/k16_cc_builder_blocker_driver.go"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k16_cc_builder_blocker_steps.js --control good","exit":0,"output":"k16 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k16_cc_builder_blocker_steps.js --control bad","exit":1,"output":"k16 observer rejected bad fixtures\n"}]}
