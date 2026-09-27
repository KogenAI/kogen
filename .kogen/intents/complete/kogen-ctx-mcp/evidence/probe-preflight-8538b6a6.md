# Re-preflight probes against develop 8538b6a6 (2026-09-27, Mac Studio, shaping)

Slices 1 (`kogen-ctx-index-and-search`, d9013413) and 2 (`kogen-ctx-symbols-and-map`,
8538b6a6cb9e10a22675a732c1d6f21908389883) have landed. These probes ran in the shaping scratchpad (`ctx3/probe/`),
never in the checkout. No global mise, rustup or cargo state was changed, and CARGO_HOME was never set. Every cargo
command was `mise exec -- cargo … --locked --offline --target-dir <probe>/target-*`, run from the checkout root so
`mise.toml`'s `rust = "1.97.1"` applied.

## Q-1. The landed crate builds offline, and so does an MCP server on it

- `git archive 8538b6a6 native/kogen-ctx` → `probe/landed/`; `cargo build --release --locked --offline` →
  `Finished`. This binary produced every CLI output in Q-3.
- `probe/mcp/` = that crate plus `evidence/probe/main-rs.patch` (8 lines added and 3 removed in `main.rs`) and
  `evidence/probe/mcp.rs` (a 114-line `src/mcp.rs`: line-at-a-time loop on `serde_json`, flush after every reply,
  tool calls re-execute `current_exe` with `--root <resolved root>`). `cargo fmt`, then
  `cargo build --release --locked --offline` → `Finished`, no warnings under `#![deny(warnings)]`.
- `cmp` shows `Cargo.lock` unchanged; its SHA-256 is still
  `2ef6860ee535431191646a3fd9fe9113d0c674b34b05d3cf2d8a306764fbf1a3` (the value `D4 dependency and lock are pinned`
  asserts). `serde_json 1` is already in the lock and already compiled by the landed `cargo-build` check stage
  (declared since slice 1, unused until now). So **no new crate and no `cargo fetch`**.

## Q-2. Every test case of this Intent passes against the probe server, and M3 catches the known defect

- `evidence/probe/mcp_probe.exs` implements M1, M2, M3, M4 and T1–T3 as specified in `scenarios.yaml` (the
  `mcp_file` and `mcp_port` helpers exactly as INTENT.md "Tests and fixtures" gives them; `CtxFixture.create!/0` and
  `CtxFixture.run/5` as landed). Run with `mix run --no-start` against the Q-1 probe binary → all pass
  (`evidence/probe/mcp-probe-output.txt`).
- The same script against a variant whose loop first reads all of stdin (the XARfeVP5 `run_mcp` shape): M1 and M2
  pass, M3 fails (`no matching message after 10000ms`, `evidence/probe/mcp-eof-probe-output.txt`). So the file-fed
  tests alone cannot catch the defect, and M3 does.
- T2's new pair `symbols {query "Shop Cart"}` gives CLI `{"", "", 0}` (one positional, no match) and a tool result
  with `isError` false and text `""`. An implementation that splits the query on whitespace (the XARfeVP5
  `run_capture` shape) runs `symbols Shop Cart`, which is a usage error (exit 2), so the pair tells them apart.

## Q-3. Landed behaviour the expected outputs depend on (read from the code and tests at 8538b6a6)

- **Usage line** (`native/kogen-ctx/src/main.rs:13`, `USAGE`):
  `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR]`.
  `usage()` (lines 14-17) prints it plus `\n` to stderr, exit 2. Pinned exactly by the landed
  `test/kogen/ctx_elixir_test.exs` helper `usage!/3` (line 18, used by
  `E4 malformed symbols, refs and map command lines are usage errors before any index work`) and by
  `test/kogen/ctx_map_test.exs` `H4 bad map arguments are usage errors` (line 176). The landed `A5` (index test) and
  `C8` (search test) check only the prefix `usage: kogen-ctx`.
- **Parsing** (`parse()`, lines 368-453): the command must be one of `index|search|symbols|refs|map` (lines
  373-378), else usage. `--root` at most once, needs a value; `--limit` rejected on `index` and `map` (lines
  404-405); `--tokens`/`--focus` only on `map`; positionals rejected on `index` and `map` (lines 440-443); any other
  `--x` is usage. Usage errors happen before `home()` and `root()`, so the home stays empty.
