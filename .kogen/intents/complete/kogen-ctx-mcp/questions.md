# Questions and choices

No open questions.

The Shaper delegated every technical decision (DIRECTION rules 46 and 46.5). Item 1 is carried over from
`kogen-ctx-tool` (its number there in brackets); items 2–5 are new with the split, and items 6–7 with the 8538b6a6 re-preflight. Each item states its reason and
how to undo it.

## Assumed

1. **The MCP server is hand-written newline-delimited JSON-RPC over `serde_json`. The tools are the four queries,
   and each tool's text is the CLI's stdout.** [10] The supported protocol versions are `2024-11-05`, `2025-03-26`,
   `2025-06-18` and `2025-11-25`; any other request gets `2025-11-25`.
   Reason: a small dependency set, and one query implementation behind two surfaces. `index` is not a tool, because
   every query refreshes.
   Undo: add an SDK crate and structured tool output.

2. **The server reads one line at a time, and flushes each reply before reading the next line.** [new, a
   clarification] The approved spec said "one JSON line per request … in request order". It did not say that
   replies must come before EOF, and the Candidate answered only at EOF.
   Reason: MCP stdio clients keep stdin open for the whole session, so an EOF-only server never answers them.
   Undo: none sensible.

3. **Runtime errors inside a tool call are `isError: true`, with the CLI's stderr line as the text.** [new, a
   clarification] The approved spec named only argument errors.
   Reason: MCP separates tool failures (`isError`) from protocol failures (JSON-RPC errors). An unwritable
   KOGEN_CTX_HOME is a tool failure the agent should read, the same as on the CLI.
   Undo: map runtime errors to a JSON-RPC error `-32603`.

4. **Tool calls re-execute the binary (`current_exe`, the CLI argv, `--root <resolved root>`); in-process is
   allowed only after refactoring the query code.** [new; narrowed at the 8538b6a6 re-preflight]
   Reason: both keep one implementation, and the byte-identity tests T1–T3 pin the result either way. But the landed
   query code in `main()` writes with `println!` and leaves with `std::process::exit`, so calling it in-process
   would write into the JSON-RPC stream or end the server. Re-execution costs one process per call (milliseconds),
   needs no change to the query code, and keeps the stdout-only rule trivial.
   Undo: refactor the query code to return its output and exit code, then call it in-process; no observable change.

5. **The MCP test's helpers live in `test/kogen/ctx_mcp_test.exs`; `test/support/ctx_fixture.ex` does not change.**
   [new]
   Reason: guarded paths cover exactly what this slice changes, and only this file uses the MCP helpers.
   Undo: move them to the support module, and add it to `may_change_guarded_paths`.

6. **`mcp` joins the usage line as ` | kogen-ctx mcp [--root DIR]`, and the two landed tests that pin the line
   exactly (E4 through `usage!/3`, and H4) are updated to it.** [new at the 8538b6a6 re-preflight]
   Reason: slice 2 set the pattern (one alternative per command, pinned exactly), and an `mcp` missing from the
   usage line would hide the command. Both test files are guarded, and their names stay, so their ledger rows stay.
   Undo: leave `USAGE` unchanged, drop the two test files from the guards, and document `mcp` only in the README.

