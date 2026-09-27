# Questions and choices

No open questions.

The Shaper delegated every technical decision (DIRECTION rules 46 and 46.5: "you gotta handle EVERYTHING"). None of
these touches UX, DX or product direction beyond what rule 46.2 already approved: `kogen ctx` is in the approved
command set, and this row ships it as `kogen-ctx` until rust-native-edge makes the one `kogen` binary. Items 1–8 and
10–15 are carried over from `kogen-ctx-tool` (their numbers there are given in brackets). Items 16–20 are new with the
split, and 21–26 came from Opus slice-1 round 1. Each item states its reason and how to undo it.

## Assumed

1. **Crate at `native/kogen-ctx/`: one package, one binary `kogen-ctx`, no Cargo workspace.** [1]
   Reason: this is the thinnest first slice of the native edge (D6). A workspace, or a `kogen` binary with only `ctx`
   in it, would be plumbing for rust-native-edge (rule 16). `native/` matches codegen-core's layout (CTX-03 "Current
   state").
   Undo: move the crate under a `native/Cargo.toml` workspace when rust-native-edge adds the `kogen` binary, and remove
   `kogen-ctx` in that same Intent (rule 44).

2. **No vendoring. Crates come from the machine's shared cargo cache, fetched outside Builds.** [2]
   Every Build-time cargo command is `--locked --offline`. `mix kogen.ctx.build` runs `cargo fetch --locked`, and so
   does the launch precondition for this Build only. `mix kogen.ctx.build --offline`, the only form tests run, runs
   `cargo fetch --locked --offline` (Assumed 11).
   Reason:
   - The Developer's write boundary allows network (`WriteBoundary.render/1` has `(allow default)` and no network
     rule) but makes `~/.cargo` read-only. So `cargo fetch` into it fails with EPERM (P2 S4), while an offline build
     from a warm read-only cache works (S1, S7).
   - The controller's `make check` runs outside the boundary, but it is the offline gate (Hex offline, "never fetch
     during a measurement"), so it must not fetch either.
   - Vendoring would commit 85 MB of crate sources (P2), most of which is never compiled on macOS.
   - A warm `cargo fetch --locked` needs no network (S6), so the task is safe to rerun. This mirrors `deps/`.
   Undo: `cargo vendor` into `native/kogen-ctx/vendor/` with a `[source]` replacement in `.cargo/config.toml`, guard
   it, and drop the launch precondition.

3. **`mise.toml` pins `rust = "1.97.1"`; there is no `rust-toolchain.toml`.** [3]
   Reason:
   - `mise.toml` is already the project's toolchain manifest.
   - Both Macs pin 1.97.1 only globally today, and the MacBook's rustup default is `stable` (P1).
   - Candidate worktrees stay trusted by mise after the edit (P1).
   - A crate-level `rust-toolchain.toml` is not consulted from the repo root with `--manifest-path`.
   - P7 found no warning from test_helper's `mise which python3` with the pin, in every variant probed.
   Undo: remove the line.

4. **No new catalog target. The three cargo commands become stages of `check`'s preparation phase in
   `offline.py`.** [4]
   Reason:
   - Proof selectors must be ExUnit files (`VerificationPlan` `valid_selector?/4`).
   - Building in the preparation phase keeps the ~20 s cold release build away from the timed ExUnit tests, and makes
     the tests' own build a no-op.
   - No cataloged test is edited.
   Undo: remove `CARGO_STAGES` from `plan_phases`, add a `native` Make target and a catalog entry, and select it in
   each scenario's `verified_by`.

5. **Cargo output goes to `_build/cargo`: `--target-dir` everywhere, plus `.cargo/config.toml` for cargo run inside
   the crate.** [5]
   Reason: `_build` is volatile for `GuardedPaths`, excluded from offline.py's source manifest and never copied into
   a Candidate. `native/kogen-ctx/target/` would be a stray-path violation in every Build (P3).
   Undo: add `native/kogen-ctx/target` to `@volatile` in `GuardedPaths` and to `SOURCE_EXCLUDES`.

6. **The index lives at `$KOGEN_CTX_HOME` or `~/Library/Caches/Kogen/ctx`, as `<project id>/index.sqlite`. The id
   is `Kogen.Build.Workspace.project_id/1`'s SHA-256 of the canonical checkout path, so a Candidate worktree gets
   its own index.** [6]
   Reason: D5 and research/context-management.md (a) call for a derived, machine-local, never-committed, rebuildable
   index; macOS `Caches` is the place for purgeable derived data; and the canonical-project-scope key is already
   shared by the login selectors and the workspaces root. Coverage note for the orchestrator: CTX-03's "per-Build
   worktree overlay over a shared base" is not in this row; it belongs with row 15.
   Undo: key a Candidate by its git-common-dir's checkout and add an overlay table.

