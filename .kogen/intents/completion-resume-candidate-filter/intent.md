# Cover resume completion candidate policy

Slug: completion-resume-candidate-filter
Model: not applicable — this adds test coverage for an existing stateless filter and ordering rule; no product behavior changes
Acceptance:
- .kogen/intents/completion-resume-candidate-filter/acceptance.feature
- features/steps/completion-resume-candidate-filter__steps.js

Add direct unit coverage in `cli/facts_test.go` for the resume branch of `completeCandidates` in `cli/facts.go`, so shell completion for `kogen intent resume` is proven to offer only runs that can be resumed. Production code, the candidate rules of other completion operations (inspect, recover, build, approve, refine, preflight) and shell completion wiring are out of scope and stay unchanged.

The new test calls `completeCandidates("resume", nil, runs)` with run objects carrying `run_id`, `slug`, `state` and `resume_status`, and compares the captured standard output (using the existing `captureStdout` helper). The fixture contains: resumable runs with `resume_status` `potentially_available` (state `build_blocked`) and `requires_validation` (state `interrupted`); one run excluded only by `resume_status` `unsupported`; one run excluded only by state `landed`; one run excluded only by state `already_present`. The expected output is exactly the resumable runs, one line each as `<run_id>\t<slug> <state>`, sorted by run id. The same fixture is also supplied in reversed input order and must give byte-identical output.

## Decisions
- The test lives in `cli/facts_test.go`, the scope the request names, and calls `completeCandidates` directly rather than through the shell. (evidence: cli/facts.go; cli/facts_test.go) (source: request)
- Resume completion prints only resumable run ids with their slug and state descriptions; runs whose resume status is unsupported, or whose state is landed or already present, are never printed. (evidence: cli/facts.go) (source: request)
- Resume candidates are printed in stable value (run id) order regardless of input order, proven by comparing the output for forward and reversed input. (evidence: cli/facts.go) (source: request)
- Acceptance observes the behavior without depending on a test name the Build must invent: it copies `cli` and `docs`, runs every test declared in `cli/facts_test.go`, and requires them to pass on the real policy and to fail under each of five wrong resume policies applied to the copy of `cli/facts.go` (offering unsupported runs, offering landed runs, offering already present runs, dropping potentially available runs, keeping input order). (evidence: cli/facts_test.go) (assumption: the wrong policy of dropping requires_validation runs and of changing the description are not acceptance scenarios because the existing TestRunCompletionDoesNotOpenPackages already covers them) (source: request)

## Source comparison
- Addressed: acceptance 1 (only resumable runs with slug and state description printed; excluded runs and dropped resumable runs fail the output comparison) by the test fixture and the scenarios for offering unsupported, landed and already present runs and for dropping a potentially available run.
- Addressed: acceptance 2 (stable value order regardless of input order) by the reversed-input comparison and the scenario for keeping input order.
- Omitted per request: changes to candidate rules of other completion operations and to shell completion wiring.

## Tests
- Resume completion prints only resumable runs, excluding unsupported, landed and already present runs, with `<slug> <state>` descriptions: new Go test in cli/facts_test.go comparing captured completeCandidates output (unit)
- Resume candidates print in run id order for forward and reversed input: same Go test comparing both outputs to one expected string (unit)
- The new coverage fails when the resume policy is wrong: acceptance scenarios run cli/facts_test.go tests against five wrong variants of completeCandidates (scenario)

## Feasibility
- evidence: {"id":"policy-observer","kind":"observer","inputs":["features/steps/completion-resume-candidate-filter__steps.js"],"observers":["features/steps/completion-resume-candidate-filter__steps.js"],"checks":[{"name":"good","command":"node features/steps/completion-resume-candidate-filter__steps.js --control good","exit":0,"output":"observer accepted good\n"},{"name":"bad","command":"node features/steps/completion-resume-candidate-filter__steps.js --control bad","exit":1,"output":"observer rejected bad\n"}]}
- Scratch probes outside the checkout showed the existing facts tests pass on the unchanged tree under `go test -run` on a copy of `cli` and `docs`, that a correct new test fails each of the five wrong policies, and that each wrong test variant lets its policy survive. (probe: exit 0)
