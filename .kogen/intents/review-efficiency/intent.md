# Batch review rounds and clarify findings errors

Slug: review-efficiency
Model: not applicable — prompt copy and stateless rejection diagnostics change; the existing review retry state machine is unchanged
Acceptance:
- .kogen/intents/review-efficiency/acceptance.feature
- features/steps/review_efficiency_steps.js
- features/steps/review_efficiency_driver.go

Deliver exactly two changes from current checkout HEAD 649e29bee3f8d5443b66dc7853433b3fd1d81785. Replace only the final sentence of paragraph two (line 3) in cli/agent/prompts/reviewer.md with the exact paragraph in acceptance.feature. Every other byte stays unchanged: original SHA-256 39e51da233be9dd2aaaae9ef3d24aa1fcb95421ae54c04360225a5a8c1cd9419, resulting SHA-256 1ab7ff81c6b94254ac71958230859fd9c76ffc15baa25ad2552017cbd11cceb9. Prove that actual emitted reviewer instructions carry the new paragraph and omit the old sentence.

In reviewRun.validate in cli/build/review.go, append field/type-specific detail only to the existing early shape-rejection message. Its prefix remains exactly `submit_review needs verdict (approve or changes) and a findings list`. The acceptance predicate `(verdict != "approve" && verdict != "changes") || !isList`, the caller, retry count, tool output wrapping (`invalid verdict:`), and second-invalid `candidate/review_invalid` stop stay exactly as they are. Do not parse, decode or coerce findings strings, even `"[]"` or a string holding a valid serialized findings array. Keep all other accepted/rejected inputs and finding/evidence validations unchanged. A valid verdict and findings array produce no new diagnostic text.

The appended clauses are specified exactly by the acceptance table: verdict detail precedes findings detail when both are wrong, separated by `; `. Distinguish findings missing, null, string, number, boolean and object. Distinguish verdict missing, each non-string JSON type, and an unsupported string without repeating it. Never echo any submitted value or part of a value in these shape diagnostics. Keep cli/agent/defs.go, including the submit_review tool schema, byte-identical.

Keep and extend the existing table in TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild in cli/build/review_test.go. Use its real review conversation through the fake provider to check the actual submit_review output in the retry request, not merely direct validation. Preserve existing cases and second-invalid-ends-the-Build coverage. Add a focused direct validate acceptance-set test covering the acceptance matrix, including null, both bad fields and private markers. The protected overlay driver is independent acceptance evidence, not a substitute for those maintained tests. Acceptance creates only disposable inputs and an overlay-mounted test, explicitly sets fixture executable permissions, and must work under caller umasks 077 and 022.

No other changes: review source construction/sizing, evidence contract, image limits, golden fixtures, Elixir parity, model/effort defaults and review model, Shape, post-block repair and Build stopping semantics are out of scope. Do not change configured checks or test tooling. No measured-savings claim belongs in specifications or documentation; research motivates this guidance but supplies no acceptance target.

## Decisions
- Use the exact requested batching paragraph, with three rounds as guidance rather than a cap; new concerns and repair verification still require further work. Complete evidence, every pinned-part read before approval, independent review, supported repairs with focused verification and every configured check remain required. (source: request)
- Reject all the same malformed submissions and disclose only the field and JSON type, never submitted contents. Keep the original message prefix and the one-retry/second-invalid stop. (source: request)
- Cite the research identity by title, `Review: a findings list sent as a JSON string is rejected with feedback that does not name the problem`, not a colliding shorthand issue number. (source: request)

## Source comparison
- addressed: request section 1 and delivery prompt-byte/emission notes map to the exact paragraph and hashes in acceptance.feature, the prompt scenario and the byte-preservation requirement above; the old one-sentence batching guidance is superseded only by its exact replacement.
- addressed: request section 2 and validate/caller/type/privacy delivery notes map to the unchanged predicate/caller/schema requirements above and the direct/conversation matrix, including approve/empty, both serialized strings, missing/null/object/boolean/number findings, missing/non-string/unknown verdicts and both bad fields.
- addressed: requested native test delivery maps to extending TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild and adding direct validate coverage in cli/build/review_test.go; independent protected acceptance also checks actual retry tool outputs and second-invalid preservation.
- addressed: caller umasks 077 and 022 map to explicit fixture modes in the overlay driver/step helper and final-byte observer controls under both masks. Slug and owned paths are review-efficiency, .kogen/intents/review-efficiency/{intent.md,acceptance.feature} and features/steps/review_efficiency_{steps.js,driver.go}.
- addressed: out-of-scope and delivery scope limits are preserved above, including unchanged cli/agent/defs.go and no golden/Elixir/model/Shape/evidence/source/image/stop changes. Research issue identity is retained by its supplied title, never a stable issue number.
- omitted deliberately as acceptance criteria: benchmark savings figures and whole-pipeline savings claims. Source request treats measurements only as limited motivation; the complete contract makes no savings claim. No requested functional behavior is omitted or in conflict.

## Tests
- Replace exactly one prompt sentence and preserve every other byte: source SHA-256 and reverse-replacement hash assertions (regression)
- Emit the exact new prompt to an actual review request and remove the old sentence without changing schema: fake-provider conversation instruction capture plus schema hash assertion (integration)
- Preserve the validate acceptance set while naming shape errors and never decoding strings or echoing submitted contents: add direct validate table tests and independent overlay matrix (unit)
- Send those diagnostics through the actual submit_review tool output and retry once: extend TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild and run independent fake-provider matrix (regression)
- Stop on the second invalid submission with candidate/review_invalid and no commit: preserve the existing native stop coverage and run the independent repeated-invalid scenario (integration)
- Preserve valid finding checks and accept valid approve/changes payloads: keep native tests and positive/inner-validation acceptance rows (existing)
- Run acceptance helpers safely under umasks 077 and 022: final-byte observer fixture controls exercise real overlay/direct/review paths under both masks (integration)

## Feasibility
- Local inspection confirms both implementation paths are editable; no required protected edit. No external dependency/protocol changes or documentation lookup is needed.
- A focused local probe confirmed the original prompt hash, single replacement occurrence, requested resulting hash, unchanged schema baseline hash, Go 1.27.2/Node 24.21.0 availability and the existing invalid-verdict integration test passes. (probe 1: exit 0, 17.4 s)
- A focused overlay probe exercised the actual Build review fixture under umask 077 with explicit accept.sh chmod: it landed after exactly two review requests, captured `invalid verdict:\nan approve verdict cannot have blocking findings`, and emitted instructions equal to the prompt bytes. This qualifies the overlay/fixture route, not the unimplemented new diagnostics. (probe 2: exit 0, 4.0 s)
- evidence: {"id":"review-observer","kind":"observer","inputs":["features/steps/review_efficiency_steps.js","features/steps/review_efficiency_driver.go"],"observers":["features/steps/review_efficiency_steps.js","features/steps/review_efficiency_driver.go"],"checks":[{"name":"good","command":"for mask in 022 077; do (umask \"$mask\"; \"$KOGEN_NODE\" features/steps/review_efficiency_steps.js --control good) || exit; done","exit":0,"output":"review efficiency observer good\nreview efficiency observer good\n"},{"name":"bad","command":"for mask in 022 077; do (umask \"$mask\"; \"$KOGEN_NODE\" features/steps/review_efficiency_steps.js --control bad); test \"$?\" -eq 1 || exit 2; done; exit 1","exit":1,"output":"review efficiency observer rejected bad fixtures\nreview efficiency observer rejected bad fixtures\n"}]}
