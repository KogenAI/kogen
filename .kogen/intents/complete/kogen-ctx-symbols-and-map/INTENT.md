# Add kogen-ctx Elixir symbols, refs and map

Slice 2 of 3 split from the approved `kogen-ctx-tool` (kept as a superseded reference in `drafts/`). Landing order:
1. `kogen-ctx-index-and-search` (**landed**, d9013413; `.kogen/intents/complete/kogen-ctx-index-and-search/`) →
**2. this Intent** → 3. `kogen-ctx-mcp`. Shaped against fa48e817 and re-preflighted against develop
d9013413eeb50af9cc2993fa839acfb277827e27, which holds slice 1's code: `native/kogen-ctx/` (`src/main.rs`,
`src/sha256.rs`, `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml`), `lib/kogen/ctx.ex`,
`lib/mix/tasks/kogen.ctx.build.ex`, `test/support/ctx_fixture.ex` and `test/kogen/ctx_index_test.exs`,
`ctx_search_test.exs`, `ctx_build_test.exs` (evidence/probe-preflight-d9013413.md).

It adds three query commands to `kogen-ctx`, parsed from Elixir with tree-sitter:
- `symbols`: modules and functions;
- `refs`: alias, import, use and require refs, calls and captures;
- `map`: a PageRank-ranked repo map within a token budget.

Everything else (the index location, freshness, `index` and `search` output, `check` wiring) is slice 1's as landed
and does not change here, except that the schema version is bumped to `2` and the usage line is extended.

**Why split.** Lesson 27. In the whole-tool Build (Candidate XARfeVP5), this part failed Final Review twice:
- F3: capture refs were missing, pipe arity was wrong, and alias resolution was **a hard-coded table of the fixture's
  names** (`resolve_mod` mapped `"Cart"`, `"Stock"`, `"Rules"` …).
- F4: map ranking, focus, dangling mass, weights and first-overflow truncation were wrong.
- F1: the tests were smoke checks.

This Intent pins every rule with exact expected outputs, a second fixture whose names appear nowhere else, and a Rust
unit test on the rank values.

## Launch

