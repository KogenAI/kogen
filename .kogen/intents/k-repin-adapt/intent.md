# Adapt Kogen to the re-pinned loop

Slug: k-repin-adapt
Model: not applicable — adapt existing integration and compatibility fixtures; shell lifecycle state remains owned by the unchanged vendored loop
Acceptance:
- .kogen/intents/k-repin-adapt/acceptance.feature
- features/steps/k_repin_adapt_steps.js

Make Kogen's configured checks pass against the already-landed re-pin commit "Re-pin kogen-loop to 1a3eb18". Do not edit cli/third_party/kogen-loop/ or cli/loop-pin.json. Preserve configured checks, their settings and useful regression coverage. No new option, timeout or limit. Acceptance runs focused regressions, not the full suite, within approval's 120-second acceptance-command limit; complete configured checks still run on the Build tree.

## Decisions
- Adopt the pinned caller contract cli/third_party/kogen-loop/docs/contract/loop-v1.md, especially Shell time limit: exactly one command or handle, each call waits at most one second without an execution timeout; fast commands retain their text result; running commands yield JSON status running, opaque handle and cumulative output; handle retrieval continues to completed with integer exit_status and cumulative output. Do not hide yielding behind host-side blocking or restart commands to simulate continuation. (source: request)
- Update Kogen-owned byte/text/hash fixtures only for intentional changes in this pin, keeping assertions for unrelated behavior. The default loop instructions now include exactly: "When your checks pass, call finish right away: no extra re-reads, re-runs or polishing after a pass." Explicit task instructions remain explicit, and finish remains a claim subject to independent verification. (source: request)
- Adapt any actual Kogen consumers that require completed output to retrieve the returned handle. Adapt scripted providers and conformance drivers that assumed a blocking shell call to continue by the actual observed handle before issuing their terminal verdict; retain interruption/deadline/process-cleanup assertions. Native shell tools must expose the documented yielding behavior to the model. (source: request)

The observed native executor already delegates tools to the loop. Its conformance provider currently puts shell and finish in one response; this no longer proves interruption of a long-running command. Repair that fixture rather than changing round cleanup or restoring obsolete blocking semantics. Update the Building chapter's "Default shell calls remain unbounded" scenario and its scripted server to exercise sleep 2 yielding and handle retrieval to successful completion, instead of expecting the first call to contain exit status 0. Retain immediate-command behavior, stderr, output bounds and background-process cleanup coverage. Build and Review silent-shell regressions must each observe running output, retrieve the same opaque handle to completion, observe done and exit status 0, and still prove one commit and no command_no_progress event. Do not merely accept a running result followed by finish as evidence of completion.

## Source comparison
- Addressed: request K-REPIN-ADAPT, change_type fix, repo kogen, slug k-repin-adapt; outcome, Decisions and executable acceptance cover adaptation to 1a3eb18 without changing the protected vendor or pin.
- Addressed: reported TestDefinitionsMatchTheElixirDefinitions/shell, TestResearchRemovalDefaults (old diagnostic lengths 36527 and 36437), TestKRevodGatePartsUnchanged, TestSilentBuildShellNotStopped, TestSilentReviewShellNotStopped, TestNativeConformance, TestNamedFeedbackCompatibility and TestKReviewRetryUnchangedValidRequests are individually executed by acceptance. The unnamed additional Go failure and reported 25-scenario/1-failure Cucumber run remain covered by the requirement that all configured checks pass, not guessed test identities.
- Superseded: old shell definition/request-byte goldens and blocking-shell fixture expectations only where intentionally changed by loop 99d858a (handle-based shell) and 6b82843 (default instruction sentence). Decisions and Tests require retaining the unrelated compatibility assertions.
- Addressed: no new option, timeout or limit; no vendor or pin edit; focused acceptance within 120 s and full configured Build-tree verification are explicit boundaries above.
- Omitted from execution: historical MacBook ~/logs/verify-kogen-landtree/ go-test.out and cucumber.out from 22:38–23:10Z are supplied diagnostic provenance, not repository fixtures or proof of current success. Current focused reproduction is recorded in Feasibility.

## Tests
- Shell tool definition matches the new pinned contract: update TestDefinitionsMatchTheElixirDefinitions/shell and its Kogen-owned golden (regression)
- Default instructions and request bytes reflect this pin without changing other defaults: update TestResearchRemovalDefaults and loop_knobs_golden.json; preserve byte ceiling, cutting and documentation assertions (regression)
- Review parts and ordinary passing Build/Review requests retain all unrelated compatibility: update only affected goldens in TestKRevodGatePartsUnchanged, TestNamedFeedbackCompatibility and TestKReviewRetryUnchangedValidRequests, and repair any other pin-induced configured failures (regression)
- Silent native Build and Review commands yield and complete through handle retrieval without a no-progress stop: update TestSilentBuildShellNotStopped and TestSilentReviewShellNotStopped through real native Build/Review entry points (integration)
- Executor cancellation/deadline and cleanup still hold with yielded commands: adapt native conformance scripted continuation and retain TestNativeConformance's interruption, deadline and no-live-child assertions (integration)
- Installed CLI shell continuation works for sleep 2: update the Building chapter default-shell scenario and its real scripted-provider fixture to retrieve the observed handle and assert successful completion (scenario)
- Full configured checks pass on the final Build tree, without relaxing their scope: run the unchanged configured verification gate (existing)

## Feasibility
- Focused existing regressions reproduced the eight named top-level failures in 18.4 seconds (probe: exit 1, no timeout). Silent Build/Review returned running JSON with an opaque handle and empty output, not completion; NativeConformance observed no error where executor/ was expected. Parts-mode byte counts changed by 19 bytes per request. No paid service or external protocol lookup is needed: the pinned local caller contract and implementation are the authority for this dependency.
- evidence: {"id":"named-test-observer","kind":"observer","inputs":["features/steps/k_repin_adapt_steps.js"],"observers":["features/steps/k_repin_adapt_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_repin_adapt_steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_repin_adapt_steps.js bad","exit":1,"output":"rejected\n"}]}
