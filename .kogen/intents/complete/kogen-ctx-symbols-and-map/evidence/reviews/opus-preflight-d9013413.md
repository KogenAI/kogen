**Verdict: ready**

I found no blocking issues. Every check you asked for passes against develop d9013413.

**What I checked**
- **Citations match the landed code.** All of these in `native/kogen-ctx/src/main.rs` are where the draft says: `USAGE` (11-12), `init()` (174-177), `refresh()` (188-334), the schema check (213), the rebuild clear (226), the schema write (228), `parse()` (335-383), `main()` (384-467). So are:
  - the `--limit` rule (355-367) and `... <k> more` (464-466);
  - the fixture API in `test/support/ctx_fixture.ex`: `sources/0`, `hashes/0`, `project_id/1`, `index_path/2`, `binary/0`, `create!/0`, `run/5`, and the private `write!`/`git!`;
  - `CARGO_STAGES` (`scripts/check/offline.py:37-40`), the D1–D4 bodies, and the `initial/3` 15-line report (`ctx_index_test.exs:9-29`);
  - the candidate diff path and `lib/mix/tasks/kogen.ctx.build.ex`.
- **Symbols and refs outputs are right.** I re-derived them by hand from the fixture bytes:
  - all 26 lines of E1, and every E2/E3 query including `--limit` and `... 25 more` / `... 3 more`;
  - pipe +1 on both steps of the chain, captures, `__MODULE__`, and the `Stock`/`Rules` alias resolution;
  - G1's line 5 and G2's sort order: `lib/shop.ex` comes before `lib/shop/extra.ex` because `.` sorts before `/`;
  - every alias-fixture output: the use-before-write alias, the nested `Invoice`, the inherited `Row`, `Row` staying unresolved in `Acme.Report`, the default-argument call, the function-level `Box`, and the inner `as: Box` shadowing it.

  They also match `reference-extractor-shop.txt` and `reference-extractor-alias.txt`.
- **Map outputs are right.**
  - I solved the PageRank fixed point by hand. It gives s≈0.10298, c≈0.20997, t≈0.22650, i=p≈0.12243 and f≈0.11271, with exact ties for inventory/pricing and shop.ex/test.
  - The focus case converges to 20/37 and 17/37. After 100 iterations the error is 0.7225^50 × 0.4595 ≈ 4.0e-8, which matches `ranks-output.txt`.
  - In `--focus lib/shop/`, the four files cart, format, inventory and pricing tie exactly, and lib/shop.ex and test are exactly 0.
  - The block sizes (80/135/137/165/69/123/40) are right, and so are the `--tokens 25/64/10` cut-offs. H1 is 32 lines and equals `map-default-expected.txt`.
- **Index outputs match slice 1.** F1's 7-line first index is right: a missing `.kogen/` walks as empty, and there's no `.gitignore`. `files 11` still holds because latin1, link and deps are skipped. G3's 15 lines are `initial(root, home, "yes")`. G4 mirrors A4.
- **No landed test needs editing.** A4 (schema `0` ≠ `2`), all 13 A5 usage cases, B1–B5, C1–C9, D2 (stages unchanged), D3 (`nist_vectors` still runs) and D4 (same four dependencies and lock hash) all still pass. A6 is unaffected, because once the new tables exist `CREATE TABLE IF NOT EXISTS` doesn't write.
- **Paths stay inside the guards.** Every scenario's `affected_paths` is within `may_change_guarded_paths`. README.md is guarded but not in any `affected_paths`, which is fine.
- **Leaving `Cargo.lock` untouched is consistent.** `Cargo.toml` already declares `tree-sitter 0.27` and `tree-sitter-elixir 0.3.5`, and the lock holds 0.27.0, 0.3.5 and `tree-sitter-language` 0.1.8.
- **Nothing depends on slice 3.** MCP appears only under Non-goals.

**Non-blocking notes**
1. G4 (`scenarios.yaml:273-278`) compares `m` with H1's lines, but H1's blocks live as module attributes in `ctx_map_test.exs`, a different file. The Developer will have to copy them or move them into `CtxFixture`. One sentence saying which would stop the Reviewer from debating it.
2. Nothing tests the README. Only the negative constraints in `readme_guidance_test.exs` apply, so the Reviewer has to check that `symbols`/`refs`/`map` are actually documented.
3. Probe P-1 dropped `[lints.rust]` and wasn't rustfmt-formatted. That's harmless because the extractor has no `unsafe`, but the probe didn't prove `#![deny(warnings)]` plus `cargo fmt --check` on the ported code. The Developer has to format it, and must not leave helpers that only the test uses, or the non-test build warns and fails.
4. If the function-target `refs` match is written with SQL `LIKE 'M.f/%'`, the `_` in names like `to_string` acts as a wildcard. Nothing tests this; a Reviewer might mention it.
5. I couldn't recompute the three `alias_hashes/0` SHA-256s here (read-only tools, no shell). F1 checks the bytes against the hashes, so a wrong pin would show up immediately in the Build rather than slip through.
6. Cosmetic: `scenarios.yaml:234` is an over-long line.

Separately, the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used; it wasn't needed for this review.
