# Capture Logs on Error Paths

**Problem**: Tests that trigger expected errors produce noisy log output, and the log content itself is never asserted.
**When**: Asserting on log output from error paths, or suppressing expected error logs from polluting test output.
**See also**: none

## Solution

**Inline — suppress noise AND verify the log in one call:**

```elixir
{result, log} = ExUnit.CaptureLog.with_log(fn -> ProcessManager.start_app(bad_app) end)
assert result == :ok
assert log =~ "Failed to boot app"
```

**Single test with async Task/GenServer spawn** — the log may arrive after the function returns, so tag the test and assert inside a capture block with a sleep:

```elixir
@tag capture_log: true
test "logs error on bad input" do
  ExUnit.CaptureLog.capture_log(fn ->
    MyWorker.process(bad_input)
    Process.sleep(50)
  end)
  # assertions on side effects here
end
```

**Whole module** — suppress all expected noise for every test in the module:

```elixir
@moduletag capture_log: true
```

Place `@moduletag` after aliases — Credo enforces ordering.

## Gotchas

`with_log` returns `{return_value, log_string}` — the log is a binary, not a list. Use `=~` for substring matching.
