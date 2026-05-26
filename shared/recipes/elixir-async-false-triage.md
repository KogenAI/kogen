# async: false Triage

**Problem**: Tests are marked `async: false` without justification, or conversely, `async: true` tests flake due to shared global state.
**When**: Deciding `async: true` vs `async: false` for a new test module, or investigating async flakiness.
**See also**: `mox-verify-on-exit-scope.md`, `task-supervisor-sandbox-allowance.md`

## Solution

Use `async: false` only when one of these three conditions is true:

1. **Tasks accessing Mox stubs** — the Task runs in a separate process and `Req.Test.allow/3` is not viable.
2. **Global GenServer or ETS** — the test reads/writes a named process or ETS table that is shared across tests.
3. **`Sandbox.allow` is impossible** — no hook exists to pass the test PID into the spawned process.

**Split strategy**: keep async-safe tests in `*Test` (e.g. `FooTest`), move Task/GenServer tests to `*SyncTest` (e.g. `FooSyncTest`) with `async: false`.

**LLM integration tests** — always `async: false`. `@moduletag :llm_integration` tests spawn Oban workers dynamically; concurrent LLM calls cause non-deterministic ordering and false failures.

## Gotchas

If you find yourself adding `async: false` to avoid a flaky Mox interaction, check `mox-verify-on-exit-scope.md` first — the root cause is often an incorrect `setup :verify_on_exit!` forcing private mode.
