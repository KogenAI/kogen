# Oban Worker Return Contract

**Problem**: Forgetting to return an explicit `:ok` from `perform/1` causes Oban to log warnings about unexpected return values.
**When**: Writing or reviewing any Oban worker's `perform/1` function.
**See also**: none

## Solution

Always end `perform/1` with an explicit `:ok` (or another valid return). Do not let the last expression be the return value of a side-effectful call.

```elixir
# ❌ Logger.info/1 returns :ok, but error reporters and port ops return `true` — Oban will warn
def perform(%Oban.Job{args: args}) do
  user = Repo.get!(User, args["user_id"])
  Logger.info("Processing user #{user.id}")
end

# ✅ explicit :ok — always clear
def perform(%Oban.Job{args: args}) do
  user = Repo.get!(User, args["user_id"])
  Logger.info("Processing user #{user.id}")
  :ok
end
```

**Why this matters**: functions like `Logger.info/1` happen to return `:ok`, but `Logger.error/1`, error reporters (Sentry, AppSignal), and port operations return `true`. If your last call changes (or you add monitoring later), Oban silently treats the unexpected return as a discard or logs a warning. Explicit `:ok` makes the contract unambiguous.

**Valid return values**:

| Return                  | Effect                             |
| ----------------------- | ---------------------------------- |
| `:ok` or `{:ok, value}` | Job succeeded                      |
| `{:error, reason}`      | Job failed, will retry             |
| `{:cancel, reason}`     | Job cancelled, no retry            |
| `{:discard, reason}`    | Job discarded permanently          |
| `{:snooze, seconds}`    | Job rescheduled N seconds from now |
