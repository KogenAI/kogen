Verdict: not ready

The Draft's approach is sound, and most of its anchors still hold at e65392cf. But a Codex pair starting from the named hunks would hit a compile error from a missing module, one test that cannot pass, and a few contradictions in the expected results. All six issues are cheap to fix in the Draft.

**Blocking findings**

1. **Slice 1 needs a module that slice 2 owns.** The qb files this Draft keeps call `Kogen.ShapingAudit.Questions`:
   - `shaping_audit.ex`: qb slice diff :539, :774-775, :830, :866, :891
   - `deterministic.ex`: :932, :946-951
   - `shaping_audit_checks_test.exs`: :2039, :2074-2075, :2120

   `questions.ex` is not in this slice. It is left out at `evidence/probe-candidate-at-3531023d/slices.py:11` and has no row in `evidence/CANDIDATE.md:16-21`, and slice 2's `CANDIDATE.md:19` takes it whole. The code compiles only if `questions.ex` is ported, and that pulls in slice-2 states and the asking gate. Tests B7 and C2 still need a `## Dispositions` parser. Even ported, qb's parser stores `"text"`, while C2 (`scenarios.yaml:313-315`) asserts `"reason"`. qb's fixtures also write the line as `- <id>: …`, while `INTENT.md:149-150` defines it with no bullet.
   - Fix: add a CANDIDATE row for a slice-1 parser that reads only `## Dispositions`. It should use the key `reason`, accept an optional `- `, and handle only `not a defect`. Remove the calls to `Questions.findings`, `state`, `entries` and the asking state. Tell slice 2 to extend this file rather than take qb's.

2. **The `verification_plan.ex` hunk is not purely additive, and qb's `repository-invalid` depends on it.**
   - `CANDIDATE.md:10`, `INTENT.md:82-83` and `risks.yaml:15-16` describe it as only adding `proof_errors/4`. It also adds `require_no_extra_targets/2` (qb diff :216-251) inside `validate_declared_targets/2` (`lib/kogen/build/verification_plan.ex:283-296`). That is a new Build admission refusal for any extra `check`, `live-*` or `cold-*` Make target.
   - qb detects `repository-invalid` only by that new message (`reason =~ "does not match declared Make targets"`, qb :988). Its layer status is also always `"ok"`.
   - The Draft's A6 fixture is a catalog naming a target the Makefile lacks (`scenarios.yaml:45-46, 121-124`). That case hits the existing `require_ordinary_targets/2`, which says "…has no ordinary Make rule" (`verification_plan.ex:298-306`). With qb's code, A6 gets no finding, readiness `ready` and exit 0, so it fails.
   - Fix: drop the extra-targets hunk (or approve it as a Build change with its own scenario). Specify how `repository-invalid` is recognised: a `VerificationPlan.load/1` error from the catalog/Makefile check, not a substring match. Its layer status is `unavailable`.

3. **The Draft is not rebaselined to e65392cf.**
   - `finish_publication/4` is now at `lib/kogen/build.ex:2732` and the `commit_staged` call at `:2742`, not :2596/:2606. The old numbers appear at `INTENT.md:108-109`, `scenarios.yaml:461`, `references.yaml:25` and `risks.yaml:8-9`.
   - The ledger paragraph in `scripts/check/README.md` is now at :221-226, not 210-215 (`references.yaml:31`, `risks.yaml:26`).
   - `shaped_against` (`intent.yaml:18-27`), "Start from develop 3531023d" (`INTENT.md:17, 69`) and every "applies at 3531023d" claim point at a commit that is not the Build's base. The Draft's own `stale-anchor` rule would flag `lib/kogen/build.ex:2606`.
   - I checked every kept hunk's context by reading the files. Each one still matches at e65392cf: `build.ex` :53-56 and :2739-2745, `verification_plan.ex` :96-101, :287-289, :306-311, `verification_policy.ex` :22-27, `harness.ex` :31-35, `intent.ex` :633-653, `commit_provenance_test.exs` :78-81 and :137-149. I had no shell, so this is not a `git apply --check` run.
   - Fix: rebaseline to e65392cf and update the line numbers.

4. **The test list is not closed.** `CANDIDATE.md:20-21` says "Start here, then add". That keeps qb tests which contradict this Draft:
   - "ledger-unstated … no refresh command" (qb :2194);
   - the extra-Make-target `repository-invalid` test (qb :2467-2489);
   - the old-shape `prior_failures/3` test (qb :2395);
   - "preservation … still pass" (qb :2544-2554). It runs a nested `mix test` in the checkout from an `async: true` test, which risks lock and `_build` contention under the gate (lesson 25). It is also redundant, since both files are already proof selectors.
   - qb's task tests use fake layers and a `demo` package, and assert `state`, `jev` and `auditor` keys (qb :2628-2796). They are not built on `Fixture.repo!` and `complete`.

   Fix: state that the two files contain exactly A1–A7, B1–B7, C1–C6 and D1–D8. Say whether the "A1"-style prefix is part of each test name, and say that every other qb test is removed.

