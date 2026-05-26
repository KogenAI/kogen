# Elixir `with` for Chained Failable Operations

**Problem**: Nested `case` statements for sequential failable operations create deeply indented, hard-to-read code.
**When**: You have 3 or more operations that each return `{:ok, _}` or `{:error, _}` and must run in sequence.
**See also**: none

## Solution

Use `with` to chain failable operations in a flat, readable pipeline. If any clause fails to match, `with` short-circuits and returns the non-matching value.

```elixir
# ❌ nested case — error handling buried, indentation grows with each step
case compile_release(path) do
  :ok ->
    case run_migrations(app) do
      :ok -> start_app(app)
      err -> err
    end
  err -> err
end

# ✅ with — flat, reads like a sequence of steps
with :ok <- compile_release(path),
     :ok <- run_migrations(app),
     :ok <- start_app(app),
     do: :ok
```

**When `case` is still correct**: a single failable operation. `with` for one clause adds noise with no benefit.

**`else` clause**: add it when you need to transform or pattern-match on specific failures. Without `else`, any non-matching value is returned as-is.

```elixir
with {:ok, user} <- fetch_user(id),
     {:ok, _} <- charge_card(user) do
  :ok
else
  {:error, :not_found} -> {:error, :user_missing}
  {:error, reason} -> {:error, reason}
end
```

## Gotchas

- `with` bindings are not in scope in the `else` clause — only the non-matching value is available there.
- Don't use `with` just to avoid a single `{:error, _}` return; use `case` for that.
