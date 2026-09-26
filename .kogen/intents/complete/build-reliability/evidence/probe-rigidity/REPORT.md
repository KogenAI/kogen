# Probe: rules that fail Builds for simple changes (2026-09-26, continuation visit)

Principle from the Shaper (this visit): "it needs to be flexible enough that it can
be changed on the fly, that the builds pass, but we have to make the builds also
follow certain rules so that the code quality is great at the end".

The test applied to every rule below:
- **keep** if it protects behavior, isolation, formatting, lint, warnings, or a
  reference that a consumer resolves;
- **relax** if it only freezes past bytes, wording, counts, layout or a commit.

Relaxing never removes the protection a rule really gives. Where a pin was the
only carrier of a real protection, it is replaced by a semantic check.

All probes ran in disposable clones of 7ed41f66 under the Shaping scratchpad
(`probe-config/clone-config`, `probe-checkside/clone-checkside`,
`probe-catalog`). The real checkout was never edited. Two `kogen-worker`
helpers ran the clone probes; the Shaping root verified the consequential
claims against source bytes and corrected one wrong locator (below).

## 1. Test-reliability hash catalog

Source: `test/support/test_reliability_catalog.ex` (`validate_row` :88-120,
`source_bound?` :144-152, `discover/1` :168-179, `exunit_declarations/1` :58-63),
`priv/kogen/test-reliability.yaml` (JSON, 346 rows),
`scripts/check/refresh_test_reliability_sources.py`,
`scripts/check/generate_test_reliability.py:81`.

- (a) A comment appended to `test/kogen/approved_mutation_test.exs` makes
  `mix test test/kogen/test_reliability_catalog_test.exs` fail with
  `test-kogen-approved-mutation-test-exs:t001: source binding is stale`.
- (b) Control: with `source_bound?` forced true in the clone, renaming the
  catalogued test's title was **not** detected. No other check cross-references
  `declaration` with the file's tests. `discover/1` and
  `exunit_declarations/1` exist but have no callers (root grep: none).
- (c) Root probe `resolve_declarations.py` against the real checkout
  (`resolve-result-7ed41f66.txt`): 274 declarations resolve to `test "..."` in
  their file, 65 live in non-ExUnit files, **7 do not resolve**:
  - 4 in `codex_compatibility_test.exs` (t001-t004). Commit 363c20af deleted or
    renamed those tests (`git show 363c20af`: `-  test "evidence requires an
    initial rework, …"`, `+  test "failed evidence names environment
    mismatches"`), and only refreshed the hashes (2-line catalog change);
  - 1 in `lifecycle_test.exs` (t001), renamed since;
  - 2 truncated at an apostrophe (`harness_args_test.exs`
    t004 "…as Codex" for "…as Codex's interactive initial prompt";
    `scenario_tracking_test.exs` t007 "…preserves the Developer").
    *Correction (Opus review):* the generator copies `declaration` verbatim
    from an ignored runtime matrix
    (`generate_test_reliability.py:14,66`), so the truncation happened
    upstream, not in the generator.
- Non-ExUnit rows: all 55 Python rows resolve to `def <declaration>` in their
  file; the 10 rows in `test/support/{isolation,scheduling_overlap}_probe.exs`
  resolve to `test "<declaration>"`.

Conclusion: the byte hash fails every legitimate edit, yet it does not keep
declarations true, because the only fix is a script that rewrites the hash
unconditionally. Resolving each declaration against the file's real test names
catches renames and deletions (7 today) and lets ordinary edits pass.

## 2. Config frozen by a test

`test/kogen/configuration_support_contract_test.exs:47-48`. With
`offline_retries: 4` appended, 9/10 pass and 1 fails at `:48`
(`String.ends_with?(tracked, "outer_resumptions: 2\nverification_retries: 2\n")`).
`Kogen.Intent.read_config/2` (`lib/kogen/intent.ex:83-101`) accepted the same
config (`{:ok, …}`): it ignores unknown top-level keys. So the suffix is the only
thing tying the file's tail to anything, and it protects no behavior. The route
matrix assertions (`:50-60`, exactly four routes, one Codex route) pin the
current set of routes.

## 3. Prose asserted as tests

Known: `test/kogen/readme_guidance_test.exs:8-58`,
`test/kogen/execution_policy_test.exs:44-48`. Classified per assertion:
- placeholders (`{{verification_ownership}}`): keep, code substitutes them;
- path/module strings quoted in README (`readme_guidance_test.exs:28-42`):
  checked only as substrings, never resolved on disk;
