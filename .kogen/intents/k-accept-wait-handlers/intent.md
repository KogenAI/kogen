# Wait for fake-server requests until kogen ends

Slug: k-accept-wait-handlers
Model: not applicable — the change replaces one test-harness wait condition; it adds no product state, transition or interacting rule
Acceptance:
- .kogen/intents/k-accept-wait-handlers/acceptance.feature
- features/steps/k_accept_wait_handlers_steps.js

Fix K-ACCEPT-WAIT-HANDLERS (change_type fix, repository kogen). In the deterministic acceptance suite, `waitForServerRequest` in `test/acceptance/support/handlers.js` (now at line 264; the request cites :271) fails a scenario when the fake ChatGPT server has not received an expected request within a fixed wall-clock wait. Its only caller is the step `the fake ChatGPT server has sent the feedback of verification pass N`, which waits for a recorded request whose text includes `Verification pass N is not green.` with `Math.max(30000, n * 5000)` ms (the function's own default is 30000 ms). Under host load that guess decided whole adoption windows: the 06Z and 00Z windows were red on `spec/features/04-building.feature:105` "Ordinary implementation failures keep repairing until the caller stops it" (waiting for verification pass 25), and the 00Z bisect blamed the wrong component for it.

After this change the wait ends on the awaited request or on the kogen process ending, never on a wall-clock guess, so a slow host slows the scenario instead of failing it. A scenario whose kogen process ended without the request still fails, and the failure names the missing request.

Current behavior (the code does this now): the handler polls `world.server.requests` every 25 ms and, after the fixed wait, fails with the generic `the fake ChatGPT server did not receive the expected request`, whether or not the kogen process is still running. It ignores the process entirely.

Required behavior:
1. The step waits for the first record in `world.server.requests` (the array the fake server pushes each received request into, each with a `text` string) whose `text` includes `Verification pass N is not green.`, and returns once it is recorded. A request already recorded when the step starts ends the wait at once.
2. The kogen process is `world.currentProcess`, the background command record that `world.invoke` creates (`child`, `code`, `signal`, and `done`, a promise resolved when the process has closed). While that process runs and the request is absent, the wait continues with no wall-clock limit of its own. The step does not stop, signal or wait out the process.
3. When the process has ended (its `done` resolved), the requests are checked once more: a request recorded before the end ends the wait normally. Otherwise the step fails promptly (not after any fixed wait), with an assertion message that includes the awaited request text in double quotes. Recommended wording: `the fake ChatGPT server did not receive the request "Verification pass 7 is not green." before the kogen command ended (exit code 3)`.
4. When no kogen process is running (`world.currentProcess` is empty) and the request is not recorded, the step fails at once with a message that includes the awaited request text in double quotes, e.g. `the fake ChatGPT server did not receive the request "Verification pass 2 is not green." and no kogen command is running`. Without this, the wait would have nothing to end it.
5. Remove the `timeoutMs` parameter, its 30000 ms default, the caller's `Math.max(30000, n * 5000)` bound and its "allow 5 s per pass" comment. Give the wait the awaited request text (or an equivalent description) so the failure can name it. The suite's existing outer Cucumber step timeout (`setDefaultTimeout(15 * 60 * 1000)` in `test/acceptance/support/world.js`) stays unchanged. It is not raised and no other timeout is added.

Boundaries: no scenario's expectations change. Every file under `spec/features/` stays as it is, including the scenario at 04-building.feature:105 and its step `When the fake ChatGPT server has sent the feedback of verification pass 25`. Kogen's CLI gets no new command or flag, and no Go code changes. `cli/go.mod` and `cli/go.sum` are protected and untouched. Other fixed waits in the harness (`reachPause`, the fake server's `waitReached`, `world.waitFor`, the two-second signal-negative observation) are outside this request and unchanged. The existing regression entry point `test/acceptance/fixed-wait-regression.cjs` must keep passing unchanged. It drives this same step with a world whose `currentProcess` has `child` and `code` but no `done`, and with the request already recorded, so rule 1 must return before the process record is consulted.

## Decisions
- The wait ends on the awaited request or on the kogen process ending, not on a wall-clock guess; a slow host slows the scenario instead of failing it. (source: request)
- A scenario whose kogen process ended without the request still fails, and the failure names the missing request. (source: request)
- No scenario's expectations change; no new commands or flags in Kogen's CLI; no timeout raised; cli/go.mod and cli/go.sum stay unchanged. (source: request)

## Source comparison
- Addressed: K-ACCEPT-WAIT-HANDLERS, filed by kogen-delivery on main's ruling, 3 Nov 2026 (entanglement audit, finding F1), repository kogen, change_type fix: the prose above and both acceptance scenarios.
- Addressed: "test/acceptance/support/handlers.js:271 (waitForServerRequest)": the function is at line 264 at HEAD 45b23b3, with the fixed 30000 ms default; its only caller is the verification-pass feedback step (`Math.max(30000, n * 5000)`). Required behavior rule 5 removes both.
- Addressed: "04-building.feature:105 ... waiting for verification pass 25": scenario 1 checks that this scenario keeps exactly its eight steps. The configured `cucumber` check runs it through the changed handler. Acceptance drives the handler with pass 1, so the old bound (30 s) is outlived by a request arriving after 31 s; the pass-25 bound (125 s) cannot be outlived inside approval's 120-second acceptance step.
- Addressed: "the wait ends on the awaited request or on the kogen process ending": rules 1 to 3; scenario 1 (late, already recorded, recorded just before the end) and scenario 2 (ended with exit 3).
- Addressed: "a scenario whose process ended without the request still fails, naming the missing request": rule 3, scenario 2. Rule 4 (no process at all) is the fail-fast end condition the unbounded wait needs.
- Addressed: "No scenario's expectations change", "no new commands or flags", "no timeout raised", "cli/go.mod and go.sum are protected": Boundaries and rule 5.
- Omitted as executable inputs: the 06Z/00Z adoption windows and the 00Z bisect itself; acceptance reproduces the failing condition (a request later than the fixed wait) locally instead.

## Tests
- A request recorded after the old fixed wait, while the kogen process runs, ends the wait instead of failing it, and the process is left running: the late case of k_accept_wait_handlers_steps.js through the real handler (regression)
- A request already recorded, or recorded just before the kogen process ends, ends the wait: the prompt and race cases (regression)
- A kogen process that ends without the request fails the wait promptly after it ends, naming the missing request: the ended case (regression)
- With no kogen process running and no request, the wait fails at once, naming the missing request: the no-process case (regression)
- The 04-building.feature scenario keeps its steps and passes through the changed handler: the scenario-steps check in acceptance, plus the configured cucumber check of 04-building.feature (existing)
- The fixed-wait regression entry point still passes against the changed step: test/acceptance/fixed-wait-regression.cjs unchanged (existing)

## Feasibility
- Repository inspection: the only caller of `waitForServerRequest` is the verification-pass feedback step. `world.invoke` records background commands with `child`, `code`, `signal` and a `done` promise resolved on close. The fake server pushes each request record (with `text`) onto `requests`. The fix fits in unprotected `test/acceptance/support/handlers.js`.
- I ran the protected step file's observation (`--observe`) against the unchanged handler in a scratch copy outside the repository (observed in this external session, not recorded by Kogen as a probe). The late request failed at 30021 ms with the generic message. The ended case (pass 7) failed at 35017 ms and the no-process case at 30020 ms, both without naming the request. The already-recorded and just-before-the-end cases resolved. Through Cucumber: 2 scenarios failed, at the late and ended assertions.
- I ran the same observation against a scratch-only prototype (poll the requests until `currentProcess.done` resolves, check once more, fail naming the request). Late resolved at 31011 ms with the process still running, ended failed at 545 ms naming "Verification pass 7 is not green.", no-process failed at 1 ms. Through Cucumber both scenarios passed (8 steps) in 31.2 s. The prototype is not part of the Intent.
- The controls below qualify the protected observer with known-good observations and independently damaged ones. Bad cases include the old fixed-wait failure, an early, late or never-ending resolution, a stopped kogen process, a lost or slowly found recorded request, a message that does not name the request, failure before the process ended, a wrong exit code, a missing observation, and a changed or missing 04-building scenario step. They are observer controls only, not product evidence.
- evidence: {"id":"kawh-observer","kind":"observer","inputs":["features/steps/k_accept_wait_handlers_steps.js"],"observers":["features/steps/k_accept_wait_handlers_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k_accept_wait_handlers_steps.js --control good","exit":0,"output":"k-accept-wait-handlers observer accepted good observations\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k_accept_wait_handlers_steps.js --control bad","exit":1,"output":"k-accept-wait-handlers observer rejected bad observations\n"}]}