**No launch precondition; no `cargo fetch` is needed.** This slice adds no crate and changes neither
`native/kogen-ctx/Cargo.toml` nor `native/kogen-ctx/Cargo.lock` (both outside the guards; `D4 dependency and lock
are pinned` pins the lock's SHA-256 `2ef6860e…`). The landed lock already holds `tree-sitter 0.27.0`,
`tree-sitter-elixir 0.3.5` and `tree-sitter-language 0.1.8`, and slice 1's `cargo-build` check stage compiles them
today, so any Build host that passed `make check` at d9013413 has them in its Cargo cache. Probe P-1 built the
reference extractor against the landed lock with `--locked --offline` and left the lock byte-identical.

```sh
mix kogen.build --route codex kogen-ctx-symbols-and-map
```

Every proof is offline (DIRECTION rule 51). Slice 1's cargo rules still hold:
- `--locked --offline` on every cargo command; `--target-dir _build/cargo` from the repo root
  (`native/kogen-ctx/.cargo/config.toml` already sets `target-dir = "../../_build/cargo"` for runs inside the crate);
- `native/kogen-ctx/target/` must never exist (`D1 mix task prints only the executable path` refutes it);
- never export `CARGO_HOME` before `mise exec`.

The new Rust code must pass the three landed check stages (`CARGO_STAGES` in `scripts/check/offline.py`):
`cargo-fmt` (`cargo fmt --check`, so format it with `cargo fmt --manifest-path native/kogen-ctx/Cargo.toml`),
`cargo-build` and `cargo-test` (which also runs `map_rank_values`). `main.rs` keeps `#![deny(warnings)]`, and
`Cargo.toml` keeps `unsafe_code = "forbid"`.

## Starting point

- **Start from develop d9013413 and extend the landed crate.** In `native/kogen-ctx/src/main.rs`:
  - `USAGE` (the usage line), `parse()` (accepts only `index` and `search`, returns `(cmd, q, rv, l)`) and `main()`
    (dispatch after `refresh()`) gain the three commands;
  - `init()` gains the two tables;
  - `refresh()` gains the schema bump (its `schema_version` check against `"1"` and its
    `insert into meta values('schema_version','1')`), the `symbols`/`refs` clears in its rebuild
    (`delete from meta;delete from files;delete from chunks;`), their per-path deletes next to the `chunks`/`files`
    deletes (re-read and removed files), and the parse of each re-read `code` file.
  New modules under `native/kogen-ctx/src/` are allowed.
- `evidence/probe/reference-extractor.rs` is a shaping probe (~120 lines) that implements this Intent's extraction
  rules literally, and reproduces every symbols/refs expected output below on both fixtures
  (`evidence/probe-split-2026-09-27.md` S1; re-run against the landed lock and fixture bytes in P-1/P-2). It may be
  ported into the crate: its symbol and ref rows go into SQLite instead of stdout, and it must be rustfmt-formatted.
- `evidence/probe/map.py` implements the ranking formula and reproduces every `map` order below (S2).
- **Optional reading only, not a starting point:** slice 1's
  `.kogen/intents/complete/kogen-ctx-index-and-search/evidence/candidate-XARfeVP5-22f254e8.diff` holds the whole-tool
  Candidate's `walk_elixir`, `collect_call`, `alias_names`, `resolve_mod` (the table of fixture names) and
  `run_map`. That is the code the Final Review rejected (F3, F4). It targets fa48e817, not d9013413; do not apply it
  and do not port those functions.

## Outcome

### Schema 2

- `meta.schema_version` becomes `2`: `refresh()` rebuilds when it is not `"2"` and writes `'2'`. Slice 1's schema-1
  layout (`meta`, `files`, the `chunks` FTS5 table) is unchanged. `init()` also creates, with
  `CREATE TABLE IF NOT EXISTS`:
  - `symbols(path TEXT NOT NULL, line INTEGER NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL)`
  - `refs(path TEXT NOT NULL, line INTEGER NOT NULL, kind TEXT NOT NULL, module TEXT NOT NULL, target TEXT NOT NULL)`
- Every index written by slice 1's binary (`schema_version` `1`, no `symbols` or `refs` table) is therefore deleted
  and rebuilt on first use, by slice 1's landed derived-index rule in `refresh()`, so an unchanged code file still
  gets its symbols. Nothing is migrated. The rebuild's `index` output is slice 1's (`rebuilt yes`, every file
  `reindexed`).
- A re-indexed code file is re-parsed and its `symbols` and `refs` rows replaced. A removed file's rows go too
  (vanished, or newly skipped as non-UTF-8, oversized or a symlink). An unchanged file's rows stay as they are, and
  are not re-parsed. Only `code` files have `symbols` and `refs` rows. All of it happens in slice 1's single
  `BEGIN IMMEDIATE` refresh transaction.
- A file that tree-sitter parses with errors is still indexed for whatever parses. Indexing never aborts on one file.

### Symbols

- **Modules:** a `defmodule <Alias>` gives kind `defmodule`. A nested `defmodule` is qualified by its enclosing
  module: `Rules` inside `Shop.Pricing` is `Shop.Pricing.Rules`.
- **Functions:** calls to `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, `defguardp` or `defdelegate` inside a
  module body. A nested module's body belongs to the nested module.
  - The head is the first argument, with a `when` guard unwrapped to its left side.
  - A bare identifier head has arity 0.
  - Arity is the parameter count as written, with default arguments counted.
  - The name is `<Module>.<fun>/<arity>`.
  - For several clauses of one `{kind, name}`, only the first (lowest line) is kept.

### Refs

- **Directives:** `alias`, `import`, `use` and `require` give a ref of that kind to each named module. `alias A.{B,
  C}` gives `A.B` and `A.C`. The ref's `module` and `target` are both the module, resolved as below.
- **Calls:** a call whose target is `<Alias>.<fun>` or `__MODULE__.<fun>` gives kind `call`, module `<Module>` and
  target `<Module>.<fun>/<arity>`. Arity is the arguments as written, plus 1 when the call is the right operand of
  `|>`. In `a |> B.f() |> C.g()`, both `B.f/1` and `C.g/1` get the +1.
- **Captures:** `&<Alias>.<fun>/<N>` gives kind `capture` with arity `N`, and no separate `call`. `&Map.put(&1, k, v)`
  is not this form: it is a `call` of `Map.put/3`.
- **No refs from:** Erlang-module calls (`:crypto.hash`), local or imported calls (`money()`), calls on variables
  (`cart.items`), and code outside any module.
- The whole module body is walked, including function heads (a default argument's call is a ref) and `do:` bodies.
- The line of a ref is the first line of its call, directive or capture.

### Alias resolution: by lexical scope, never by name

- In a module, the aliases in scope are:
  - every `alias` call anywhere in its body or in an enclosing module's body, regardless of position (function-level
    aliases included). A nested module's body is not part of its parent's body.
  - the first segment of each `defmodule` nested directly in its body or in an enclosing module's body
    (`Rules` ↦ `Shop.Pricing.Rules`).
- `alias A.B` maps `B`; `alias A.B, as: C` maps `C`; `alias A.{B, C}` maps `B` and `C`.
- An inner module's mapping shadows an enclosing module's mapping for the same name.
- A module reference (in a call, capture or directive) whose first segment is mapped is rewritten: the first segment
  is replaced by the mapped module. Otherwise it stays as written. `__MODULE__` is the enclosing module.
- **There is no table of module names anywhere in the crate.** Resolution uses only the aliases and `defmodule`s of
  the file being parsed. The second fixture (`evidence/alias-fixture/`, names `Acme.*`, `Outer`, `Kit.Box`) proves
  this, as does test F3, which rejects any Rust string literal naming a fixture module.
- This is lexical-approximate (Assumed 4): an alias applies to the whole module body regardless of position, and
  imported local calls are not resolved.

### `symbols <query> [--limit N]` and `refs <target> [--limit N]`

- `symbols <query>` lists symbols whose name contains `<query>` (case-sensitive substring), sorted by path, line and
  name. The output is one line per symbol, `<path>:<line> <kind> <name>`. Default limit 50.
- `refs <target>`:
  - When the last dot-segment of `<target>` starts with a lowercase letter, it is a function target (`M.f` or
    `M.f/N`): it matches calls and captures into module `M` of function `f`, of arity `N` when given.
  - Otherwise it is a module target `M`: it matches every ref whose module is exactly `M` (its
    alias/import/use/require refs, and the calls and captures into it).
  - Results are sorted by path, line, kind and target. The output is one line per ref,
    `<path>:<line> <kind> <target>`, where `<target>` is the module for alias/import/use/require and
    `<Module>.<fun>/<arity>` for call/capture. Default limit 50.
- With `--limit N`, output stops after N lines, followed by `... <k> more` when k results were left out, exactly as
  the landed `search` prints it. The default limit is 50 for both (`search` keeps its 20).

### `map [--tokens N] [--focus PATH]...` — ranked repo map

- **Graph** over indexed code files: `w(u, v)` is the number of refs in file `u` whose module is defined (by a
  `defmodule` symbol) in file `v`, with `v ≠ u`. `W(u)` is `u`'s total out-weight; `u` is dangling when `W(u) = 0`.
- **Personalization `p`:** uniform over all code files. With `--focus`, it is uniform over the matched files instead.
  `--focus` is repeatable, and each value is a code file path or a directory prefix ending in `/`, relative to the
  root. A focus value that matches no indexed code file is a usage error: exit 2, empty stdout, the usage line on
  stderr. It is the one usage error found after the refresh (it needs the index), so the index may have been
  written.
- **PageRank**, deterministic: start at `p`, then run exactly 100 iterations of
  `r'(v) = 0.15·p(v) + 0.85·(Σ_u r(u)·w(u,v)/W(u) + p(v)·Σ_dangling r(d))`.
  Order by rank descending; two ranks that differ by less than 1e-12 are a tie, broken by path.
- **Blocks:** each file is a block: `<path>`, then, in line order, one `  <kind> <name>` line per symbol of the file,
  except `defp`, `defmacrop` and `defguardp`. The block's bytes are its lines with their `\n`.
- **Budget:** blocks are appended in rank order while `ceil(total bytes of the blocks so far / 4) ≤ N` (default N
  1024). At the first block that does not fit, output stops, and `... <k> more files` is printed, where k counts that
  block and every later one. No later, smaller block is tried.
- **Rust unit test `map_rank_values`**, anywhere in the crate. It builds the shop fixture's 7-file graph in memory
  (the edges listed in scenario `repo-map-ranks-and-fits-budget`), runs the ranking, and asserts each rank within
  1e-12 of the values in `evidence/probe-split-2026-09-27.md` S2, for the uniform and the `test/shop_test.exs`-focus
  cases.

### CLI surface (extends the landed `parse()`)

- **The usage line** (the `USAGE` constant) becomes exactly:
  `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR]`
  It extends the landed line (its first two alternatives are unchanged), and every usage error prints it and a
  newline to stderr, as landed.
- **Parsing**, as landed for `index` and `search`, plus:
  - the first argument may also be `symbols`, `refs` or `map`;
  - `--root DIR` works on every subcommand, at most once;
  - `--limit N` works on `search`, `symbols` and `refs`, at most once, with the landed `N` rule (decimal digits, not
    `0`);
  - `--tokens N` works on `map` only, at most once, with the same `N` rule;
  - `--focus PATH` works on `map` only, and may repeat; each takes the next argument as its value;
  - `symbols` and `refs` take exactly one positional argument (the query or target); `map` takes none;
  - any other `--` argument is an unknown option.
- **Usage errors** (exit 2, empty stdout, stderr the usage line), all found before the root is resolved, so they
  touch neither the root nor the index home, as landed: everything slice 1 lists, and `symbols` or `refs` with no or
  two positional arguments, `map` with a positional argument, `--limit` on `map`, `--tokens` or `--focus` on
  anything but `map`, `--tokens` twice or with a bad `N`, and `--tokens` or `--focus` with no value. A `--focus`
  that matches no indexed code file is the one usage error found after the refresh (above).
- Exit codes and the runtime-error form (`kogen-ctx: <reason>`, exit 1) are slice 1's, unchanged. Every command
  refreshes the index first, as landed.
- **README.md:** the landed `## Context index (`kogen-ctx`)` section, just before `## Run the checks`, is extended
  to document `symbols`, `refs` and `map`, their options and output formats, the alias approximation, the map
  formula and the budget, and that the index is now schema 2 (old indexes rebuild). Its existing `index`/`search`
  sentences stay. `test/kogen/readme_guidance_test.exs` must keep passing, so the text must not contain a
  backticked `lib/`, `test/`, `scripts/` or `priv/` path that does not exist in the repository (such as a shop
  fixture path), nor any `Module.fun/<digits>` pattern (such as a fixture ref like `Cart.total/2`): that test
  resolves every such pattern against exported `Kogen.*` functions. Use placeholders such as
  `<Module>.<fun>/<arity>`.

## Tests and fixtures

- **Fixture module:** `Kogen.Test.CtxFixture` in `test/support/ctx_fixture.ex`. Each new test file starts, like
  `test/kogen/ctx_index_test.exs`, with `Code.require_file("../support/ctx_fixture.ex", __DIR__)` and
  `alias Kogen.Test.CtxFixture`.
- **The shop fixture:** the landed `CtxFixture.create!/0`, byte for byte; the expected outputs below refer to it.
  Its seven sources equal `evidence/fixture/` and `CtxFixture.hashes/0` (probe P-2). Besides them it writes a
  `.gitignore`, three `.kogen/` docs (committed), then an untracked draft, a `-raw` file, `deps/dep/lib/dep.ex`, a
  non-UTF-8 `lib/shop/latin1.ex`, a 600 KiB doc and the `lib/shop/link.ex` symlink, so a first `index` reports
  `files 11 reindexed 11 removed 0`.
- **The landed API does not change:** `sources/0`, `hashes/0`, `project_id/1`, `index_path/2`, `binary/0`,
  `create!/0` and `run(binary, root, home, args, extra_env \\ [])` (→ `{stdout, stderr, status}`, with
  `PATH=/usr/bin:/bin` and `KOGEN_CTX_HOME=home`), and the private `write!/3` and `git!/2`, which the new function
  may reuse.
- **`CtxFixture` gains three functions:**
  - `alias_sources/0`: the three `evidence/alias-fixture/` files as a map of path to bytes, embedded as `~S"""`
    heredocs (`lib/outer.ex` line 2 contains `x \\ Kit.Box.new()`);
  - `alias_hashes/0`: their pinned SHA-256s,
    - `lib/acme/billing.ex` f1f2c61aa124a218811d4ec295b9e561a69d174560539879976a77e5be6aceab
    - `lib/acme/report.ex` 4ddb4fb346e4ae955dcb6849b8a14512721ca415c36bab64f3189fa212991083
    - `lib/outer.ex` 69263cc79f10ee3610b9e6643da5b99649d455ece5309cbf05ae558d699a6b3c
  - `create_alias!/0`, which returns `{root, home}` like `create!/0`: a fresh nonce root under
    `System.tmp_dir!()`, the three files and nothing else, `git init -q`, the local empty `core.excludesFile`
    (`.git/empty-excludes`), one commit (`user.name=Test`, `user.email=test@example.com`), and a fresh empty home
    outside the root.
- No test reads the checkout's `.kogen/`.
- **Test files (new):**
  - `test/kogen/ctx_elixir_test.exs`: scenarios E (symbols and refs), F (aliases by scope) and G (code refresh and
    rebuild);
  - `test/kogen/ctx_map_test.exs`: H (map).
  Both use `use ExUnit.Case, async: true` and run the binary only through `CtxFixture.run/5`. Each test is named
  exactly `"<id> <title>"` as the scenario lists it (for example `test "E1 symbols lists every module and function
  by the specified rules"`), because the ledger binds its rows by test name.
- **Existing tests keep their landed names and bodies.** The guards do not include
  `test/kogen/ctx_index_test.exs`, `ctx_search_test.exs` or `ctx_build_test.exs`, `native/kogen-ctx/Cargo.toml`,
  `Cargo.lock`, `lib/kogen/ctx.ex`, `lib/mix/tasks/kogen.ctx.build.ex` or `scripts/check/`. Their expectations
  after this slice:
  - `A4 rebuilds deleted, corrupt, old-schema and foreign-root indexes identically`: still passes; a
    `schema_version` of `0` is still not `2`, so it rebuilds.
  - `A5 validates usage before filesystem work and reports runtime paths exactly`: still passes; every one of its
    usage cases is still a usage error, and stderr still starts with `usage: kogen-ctx`.
  - `B1` to `B5` and `C1` to `C9`: unchanged outputs; code files still have no `chunks`, and `index` output is
    unchanged.
  - `D2 check places cargo stages in preparation`: unchanged `CARGO_STAGES`.
  - `D3 Rust tests include all NIST vectors`: the crate's `cargo test` output still contains
    `test sha256::tests::nist_vectors ... ok` (and now also `map_rank_values`).
  - `D4 dependency and lock are pinned`: the same four dependencies, and `Cargo.lock` SHA-256
    `2ef6860ee535431191646a3fd9fe9113d0c674b34b05d3cf2d8a306764fbf1a3`.
  - `test/kogen/readme_guidance_test.exs`: still passes on the extended README.
- **Expected outputs:**
  - Shop-fixture symbols and refs outputs, and the `map`, `--tokens 25` and `--focus` orders, are carried over
    unchanged from `kogen-ctx-tool` (Opus hand-verified). The reference extractor and `map.py` reproduce them, also
    on the landed fixture bytes (probe P-2).
  - New outputs, each derived by the probes in `evidence/probe-split-2026-09-27.md`:
    - the full `symbols Shop` list;
    - the alias fixture's outputs;
    - `--tokens 64` and `--tokens 10`;
    - `symbols Shop.Extra`;
    - the rank values.
  - Outputs that depend on slice 1's landed behaviour (the usage line, the `index` lines, `files 11`, the alias
    fixture's first `index`) are re-derived from the landed code and tests in `evidence/probe-preflight-d9013413.md`
    P-3.

## Non-goals

- `mcp` (slice 3). Any change to `index`, `search`, freshness, the index location or `check` wiring (slice 1).
- Position-aware alias scopes, resolving imported local calls, macro expansion, `mix xref` or compiler truth (row
  16b program-database). Other languages.
- Tuning the ranking constants or budgets for role briefings (row 15).

## Notes for the Developer (Opus re-preflight review, 2026-09-27)

- G4 compares with H1's expected blocks: put those blocks in `test/support/ctx_fixture.ex` (a function both test files
  call) rather than duplicating module attributes.
- Document `symbols`, `refs` and `map` in the README's kogen-ctx section (placeholders, not fixture names).
- Run `cargo fmt` and keep the non-test build warning-free (`#![deny(warnings)]`): no helpers used only by tests outside
  `#[cfg(test)]`.
- If the function-target `refs` match uses SQL `LIKE`, escape `_` and `%` (e.g. `ESCAPE '\'`), or compare prefixes
  without LIKE; names such as `to_string` contain `_`.
