# Mox.verify_on_exit! Scope

**Problem**: `setup :verify_on_exit!` is added reflexively to every test file that uses Mox, causing async test failures when only stubs are used.
**When**: Adding `setup :verify_on_exit!` to a test module, or deciding between `Mox.stub` and `Mox.expect`.
**See also**: `elixir-async-false-triage.md`

## Solution

Only add `setup :verify_on_exit!` when the test uses `Mox.expect/3` — unmet expectations must be caught at test exit.

With `Mox.stub/3` only — omit `verify_on_exit!` entirely. Stubs have no "unmet expectation" semantics, and adding `verify_on_exit!` at the module level in an `async: true` file forces Mox into private mode, which breaks other concurrent tests that share the same mock globally.

```elixir
# ✅ expect — verify is meaningful
setup :verify_on_exit!
expect(MockHTTP, :post, fn _url, _body -> {:ok, %{status: 200}} end)

# ✅ stub only — no verify needed, full path required
Mox.stub(MockHTTP, :post, fn _url, _body -> {:ok, %{status: 200}} end)
# do NOT import Mox when using stub — use the full module path
```

## Gotchas

Module-level `verify_on_exit!` in an `async: true` file affects global mock state across all concurrent tests sharing that mock module. If you need strict verification on a stubbed mock, convert to `expect` instead of adding `verify_on_exit!`.