7. **`mcp` resolves home and root, then serves without refreshing; only tool calls touch the index.** [new at the
   8538b6a6 re-preflight] The landed `main()` refreshes before dispatching every command.
   Reason: T3 needs a server started with an unwritable home to report each call's runtime error and keep answering
   `ping`; a startup refresh would exit 1 instead. Root and home errors still exit before stdin is read (M4).
   Undo: refresh at startup and exit 1 on failure (T3's 0500 case would then test the CLI exit instead).

## Audit

- **The split (2026-09-27):**
  - `kogen-ctx-tool`'s codex Build XARfeVP5 did not converge (lesson 27).
  - Its MCP part passed Final Review on the tool schemas (F5 closed). But its only test was a 39-line smoke check of
    two replies (F1), and splitting found a defect no test had caught: the server read all of stdin before
    answering.
  - Two scenarios. Both list their ExUnit test cases with exact values, and name smoke tests as wrong results.
  - The transcript of `kogen-ctx-tool` scenario 6 (13 replies, ids, codes, protocol versions, tool order and
    required fields) is carried over unchanged, as test M1.
  - New:
    - M2 (the `-32600` case the approved spec named but did not test);
    - M3 (an interactive Port);
    - T2 (argument-to-flag mapping; the `map` tokens-64 focus `lib/shop/` output was derived with slice 2's
      `map.py` block sizes: 80 + 135 = 215 bytes, 54 tokens, and format's 69 would make 71 > 64);
    - T3 (error parity, including the runtime error).
  - The tool texts are defined by parity with the CLI. T1 also pins the CLI side to slices 1 and 2's exact outputs.
- **Carried from `kogen-ctx-tool`:** Sol rounds 1–2 (round 1 fixed the tools/list order) and Opus rounds 3–4 (in
  drafts/kogen-ctx-tool/evidence/reviews/), and the delegated human approval of 2026-09-27T07:08:49Z. The split needs
  its own approval.
- **Deterministic:** `plan/tools/validate.exs` on this directory at fa48e817 → `Intent.read` ok, `Contract.load` ok,
  `VerificationPlan.build` ok, `VerificationPolicy.preflight` :ok.
- **Not run:** Sol/Opus readiness rounds on the split packages, a Jev clause audit and an Astra second opinion.
- **Re-preflight at 8538b6a6 (2026-09-27), after slices 1 and 2 landed:**
  - `shaped_against.head` → 8538b6a6cb9e10a22675a732c1d6f21908389883 ("Add kogen-ctx Elixir symbols, refs and
    map"); slice 1 landed as d9013413.
  - Citations re-derived from the landed code and tests (evidence/probe-preflight-8538b6a6.md Q-3), and fixed:
    - the fixture module is `Kogen.Test.CtxFixture`, loaded with `Code.require_file`; its runner is
      `run(binary, root, home, args, extra_env \\ [])` (run/5), not `run(root, home, argv)`/`run/4`; T1–T3 and the
      new M4 pass `CtxFixture.binary()`; the fixture does not change;
    - slices 1 and 2 are under `complete/`, not `drafts/` (references.yaml);
    - the CLI surface is no longer `kogen-ctx <index|search|symbols|refs|map|mcp> …` (the Candidate's form): the
      landed `USAGE` is one alternative per command, and `mcp` extends it with ` | kogen-ctx mcp [--root DIR]`
      (item 6), pinned exactly; `parse()` and `main()` changes are cited by line;
    - the index is schema `"2"` and this slice does not bump it or touch `init()`/`refresh()`;
    - `mcp` dispatches after `home()`/`root()` and before `refresh()` (item 7);
    - the check stages are the landed `CARGO_STAGES` (cargo-fmt, cargo-build, cargo-test) under
      `#![deny(warnings)]`; README edits must pass `test/kogen/readme_guidance_test.exs` (new risk
      `readme-guidance-references`);
    - item 4 is narrowed: the landed query code prints and exits in `main()`, so tool calls re-execute the binary
      (new risk `in-process-tool-calls`).
  - Test cases re-verified against the landed behaviour: every T1/T2/T3 CLI output equals the landed pins (C1, C3,
    C4, E2, E3, H2, H3); the usage text is now exact (`USAGE <> "\n"`, not a prefix) in M1 id 11 and T3; T3's runtime
    error is pinned by `CtxFixture.index_path/2`, as A6 does. New: M4 (six malformed `mcp` command lines and a
    non-checkout root, all exiting before stdin is read, home left empty) and T2's `symbols "Shop Cart"` pair (catches
    the Candidate's whitespace split). wrong_results now name smoke tests, fixture-name/output tables, a startup
    refresh, a stale usage line in E4/H4 and any Cargo change.
  - Existing tests: E4 (`ctx_elixir_test.exs`, via `usage!/3`) and H4 (`ctx_map_test.exs`) pin the old usage line;
    both files are added to `may_change_guarded_paths` and to scenario 1's `proof.offline`, and INTENT.md states their
    new expectation. Every other landed ctx test and the README guidance test stays unedited and is listed with its
    expectation.
  - Starting point: the Candidate excerpt (`evidence/candidate-mcp-excerpt.rs`) and its "reuse them" instruction are
    removed; the Build starts from the landed crate. The XARfeVP5 diff's MCP code (slice 1's evidence, diff lines
    1483-1624) is optional reading only, with its two defects named (reads all stdin; splits the query).
  - Probes (scratchpad `ctx3/probe/`, no global state changed, CARGO_HOME never set): Q-1 builds the landed crate and
    a probe MCP server on it with `--locked --offline`, lock unchanged (SHA-256 `2ef6860e…`); Q-2 runs every test case
    (M1–M4, T1–T3) against the probe server → all pass, and against a read-all-stdin variant → M3 fails.
  - Launch: no new crate and no Cargo.lock change, so no `cargo fetch` is needed on the Build host (INTENT.md
    "Launch").
  - `plan/tools/validate.exs` on this directory at 8538b6a6 → `Intent.read` :ok, `Contract.load` ok,
    `VerificationPlan.build` ok (targets `check`; offline `test/kogen/ctx_mcp_test.exs`,
    `test/kogen/ctx_elixir_test.exs`, `test/kogen/ctx_map_test.exs`), `VerificationPolicy.preflight` :ok.
  - Not run: Sol/Opus readiness rounds on the re-preflighted package.
- Opus re-preflight review at 8538b6a6: ready; notes 1 and 3 added to INTENT.md "Notes for the Developer".
