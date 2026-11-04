# Assert review outcomes, not kogen-review's layout

Slug: k-consumes-review-parts-unpinned
Model: not applicable — only a Go test and its test helpers change; no product state or transition is added or changed
Acceptance:
- .kogen/intents/k-consumes-review-parts-unpinned/acceptance.feature
- features/steps/k-consumes-review-parts-unpinned__steps.js

kogen-review's k-review-parts-linear-input (candidate 7d005ed6, Build 7397652b) deliberately changes how a review split into parts is sent: each part is read once, so input grows about linearly, and the "# Review task" part catalog and the re-sent history are gone. kogen's TestKReviewVerdictStrandPinnedResume pins that layout, so delivery's consumer gate refused the change twice (land log k-review-parts-linear-input-20261104T071731Z.log):

```
kogen	TestKReviewVerdictStrandPinnedResume	k_review_verdict_strand_test.go:74: no catalog in # Review task
```

After this change TestKReviewVerdictStrandPinnedResume (cli/buildprogram/k_review_verdict_strand_test.go) asserts the outcomes kogen relies on, not kogen-review's prompt text or layout. Lesson 4: a consumer never pins a producer's bytes or wording. The test keeps its name, keeps running the real `kogen intent build` and `kogen intent resume` against the scripted provider, and its doc comment states what it checks. Only `_test.go` files under `cli/buildprogram/` change. There is no production change in kogen: no non-test Go file, go.mod or go.sum changes, and cli/go.mod keeps requiring github.com/KogenAI/kogen-review `v0.0.0-20261103161351-e5005fa1daf8` without a replace.

## What the test no longer asserts
These rules apply to TestKReviewVerdictStrandPinnedResume and every helper it calls (`reviewCatalog`, `catalogParts`, `pinnedOf`, `authorityOf`, `forcedBodies`, `confirmingReviewer`). Helpers that become unused are deleted.
- **Request layout.** Nothing is read out of a reviewer request by its position or heading: no pinned-part catalog from the opening's second content block (`no catalog in …`, "# Pinned complete candidate source evidence"), no comparison of the opening's first block (`authorityOf`, the "same authority" check), no assumption about a "# Review task" heading.
- **Request counts.** No exact number of reviewer requests and no request picked by an index that follows from an expected count (`reqs[3]`, `forced[1]`). The "review 2 prefill requests = 3" and "forced requests, one per review = 2" checks go. Counting the builder's requests as all provider requests minus the reviewer's, and taking the first reviewer request after an observed count (the first request of the resumed review), stay allowed.
- **Request bytes.** No bytes, byte counts or SHA-256 of reviewer requests.
- **kogen-review's sentences.** No match on kogen-review's refusal or reminder wording, such as "invalid verdict:" or "Read all pinned source evidence before approving:".
- **What stays allowed.** kogen-build's own artifacts and what kogen-review exports:
  - the pinned part files `<run dir>/review-source/<review>-<candidate tree>/<n>.json` (n = 1..N; JSON with an empty `input` and `review_source` {`review`, `part`, `parts`, `text`}); their absolute paths are the part paths a reviewer reads with read_file;
  - kogen-build's native prefill messages (`prefillMarker`, `prefilledParts`) and its working-window reset handoff (`resetHandoff`, "Local working-window reset", its `review_delivery`);
  - the Build's exit code and stdout, the run result, checkpoint and events (`review_source_prefill`, `review_material`, `provider_fault`, `review`, `review_retry`, `review_only`, `review_edits_discarded` and the others asserted today), Git state, the request fields `tool_choice` and `prompt_cache_key`, and recognising reviewer requests by `review.ReviewerInstructions()`.

## What the test asserts
The fixture is unchanged up to the explicit resume: the builder writes `bigFile()` to app.txt; review 1 edits, then answers two prose-only turns; review 2 makes a tool call, three 150_000-byte fillers, a large prose turn and a text-only answer to the forced request.
- **The stopped Build** (a verdict strand of reviewers that never read is stopped):
  - exit 1 and stdout names `candidate/review_invalid`, as today;
  - review 2's pinned parts are the files `1.json`..`N.json` under `<stopped run>/review-source/2-<green tree>/`, numbered without gaps, each with `review_source` review 2, part n and parts N, and N ≥ 20;
  - at least one `review_source_prefill` event of review 2, and every part number it lists is within 1..N (prefill around the forced turn);
  - exactly one `provider_fault` event per review, for review 1 and for review 2, each with fault `forced_tool_not_called`;
  - the stopped run's reviewer requests belong to exactly two conversations (`prompt_cache_key`), review 1's then review 2's; each conversation has at least one request whose `tool_choice` is `forcedSubmit`, and review 2's last such request carries a working-window reset handoff (the reset);
  - unchanged: the discard event and its paths, the `review_only` events, the checkpoint (stage review_only, green tree and pass, automatic retry spent, two invalid reviews), the result (review_invalid, reviews 2, passes 1), app.txt, README.md, the diff, no notes.txt, HEAD and one builder request.
