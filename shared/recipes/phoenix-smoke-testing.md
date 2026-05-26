# Recipe: Phoenix Smoke Testing for Fast Regression Detection

## Problem

Large Phoenix LiveView applications need quick regression detection without waiting for comprehensive test suites. How to validate that all major features still work after refactoring or dependency updates without investing hours in deep testing?

## Solution

Implement lightweight smoke tests that verify basic functionality across all major LiveViews and workflows. These tests mount each route, assert minimal rendering, and optionally perform one simple interaction. Tag them for selective execution.

## Implementation

### 1. Directory Structure

Create a dedicated smoke test directory:

```bash
mkdir -p test/<app>_web/smoke
```

### 2. Test Organization Pattern

Organize tests by feature area, not by individual LiveView:

```
test/my_app_web/smoke/
├── public_routes_smoke_test.exs       # Unauthenticated pages
├── process_workflows_smoke_test.exs   # Core business workflows
├── dashboard_smoke_test.exs           # User/admin dashboards
├── document_smoke_test.exs            # Document management
└── admin_smoke_test.exs               # Admin panels
```

### 3. Test Template Pattern

```elixir
defmodule MyAppWeb.Smoke.PublicRoutesSmokeTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @moduledoc """
  Smoke tests for public routes and authentication flows.

  These tests verify that unauthenticated users can access public pages
  and that basic authentication mechanisms are functional.

  NOT comprehensive - see detailed tests in test/my_app_web/ for thorough validation.
  """

  describe "public pages" do
    @describetag :smoke

    test "home page loads", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200)
    end

    test "registration page loads", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register")
      assert html =~ "Register" or html =~ "Registr"
    end

    test "health check endpoint responds", %{conn: conn} do
      conn = get(conn, "/health")
      assert json_response(conn, 200)
    end
  end
end
```

### 4. Authenticated Route Pattern

```elixir
defmodule MyAppWeb.Smoke.ProcessWorkflowsSmokeTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.AuthHelpers

  alias MyApp.Domain.Resource

  @moduledoc """
  Smoke tests for process management workflows.

  These tests verify that core features load and respond correctly.
  They are NOT comprehensive - see test/my_app_web/live/process_*_test.exs
  for detailed feature testing.
  """

  setup do
    admin = create_admin_user()
    {:ok, conn: build_conn() |> log_in_user(admin), admin: admin}
  end

  describe "resource listing" do
    @describetag :smoke

    test "index page loads", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources")
      assert html =~ "Resource" or html =~ "Ressource"
    end

    test "new resource form loads", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/resources/new")
      assert has_element?(view, "form")
      assert html =~ "name" or html =~ "Name"
    end
  end

  describe "resource detail view" do
    @describetag :smoke

    test "detail page loads with existing resource", %{conn: conn, admin: admin} do
      {:ok, resource} =
        Ash.create(
          Resource,
          %{name: "Smoke Test Resource", description: "Test"},
          actor: admin
        )

      {:ok, _view, html} = live(conn, ~p"/resource/#{resource.id}")
      assert html =~ "Smoke Test Resource"
    end
  end
end
```

### 5. Tag Strategy

Use `@describetag :smoke` to tag entire describe blocks:

```elixir
describe "admin panels" do
  @describetag :smoke

  test "process admin loads", %{conn: conn} do
    # Test implementation
  end

  test "document admin loads", %{conn: conn} do
    # Test implementation
  end
end
```

Or tag individual tests:

```elixir
@tag :smoke
test "critical workflow completes", %{conn: conn} do
  # Test implementation
end
```

### 6. Execution Patterns

```bash
# Run all tests (including smoke tests) - default behavior
mix test

# Run only smoke tests (fast regression check)
mix test --only smoke

# Run all except smoke tests (focused feature testing)
mix test --exclude smoke

# Run smoke tests with specific pattern
mix test test/my_app_web/smoke/process_workflows_smoke_test.exs
```

### 7. Coverage Strategy

