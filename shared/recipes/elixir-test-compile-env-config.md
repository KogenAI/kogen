# Compile-Time Config Values in Tests

**Problem**: Tests use `System.get_env` for config values that are needed at compile time (e.g. `@moduletag timeout:`), causing repeated OS lookups and duplication.
**When**: A test module needs a compile-time config value such as a timeout multiplier or a feature flag read at module load time.
**See also**: none

## Solution

Compute the value once in `config/test.exs` and read it in the test module with `Application.compile_env/2` (no default — default lives in config only).

**`config/test.exs`** — compute once, reuse across multiple config keys:

```elixir
timeout_multiplier =
  "TIMEOUT_MULTIPLIER"
  |> System.get_env("1")
  |> String.to_integer()

config :my_app, :timeout_multiplier, timeout_multiplier
config :my_app, Repo, ownership_timeout: timeout_multiplier * 600_000
```

**Test module** — read at compile time, no default:

```elixir
@timeout_multiplier Application.compile_env(:my_app, :timeout_multiplier)
@moduletag timeout: 300_000 * @timeout_multiplier
```

## Gotchas

Do not pass a default to `Application.compile_env/3` in the test module — put the default in `config/test.exs`. Two sources of truth for the same value will diverge.