- **The explicit resume** (a verdict strand resumes as today; the fault test). The scripted review 3 is:
  1. its first response is `submit_review` approve with no reads: the fault reviewer approves while parts are unread (those that its first request's native prefill did not carry);
  2. afterwards the confirming reviewer: in each request it reads, at most 8 per response, the review 3 parts it cannot confirm were delivered, from the request's own completed reads, its prefill messages and a current reset's `review_delivery` unread numbers, with the part list taken from the part files `<resumed run>/review-source/3-<green tree>/<n>.json` in part order; when none is left, it approves.
- **The resume asserts:**
  - exit 0 and stdout contains `landed <slug> `;
  - the early approval is refused: a later reviewer request carries the `function_call_output` of that `submit_review` call. If none does, the test fails saying the approval with unread parts was accepted;
  - that output names at least one review 3 part path, and every review 3 part path it names was not carried by the prefill of review 3's first request (unread at that approval);
  - every request of the resume is the reviewer's; review 3's first request uses a `prompt_cache_key` no earlier request used and contains no `function_call`;
  - no `pass`, `command`, `command_result` or `executor_round` event in the resumed run; one `review_retry` event, kind `resume`;
  - exactly one `review` event, review 3 approving the green tree, and the last `review_material` event has `parts_read` equal to review 3's part-file count;
  - result landed, `resumed_from` the stopped Build, reviews 3, passes 1; one new commit whose tree is the green tree, HEAD:app.txt is `bigFile()`, a clean status, and the stopped run keeps its review_invalid result.

## Acceptance
TestKReviewVerdictStrandPinnedResume passes, run once and not skipped, in each of these runs:
- with the committed cli/go.mod;
- against kogen-review main `v0.0.0-20261104085219-f04169324523` (f041693), through a temporary `-modfile`;
- against the 7d005ed6 layout stand-in: a temporary copy of that main whose `env.Prepare` result goes through `standInOpening` (the opening's source block begins with "# Review task" and carries no pinned-part catalog), with the native "changes with unread parts" send-back disabled.

Fault test: with the stand-in, the test fails once the copy also accepts an approval with unread parts, or once its refusal stops naming the unread parts (`%.0s`). The steps run the five variants concurrently, so the acceptance fits the 120-second readiness step bound.

## Decisions
- TestKReviewVerdictStrandPinnedResume stops asserting kogen-review's prompt text and layout: no "catalog in # Review task", no exact review request counts, no request bytes or SHA-256 of review requests (source: request)
- It asserts the outcomes kogen relies on: approval refused while a pinned part is unread, naming it; a verdict strand resumes and resets as today; reviewers that never read are stopped (source: request)
- No production change in kogen (source: request)
- The fault reviewer approves before reading anything, while the parts its first request's prefill did not carry are unread, not with exactly one part unread. kogen-build's native prefill puts any leftover unread part into the next request whenever it has room, and that request is answered before any approval. Exactly one unread part could only be staged by sizing fillers to kogen-review's prompt bytes, which this request forbids. (source: request)

## Source comparison
- **Addressed: the gate row** `kogen TestKReviewVerdictStrandPinnedResume k_review_verdict_strand_test.go:74: no catalog in # Review task`. It is reproduced on today's tree by the stand-in (k_review_verdict_strand_test.go:74, "no catalog in # Review task"), and acceptance scenario 3 requires the test to pass there.
- **Addressed, resolved: "The tests pass against kogen-review main".** kogen-review main is c8e5c9b now. From ba84b86 ("Require kogen-loop by its canonical module path") on, it requires github.com/KogenAI/kogen-loop and newer coordinator, executor and verification. With kogen's go.mod, `go build` then fails with "missing go.sum entry for module providing package github.com/KogenAI/kogen-loop/…", so kogen cannot build against it without moving its whole lineup, which go.mod protection and "no production change" exclude. f041693 ("Stop writing max_rounds in kogen-review fixtures") is the newest main commit kogen's pinned lineup builds. It changes only kogen-review test files after fee5268. Against it the unchanged test passes today.
- **Addressed with a stand-in: "… and against kogen-review at 7d005ed6".** 7d005ed6 is not retrievable: `go list -m github.com/KogenAI/kogen-review@7d005ed6` reports "invalid version: unknown revision 7d005ed6", and the local mirror lacks it. The stand-in uses the same edits as kogen-build's landed k-build-review-parts-unpinned. Passing against it is not proof of passing against 7d005ed6. Delivery's consumer gate re-runs the test against the real candidate.
- **Addressed: "approval is refused while a pinned part is unread (and that part is named)" and "Fault test: a scripted reviewer that approves with one part unread is still refused".** This is review 3's early approval, with the deviation under Decisions. Probe: on fee5268, an immediate approval in review 3 was refused, and the refusal named 8 review 3 part paths. With approval guard disabled, it landed with 57 of 106 parts delivered. With `%.0s`, the refusal named none.
- **Addressed: "a verdict strand resumes and resets as today"** (review 2's forced request after the reset, and the resume) and **"a reviewer that never reads is stopped"** (reviews 1 and 2 never read and the Build stops review_invalid).
- **Addressed, mapped: "a part changed after it was read blocks approval".** kogen's installed-CLI scenario spec/features/06-reviewing.feature:44 ("Altered pinned review source refuses before another tool or approval") and kogen-build's TestReviewBudgetOmittedPartsRemainUnderCustodyValidation already assert it. A fixture that changes a part file would end this test's resume as a custody refusal rather than "as today", so the test does not add it.
- **Addressed: "No production change in kogen".** Scenario 1 checks the kogen-review pin; go.mod and go.sum are protected.
- **Out of scope:** the installed-CLI scenario fakes test/acceptance/support/fake-servers.js:670 and handlers.js:479, which read the catalog for spec scenarios 06-reviewing.feature:33/:44 (the specification of REV-2/REV-4, not in the gate's rows). Also the inline-review request counts in k_reviewretry_cli_test.go:82/:169 and satisfied_rebuild_test.go:86, which pin no parts layout and pass against the stand-in. kogen-build's own tests, and production code, go.mod pins and consumes/ suites, are out of scope too.
- **Preserved literals:** the test name and file, the land-log row and log name, candidate 7d005ed6, Build 7397652b, the pin `v0.0.0-20261103161351-e5005fa1daf8`, main f041693 `v0.0.0-20261104085219-f04169324523`, and the stand-in and fault edit texts.

## Tests
- Reviewer request layout, counts, bytes and kogen-review wording are no longer asserted, and the verdict strand still stops, resumes and resets as today: update TestKReviewVerdictStrandPinnedResume as above; it passes with the pin, kogen-review main f041693 and the 7d005ed6 stand-in (acceptance scenarios 1–3) (regression)
- An approval with pinned parts unread is refused and names them: review 3's early approval in TestKReviewVerdictStrandPinnedResume, which fails against the stand-in once the approval is accepted or the refusal stops naming parts (acceptance outline, 2 examples) (regression)
- Reviewers that never read are stopped: the kept review_invalid stop assertions of the same test (existing)
- A part changed after it was read blocks approval: spec/features/06-reviewing.feature:44 and kogen-build's custody test, unchanged (existing)
- No production change and an unchanged kogen-review pin: acceptance scenario 1 and the protected go.mod/go.sum (existing)

## Feasibility
- I ran these myself in this read-only external session, in scratch copies under /tmp; they are not Kogen probe records.
  - With the committed go.mod, the unchanged test passes (about 13 s alone).
  - Against fee5268 and f041693 (`go get` through `-modfile`), kogen builds. The unchanged test passes against fee5268.
  - The stand-in builds from f041693 with the feature's edit table and file, and fails the unchanged test at k_review_verdict_strand_test.go:74 "no catalog in # Review task" (legitimate missing-feature red).
  - Against c8e5c9b, kogen does not build (canonical kogen-loop path, see Source comparison).
  - Review 3's part files are under the resumed run's `review-source/3-<green tree>/` (106 parts), and review 2's under the stopped run's `2-<green tree>/`. The catalog's part paths equal those files' paths.
  - Five variant runs concurrently took about 20 s with a warm build cache.
  - The fault probes are listed under Source comparison.
- evidence: {"id":"strand-run-judge","kind":"observer","inputs":["features/steps/k-consumes-review-parts-unpinned__steps.js"],"observers":["features/steps/k-consumes-review-parts-unpinned__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k-consumes-review-parts-unpinned__steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k-consumes-review-parts-unpinned__steps.js bad","exit":1,"output":"rejected\n"}]}
- The observer's controls use real `go test -json` output of package buildprogram with the committed go.mod. Good: a real passing run of TestSatisfiedRebuildAlreadyPresent is accepted as passing. Bad: the same real passing run judged as failing, and a real run of an absent test name (zero runs) judged as passing, are both rejected. They qualify the judge only, not product behaviour.
