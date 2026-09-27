# Add the kogen-ctx MCP stdio server

Slice 3 of 3 split from the approved `kogen-ctx-tool` (kept as a superseded reference in `drafts/`). Landing order:
1. `kogen-ctx-index-and-search` (**landed**, d9013413) → 2. `kogen-ctx-symbols-and-map` (**landed**, 8538b6a6) →
**3. this Intent**. Shaped against fa48e817 and re-preflighted against develop
8538b6a6cb9e10a22675a732c1d6f21908389883, which holds both slices (`.kogen/intents/complete/`): `native/kogen-ctx/`
(`src/main.rs`, `src/elixir.rs`, `src/map.rs`, `src/sha256.rs`, `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml`),
`lib/kogen/ctx.ex`, `lib/mix/tasks/kogen.ctx.build.ex`, `test/support/ctx_fixture.ex` and `test/kogen/ctx_index_test.exs`,
`ctx_search_test.exs`, `ctx_build_test.exs`, `ctx_elixir_test.exs`, `ctx_map_test.exs`
(evidence/probe-preflight-8538b6a6.md).

`kogen-ctx mcp` serves the four queries (`search`, `symbols`, `refs`, `map`) to MCP clients over stdio, so agents can
call them as tools (for example `claude mcp add kogen-ctx -- <path> mcp`). There is one query implementation behind
two surfaces: every tool's text is byte-identical to the CLI's stdout (or, on failure, its stderr).

**Why a separate slice.** Lesson 27 caps codex-route Intents at 3–5 scenarios, and slice 2 already had four. The MCP
part of Candidate XARfeVP5 passed Final Review on its schemas (F5 closed), but its test was a smoke check (F1), and
it reads all of stdin before answering: a real client, which keeps stdin open, never gets a reply. That defect was
not found, because the only test fed a file and closed stdin.

## Launch

