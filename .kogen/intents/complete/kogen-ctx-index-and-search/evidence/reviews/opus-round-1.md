Verdict: not ready

The spec, tests and expected outputs are mostly solid, and I found no output that is wrong. Two gaps in the Candidate instructions would likely cost the Build a Reviewer rework round or a guard violation, which is the kind of failure that sank XARfeVP5.

**Blocking findings**

1. **INTENT.md:43-62: the keep/delete/fix list misses two Candidate test files and doesn't say to rewrite the two doc hunks.**
   - `git apply` also creates `test/kogen/ctx_mcp_test.exs` (diff:1914) and `test/kogen/ctx_tool_test.exs` (diff:1959).
   - Neither file is in `may_change_guarded_paths` (intent.yaml:24-36). If left in place, `GuardedPaths` reports them as stray paths.
   - Both would also fail: `ctx_mcp_test` runs the removed `mcp` subcommand, and `ctx_tool_test` calls the old `CtxFixture.run(binary, root, home, args)`.
   - "F1: replace the three smoke tests" (line 62) doesn't say to delete these two files. Add both to **Delete**.
   - Add a **Rewrite** bullet for the `README.md` hunk (after the copyright line, and it advertises `symbols/refs/map/mcp` and `claude mcp add`).
   - The same bullet should cover the `scripts/check/README.md` hunk. It is a paragraph added after the ledger section, while the spec (INTENT.md:242) wants the cargo stages in step 1 of the check order at scripts/check/README.md:21-27.

2. **INTENT.md:187-192 (CLI surface) and questions.md:148-151 (Assumed 20): part of the specified CLI behaviour has no test and isn't on the fix list, and the Candidate breaks it.** A high-effort Reviewer will catch this, and with no proof test it can bounce between rounds. In the Candidate's `main.rs`:
   - It resolves the root before checking usage (diff:1637-1650), so `kogen-ctx` with no arguments outside a checkout exits 1, not 2.
   - `--root` with no value is silently ignored (diff:1628-1636), and `index` accepts extra arguments.
   - `parse_limit` accepts `0` and negative numbers (diff:1156-1167). The spec says "a positive integer", so `--limit 0` should be a usage error; instead it prints `... 5 more`.
   - The usage string still lists `<index|search|symbols|refs|map|mcp>` (diff:631).

   Fix: add these to the fix list and enumerate tests with exact results, for example A5(v)–(viii):
   - `run(nonrepo_dir, home, [])` → status 2, stderr starts with `usage: kogen-ctx`
   - `["index", "--root"]` → 2
   - `["search", "stray", "--limit", "0"]` → 2, stdout ""
   - `["bogus"]` → 2

**Checked and correct**
- **A1:** the 15-line first `index` output. The count of 11 holds: 7 code files, 3 intents and 1 memory record, with the symlink, latin1, big.md, codex-raw and deps excluded. Sorting is byte order (`lib/shop.ex` before `lib/shop/…`).
- **B1–B4:** the before/after file counts, and `3-4` with the collapsed snippet.
- **Search ordering:** C1, C4 and C5 match `fts5-bm25-probe.txt`. The C2/C3 tie between scenarios.yaml and the memory record (both 18 tokens with `stray` three times) is broken by path, so `... 3 more` is right. C6's 1-1 before 3-3 follows from its shorter length.
- **C4 and C9 lengths:** the C4 snippet is 131 characters. The C9 121-130 line is 149.
- **SHA-256:** all four FIPS vectors are correct.
- **Nothing depends on slices 2–3.**
- **Guarded paths** cover everything the slice itself should change, and a declared `.gitignore` edit is allowed (`guarded_paths.ex:118-131`).
- **Consistent with the original's fixes:** the `CARGO_STAGES`, `plan_phases` and `_stage_name` hunks, `--target-dir` everywhere plus `.cargo/config.toml`, the `.gitignore` line, the mise pin and the launch precondition.
- **README check:** it doesn't look at `native/` paths (`document_references.ex:18`).

**Non-blocking notes**
- **Hashing deleted files:** `git ls-files --cached` still lists the deleted `format.ex` in B3. Passing it to `git hash-object --stdin-paths` kills the whole call, so INTENT.md:154 should say to hash only files that pass the skip filters. B3 would catch this, but saying it up front saves a cycle.
- **Stale rows:** the Candidate records a file as seen before its size/UTF-8 check (diff:1085), so a file that becomes skipped keeps its old rows. The spec doesn't say what should happen.
- **Write errors:** only directory-creation and open errors get the `cannot write index at … set KOGEN_CTX_HOME` wording. Later write errors come out bare, and no test covers them.
- **No HOME:** with `HOME` unset, `index_path` falls back to a relative path, i.e. inside the checkout (diff:672).
- **Toolchain version:** D5's `cargo 1.97.1` relies on the controller's `cargo` coming from mise or a rustup default of 1.97.1. The MacBook's rustup default is `stable`. `rustfmt` for 1.97.1 (needed by the cargo-fmt stage) was never probed.
- **Mix task:** the Candidate calls `Mix.Task.run("app.start")`, which no other `kogen.*` task does. It's harmless (there's no app module), but a Reviewer may ask about it.
