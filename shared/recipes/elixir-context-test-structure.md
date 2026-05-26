# Elixir Context Test Structure

**Problem**: New context functions lack proper describe-block placement, coverage of edge cases, or coverage of all new code paths.
**When**: Writing tests for a new or updated context function in a Phoenix app.
**See also**: `elixir-async-false-triage.md`, `elixir-capture-logs-on-error-paths.md`

## Solution

Grep the test file first to find the right describe block: `grep "describe " test/my_app/foo_test.exs`

Put each function's tests under its own describe block. Cover the happy path, at least one failure path, and boundary/edge values (nil, empty list, duplicate, missing assoc).

```elixir
describe "create_user/1" do
  test "with valid attrs creates user" do
    assert {:ok, %User{} = user} = Accounts.create_user(%{email: "test@example.com", name: "Test"})
    assert user.email == "test@example.com"
  end

  test "with duplicate email fails" do
    {:ok, _} = Accounts.create_user(%{email: "test@example.com", name: "Test"})
    assert {:error, changeset} = Accounts.create_user(%{email: "test@example.com", name: "Test"})
    assert "has already been taken" in errors_on(changeset).email
  end
end
```

Cover ALL new code — not just enough to hit the coverage threshold. Deleting tests requires replacement tests; coverage must not drop.

## Gotchas

Never add `# coveralls-ignore-next-line` on business logic to paper over missing tests — write the test instead.
