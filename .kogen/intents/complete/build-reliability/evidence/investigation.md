# Investigation at 9ff7af6e (2026-09-26)

Method: the Shaping root read the brief, the mining report, the lessons and Astra's
review. Four read-only `kogen-worker` helpers (claude-sonnet-5, medium) mapped A-E.
The root re-checked the consequential locators against the source bytes.
*Historical note:* no probes had been run when this file was written. The probes
run afterwards are summarised in `PROBES.md`.

## A. Accounting
- `run_cycle/4`, `lib/kogen/build/verification.ex:130-191`: `after_count` over
  `verification_retries` gives `"exhausted"` (line 176). `run_targets/4` halts on
  the first failure, in catalog order (:193-212).
- The offline gate is emergent. Every provider entry has `dependencies: [check]`,
  `selected_order/3` requires the dependencies, and `check` has rank 0. There is
  no class rule.
- Config: `lib/kogen/intent.ex:82-101` requires integer keys and does not reject
  unknown keys.
- Catalog loader: `valid_entry?/1` (`verification_plan.ex:292-297`) ignores extra
  keys. `CatalogChange.check/4` keeps each existing target's admission entry
  (`catalog_change.ex:4-14`).
- Provider evidence: `String.slice(output, 0, 4000)`, which keeps the head, at
  `lib/kogen/harness/claude.ex:335,340,359` and `lib/kogen/harness/codex.ex:250,304,315`.
  A Developer-turn provider failure stops the Build unclassified
  (`lib/kogen/build.ex:836-857`). `ProviderOutcome` has no usage-limit or
  overload kind.

## B. Prepare
- offline.py stages: format, compile, and the clang guard in parallel; then credo,
  `mix test --exclude live --warnings-as-errors`, and then `rehearsals.exs`. There
  is no test-compile-first stage.
- rehearsals.exs checks the paired-fixture contract and trace assertions. It does
  not check copy exclusions, warm seed, isolated compile, login scope or toolchain.
  `Kogen.CompiledFixture.prepare_build!/2` does not exist.
- Private owner setups: `test/kogen/live_test.exs:319` `setup_fixture/2`, and
  `test/kogen/live_shape_to_build_test.exs:649-701` `setup_fixture/3` and
  `precompile!/2`. The reviewer-rework setup is in
  `test/support/live_reviewer_rework_fixture.ex` (login preflights at :83-84,
  precompile at :218). Shaping-quality setup is in `driver.py`. Live-native setup
  is in `Kogen.Codex.Compatibility.prepare_fixture`.
- Defect (a) is still open: `test/support/shaping_evaluation/driver.py:348-349`
  rsync excludes `.kogen/runtime`, but not `.kogen/build.lock`. The two other
  copiers exclude it.
- Defect (b) is fixed in 9ff7af6e (`record_finished_at/1`). There is no dedicated
  regression in rehearsals.
- Defect (c) is avoided by the prompt redesign (empty `messages` for the stateful
  cases). There is no fail-fast guard.
- Defect (d) is in the unlanded containment audit (stash@{0}), so it is not
  present at HEAD. Scope keys hash `Path.expand(project)`, which does not resolve
  symlinks.

## C. Handoff
- `verification_failure_prompt/3`, `lib/kogen/build.ex:520-561`: one receipt, one
  log with its sha, and `String.slice(output, -6_000, 6_000)`.
- `TargetEvidence.capture/4` runs for every receipt, pass or fail
  (`verification.ex:308`).
- The driver's `run_suite`, `driver.py:1097-1159`, cancels all pending cases on the
  first nonzero exit and writes `suite-failure.json` with `cancelled_children`.
  `SUITE_SECONDS = MAX_SECONDS + 120` (720 s). The driver runs 7 cases, and the
  owner's text still says "five-session".
- The owner prints the manifest only after `assert status == 0`
  (`live_shaping_evaluation_test.exs:45-90`). The driver's `write_manifest` runs
  only on success (`driver.py:1154`).

## D. Signatures
- `failure_signature.ex`: `@head_limit 320` and digest = sha256(target, identity,
  head). Nothing reads `repeated` outside its own test.
- The Candidate id is a git tree digest (`lib/kogen/git.ex:130-150`).
- Real receipts exist, for example a2sPFUvF cycle 1: 18,206 chars, with
  `Stage elapsed (…)` markers and ExUnit `  2) test …` headers.

## E. Verdict
- `lib/kogen/harness/verdict.ex`: `schema/1` is static, with no id enum and a
  path that is only a `minLength` string. `validate/2` returns a bare `:error`
  (:143-148).
- Codex gets `--output-schema <file>` (`codex.ex:63-71`), and Claude gets
  `--json-schema` inline (`claude.ex:132`). `enum`, `minItems` and `maxItems`
  already appear in the ledger extension.
- Both adapters return `reviewer_session_id` with `:malformed_verdict`. There is
  no `resume_reviewer`. `resume_developer` exists in both adapters and is the
  pattern to mirror.
- The review packet cites receipts as `/receipts/N` pointers
  (`review_packet.ex:229-278`).
- `Contract.verdict/4` requires exact top-level keys (`contract.ex:125-132`).
- The live-reviewer-rework fixture runs `--route claude-dominant-adversarial-codex`,
  so its Reviewer is Codex.