5. **D7's fixture is not specified, and neither Candidate has one.**
   - `Kogen.CompiledFixture.mix_task!/3` (`test/support/compiled_fixture.exs:88-109`) runs `elixir -S mix` in the fixture. That needs the `mix.exs`/`deps`/`lib` layout from `create!/2` (:52-85), which also writes its own `.kogen/config.yaml` and a check-only Makefile.
   - `Fixture.repo!` (`scenarios.yaml:2-26`) has no `mix.exs`. It also has no `.kogen/config.yaml`, which `main/2` reads from the checkout and D2 (:416-417) needs with routes `codex` and `other`.
   - qb's D7 is only a source grep (qb :3315-3320).
   - Fix: add something like a `Fixture.repo!(compiled: true)` option that builds on `CompiledFixture.create!` and then writes the Makefile, catalog and config and commits. Add `.kogen/config.yaml` to the fixture header.

6. **Some given text contradicts the exact expected results.**
   - `stale-disputed` is "the same [as stale], plus the disposition" (`scenarios.yaml:264-265`). `stale` also cites `lib/a.ex:3`, so an undisputed `stale-anchor lib/a.ex:3` would remain and C2's exit 0 / `ready` (:313-315) could not hold. qb's fixture cites only `cited_bytes` (Zuj slice diff :4143-4203); say so in the Draft.
   - A2 (:99-102) runs `build/4` "on the same materialization" after `main/2`, which has already removed it. Say "a fresh materialization of the same HEAD and package".
   - A3 (:104-107) cannot call `build/4` on `invalid`, which has no scenario list. qb skips it (qb :2510); say so.
   - B2's sentence starts with a capital "Delete", but `INTENT.md:175-180` lists lowercase words and never says matching is case-insensitive. State that it is.

**Brief notes (not blocking)**

- **Ledger.** It is handled for the Build: E2 keeps the catalogued name "first and subsequent Builds record truthful automated provenance" (row `…commit-provenance-test-exs:t001`), and E1 only adds a test, so no row change is needed. But the Draft fails its own mechanical `ledger-closure` rule: it edits `intent_test.exs` (catalogued as rows t001–t020) and `commit_provenance_test.exs` without guarding `priv/kogen/test-reliability.yaml`. Guard it; Assumed 10 already says that is harmless.
- **failure-reports.** Builds now write `failure-report.json` beside `record.json` (`lib/kogen/build/failure_report.ex:31-38, 112-134`; `README.md:111-123`). It carries `intent_id`, a signature digest, `category` and `same_signature_count`. `prior-failures` (`INTENT.md:224-234`) still parses only `record.json`, which remains valid: `attempts[].failure` is still a string (`build.ex:2129, 2334`). Decide explicitly whether to keep that or prefer the new report.
- **Gate evidence.** Probe P1 ran only `mix test`. `check` also runs `mix format --check-formatted`, `mix compile --warnings-as-errors --force` and `mix credo --strict` (`scripts/check/offline.py:22-28`). Whether qb's files pass `credo --strict` is untested; worth a probe.
- **Checked and fine at e65392cf:**
  - Function anchors: `build/4` :66, `validate_added` :190 and `validate_proofs` :499 in `verification_plan.ex`; `verification_policy.ex` :18/:19/:34; `settings_path` at `claude.ex:232`; `intent.ex:633/635`; `git.ex:256`; `test_reliability_catalog.ex:36`. The refresh script is absent.
  - `ctx.intent` comes from `Intent.read/2` (`build.ex:114`), so `Map.get(ctx.intent, :commit_subject)` works.
  - The guarded paths cover every file the plan touches, including a new `questions.ex`.
  - Every proof selector passes admission, and the extra `tests` key is allowed (`contract.ex:13, 273-277`).
  - The Zuj `commit_provenance_test.exs` hunk still matches the file.
- **Untested spec.** The multi-line commit-subject rule and the `prepare` and `proving-run` branches of `paid-path-unproven` have no test.

I read the checkout directly: `develop` is at e65392cf, and I assumed the working tree is clean. This session was in plan mode without a write tool, so I gave the review here rather than writing a plan file. Separately, the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used.