7. **Every query refreshes the index first; `index` only refreshes and reports.** [7]
   Reason: rule 44 (loud, never silently stale) and D5's "validated just in time". A refresh costs one
   `git ls-files`, one `git hash-object --stdin-paths` and re-reading only the changed files.
   Undo: add a `--no-refresh` flag for callers that refresh explicitly.

8. **`search` covers Intents and memory only.** [8] It uses FTS5 with the default `unicode61` tokenizer, no stemming,
   all terms required, bm25 order, and each term quoted with `"` doubled.
   Reason:
   - This is the row's text ("derived FTS index over memory and Intents").
   - Trigram and porter would make hit sets fuzzy and harder to prove.
   - Doubling is FTS5's own escape, so every user byte reaches the tokenizer and none reaches the query syntax.
   Coverage note: CTX-03's `memory` subcommand has no caller yet (rule 16); memory is searchable here as `[memory]`
   hits.
   Undo: add code chunks with kind `code`, or `tokenize = 'trigram'`.

9. **Plain-text output (one result per line), no `--json`.** [11]
   Reason: grep-like lines are the cheapest for agents in bash, and they are what slice 3's MCP text carries.
   Undo: add `--json` with its tests.

10. **Hand-written SHA-256 (`src/sha256.rs`, all four FIPS 180-2 vectors) instead of the `sha2` crate.** [12]
    Reason: it is used only for the project id, and `sha2 0.10.9` would add 9 crates (P2). The vector test and the
    equality with `Kogen.Build.Workspace.project_id/1` (test A1) pin it.
    Undo: add `sha2` and re-fetch.

11. **`mix kogen.ctx.build --offline` (`Kogen.Ctx.fetch(root, offline: true)`) is the only fetch that `check` and
    the tests run.** [14]
    Reason: the controller's `check` runs outside the write boundary, so a plain `cargo fetch --locked` there would
    silently download on a cold cache; `--offline` fails instead (P8).
    Undo: remove the flag, and have the test call `Kogen.Ctx.build/1` only.

12. **The root `.gitignore` gains `/native/kogen-ctx/target/` (declared in `may_change_guarded_paths`).** [15]
    Reason: cargo from the repo root without `--target-dir` writes ~123 MB there (P6), and `git add -A` would commit
    it. A declared root `.gitignore` edit is an ordinary guarded change.
    Undo: drop the line and the guard entry, and rely on test D1 alone.

13. **The fixture's bytes live in `test/support/ctx_fixture.ex`, with the seven Elixir sources' SHA-256s pinned. No
    test reads the checkout's `.kogen/`.** [16]
    Reason: `evidence/fixture/` moves to `complete/`, and the cold-offline copy excludes `.kogen/intents`.
    Undo: store the sources as files under `test/fixtures/ctx/`.

14. **The binary is built once per test run (a `:persistent_term` cache in `CtxFixture.binary/0`), and binary runs
    keep `PATH=/usr/bin:/bin` despite Apple's git launcher.** [17]
    Reason: `Kogen.Ctx.build/1` is a 1–2 s fingerprint check even when warm, and the launcher costs ~8 ms per git
    call (P9). That is cheaper than weakening the no-BEAM proof.
    Undo: prepend `Path.dirname(System.get_env("KOGEN_CHECK_GIT"))` to PATH when that directory has no `elixir`,
    `erl` or `mix`.

15. **The index's `KOGEN_CTX_HOME` in tests is a separate temp dir, never inside the fixture checkout.** [new rule
    from the Candidate's fixture]
    Reason: a home inside the checkout shows up in `git status`. That breaks scenario A(d), and it is the
    "written inside the checkout" wrong result.
    Undo: none needed; it is a test-hygiene rule.

16. **Split `kogen-ctx-tool` into three Intents, and start this one from the saved Candidate.** [new]
    Reason: lesson 27 (3–5 scenarios on the codex route; split at the first non-converging stop; start the first
    slice from the saved Candidate). The Candidate's build wiring, crate skeleton, Kogen.Ctx, mix task and fixture
    bytes matched the design. Its failures were in the tests (F1), search quoting (F2), Elixir extraction (F3), map
    (F4) and the SHA-256 vector set (F6).
    Undo: re-approve `kogen-ctx-tool` from drafts/ as one Intent.

