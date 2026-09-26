I found four blocking defects, two of them in the new test-catalog scenario. I'd also split the Intent before approval, because 28 scenarios is too much for one Developer conversation.

## Blocking

**B1. `test-catalog-binds-declarations`: removing a stale row stops the Build.**
- **Failure:** The scenario lets the Developer remove a stale row. `validate_remediation` then requires matching edits to `priv/kogen/test-reliability-remediation.yaml`: the count and per-row fields must agree (`test/support/test_reliability_catalog.ex:33-51`, `test_reliability_catalog_test.exs:11,19`). That file is not in `may_change_guarded_paths`. Main stops on a guard violation (`guarded_paths.ex:51-57`, `build.ex:1172-1173`).
- **Fix:** Add that file to `may_change_guarded_paths` and to the scenario's `affected_paths`. Otherwise, allow only edits to `declaration` and forbid removal.

**B2. Same scenario: the "generator reads full test names" clause can't be met.**
- **Failure:** `generate_test_reliability.py:64` copies `row["declaration"]` verbatim from an ignored runtime file, `.kogen/runtime/.../coverage-matrix.json` (`:14,95`). The apostrophe truncation happened upstream, in an untracked matrix builder, so REPORT §1(c)'s claim that the generator cut them is wrong. The Candidate worktree has no matrix, so the Developer can't fix or test this, and Review can reject the unmet `then`.
- **Fix:** Drop the clause. Repair the two rows by hand; the name-binding check is what stops a repeat.

**B3. `docs-and-prompts-checked-by-meaning`: its new rule fails on today's README.**
- **Failure:** The rule is "every path named in backticks exists". README names paths that never exist in a Candidate worktree or gitless copy:
  - `.kogen/build.lock` (:109, :206)
  - `.kogen/runtime/verification.json` (:137)
  - `.kogen/runtime/scenario-tracking/<build-id>/…` (:259, :306)
  - `deps/` and `_build/` (:84-86)

  Its `Module.function/arity` citations are short aliases, such as `VerificationPlan.load/1` (:557). The Developer either fails `check` or writes an ad-hoc allowlist, which is a new rigid rule.
- **Fix:** Define the rule in the contract:
  - only paths whose first segment is tracked in Git count;
  - `<placeholder>` segments and ignored or runtime paths are skipped;
  - a short module name resolves to exactly one `Kogen.*` module.

**B4. `INTENT.md:92` contradicts `prepare-rehearsed-in-check`.**
- **Failure:** INTENT says rehearsals.exs enforces "every live target has a `prepare`". The scenario (`scenarios.yaml:236-238`) gives `prepare` to only three targets. Built literally, `check` fails, or the Developer adds a `prepare` to live-native, whose `lib/kogen/codex/compatibility.ex` is outside the guarded paths.
- **Fix:** Reword INTENT to "rehearses every declared `prepare`".

**B5. Appetite: 28 scenarios won't fit one conversation.**
- **Why:** This Build still runs under main's accounting, so every formatting or compile failure spends one of three paid cycles. Each cycle runs `check` (about 4 min), smoke (about 2.5 min) and live-reviewer-rework (6-13 min). live-reviewer-rework's nested Build (`live_reviewer_rework_fixture.ex:111`) runs the Candidate's whole new controller: custody, status, prepare and budgets. Any bug there fails a paid target.
- **Scenarios out of proportion:**
  - `process-custody-teardown` and `stale-lock-and-orphan-sweep`: every launch site, signal traps, pty kill tests.
  - `build-status-output` and `build-notify`: pty rendering, with no reliability effect.
  - `docs-and-prompts-checked-by-meaning`: 7 test files plus a new resolver.
- **Fix:** Split these into a follow-up Intent.

## Non-blocking

- **Prompts come from control, not the Candidate.** At 7ed41f66 main renders both prompts from control (`build.ex:2259-2261`, `:2312-2314`, `roots/1` at `:1706`). So these are stale:
  - risk `self-hosting-review`;
  - the "Self-hosting" paragraph in `per-launch-verdict-schema`;
  - INTENT's `receipt` challenge bullet;
  - `README.md:575-577`.

  The conditional wording is harmless, and `role-prompt-tune-up` has no effect on this Build. The README list should be corrected, since the Intent rewrites README anyway.
- **proof.base is never enforced.** The catalog has no integrity fields (`verification_surface`, `focused_runner`, `base_cache`), so proofs are labelled `integrity-not-configured` (`verification_plan.ex:158`). Every `base: fail` claim is checked only by Review. Each selector would plausibly fail on base; none can fail the Build.
- **Gitless runs.** The new `tracked_ignored_files_test` and the new path-existence check need a skip when Git is absent, as `whole_suite_remediation_test.exs:36-40` does. `cold-offline` runs `check` without Git (`offline.py:144-156`).
- **Contradictions and stale text:**
  - questions.md Q2 still gives live-native a `prepare`.
  - Q3 says `lib/kogen/codex*` and `lib/kogen/claude_code.ex` aren't touched, but custody edits them (`intent.yaml:70-71`, `scenarios.yaml:1070-1071`).
  - `scenarios.yaml:251-256` sends defect (d) to isolated-candidate-workspace; INTENT (:140-143) says a later Intent.
  - Some risks still name 9ff7af6e.
  - `questions.md:47-49` cites a `build_prerequisite` that intent.yaml doesn't have.
- **Smoke target risk.** The smoke was probed only by running `driver.py` directly, never through `make` under a Build. One sample took 156 s against a 300 s bound, and the medium-effort run took 410 s. A timeout spends paid retries.
- **REPORT §5** lists prompt rendering (`build.ex:2223`) as a caller on the Candidate. It actually loads the control catalog.

## Checked and fine

- **Self-hosting:** No scenario needs main's controller to understand anything new.
  - `live-shaping-smoke` has rank 150 (unique) and satisfies `added_rehearsals` (`catalog_change.ex:91-111`).
  - Main's loader ignores `prepare` and `offline_retries` (`verification_plan.ex:292-297`, `intent.ex:83-101`).
  - The Makefile gains only the catalogued target.
- **Guarded paths:** Every `affected_paths` entry matches a guard. All 18 trash files match the globs. The `__pycache__` deletions are volatile, but `git add -A` (`git.ex:238`) publishes them. No owner of an unselected live target is edited.
- **Other REPORT claims hold:**
  - the 7 unresolved rows, including the codex_compatibility tests renamed in 363c20af;
  - `discover/1` and `exunit_declarations/1` have no callers;
  - `read_config` ignores unknown keys;
  - the locators `:144`, `:254`, `:271`, `:292` and `:499` are correct.
