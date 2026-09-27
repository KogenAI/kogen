# Re-preflight probes against develop d9013413 (2026-09-27, Mac Studio, shaping)

Slice 1 (`kogen-ctx-index-and-search`) landed as d9013413eeb50af9cc2993fa839acfb277827e27. These probes ran in the
shaping scratchpad (`ctx2/probe/`), never in the checkout. No global mise, rustup or cargo state was changed, and
CARGO_HOME was never set.

## P-1. The landed lock builds the extraction offline

- `native/kogen-ctx/Cargo.toml` and `Cargo.lock` of d9013413 were copied to `probe/ext/` (the `[lints.rust]` table
  dropped; `[dependencies]` unchanged: `rusqlite 0.40` bundled, `tree-sitter 0.27`, `tree-sitter-elixir 0.3.5`,
  `serde_json 1`), with `evidence/probe/reference-extractor.rs` as `src/main.rs`.
- `mise exec rust@1.97.1 -- cargo build --release --locked --offline --target-dir probe/target` → `Finished`, no
  warnings. `cmp` shows the lock unchanged after the build (lock entries: `tree-sitter 0.27.0`,
  `tree-sitter-elixir 0.3.5`, `tree-sitter-language 0.1.8`).
- So this slice needs no new crate and no `cargo fetch`: the landed `cargo-build` check stage already compiles the
  tree-sitter crates (declared but not yet used by slice 1's code).

## P-2. The landed shop fixture is the shaped one, and the outputs still hold

- `Kogen.Test.CtxFixture.sources/0` of d9013413 (loaded with `Code.require_file`) was written out to
  `probe/landed-shop/`. `diff -r` against `evidence/fixture/` → identical. Its seven SHA-256s equal
  `CtxFixture.hashes/0` and the `given` of scenario `symbols-and-refs-resolve-elixir`.
- The P-1 binary on `probe/landed-shop/` → byte-identical to `evidence/probe/reference-extractor-shop.txt`.
- The P-1 binary on `evidence/alias-fixture/` → byte-identical to `evidence/probe/reference-extractor-alias.txt`.
- `map.py` and `ranks.py` re-run → identical to `map-py-output.txt` and `ranks-output.txt`.

## P-3. Landed behaviour the expected outputs depend on (read from the code and tests at d9013413)

- `USAGE` (`native/kogen-ctx/src/main.rs:11-12`):
  `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR]`. Usage errors print it
  plus `\n` to stderr and exit 2 before the root is resolved (`parse()` then `main()`; test
  `A5 validates usage before filesystem work and reports runtime paths exactly` asserts `File.ls!(home) == []`).
- `--limit`: decimal digits, not `0`, at most once (`parse()`, lines 355-367); default 20 for `search`;
  `... <k> more` after the last shown line (lines 464-466).
- Schema: `init()` (line 176) creates `meta`, `files`, `chunks`; `refresh()` rebuilds when meta `root` differs or
  `schema_version` is not `"1"` (line 213) and writes `'1'` (line 228); the rebuild clears
  `meta`, `files`, `chunks` (line 226). Code files get a `files` row only.
- `index` output (lines 406-418): `index <path>`, `project <id>`, `rebuilt yes|no`, sorted `reindexed`/`removed`
  lines, `files <n> reindexed <k> removed <r>`. On the shop fixture a first index is the 15 lines of
  `initial(root, home, "yes")` in `test/kogen/ctx_index_test.exs` (`files 11 reindexed 11 removed 0`; `latin1.ex`,
  the `link.ex` symlink and `deps/` are skipped).
- Fixture API: `sources/0`, `hashes/0`, `project_id/1`, `index_path/2`, `binary/0`, `create!/0`,
  `run(binary, root, home, args, extra_env \\ [])` → `{stdout, stderr, status}`; test files load it with
  `Code.require_file("../support/ctx_fixture.ex", __DIR__)` and `alias Kogen.Test.CtxFixture`.
- Check: `scripts/check/offline.py` `CARGO_STAGES` = `cargo fmt --check`, `cargo build --release --locked --offline`,
  `cargo test --release --locked --offline` (manifest `native/kogen-ctx/Cargo.toml`, `--target-dir _build/cargo`),
  stage names `cargo-fmt`, `cargo-build`, `cargo-test`. `native/kogen-ctx/.cargo/config.toml` sets
  `target-dir = "../../_build/cargo"`.
- `test/kogen/ctx_build_test.exs` `D4 dependency and lock are pinned` asserts the four dependency names and
  `Cargo.lock` SHA-256 `2ef6860ee535431191646a3fd9fe9113d0c674b34b05d3cf2d8a306764fbf1a3`.
- `test/kogen/readme_guidance_test.exs` rejects README backticked `lib/`, `test/`, `scripts/`… paths that do not exist
  and any `Module.fun/<digits>` reference that is not an exported `Kogen.*` function.
- None of `native/kogen-ctx/src/*.rs` at d9013413 contains any F3 literal.