17. **Schema 1 has only `meta`, `files` and `chunks`. Code files are recorded by blob but not parsed until slice
    2, which adds `symbols` and `refs` and bumps `schema_version` to `2`.** [new]
    Reason: no unused tables (rule 16). The bump makes every index written by this slice's binary rebuild once
    under slice 2, so a code file whose blob is unchanged still gets its symbols. Tests in this slice never assert
    the literal `schema_version`, so slice 2 needs no edit here.
    Undo: create the slice-2 tables now and keep schema 1 throughout.

18. **The four dependencies are pinned now, although tree-sitter, tree-sitter-elixir and serde_json are unused until
    slices 2 and 3.** [new]
    Reason: the lock and the launch fetch stay identical across the three slices, and machines that fetched for
    `kogen-ctx-tool` are already warm. Unused crate dependencies do not warn (`unused_crate_dependencies` is
    allow-by-default), so `#![deny(warnings)]` holds.
    Undo: drop them from Cargo.toml and regenerate a smaller lock (which needs a new launch fetch).

19. **Tests capture stderr separately through `/bin/sh -c 'err="$1"; shift; exec "$0" "$@" 2>"$err"'`.** [new]
    Reason: `System.cmd/3` can only merge stderr into stdout, while the scenarios assert complete stdout and exact
    stderr separately. `/bin/sh` is on the restricted PATH, so the no-BEAM proof holds.
    Undo: use an Erlang Port with `:stderr_to_stdout` off, and read stderr through a file descriptor.

20. **Usage errors are detected before the root is resolved.** [new, a clarification]
    Reason: `kogen-ctx` with no arguments is a usage error (exit 2) wherever it runs. The original spec did not order
    the two checks. Test A5 (v) runs it outside a checkout.
    Undo: resolve the root first.

21. **The full usage grammar is fixed in INTENT.md "CLI surface", and tests assert only the `usage: kogen-ctx`
    prefix of the usage line.** [new, Opus slice-1 round 1]
    The subcommand comes first; `--root` and `--limit` may appear anywhere after it, at most once each; any other
    `--` argument is an unknown option; `index` takes no other argument; `N` is a positive decimal integer. The usage
    line is `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR]`.
    Reason: the Candidate accepted `--limit 0`, ignored a valueless `--root` and extra `index` arguments, and a
    Reviewer can only hold a Build to rules the Intent states. Asserting only the prefix lets slices 2 and 3 extend
    the line without editing this slice's tests (as with `schema_version`, Assumed 17).
    Undo: accept `--opt=value` forms or a leading `--root`, with tests.

22. **A file that becomes skipped counts as removed: its rows go, and it gets one `removed` line.** [new, Opus
    slice-1 round 1]
    Reason: the index must match what a fresh rebuild would hold (a rebuild would not index the file), and "removed"
    is the report's existing word for "no longer indexed". Test B5.
    Undo: keep a skipped file's last good rows and report nothing.

23. **Only files that pass the skip filters go to `git hash-object --stdin-paths`.** [new, Opus slice-1 round 1]
    Reason: one missing or unreadable path fails the whole call, and `git ls-files --cached` still lists a deleted
    tracked file (B3). Filtering first also avoids hashing 614,400-byte files that are then dropped.
    Undo: hash every listed path with `--stdin-paths` per file and ignore failures (one git call per file again).

24. **No `KOGEN_CTX_HOME` and no `HOME` is a runtime error (`kogen-ctx: HOME is not set; set KOGEN_CTX_HOME to a
    writable directory`, exit 1), and every index write failure uses the `cannot write index at …` wording.** [new,
    Opus slice-1 round 1]
    Reason: rule 44 (loud). The Candidate's relative fallback wrote inside the checkout, and bare SQLite errors after
    the open gave no advice. Tests A6 (i) and (ii).
    Undo: fall back to `std::env::temp_dir()` joined with `Kogen/ctx`.

25. **The README section goes before `## Run the checks` and names only `index` and `search`; the check-README
    change goes into step 1 of the check order.** [new, Opus slice-1 round 1]
    Reason: the Candidate's section sat after the copyright line and advertised slices 2-3; its check-README
    paragraph sat after the ledger section, away from the ordered steps it changes. Neither is proven by a test
    beyond `readme_guidance_test.exs`, so the Reviewer checks placement and content.
    Undo: move the section; each later slice extends it anyway.

26. **`mix kogen.ctx.build` does not call `Mix.Task.run("app.start")`.** [new, Opus slice-1 round 1]
    Reason: no other `kogen.*` task does, and fetch and build need nothing started.
    Undo: add the call back.

## Audit

