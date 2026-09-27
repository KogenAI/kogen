# Questions and choices

No open questions.

The Shaper delegated every technical decision (DIRECTION rules 46 and 46.5). Items 1–4 are carried over from
`kogen-ctx-tool` (their numbers there in brackets); items 5–10 are new with the split; items 11–13 are new with the
re-preflight at d9013413. Each item states its reason and how to undo it.

## Assumed

1. **Elixir extraction uses tree-sitter only, with a documented lexical alias approximation.** [9] Aliases apply to
   the whole module body regardless of position, function-level aliases included, and nested modules inherit them.
   Imported local calls are not resolved.
   Reason: CTX-03 leaves compiler enrichment evidence-gated (16b program-database). The two fixtures pin the covered
   forms.
   Undo: position-aware alias scopes, or `mix xref` data in 16b.

2. **Ranking parameters are fixed:** damping 0.85, exactly 100 iterations from the personalization vector, dangling
   mass redistributed by `p`, ties by path, tokens estimated as block bytes/4, a default budget of 1,024 tokens, and
   whole blocks only, stopping at the first block that does not fit. [13]
   Reason: deterministic and inspectable (Aider-style). CTX-03 leaves the parameters to agents, and row 15 tunes
   budgets.
   Undo: change the constants, the expected orders and `map_rank_values`.

3. **Plain-text output (one result per line), no `--json`.** [11]
   Reason: as in slice 1.
   Undo: add `--json` with its tests.

4. **`symbols` substring matching is case-sensitive; `refs` distinguishes function and module targets by the case of
   the last segment.** [part of the approved spec]
   Reason: Elixir module names are capitalized and function names are not, so the target's own spelling says which
   kind it is.
   Undo: add explicit `--module` and `--function` flags.

5. **Schema version 2 adds `symbols` and `refs`; slice 1's schema-1 indexes are rebuilt, not migrated.** [new]
   Reason: slice 1 records code files by blob without parsing them. Without the bump, an unchanged file would never
   get symbols. Slice 1's derived-index rule already covers the rebuild.
   Undo: have slice 1 create the tables (not possible once slice 1 has landed).

6. **Ranks that differ by less than 1e-12 are ties, broken by path.** [new, a clarification]
   Reason: the specified orders include exact ties, and floating-point summation order must not break them. No
   expected order changes, because distinct ranks here differ by more than 1e-3.
   Undo: compare ranks exactly.

7. **A second fixture with unrelated names, plus a source scan for fixture-name literals (tests F1–F3).** [new]
   Reason: the Candidate's `resolve_mod` table passed the shop fixture. Lesson 27 asks for fixture-specific tables to
   be named as wrong results, and this makes that result observable.
   Undo: drop `create_alias!/0` and tests F1–F3 (not advised).

8. **A Rust unit test `map_rank_values` pins the rank values.** [new]
   Reason: on this fixture the printed order cannot detect a dropped dangling mass or iteration to convergence
   (evidence/probe/variants.py). The values can: 1e-12 tolerance against a 4e-8 difference from convergence and a
   0.18 difference without dangling mass. The ExUnit test H5 runs it by name.
   Undo: add a third fixture where the order itself differs.

9. **The whole module body is walked, including function heads.** [new, a clarification] So a remote call in a
   default argument is a ref (`lib/outer.ex:2 call Kit.Box.new/0`).
   Reason: a generic walk is simpler than skipping heads, and Elixir does evaluate defaults. The shop fixture's
   outputs are unchanged, because it has no remote calls in heads (probe S1).
   Undo: skip the head argument when walking.

