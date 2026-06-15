# Elixir Telemetry Test Isolation

Use `:telemetry_test.attach_event_handlers/2` (shipped with the `telemetry` library) to isolate
telemetry assertions per test. It generates a unique ref used as both the handler ID and the
message tag, so concurrent async tests never bleed events into each other.

## Pattern

```elixir
ref = :telemetry_test.attach_event_handlers(self(), [[:my, :event]])
on_exit(fn -> :telemetry.detach(ref) end)

# trigger the event ...

assert_received {[:my, :event], ^ref, measurements, metadata}
```

- `^ref` pins the unique ref — only this test's events match, even under async concurrency.
- Use `assert_received` (not `assert_receive`) when the call is synchronous and the message is
  already in the mailbox.
- The `on_exit` cleanup is required; without it, the handler leaks across test runs.

## Before / After

**Before** (leaks between concurrent tests):

```elixir
handler_id = "test-rollup-telemetry"
test_pid = self()

:telemetry.attach(handler_id, [:my_app, :llm, :rollup, :run], fn _event, m, _meta, _cfg ->
  send(test_pid, {:telemetry, m})
end, nil)
on_exit(fn -> :telemetry.detach(handler_id) end)

RollupWorker.perform(%Oban.Job{args: %{}})

assert_receive {:telemetry, %{rows_rolled: rows_rolled}}
```

**After** (fully isolated):

```elixir
ref = :telemetry_test.attach_event_handlers(self(), [[:my_app, :llm, :rollup, :run]])
on_exit(fn -> :telemetry.detach(ref) end)

RollupWorker.perform(%Oban.Job{args: %{}})

assert_received {[:my_app, :llm, :rollup, :run], ^ref, measurements, _metadata}
assert measurements.rows_rolled >= 1
```

## Notes

- Works in both `async: true` and `async: false` test cases.
- No extra dependency — `:telemetry_test` is part of the `telemetry` package itself.
- To subscribe to multiple events at once, pass them all in the list:
  `attach_event_handlers(self(), [[:event, :a], [:event, :b]])`.