- **The split (2026-09-27):**
  - The approved `kogen-ctx-tool` (7 scenarios) went to a codex Build (XARfeVP5). It produced a 2036-line Candidate
    and stopped after 2 outer resumptions.
  - Final Review:
    - F1: proof tests were 14–39-line smoke checks.
    - F2: FTS quotes stripped instead of doubled.
    - F3: capture refs missing, pipe arity wrong, alias resolution a table of fixture names.
    - F4: map ranking, focus, dangling, weights and first-overflow truncation wrong.
    - F5: MCP schemas (closed).
    - F6: SHA-256 vector set and build proof incomplete.
  - Following lesson 27, it is split into three slices in landing order:
    1. this one (crate, check wiring, `index`, `search`: 4 scenarios, starting from the Candidate);
    2. `kogen-ctx-symbols-and-map` (tree-sitter `symbols`/`refs` and `map`);
    3. `kogen-ctx-mcp` (the MCP server).
  - This slice takes F1 (its three test files), F2 and F6, plus the `... k more` count, the 60-line cut, the single
    `hash-object --stdin-paths` call and the fixture home.
  - Every scenario now lists its ExUnit test cases with exact commands and complete expected outputs, and names
    smoke tests as a wrong result.
  - Every expected output of the original scenarios 1, 2, 3 and 7 that concerns `index` and `search` is carried over
    unchanged. Their symbols/refs/map parts move to slice 2.
  - New expected outputs:
    - test B4 (query refresh through `search`, replacing the original's `symbols Shop.Tax.vat` step, which moves to
      slice 2);
    - test C9 (60-line cut; snippet lengths computed with Python);
    - D4's lock hash (`shasum -a 256`);
    - the 448-bit vector (`shasum -a 256` of the message).
  - Checked: `git apply --check` of the Candidate at fa48e817 (clean), and the Candidate's Cargo.lock is
    byte-identical to evidence/cargo/Cargo.lock.
- **Carried from `kogen-ctx-tool`:**
  - Sol round 1 (NOT READY, all blocking findings adopted) and Sol round 2 (READY).
  - Opus round 3 (NOT READY: canonical path message and fixture home, fixed with probes P7–P9) and Opus round 4
    (READY). Their files are in drafts/kogen-ctx-tool/evidence/reviews/.
  - Human Shaper approval, by delegation to the orchestrator, on 2026-09-27T07:08:49Z.
  - This split is a re-shape and needs its own approval.
- **Opus slice-1 round 1 (2026-09-27): not ready** (evidence/reviews/opus-round-1.md). All findings adopted:
  - Blocking 1: `test/kogen/ctx_mcp_test.exs` and `test/kogen/ctx_tool_test.exs` added to **Delete**; a **Rewrite**
    bullet for the README.md hunk (a `##` section before `## Run the checks`, only `index` and `search`, no
    `symbols`/`refs`/`map`/`mcp`/`claude mcp add`) and the scripts/check/README.md hunk (cargo stages in step 1,
    prerequisite at line 3, never-fetch next to line 56); references.yaml's Candidate note and risk
    `candidate-carries-out-of-scope-code` updated to match.
  - Blocking 2: the CLI fixes added to the fix list; "CLI surface" now states the full grammar and usage line
    (Assumed 21); tests A5 (v)-(viii) enumerate 14 usage-error runs, including two outside a checkout, plus an empty
    KOGEN_CTX_HOME afterwards; C3 adds `--limit 1` → `... 4 more`.
  - Notes: hash only filtered files (Assumed 23); a file that becomes skipped is `removed` (Assumed 22, test B5);
    every write error uses the KOGEN_CTX_HOME wording and no HOME is an error (Assumed 24, test A6);
    `Mix.Task.run("app.start")` dropped (Assumed 26); rustfmt probed (P10: Mac Studio `mise exec rust@1.97.1 --
    rustfmt --version` and `cargo fmt --version` → `rustfmt 1.9.0-stable (8bab26f4f6 2026-07-14)`, rustfmt
    component installed, `cargo --version` at the repo root 1.97.1; the MacBook not probed).
  - New expected outputs (B5, A5 (v)-(viii), A6, C3's `--limit 1`) are derived from the spec, not from a run.
- **Deterministic:** `plan/tools/validate.exs` on this directory at fa48e817 → `Intent.read` ok, `Contract.load` ok,
  `VerificationPlan.build` ok, `VerificationPolicy.preflight` :ok.
- **Not run:** a second Opus round on these fixes, Sol rounds on the split packages, a Jev clause audit and an Astra
  second opinion.
- Opus slice-1 round 2: ready; HOME check placed before root resolution (note applied).
