# Clarify compact readiness acknowledgements

Slug: compact-ack-guidance
Model: not applicable — guidance and schema alignment change no protocol or state transitions
Acceptance:
- .kogen/intents/compact-ack-guidance/acceptance.feature
- features/steps/compact_ack_guidance_steps.js

Repair KOGEN-011 on source baseline f3ff1070d37a023f4cc1163ac1a227f1e53a497b. Replace invitations to resubmit the unchanged complete/cumulative candidate with concise shared Shape/Refine guidance: after inspecting legitimate missing-feature red, submit the smallest eligible owned artifact with its exact current candidate bytes, including previously proposed corrections. Omitted well-formed proposals remain retained; publication and acknowledgement still concern the exact complete package. Do not encourage large unchanged prose/helper retransmission or restoration of original disk bytes. A nonempty files array remains mandatory; when only one eligible large artifact exists, submit that entire artifact.

Apply the shared guidance to emitted Shape and Refine prompts/tool descriptions and readiness acknowledgement feedback in lib/kogen/shape.ex, lib/kogen/refine.ex and lib/kogen/readiness.ex. Explicitly advertise minItems: 1 for both files-array schemas, matching existing runtime rejection of empty arrays. Align active README.md, docs/configuration.md and spec/prose/02-shaping.md (SHP-4/8/11), including Refine's misleading changed-files-only wording as it applies to acknowledgements. Keep this concise; preserve intentional original-content reversion for actual edits, ownership restrictions, proposal accumulation, formatter behavior and all substantive readiness semantics.

No new envelope, patch/reference tool, empty-array acceptance, cache, retrieval system, framework, planner/critic, settings/model/default adoption, path normalization, autoapproval or authority/check changes. Changed complete candidates still receive fresh validation; exact hash/HEAD/full-baseline acknowledgement, safety checks, approval revocation and explicit approval remain intact. Operation chronology/accounting belongs to external evidence, not this package. This package ends at native readiness; exact-hash delegated approval, normal Build/review/final verification and focused deterministic installed acknowledgement/schema qualification after signed packaging follow separately. No provider-speed benchmark or duplicate broad suite outside native gates.

## Decisions
- Recommend the smallest eligible owned artifact's exact current candidate whole body for legitimate unchanged-red acknowledgement, retaining every omitted proposal and correction; one eligible large artifact still requires its whole body. (source: request)
- Keep nonempty whole-file submissions and current readiness/approval semantics; advertise files minItems: 1 in both tools. (source: request)
- Share concise guidance across Shape, Refine and readiness feedback and align matching active documentation without enlarging protocol authority. (source: request)

## Tests
- Emitted Shape/Refine guidance and readiness feedback explain smallest-artifact current-candidate acknowledgement and retained corrections: independent installed CLI acceptance captures real provider requests and feedback for both operations (regression)
- Both advertised files schemas require at least one entry and runtime still rejects empty arrays: acceptance captures minItems and submits an empty array before valid proposals (scenario)
- Small unchanged acknowledgement retains earlier helper corrections and the exact complete package without another readiness execution: acceptance submits a corrected helper, then only the smaller feature, and checks every baseline byte, evidence hash/HEAD/baseline and execution count for Shape and Refine (regression)
- Unsafe mixed submissions contribute nothing, while changed candidates receive fresh checks and approval remains explicit: acceptance poisons an unsafe mixed payload before correcting the helper and checks final bytes, two candidate executions and absent approval (integration)
- Stale HEAD/hash/baseline cannot acknowledge earlier observations and Refine preserves frozen publication safety: retain readiness_observations_test.exs changed-HEAD coverage and refinement_test.exs stale/unsafe/mutation regressions, plus existing shaping/refinement declaration and topology checks (existing)

## Feasibility
- Existing installed integration helpers create an approved fixture with an eligible untracked owned step, usable without new infrastructure. (probe 1: exit 0, 28.2 s)