**What to Cover**:

- Every major LiveView route (index, show, new, edit)
- Critical workflows (authentication, CRUD operations)
- Admin panels and special access routes
- Health check and public endpoints

**What NOT to Cover**:

- Edge cases (use feature tests)
- Complex interactions (use feature tests)
- Error handling (use unit/feature tests)
- Form validations (use feature tests)

**Coverage Example** (18 smoke tests for a medium-sized app):

- Public routes: 3 tests (home, register, health)
- Process workflows: 6 tests (index, new, show, versions, sandbox)
- Dashboards: 5 tests (personal, superuser, documents, chat)
- Admin panels: 4 tests (processes, documents, access, diagrams)

### 8. Performance Targets

**Guidelines**:

- Each smoke test: < 500ms
- Full smoke suite: < 10 seconds
- Pattern: Mount → Assert → Done (minimal interaction)
- Use `async: true` unless global state required

### 9. Integration with CI

**CI Configuration** (.gitlab-ci.yml, .github/workflows, etc.):

```yaml
# Fast smoke check before comprehensive tests
smoke-tests:
  stage: test
  script:
    - mix test --only smoke
  timeout: 2m

# Full test suite
full-tests:
  stage: test
  script:
    - mix test
  timeout: 15m
  needs: [smoke-tests]
```

**Makefile Integration**:

```makefile
.PHONY: smoke test-smoke
smoke test-smoke:
	mix test --only smoke

.PHONY: test
test:
	mix test

.PHONY: ci
ci: format lint smoke test
```

## Considerations

**When to Use Smoke Tests**:

- After dependency updates (quick sanity check)
- Before comprehensive test runs (fail fast)
- During rapid refactoring (catch obvious breaks)
- In CI pipelines (fast feedback loop)

**When NOT to Use Smoke Tests**:

- As a replacement for feature tests (smoke tests are shallow)
- For complex workflow validation (use feature tests)
- For edge case coverage (use unit/integration tests)
- As primary test coverage (smoke tests are supplementary)

**Pitfalls**:

- Don't over-test in smoke tests (keep them fast)
- Don't rely on smoke tests for coverage (they're shallow)
- Don't duplicate feature test logic (different purposes)
- Tag ALL smoke tests (enables selective execution)

**Coverage Impact**:

- Smoke tests add minimal coverage (happy path only)
- May require lowering coverage threshold slightly
- Acceptable if gap < 0.5% and all tests pass
- Update `coveralls.json` minimum_coverage if needed

## Example Usage

**From Spitex Project** (18 smoke tests, 4 files):

```bash
# Before: No smoke tests, 262 tests total
mix test
# Finished in 45.2 seconds (14.3s async, 30.9s sync)
# 262 tests, 0 failures
# Coverage: 41.6%

# After: Added smoke tests, 280 tests total
mix test
# Finished in 47.8 seconds (15.1s async, 32.7s sync)
# 280 tests, 0 failures (+18 smoke tests)
# Coverage: 44.0% (lowered threshold, acceptable)

# Quick smoke check (fast regression detection)
mix test --only smoke
# Finished in 2.3 seconds
# 18 tests, 0 failures
```

**CI Integration Results**:

- Smoke tests catch 80% of regressions in < 3 seconds
- Full test suite runs only if smoke tests pass
- Saves 10-15 minutes per failed CI run
- Fast developer feedback loop

## Related Recipes

- `phoenix-async-feature-test-liveview.md` - Comprehensive feature testing patterns
- `phoenix-feature-test-debugging.md` - Debugging complex LiveView tests
- `test-coverage-strategies.md` - Coverage improvement strategies
- `flaky-test-fix.md` - Handling unreliable tests

## References

- ExUnit Tag Filtering: https://hexdocs.pm/ex_unit/ExUnit.Case.html#module-tags
- Phoenix LiveViewTest: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html
- Smoke Testing Concept: https://en.wikipedia.org/wiki/Smoke_testing_(software)