- role constraints (Reviewer must not modify the Candidate, writes the
  schema-valid verdict itself, same-conversation approval, the Shaping prompt
  must not carry the self-hosting section): real, keep in short form;
- historical phrases and past Intent slugs (`:12-22`, `:48-52`): pins.

Found by the whole-suite sweep (not in the audits):
- `test/kogen/core_integrity_test.exs:74-96,106-139` (13+ README phrases, an
  exact `jev-1.13.0`);
- `test/kogen/shape_task_test.exs:123-207` (about 28 long prompt/README
  sentences, a few of them parsed formats such as `provider-required:`);
- `test/kogen/review_packet_test.exs:305-334` (Reviewer prompt sentences);
- `test/kogen/scenario_contract_test.exs:123-125,162-163`;
- `test/kogen/selective_verification_targets_test.exs:213-230` (README
  phrases; the Makefile recipe checks at `:59-70` are real and stay).

This Intent rewrites README and the Developer and Reviewer prompts, so several
of these fail on its own Candidate.

## 4. Hooks frozen to a commit

`test/kogen/verification_policy_test.exs:170-222` compares `.codex/hooks.json`,
the Claude settings and every hook script with 9ff7af6e. A trailing comment in
`.codex/hooks/verification_policy.py` gives
`.codex/hooks/verification_policy.py changed since 9ff7af6e…` (7/8 pass).
The same file already tests behavior: blocking every covered gate
(`:8`, `:112`), permitting focused tests (`:32`), denying on missing data
(`:47`), registration via `preflight/2` (`:70`, `:134`). The Intent's guarded
paths separately refuse undeclared hook edits during a Build.

## 5. Every Make target must be a catalog target

`lib/kogen/build/verification_plan.ex:262-278` (`MapSet.equal?`),
`lib/kogen/make_inventory.ex:64-95`. In the clone:
- `fmt:\n\tmix format` appended → `VerificationPlan.load()` gives
  `{:error, "verification target catalog does not match declared Make targets"}`;
- `%.txt: ;` → `{:error, "could not read Makefile for verification target
  inventory: pattern Make rule at line 31 is unsupported"}`.

Callers: admission (`build.ex:300`), prompt rendering (`build.ex:2223`, which
loads the control catalog, not the Candidate's; Opus review correction), every
cycle via `CatalogChange.check/4` (`catalog_change.ex:23-48`), and the
`live_reviewer_rework_fixture.ex:96` pre-dispatch check (E8wJA-G0's death,
20.2 min in). **Main's controller runs these on the Candidate every cycle, so
this Build's own Candidate must not add a non-catalog Make target or an
unsupported rule** (risk `self-hosting-relaxations`).

Correction: the helper reported that `verification_plan.ex` has no line 499.
The file has 536 lines, and `:499` sorts by `{rank, name}`. Unique ranks
(`:249-256`) stay, because the `verified_by` order check (`:144`) relies on
them; no Build was lost to them.

## 6. An unused route refuses the selected Build

`lib/kogen/intent.ex:115-127` normalizes every route before selection (comment
at `:115-116` makes it deliberate). A `broken: {harness: claude}` route gives
`{:error, "config.yaml missing required key: routes.broken.shaping"}` with the
default route selected. Callers: `harness.ex`, `build.ex`, `build/tracking.ex`,
`mix/tasks/kogen.shape.ex`. Route-map shape (`:105-111`) and the selected
route's harness and model checks (`:91-93`) stay.

## Examined and left alone

- `selective_verification_targets_test.exs:319-336` validates every approved
  and complete package against the current catalog. It freezes target names in
  history, but it also catches really broken references and no Build was lost to
  it. Not folded.
- No test pins bytes of `.kogen/intents/complete/**`.
- Quality rules that stay: formatting, `credo --strict`, warnings as errors,
  Boundary, prompt placeholders, Makefile recipe paths, write-boundary
  profiles, guarded paths, proof.base, the binding and publication integrity
  checks.

## Limitations

- Single runs. Sweep coverage: every `test/kogen`, `test/support` and
  `scripts/check` file that reads a maintained file; fixture writers were
  skimmed, not read in full.
- The helper probes ran `mix test <file>` in clones with copied `deps/` and
  `_build/`; no `make` target and no provider ran.
