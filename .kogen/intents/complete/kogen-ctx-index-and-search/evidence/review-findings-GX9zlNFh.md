# Open Review findings after Build GX9zlNFhwNX7xhMqI51egYNq (last attempt, verdict rework)

- F2 (open): Open: the fixture runner stderr issue is fixed, but the Candidate still has substantially weakened smoke tests instead of the approved exact behavioral proof cases across all four scenarios.
   - .kogen/intents/approved/kogen-ctx-index-and-search/scenarios.yaml: The approved contract explicitly requires exact A1-A6, B1-B5, C1-C9 and D1-D6 behavioral cases and rejects substring, status-only, and line-count smoke checks.
   - test/support/ctx_fixture.ex: The fixture runner now returns separate stdout, stderr, and status, but this does not replace the required behavioral assertions.
   - test/kogen/ctx_index_test.exs: Index tests contain only partial A1/A2/A5/A6/B1/B3 coverage and use substring assertions, omitting the specified exact cases.
   - test/kogen/ctx_search_test.exs: Search tests use substring/count checks and omit exact ranking, result sets, snippets, limits, refresh, and chunk assertions.
   - test/kogen/ctx_build_test.exs: Build tests check only partial stage, dependency, vector, and output properties rather than the specified exact D1-D6 assertions.

- index-is-derived-and-outside-the-repo: needs_rework — Needs rework because the approved A1-A6 behavioral proof is not implemented; the current index tests remain smoke assertions despite the implementation being present.
- index-refreshes-only-changed-files: needs_rework — Needs rework because the required B1-B5 proof is missing; current tests do not establish changed-file-only refresh semantics or all removal/refresh results exactly.
- search-finds-intents-and-memory: needs_rework — Needs rework because the approved C1-C9 exact search proof remains substantially weakened to smoke checks.
- check-builds-and-tests-the-crate: needs_rework — Needs rework because the approved build/check proof cases are not implemented; the passing check receipt only verifies the weakened tests that are present.
