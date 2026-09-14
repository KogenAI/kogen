# Failed-Build investigation

## Observed outcome and ownership

The Shaper supplied the failed Build output and requested “Fix Intent?”. `record-summary.json` retains the exact failure strings, findings, source record SHA-256 and dirty Candidate status for Build m0nviywjh4fw3HrB8P3K6HaG. Accepted HEAD remains c1c9d137; the dirty implementation is unaccepted. Neither the source Candidate nor its controller record was modified by this investigation.

Attempt 0 passed Check and failed live: the real Shape-to-Build consumer read check.finished_at as nil. Attempt 1 passed Check but was rejected for citing test/kogen/live_shape_to_build_test.exs:361 as a path instead of putting the line number in locator. Attempt 2 passed Check/live but the first Reviewer found the state reset defect; the old runner's two outer resumptions were exhausted. F1 remains open. MCP warnings and patch/tool errors were not these retained stop reasons.

The existing Intent already required bounded counters, corrupt/replayed-state rejection and no post-exhaustion dispatch. The implementation failed that contract. The revised Draft tightens its evidence requirements and pre-dispatch order rather than claiming a new product decision or changing the allowance.

## Source-linked execution

`candidate-source.py` is an exact retained copy of the stopped Candidate's .codex/hooks/stop_runner.py; source-sha256.txt records its digest. `probe.py` executes that exact source in five private Git fixtures, with the unified context fields produced by the inspected Candidate initializer and harmless check targets. Each target appends a dispatch marker under ignored runtime state. No root Make gate or provider invocation ran. Every fixture retains source, context, state, stdout/stderr and dispatch-count receipts; private Git metadata was removed after completion.

The natural prior cycles are produced by executing the hook, not by fabricating its counter values. After those cycles the driver changes only the stated owned fixture state. `probe-results.json` records:

- pass-control: a real failed cycle followed by a passing cycle dispatches twice and resets failures to zero.
- corrupt-after-two and delete-after-two: the next callback dispatches again, replacing two prior failures with sequence 1/failure 1 and issuing more repair feedback.
- intact-exhausted: after three genuine failed cycles, an extra callback dispatches a fourth gate even though it returns continue:false and leaves exhausted state intact. The latch check is after target execution.
- delete-exhausted: deleting state after exhaustion allows a fourth dispatch and resets the state to pending/failure 1.

These are valid defect reproductions, paired with a valid passing-repair control. They are not proof of a repair. Current tests exercise happy-path unified execution indirectly through public fixtures but the inspected test sources have no explicit unified-state corruption/deletion/exhaustion-dispatch controls. Passed gates therefore did not establish these required negative cases.

## Reproduction and limits

Starting at the repository root, a fresh authorized copy of this evidence directory needs Python 3, Git and Make. Run python3 <fresh-directory>/probe.py after preserving the intended Candidate source and its hash. Fixture destinations must be absent; never overwrite these results. The subprocess bound is 20 seconds per callback. Outputs are five receipt files plus probe-results.json. No installed application dependency or credential is required.

The revised Build must promote equivalent controls to maintained tests using its production initializer and registered hook, verify pre-dispatch markers, and connect terminal results through actual public Build to no-resume/no-Review/no-publication assertions. The historical source snapshot is a disconfirming reference, not an implementation to adopt or a replacement for current production tests.

## Subsequent process scope

The Shaper then accepted a bounded shaping-process improvement inside this Intent. Root inspected the maintained shaping quality section, its source/text delivery test, five-case evaluation README, hidden semantic counterexamples and driver manifest owner. Quality guidance is substantially identical at accepted HEAD and dirty Candidate (the dirty delta only changes budget wording). The new contract adds ordered state/action analysis and a source-backed native brief pair; it does not treat literal prompt assertions as behavioral proof. No source/test files were changed during this shaping step.
