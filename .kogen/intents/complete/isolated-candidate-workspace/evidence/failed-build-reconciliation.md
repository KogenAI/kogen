# Failed Build reconciliation

## Observed attempts

- `.kogen/runtime/scenario-tracking/VZFIeCIgbbYcNE4VRr3TcYUy/record.json` records a failed Build whose first offline cycle exposed multiple migration regressions. Its later cycles repeatedly failed `Kogen.CoreIntegrityTest` scenario `late_dangling_complete`.
- `.kogen/runtime/scenario-tracking/1vg5QEsjup-8dCzHbvkuGXBZ/record.json` records the subsequent clean-baseline Build. Its first cycle also exposed `stale_verification_record`; the Developer corrected that within the guarded implementation. Cycles two and three then repeatedly failed only `late_dangling_complete`, exhausting verification retries before any paid target.

## Source-linked contradiction

At shaped HEAD, `test/kogen/core_integrity_test.exs` creates a `late_dangling_complete` fake harness scenario and asserts that the dangling Complete symlink is present under the control fixture. After this Intent's required explicit Candidate cwd routing, that fake Developer creates the symlink under the Candidate instead. The retained second Developer handoff identifies 319 of 320 offline cases passing and the unguarded historical assertion as the sole remaining failure.

Changing production code to mirror the Candidate-created symlink into control would make the old assertion pass, but would violate the required structural boundary: role work must remain Candidate-owned and failed work must leave control unchanged. The correct reconciliation is to treat `test/kogen/core_integrity_test.exs` as an affected consumer, preserve its dangling-symlink rejection purpose at the Candidate boundary, and add an explicit control-preservation assertion.

## Limits

These are failed verification records, not readiness evidence. No paid target ran, no Candidate was accepted, and this shaping continuation did not run the gate or modify implementation/test source. The dirty source tree visible during continuation is retained failed-Candidate work and was inspected read-only.
