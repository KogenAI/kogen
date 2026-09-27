Verdict: not ready

All six round-1 findings are fixed, and the fixes agree across INTENT.md, scenarios.yaml, references.yaml, risks.yaml, questions.md, intent.yaml and evidence/CANDIDATE.md. The fixes introduced one new blocker.

**Round-1 findings, checked against e65392cf**

1. **`Questions` module:** fixed. The new Dispositions-only `questions.ex` uses the key `reason`, accepts an optional leading `- ` and handles only `not a defect` (INTENT.md:121-126, 169-176; CANDIDATE.md:19). The calls to `findings`, `state` and `entries` and the asking state are removed (CANDIDATE.md:17-18). C2's expected disposition matches.
2. **`repository-invalid`:** fixed. Hunks 2 and 3 are dropped, and the finding is any `{:error, _}` from `load/1`, with the layer `unavailable` (INTENT.md:84-87, 274-285). A6 now passes: `load/1` at :23-56 runs `require_ordinary_targets/2` (:298-306), which returns an error for the `mismatch-x` catalog target. Other Makefile targets are allowed (:279-281), so the extra `live-extra` check in A6 is right. If the fixture writes `mismatch-x` wrong (for example with a duplicate rank), `load/1` still returns an error, and A6 still passes.
3. **Rebaseline:** fixed. These anchors all hold at e65392cf: `finish_publication/4` at build.ex:2732 with its call at :2742, the failure strings at :2129 and :2334, `scripts/check/README.md:221-226`, and the `## Context index` heading at README.md:957.
4. **Test list:** fixed. The list is closed, the label is not part of a test name, and the contradicting qb tests are named for removal (INTENT.md:313-346; CANDIDATE.md:22-23).
5. **D7 fixture:** fixed. The `compiled: true` option and `.kogen/config.yaml` are now in the fixture header (scenarios.yaml:16-17, 34-37). `mix_task!/3` returns `{output, exit_code}`, which fits D7's assertions.
6. **Contradictions:** fixed. `stale-disputed` now cites only `cited_bytes`, A2 uses a fresh materialization, A3 excludes `invalid` and `non-regular`, and word matching ignores case (INTENT.md:204-207; scenarios.yaml:183-184).

**Blocking finding (new)**

1. **`KOGEN_ROLE` leaks into the tests outside the gate.** The Codex harness sets `KOGEN_ROLE=developer` for the Developer and `reviewer` for the Reviewer (`lib/kogen/harness/codex.ex:97, 240, 255`). Only the verification runner removes it (`lib/kogen/build/verification_runner.ex:25`).
   - In qb, `main/2` defaults to `System.get_env()` (qb slice diff :560, :614).
   - The Draft's test descriptions call `main([slug], root: root)` with no `env:` (scenarios.yaml:64, 123, 147, 207). D7 passes `[]` to `mix_task!` (scenarios.yaml:496), and the child process inherits the caller's environment.
   - So when the Developer runs the tests in its own session, which the readiness commands tell it to do, A1-C6, D1, D2 and D7 all get exit 2 (refused role). The gate would pass the same code. That invites the Developer to weaken the refusal or D7, or the Reviewer to reject a correct Candidate.
   - Fix: in INTENT.md "Tests and fixtures" (around :348-352) and D7, state that every `main/2` call passes `env: %{}` (or the role under test, as qb does). D7 should pass `[{"KOGEN_ROLE", nil}]` to `mix_task!/3`. Give the reason: the Developer and Reviewer sessions set `KOGEN_ROLE`, and only the gate removes it.

**Not blocking**

- `references.yaml:22` gives `validate_declared_targets/2` as :368, but it is at :283 (:368 is `valid_entry?`). It gives `load/1` as :22, but it is at :23.
- `questions.md:189` still says "The slices are shaped against develop 3531023d".
- `questions.md:245` says the validator was "re-run at e65392cf below", but no re-run is recorded below.
- The Dispositions parser should split each line on `: not a defect`, because some ids contain `:` (for example `stale-anchor lib/a.ex:3`). No test covers this.

I reviewed read-only and wrote nothing, not even the plan file; this session has no write tool. Separately, the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used.
