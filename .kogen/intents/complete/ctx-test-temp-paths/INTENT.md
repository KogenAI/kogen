# Give kogen-ctx tests collision-free temp paths

## Why

Build TNKFPX6XyfcLVYkQfugKKMTa (build-reconcile, MacBook, 2026-09-27 21:39) stopped after check cycle 1 failed one test
outside its scope: `test/kogen/ctx_index_test.exs` "A2 symlinked roots and subdirectories reuse one index" (:59) with
`(File.LinkError) could not create symlink from ".../T/ctx-link-47042" ...: file already exists`. The kogen-ctx tests and
`test/support/ctx_fixture.ex` name several paths in the shared `System.tmp_dir!()` with only
`System.unique_integer([:positive])` (ctx_index_test.exs: `ctx-link-`, `ctx-home-` ×2, `ctx-outside-`, `ctx-outside-home-`,
`ctx-ro-`; ctx_mcp_test.exs: `kogen-ctx-outside-`, `kogen-ctx-read-only-`; ctx_fixture.ex `run/5`: `kogen-ctx-stderr-`).
That integer is unique only within one VM and restarts in every isolated test VM and every gate run, and most of these
paths are never removed, so a leftover (or a concurrent test VM) makes the same name collide.

## Outcome

- `test/support/ctx_fixture.ex` gains `tmp_path(prefix)`: `Path.join(System.tmp_dir!(), "<prefix>-<os pid>-<System.os_time(:nanosecond)>-<System.unique_integer([:positive])>")`
  (`System.pid()` for the OS pid). It only builds the name; it creates nothing.
- Every temp path listed above is built with `CtxFixture.tmp_path/1` instead of `System.unique_integer` alone, and every
  one a test creates is removed in an `on_exit` (the read-only ones get their permissions restored first, as today);
  `run/5`'s stderr file is removed after it is read. The existing nonce-based roots/homes in `create!/0`,
  `create_alias!/0` and ctx_mcp_test.exs's `kogen-ctx-mcp-` dir stay as they are.
- A new test in `test/kogen/ctx_index_test.exs`, "temp paths are collision-free and cleaned up": (a)
  `CtxFixture.tmp_path("x")` called twice returns two different paths, neither of which exists, both under
  `System.tmp_dir!()` and both containing `System.pid()`; (b) a source scan of `test/kogen/ctx_index_test.exs`,
  `test/kogen/ctx_mcp_test.exs` and `test/support/ctx_fixture.ex` finds no `Path.join(System.tmp_dir!(), "...#{System.unique_integer` expression
  (i.e. no temp path named by `unique_integer` alone; the regex is `~r/System\.tmp_dir!\(\),\s*"[^"]*#\{System\.unique_integer/`).
- No other test changes behaviour; no test is renamed (the ledger binds rows by test name); no assertion is weakened.

## Non-goals

- Other test files, production code, deadlines.