**No launch precondition; no `cargo fetch` is needed.** This slice adds no crate and changes neither
`native/kogen-ctx/Cargo.toml` nor `native/kogen-ctx/Cargo.lock` (both outside the guards; `D4 dependency and lock
are pinned` asserts the four dependencies and the lock's SHA-256 `2ef6860e…`). `serde_json 1` has been declared and
locked since slice 1, and the landed `cargo-build` check stage already compiles it, so any Build host that passed
`make check` at 8538b6a6 has it in its Cargo cache. Probe Q-1 built an MCP server on the landed crate with
`--locked --offline` and left the lock byte-identical.

```sh
mix kogen.build --route codex kogen-ctx-mcp
```

Every proof is offline (DIRECTION rule 51). Slice 1's cargo rules still hold:
- `--locked --offline` on every cargo command; `--target-dir _build/cargo` from the repo root
  (`native/kogen-ctx/.cargo/config.toml` already sets `target-dir = "../../_build/cargo"` for runs inside the crate);
- `native/kogen-ctx/target/` must never exist (`D1 mix task prints only the executable path` refutes it);
- never export `CARGO_HOME` before `mise exec`.

The new Rust code must pass the three landed check stages (`CARGO_STAGES` in `scripts/check/offline.py`):
`cargo-fmt` (`cargo fmt --check`, so format with `cargo fmt --manifest-path native/kogen-ctx/Cargo.toml`),
`cargo-build` and `cargo-test`. `main.rs` keeps `#![deny(warnings)]` (an unused import fails the build), and
`Cargo.toml` keeps `unsafe_code = "forbid"`.

## Starting point

- **Start from develop 8538b6a6 and extend the landed crate.** In `native/kogen-ctx/src/main.rs`:
  - `USAGE` (line 13) gains ` | kogen-ctx mcp [--root DIR]` at its end (below);
  - `parse()` (lines 368-453) accepts `mcp` in its command match (lines 373-378) and rejects, for `mcp`, `--limit`
    (next to the `index`/`map` rejection, lines 404-405) and any positional (next to lines 440-443); `--tokens` and
    `--focus` are already `map`-only;
  - `main()` (lines 454-701) dispatches `mcp` **after `home()` and `root()` and before `refresh()`** (line 467), so a
    server starts without touching the index.
  New modules under `native/kogen-ctx/src/` are allowed (for example `src/mcp.rs`).
- **Tool calls re-execute the binary** (`std::env::current_exe()`, the CLI argv, then `--root <resolved root>`,
  inheriting the environment), capturing stdout, stderr and the exit status. The landed query code prints with
  `println!` and leaves with `std::process::exit` (runtime errors; `map`'s unmatched `--focus` at line 593), so
  running it in-process would write into the JSON-RPC stream or kill the server. In-process is allowed only if that
  code is first refactored to return its output and exit code, with no observable change (Assumed 4).
- `evidence/probe/main-rs.patch` and `evidence/probe/mcp.rs` are a shaping probe against the landed crate (Q-1): with
  them, every test case below passes (Q-2). They may be ported; they must stay rustfmt-clean and warning-free.
- **Optional reading only, not a starting point:** slice 1's
  `.kogen/intents/complete/kogen-ctx-index-and-search/evidence/candidate-XARfeVP5-22f254e8.diff` holds the whole-tool
  Candidate's `mcp_reply`, `run_mcp` and `run_capture` (diff lines 1483-1624). Its dispatch, error codes and tool
  schemas match this Intent. It has two known defects: `run_mcp` reads all of stdin before answering (so a client
  that keeps stdin open never gets a reply; M3), and `run_capture` splits `query`/`target` on whitespace (so
  `symbols "Shop Cart"` becomes a usage error; T2). It targets fa48e817, not 8538b6a6: do not apply it.

## Outcome

- **Invocation:** `kogen-ctx mcp [--root DIR]` parses, resolves the index home and the root like every command, and
  then serves. Before reading stdin:
  - a usage error (a positional argument, `--limit`, `--tokens`, `--focus`, an unknown `--` option, `--root` twice or
    without a value) → exit 2, empty stdout, the usage line on stderr, and the index home untouched;
  - HOME and KOGEN_CTX_HOME both unset or empty, a `--root` that is not a directory, or a root that is not a Git
    checkout → exit 1 with the landed `kogen-ctx: …` stderr line.
  Starting the server does not refresh or open the index; only tool calls do.
- **Transport:**
  - The server reads newline-delimited JSON-RPC 2.0 from stdin, **one line at a time**.
  - For each request line that has an `id`, it writes exactly one JSON line to stdout and **flushes** before
    reading the next line, so replies come in request order, and each is available while stdin stays open.
  - Notifications (no `id`) get no reply. Blank lines are ignored. EOF exits 0.
  - Nothing else is ever written to stdout. The server is hand-written on `serde_json`: no SDK, no async runtime.
- **Reply shape:** `{"jsonrpc":"2.0","id":<id>,"result":…}` or `{"jsonrpc":"2.0","id":<id>,"error":{"code":<int>,
  "message":<text>}}`.
- **`initialize`** → `{protocolVersion, capabilities: {tools: {listChanged: false}}, serverInfo: {name: "kogen-ctx",
  version: "0.1.0"}}`. `protocolVersion` is the requested one when it is `2024-11-05`, `2025-03-26`, `2025-06-18` or
  `2025-11-25`, and `2025-11-25` otherwise. `ping` → `{}`.
- **`tools/list`** → exactly four tools, in this order, each with an object `inputSchema`:
  - `search`: `query` string, required; `limit` integer.
  - `symbols`: `query` string, required; `limit` integer.
  - `refs`: `target` string, required; `limit` integer.
  - `map`: `tokens` integer; `focus` array of strings. Nothing is required.
- **`tools/call`** with `{name, arguments}` runs the same query as the CLI command, with argv built as:
  - the tool name, then the `query` or `target` string as **one** argument, as is (never split: the landed CLI joins
    and re-splits `search` terms itself, and `symbols`/`refs` take exactly one positional);
  - an integer `limit` → `--limit <decimal>`; an integer `tokens` → `--tokens <decimal>`;
  - each string `focus` item → one `--focus <item>`;
  - then `--root <resolved root>`.
  - A missing or non-string `query`/`target` adds no positional, so the CLI reports its usage error. Values the CLI
    rejects (`limit` 0, `tokens` on `search`, …) reach it unchanged and are its usage errors.
  - On exit 0, the result is `{content: [{type: "text", text}], isError: false}`, where `text` is byte-identical to
    the CLI's stdout for the same arguments on the same root and KOGEN_CTX_HOME (an empty stdout gives `""`).
  - On a usage error (exit 2; for example a missing `query`, or a `focus` that matches no code file), the result has
    `isError: true` and the CLI's stderr as the text: the usage line plus `\n`.
  - On a runtime error (exit 1; for example an unwritable KOGEN_CTX_HOME), the result has `isError: true` and the
    CLI's stderr as the text: the `kogen-ctx: …` line plus `\n`. The server keeps serving.
- **Errors:**
  - an unknown tool name → JSON-RPC error `-32602`;
  - an unknown method → `-32601`;
  - an unparsable line → `-32700` with `id: null`;
  - a JSON value that is not a request object (for example `[1,2]`) → `-32600` with `id: null`;
  - an object with an `id` but no string `method` → `-32600` with that `id`.
- **Index sharing:** every tool call refreshes the index first, like the CLI (each re-executed call runs the landed
  `refresh()`). A running server and CLI calls share one index through the landed single `BEGIN IMMEDIATE`
  transaction with its 10-second busy timeout. The index schema stays `"2"`; this slice does not touch `init()` or
  `refresh()`.
- **CLI surface:** the usage line (the `USAGE` constant) becomes exactly:
  `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR] | kogen-ctx mcp [--root DIR]`
  It extends the landed line (its first five alternatives are unchanged), and every usage error of every command
  prints it plus a newline to stderr, as landed. Exit codes and the runtime-error form (`kogen-ctx: <reason>`,
  exit 1) are unchanged.
- **README.md:** the landed `## Context index (`kogen-ctx`)` section, just before `## Run the checks`, gains a
  paragraph on `mcp`: the invocation, the four tools and their arguments, the byte-identical text rule (stdout on
  success, stderr with `isError` on failure), that every call refreshes the index, and registration
  (`claude mcp add kogen-ctx -- <path> mcp`, with the path `mix kogen.ctx.build` prints). Its existing paragraphs
  stay. `test/kogen/readme_guidance_test.exs` must keep passing: no backticked `lib/`, `test/`, `scripts/` or
  `priv/` path that does not exist, and no `Module.fun/<digits>` pattern that is not an exported `Kogen.*` function.

## Tests and fixtures

- **Fixture module:** the landed `Kogen.Test.CtxFixture` (`test/support/ctx_fixture.ex`), unchanged. The new test file
  starts, like the landed ones, with `Code.require_file("../support/ctx_fixture.ex", __DIR__)` and
  `alias Kogen.Test.CtxFixture`. It uses `CtxFixture.create!/0` (the shop fixture; `{root, home}`, a fresh empty home
  outside the root), `CtxFixture.binary/0` and `CtxFixture.run(binary, root, home, args, extra_env \\ [])` (run/5, →
  `{stdout, stderr, status}`, with `PATH=/usr/bin:/bin` and `KOGEN_CTX_HOME=home`). There is no `run/4` without the
  binary.
- **One new file, `test/kogen/ctx_mcp_test.exs`** (`use ExUnit.Case, async: true`, explicit `cd:` and `env:`). Each
  test is named exactly `"<id> <title>"` as `scenarios.yaml` lists it (for example
  `test "M1 a scripted session gets one reply per request, in order"`), because the ledger binds its rows by test
  name. Its private helpers live in the test file:
  - **`mcp_file(root, home, lines)`** writes `lines` (joined with `\n`, trailing `\n`) to a request file in a fresh
    temp dir outside the fixture. It runs `System.cmd("/bin/sh", ["-c", ~S(exec "$0" mcp --root "$1" < "$2"),
    CtxFixture.binary(), root, request_file], cd: root, env: [{"PATH", "/usr/bin:/bin"}, {"KOGEN_CTX_HOME", home}])`:
    the redirect gives the EOF the server exits on, and `System.cmd/3` cannot write to a child's stdin. It returns
    `{stdout_lines, status}` (stdout split on `\n`, trimmed).
  - **`mcp_port(root, home)`** opens `Port.open({:spawn_executable, CtxFixture.binary()}, [:binary,
    {:line, 1_048_576}, :exit_status, args: ["mcp", "--root", root], cd: root, env: [{~c"PATH", ~c"/usr/bin:/bin"},
    {~c"KOGEN_CTX_HOME", String.to_charlist(home)}]])` for the interactive case. `Port.command/2` writes a line, and
    `assert_receive {^port, {:data, {:eol, line}}}, 10_000` reads the reply while stdin stays open. `Port.close/1`
    ends it.
  - Request lines are built with `Jason.encode!` from maps carrying `"jsonrpc" => "2.0"`; replies are decoded with
    `Jason.decode!`.
- A `CtxFixture.run/5` call of `mcp` leaves the child's stdin open (an Erlang port), so M4's exits prove the server
  stops before reading stdin: a server that read first would hang the test.
- No test reads the checkout's `.kogen/`.
- **Existing tests that change** (both files are in `may_change_guarded_paths`; names and all other bodies unchanged):
  - `test/kogen/ctx_elixir_test.exs`: the private `usage!/3` helper's expected stderr (line 18) becomes the new usage
    line plus `\n`. So `E4 malformed symbols, refs and map command lines are usage errors before any index work`
    expects, for each of its 20 command lines, `{"", <new usage line> <> "\n", 2}` and still `File.ls!(home) == []`.
  - `test/kogen/ctx_map_test.exs`: `H4 bad map arguments are usage errors` expects, for each of its four command
    lines, `out == ""` and `err ==` the new usage line plus `\n` (line 176).
  Moving the usage line into one shared function (for example `CtxFixture.usage/0`) is not allowed: the guards do not
  include `test/support/ctx_fixture.ex`.
- **Existing tests that stay unedited and must keep passing** (not guarded): `test/kogen/ctx_index_test.exs`
  (A1–A6, B1–B5; `A5 validates usage before filesystem work and reports runtime paths exactly` checks only the prefix
  `usage: kogen-ctx`, and none of its cases names `mcp`), `test/kogen/ctx_search_test.exs` (C1–C9; `C8` checks only
  the prefix), `test/kogen/ctx_build_test.exs` (D1–D6; D4's four dependencies and lock SHA-256 unchanged, D2's
  `CARGO_STAGES` unchanged), the rest of `ctx_elixir_test.exs` (E1–E3, F1–F3, G1–G4) and `ctx_map_test.exs` (H1–H3,
  H5), and `test/kogen/readme_guidance_test.exs`. `native/kogen-ctx/Cargo.toml`, `Cargo.lock`, `lib/kogen/ctx.ex`,
  `lib/mix/tasks/kogen.ctx.build.ex`, `scripts/check/` and `test/support/ctx_fixture.ex` do not change.
- **Expected outputs:**
  - The transcript's ids, codes and protocol versions are carried over unchanged from `kogen-ctx-tool`
    scenario 6.
  - The tool texts are defined as the CLI's output. The tests also assert those CLI outputs equal the exact outputs
    slices 1 and 2 pinned in the landed tests (C1, C3, C4, E2, E3, H2, H3), so parity is never vacuous (for example two
    empty strings); the one empty text (T2's `symbols "Shop Cart"`) is asserted as `""` with `isError` false.
  - The usage text is the new usage line above, plus `\n`. All were re-derived against 8538b6a6 (probe Q-3) and
    pass against the probe server (Q-2).

## Non-goals

- MCP resources, prompts, sampling, `listChanged` notifications, structured tool output, an `index` tool (every
  query refreshes), HTTP or SSE transports, an MCP SDK or async runtime.
- Registering the server in any client configuration, or wiring it into role prompts (row 15).
- Any change to the query commands, their outputs, the index or its schema (slices 1 and 2), the fixture, the crate's
  dependencies or the check wiring.

## Notes for the Developer (Opus re-preflight review, 2026-09-27)

- `ctx_elixir_test.exs` F3 (must pass) fails on any `.rs` file under `native/kogen-ctx/src/` containing fixture module
  names such as `"Shop`, `"Tax"`, `"Format"`: Rust unit tests in `mcp.rs` must not use fixture names (use neutral
  strings like `"M.f"`).
- Also test the Outcome clauses the enumerated cases don't cover: an object with an `id` but no string `method` → -32600
  with that id; blank input lines are ignored; `mcp` with HOME and KOGEN_CTX_HOME unset exits 1 with the landed message.
