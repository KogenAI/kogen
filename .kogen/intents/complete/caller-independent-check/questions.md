# Questions and choices

No open questions. The Shaper is not asked (DIRECTION §4, rule 24; ORCHESTRATOR.md "Questions").

## Assumed

1. **Test-support only.** ORCHESTRATOR.md says the fix is "a tiny Intent whose guarded paths
   include those two test files" and that the tests must not depend on the caller's value, and
   must not clear it globally in test_helper.exs. The fixtures are where the dependency lives, so
   `test/support/workspace_fixture.ex` and `test/support/verification_cycle_fixture.ex` are
   guarded too.
2. **Regression tests go into the two existing files**, as `Kogen.IsolatedCase, async: true`
   tests (isolation_test.exs requires async: true; IsolatedCase gives each test its own VM, so
   setting the variable in a test body is safe). This is the cheapest check that observes the
   defect in any `check` (§1.19). Plain `make check` on a developer machine has the variable
   unset and would never see it otherwise.
3. **No registry change.** None of the four files is in priv/kogen/test-reliability*.yaml, and
   adding a row would break the pinned declaration_count of 346 (review finding, all three
   reviewers).
4. **Ordering.** It goes before shaping-quality's rebuild and every other Build (DIRECTION §4
   rule 21). Its four files fall under shaping-quality's and build-reliability's `test/support/**`
   or `test/kogen/**` globs, so those get re-preflighted afterwards.

## Audit, 2026-09-26

- Round 1 (Astra medium, Sol high, Opus high): all "not ready". Blocking: registry count trap
  (all three), `async: false` impossible under IsolatedCase/isolation_test (Opus), run_cycle
  has no env path within guarded files (Astra). Fixed by the reshape above plus a prototype run
  (lesson 18). Advisories (live-writing recipe, name the run_cycle wrapper, narrow the outcome,
  prove red-on-base) all adopted.
