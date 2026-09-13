# Reliable isolated tests

Approved for one Build: one Developer conversation, at most two outer resumptions.
Start with [scenarios](scenarios.yaml), [risks and ownership](risks.yaml), and
[questions](questions.md). [Evidence](evidence/README.md) records shaping probes;
[references](references.yaml) identifies historical inputs.

## Problem and outcome

Parallel fixtures must not write through dependency symlinks into shared sources.
Timing probes must distinguish startup from the behavior measured after readiness,
while retaining bounded cancellation and confirmed cleanup. The accepted baseline
already implements private copies and supervised child cleanup; repair remaining
boundary defects and preserve those guarantees rather than reimplementing them.

## Proposed scope

Reject any existing dependency-copy destination, including dangling symlinks,
before mutation. Materialize valid linked dependency sources as independent files
and directories, retain necessary headers, and exclude existing build caches.
Treat broken/cyclic links and copy failures as failures, never usable partial copies.
A failed newly owned destination may be removed; preexisting paths must remain intact.
Do not introduce a general filesystem sandbox or a concurrent hostile-path defense.

Add opt-in readiness to existing isolated and terminal test probes. Use a fresh,
fixture-owned marker emitted after the relevant child/workload is actually running.
Bound startup separately from the post-readiness collection/behavior deadline;
keep existing no-readiness callers and overall safety bounds meaningful. Handle
exit-before-readiness immediately, missing readiness as a startup failure, and
post-readiness timeout as a behavior timeout. Use monotonic deadlines. Do not
reset deadlines on output or polling. Private helper option names and bounded
per-test budgets are engineering decisions, not new Kogen CLI/configuration.

Exercise both direct isolated dispatch and its macro/run! consumer, plus the
existing Harness.exec_shaper pipe/PTY consumer using a fake provider. A child-only
passing assertion cannot establish that the parent observed success or failure.
Readiness must be generated inside the actual child route, not asserted by the parent.

Verification is the existing `check` target and ordinary independent Review.
Any Python regressions must be reached by that target through an ExUnit wrapper;
a standalone Python file absent from check is insufficient. Live fixture callers
may receive only mechanical copy-helper compatibility changes. No paid run is
required for these deterministic infrastructure behaviors.

## Non-goals

No global timeout increase, result cache, new gate/retry policy, public interface,
new persistent storage or retention policy, production engine behavior change,
Shaping driver, evidence-forwarding/manifest feature, live-suite scheduling change,
model-quality claim, platform expansion, or wholesale import of an old Candidate.
Historical evidence delivery and Shaping evaluation obligations remain with their
existing proposals; this Draft transfers only the infrastructure subset on approval.
