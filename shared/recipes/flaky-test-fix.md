# Flaky Test Detection and Fixing Recipe

## Problem

Tests that pass sometimes and fail other times, making CI unreliable and debugging difficult.

## Detection Method

Use ExUnit's `--repeat-until-failure` flag to reproduce intermittent failures:

```bash
# Run specific test up to 10,000 times or until failure
mix test test/elixir_drops_web/live/user_drop_live_test.exs:398 --repeat-until-failure 10000
```

## Common Patterns and Fixes

### 1. Multiple Database Fetches Race Condition

**Problem**: Test fetches data multiple times with state changes between fetches.

```elixir
# BAD - Race condition prone
|> render_submit()
drops = Drops.list_drops(%{user_id: user.id})
created_drop = List.last(drops)  # First fetch
assert created_drop.screenshot.status == :pending

drop = %{user_id: user.id}
|> Drops.list_drops()
|> List.last()  # Second fetch - might get different state!

{:ok, updated_drop} = Drops.update_drop(drop, user, %{
  screenshot: %{status: :completed}
})
```

**Fix**: Use single fetch with specific query:

```elixir
# GOOD - Single source of truth
|> render_submit()
created_drop = Repo.get_by!(Drop, user_id: user.id, title: "Test Title")
assert created_drop.screenshot.status == :pending

# Reuse same instance for update
{:ok, updated_drop} = Drops.update_drop(created_drop, user, %{
  screenshot: %{status: :completed}
})
```

### 2. Assertion-Update Race in Same Test

**Problem**: Test asserts state then immediately updates it, causing timing issues.

**Fix**: Split into separate tests:

```elixir
# Instead of one test doing:
# 1. Create drop
# 2. Assert pending status
# 3. Update to completed
# 4. Assert completed status

# Split into:
test "creates drop with pending screenshot status" do
  # Only test creation and initial state
end

test "updates screenshot status to completed" do
  # Start with known state, test update
end
```

### 3. Async Operations Without Synchronization

**Problem**: Broadcasting or async operations happening during assertions.

**Fix**: Add proper synchronization:

```elixir
# Wait for LiveView to process
assert_receive {:updated, _}, 100

# Or force render to synchronize
_html = render(view)

# Then make assertion
assert Repo.get!(Drop, drop.id).status == :completed
```

### 4. Dynamic List Operations

**Problem**: Using `List.last/1` on lists that might change.

```elixir
# BAD - Assumes order and single item
drops = Drops.list_drops()
created_drop = List.last(drops)
```

**Fix**: Use specific queries:

```elixir
# GOOD - Explicit query
created_drop = Repo.get_by!(Drop,
  user_id: user.id,
  title: "Specific Title"
)
```

## Real-World Example

From ElixirDrops flaky test fix:

```elixir
# The test was:
# 1. Creating a drop with pending screenshot
# 2. Asserting screenshot.status == :pending
# 3. Updating same drop to completed
# 4. Broadcasting the update

# Race condition: Sometimes step 3-4 happened before step 2 completed

# Fix approach:
# - Use single drop fetch
# - Add synchronization between operations
# - Consider splitting into separate tests
```

## Prevention Strategies

1. **Design tests with clear boundaries** - One test, one concern
2. **Avoid shared state** between test operations
3. **Use specific queries** instead of generic list operations
4. **Add explicit waits** for async operations
5. **Run with `--repeat-until-failure` during development** for new tests

## Debugging Tips

1. Add temporary logging to understand execution order
2. Use `Process.sleep(10)` to isolate race conditions
3. Check for background processes or workers
4. Look for PubSub broadcasts affecting state
5. Verify Oban is in manual mode for tests

## When to Apply

- CI fails intermittently on same test
- Test passes locally but fails in CI
- Test fails only under system load
- Multiple "Flaky test" comments in codebase
- Tests using `List.last/1` or multiple fetches