10. **An inner module's alias shadows an enclosing module's alias for the same name.** [new, a clarification]
    Reason: this matches Elixir's lexical scoping, and the alias fixture pins it (`lib/outer.ex:9 call
    Other.Thing.open/0`).
    Undo: let the outer mapping win.

11. **The usage line is extended in place, and usage errors are asserted exactly.** [new, re-preflight] The landed
    `USAGE` keeps its two alternatives and gains `symbols`, `refs` and `map`; E4 and H4 assert stderr equals it.
    Reason: slice 1's tests assert only the `usage: kogen-ctx` prefix so that this extension needs no edit to them;
    this slice's own tests can pin the whole line.
    Undo: assert the prefix only, as slice 1 does.

12. **Option rules extend the landed `parse()`.** [new, re-preflight] `symbols`/`refs` take exactly one positional
    argument; `--limit` keeps the landed `N` rule (default 50 here, 20 for `search`); `--tokens` uses the same rule,
    once, `map` only; `--focus` repeats, `map` only. Every usage error except an unmatched `--focus` is found
    before the root is resolved, as landed (E4 asserts the home stays empty). An unmatched `--focus` needs the
    index, so it is found after the refresh.
    Reason: one parser, one `N` rule, and slice 1's "usage before filesystem work" guarantee kept wherever it can be.
    Undo: report an unmatched focus as a runtime error (exit 1) instead.

13. **No landed test is edited; the fixture only grows.** [new, re-preflight] The guards stay
    `native/kogen-ctx/src/**`, `README.md`, `test/support/ctx_fixture.ex` and the two new test files. The landed
    A1–A6, B1–B5, C1–C9 and D1–D6 must pass unedited (INTENT.md "Existing tests keep their landed names and
    bodies"), and `CtxFixture` gains `alias_sources/0`, `alias_hashes/0` and `create_alias!/0` next to the unchanged
    API.
    Reason: every landed expectation still holds after the extension (the schema check against `0` still rebuilds;
    every A5 usage case is still a usage error; code has no chunks; the lock and dependencies are unchanged), and
    the ledger binds rows by test name.
    Undo: add a landed test file to the guards with its changed expectation stated.

## Audit

- **The split (2026-09-27):**
  - `kogen-ctx-tool`'s codex Build XARfeVP5 did not converge. This slice owns Final Review F3 (captures, pipe arity,
    the fixture-name alias table) and F4 (map ranking, focus, dangling, weights, first-overflow truncation), plus F1
    for its two test files.
  - Scenarios: 4 (lesson 27). Each lists its ExUnit test cases with exact commands and complete expected outputs, and
    names smoke tests and name tables as wrong results.
  - Every expected output of `kogen-ctx-tool` scenarios 4 and 5, and the code parts of scenario 2 steps 3 and 5, is
    carried over unchanged.
  - Probe S1 (a literal reference extractor) reproduces all of those shop outputs from the rules alone. Probe S2
    (`map.py`) reproduces the map orders.
  - New outputs:
    - the 26-line `symbols Shop`;
    - the alias fixture's outputs (from the extractor);
    - `--tokens 64` and `--tokens 10`, and the block sizes;
    - `symbols Shop.Extra` (from the stated rules);
    - the rank values (`ranks.py`).
- **Carried from `kogen-ctx-tool`:** Sol rounds 1–2 and Opus rounds 3–4 (in drafts/kogen-ctx-tool/evidence/reviews/),
  and the delegated human approval of 2026-09-27T07:08:49Z. The split needs its own approval.
- **Deterministic (at shaping):** `plan/tools/validate.exs` on this directory at fa48e817 → `Intent.read` ok,
  `Contract.load` ok, `VerificationPlan.build` ok, `VerificationPolicy.preflight` :ok.
- **Not run:** Sol/Opus readiness rounds on the split packages, a Jev clause audit and an Astra second opinion.
- **Re-preflight at d9013413 (2026-09-27), after slice 1 landed:**
  - `shaped_against.head` → d9013413eeb50af9cc2993fa839acfb277827e27 ("Add kogen-ctx index and search").
  - Citations re-derived from the landed code and tests (evidence/probe-preflight-d9013413.md P-3), and fixed:
    - the fixture module is `Kogen.Test.CtxFixture`, loaded with `Code.require_file`; its runner is
      `run(binary, root, home, args, extra_env \\ [])` (run/5), not `run/4`; the ids and paths come from
      `CtxFixture.project_id/1` and `CtxFixture.index_path/2`;
    - the slice 1 Intent is under `complete/`, not `drafts/`; `create_alias!/0` gains `alias_sources/0` and
      `alias_hashes/0`, as `create!/0` has `sources/0` and `hashes/0`;
    - the schema bump names the landed `init()` and `refresh()` (the `"1"` check and write, the rebuild clear);
    - the usage line extends the landed `USAGE`, pinned exactly (item 11), with the option rules of item 12;
    - the check stages are the landed `CARGO_STAGES` (cargo-fmt, cargo-build, cargo-test), so the new Rust must be
      rustfmt-clean; `.cargo/config.toml` already sets the target dir;
    - README edits must pass the landed `test/kogen/readme_guidance_test.exs` (new risk `readme-guidance-references`).
  - Outputs that depend on slice 1 re-verified against the landed code and tests: the `index` report lines and
    `files 11` (G1, G3 = the landed `initial(root, home, "yes")`), `... <k> more`, the rebuild on damage (G4 mirrors
    A4). New exact outputs: E4 (20 malformed command lines, `{"", USAGE, 2}`, home stays empty), F1's first `index`
    of the alias fixture (7 lines, `files 3 reindexed 3 removed 0`), H4's second unmatched-focus case. G3 now drops
    the `symbols` and `refs` tables, so the damaged file has exactly slice 1's layout.
  - Probes (scratchpad `ctx2/probe/`, no global state changed, CARGO_HOME never set): P-1 builds the reference
    extractor against the landed Cargo.toml/Cargo.lock with `--locked --offline` (lock unchanged); P-2 finds the
    landed shop fixture byte-identical to `evidence/fixture/` and both extractor outputs, `map.py` and `ranks.py`
    unchanged. No expected symbols, refs or map output changed.
  - Launch: no new crate and no Cargo.lock change, so no `cargo fetch` is needed on the Build host (INTENT.md
    "Launch").
  - Starting point: the Candidate-diff instructions are gone; the build starts from the landed crate, and the
    XARfeVP5 diff's extraction and map code is optional reading only.
  - Existing tests: none edited, none guarded; each landed test's expectation after this slice is stated in
    INTENT.md (item 13).
  - `plan/tools/validate.exs` on this directory at d9013413 → `Intent.read` :ok, `Contract.load` ok,
    `VerificationPlan.build` ok (targets `check`; offline `test/kogen/ctx_elixir_test.exs`,
    `test/kogen/ctx_map_test.exs`), `VerificationPolicy.preflight` :ok.
  - Not run: new Sol/Opus readiness rounds on the re-preflighted package.
- Opus re-preflight review at d9013413: ready; notes 1-4 added to INTENT.md "Notes for the Developer".