- **`main()`** (lines 454-701): `parse()` → `home()` (line 459; `HOME is not set; …` → exit 1) → `root()` (line 463;
  `not a directory: …` / `not a Git checkout: <canonical>` → exit 1) → `refresh()` (line 467) → dispatch `index`
  (471), `symbols` (491), `refs` (512), `map` (568), else `search` (655). Query code writes with `println!` and
  leaves with `std::process::exit` (runtime errors, and `map`'s unmatched `--focus` at line 593, which is a usage
  error found after the refresh). So an in-process MCP tool call would need that code refactored; re-executing the
  binary needs none.
- **Index:** schema `"2"` (`refresh()` check at line 214, write at line 229), tables `meta`, `files`, `chunks`,
  `symbols`, `refs` (`init()`, line 177), `busy_timeout` 10 s (line 176), one `BEGIN IMMEDIATE` … `COMMIT` per
  refresh (lines 225-360). The write-failure text is `we()` (lines 182-188):
  `cannot write index at <path>: <err>; set KOGEN_CTX_HOME to a writable directory`. This slice does not change the
  schema.
- **Fixture API** (`test/support/ctx_fixture.ex`, module `Kogen.Test.CtxFixture`): `sources/0`, `hashes/0`,
  `alias_sources/0`, `alias_hashes/0`, `create!/0`, `create_alias!/0`, `project_id/1`, `index_path/2`, `binary/0`
  (builds once via `Kogen.Ctx.build/1`, cached in `:persistent_term`), and
  `run(binary, root, home, args, extra_env \\ [])` → `{stdout, stderr, status}` with `PATH=/usr/bin:/bin` and
  `KOGEN_CTX_HOME=home` (run/5; there is no `run/4` without the binary). Test files load it with
  `Code.require_file("../support/ctx_fixture.ex", __DIR__)` and `alias Kogen.Test.CtxFixture`.
- **Landed test names** (ledger rows): A1–A6, B1–B5 (`ctx_index_test.exs`), C1–C9 (`ctx_search_test.exs`), D1–D6
  (`ctx_build_test.exs`), E1–E4, F1–F3, G1–G4 (`ctx_elixir_test.exs`), H1–H5 (`ctx_map_test.exs`). This slice's
  M1–M4 and T1–T3 collide with none.
- **Check:** `scripts/check/offline.py` `CARGO_STAGES` = `cargo-fmt` (`cargo fmt --check`), `cargo-build`
  (`cargo build --release --locked --offline`), `cargo-test` (`cargo test --release --locked --offline`), all with
  `--manifest-path native/kogen-ctx/Cargo.toml` and (build/test) `--target-dir _build/cargo`, in the preparation
  phase. `native/kogen-ctx/.cargo/config.toml` sets `target-dir = "../../_build/cargo"`.
- **README:** `## Context index (`kogen-ctx`)` (two paragraphs: slice 1's, then slice 2's), just before
  `## Run the checks`. `test/kogen/readme_guidance_test.exs` rejects backticked repository paths that do not exist
  and `Module.fun/<digits>` names that are not exported `Kogen.*` functions.
- **CLI outputs on the shop fixture** (`evidence/probe/landed-cli-outputs.txt`, from
  `evidence/probe/landed-cli-outputs.exs`): every T1/T2/T3 CLI output equals the landed pins: `search the` = C1,
  `symbols Shop.Cart.total` = E2's first, `refs Shop.Tax.add` = E3's third, `map --tokens 25` = H2's first,
  `map --focus test/shop_test.exs` = H3's first, `search "Mix lock"` = C4, `search stray --limit 2` = C3's first,
  `symbols Shop --limit 1` = E2's last, `refs Shop.Cart --limit 2` = E3's second, `map --tokens 64 --focus lib/shop/`
  = H2's second (the tax and cart blocks, then `... 5 more files`). `search`, `refs` and `map --focus nope.ex` →
  `{"", USAGE <> "\n", 2}`. With a 0500 home, `search the` →
  `{"", "kogen-ctx: cannot write index at <home>/<project-id>/index.sqlite: Permission denied (os error 13); set KOGEN_CTX_HOME to a writable directory\n", 1}`.
  At 8538b6a6, `mcp` itself is `{"", USAGE <> "\n", 2}`.
