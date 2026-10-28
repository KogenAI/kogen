# Configure Shape submission retries internally

Slug: k-shaperetry
Model: .kogen/intents/k-shaperetry/model.qnt invariants=Bounded seed=1 samples=100 steps=20
Acceptance:
- .kogen/intents/k-shaperetry/acceptance.feature
- features/steps/k_shaperetry_steps.js

Add an internal integer SubmissionRetryLimit field to ShapeInput and RefineInput. Zero/unset retains 3; positive values select the invalid-submission budget. Treat negative internal values as default too, without adding a public validation surface. Apply the effective limit to native and external Shape and Refine. Count precisely the same invalid/not-ready submissions as today: readiness acknowledgment and other limits must not change. All existing last-attempt fallbacks (K25c/K26c/K26d/K26e, including every priorInvalid >= 2 condition) use effective limit minus one. Refusal copy substitutes the effective number, retaining exact default copy.

Record one shaping evidence event `submission_retry_limit` with integer `limit` when the effective limit differs from 3, for Shape and Refine. Explicit 3 and zero/unset emit no new event. No CLI, project.yaml, provider, round-budget or other limit changes. Unset behavior, messages and events remain byte-identical apart from existing nondeterministic metadata. Preserve publication, accumulated proposals, refusal preservation and readiness rules.

Research motivation: seed 1, 28 Oct night, MECHANISMS shape-retry-limit reported 20/26 refusals with both checks on and wants limits 1, 3 and 5, measuring refusal rate then cost. This change supplies the knob, not an experiment, paid calls or measurement system. Shared-host safety: temp directories only; never stop processes by name/pattern, only owned PIDs; no synthetic CPU load.

## Decisions
- Keep the option internal to Shape/Refine input, with default 3 and no CLI/yaml setting. (source: request)
- Preserve all other limits and unset behavior. (source: request)

## Source comparison
- Addressed: request K-SHAPERETRY internal option, zero/unset 3, last-attempt fallbacks and actual-number refusal copy are specified above and exercised by the named Go integration contracts below.
- Addressed: request nondefault shaping event requirement is settled as submission_retry_limit with limit; explicit default has no event.
- Addressed: supplied unset twice-invalid-then-valid, three-invalid refusal, limit 1 fallback/refusal and limit 5 four-invalid-then-valid examples are acceptance rows. Refine and external routes are included, not omitted.
- Addressed: all configured checks remain required, with no CLI/yaml or other-budget changes; host safety and research context retained above. No requested behavior is superseded or intentionally omitted.

## Tests
- Default retries preserve messages, events and publication: TestSubmissionRetryDefault through real Shape with fake provider, two invalid then valid, and three invalid refusal (integration)
- Limit 1 makes the first attempt final and refuses after one invalid submission: TestSubmissionRetryOne including K25c/K26c/K26d/K26e fallback outcomes (integration)
- Limit 5 permits four invalid then valid and refuses on fifth invalid with actual-number copy: TestSubmissionRetryFive (integration)
- Refine uses the effective budget and preserves originals on refusal: TestSubmissionRetryRefine with 0, 1, 3 and 5, publication and refusal cases (integration)
- External executors share the budget: TestSubmissionRetryExternal for Shape and Refine (integration)
- Only nondefault effective limits add the specified evidence event and no other limits/settings change: TestSubmissionRetryEvidence including unset, zero, explicit 3, 1 and 5 (integration)

Implement these tests in cli/shape using existing local fixtures and fake provider/executor infrastructure. They must call real Shape/Refine entry points and assert requests/submissions consumed, published bytes or preserved originals, structured refusal and exact copy, and parsed events. Names are acceptance interfaces, not permission for empty tests. Retain existing useful tests. Run all configured checks before delivery.

## Feasibility
- Quint counter model typechecked successfully in scratch (exit 0, 0.7 s); first attempted absolute scratch path was rejected before execution.
- evidence: {"id":"observer","kind":"observer","inputs":["features/steps/k_shaperetry_steps.js"],"observers":["features/steps/k_shaperetry_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_shaperetry_steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_shaperetry_steps.js bad","exit":1,"output":"rejected\n"}]}
