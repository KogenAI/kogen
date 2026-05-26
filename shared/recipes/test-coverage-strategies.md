# Recipe: Test Coverage Optimization Strategies

## Problem

How to achieve and maintain high test coverage (90%+) in Phoenix LiveView applications while dealing with unused components, complex UI interactions, and evolving codebases? Poor coverage often results from untested components and difficult-to-test UI elements.

## Solution

Implement strategic approaches for identifying and removing unused code, writing effective tests for LiveView components, and optimizing coverage through targeted testing patterns. Focus on meaningful coverage rather than just hitting percentage targets.

## Implementation

### 1. Unused Component Identification and Removal

Systematically identify and remove unused components to improve coverage:

```bash
# Step 1: Find all component definitions
find lib/ -name "*.ex" -exec grep -l "def.*_component\|defp.*_component" {} \;

# Step 2: Search for component usage across codebase
grep -r "phone_input\|progress_indicator\|user_type_card\|date_picker" lib/ --include="*.ex" --include="*.heex"

# Step 3: Check for imports and aliases
grep -r "Components.Core.PhoneInput\|import.*PhoneInput" lib/ --include="*.ex"
```

```elixir
# Coverage analysis before cleanup
# Use mix coveralls.json to generate detailed coverage data

# Find files with low coverage
def find_uncovered_files do
  coverage_data = Jason.decode!(File.read!("cover/excoveralls.json"))

  coverage_data["source_files"]
  |> Enum.filter(fn file ->
    covered_lines = Enum.count(file["coverage"], fn line -> is_integer(line) && line > 0 end)
    total_lines = Enum.count(file["coverage"], fn line -> line != nil end)
    coverage_percent = if total_lines > 0, do: covered_lines / total_lines, else: 0
    coverage_percent < 0.5  # Less than 50% coverage
  end)
  |> Enum.map(& &1["name"])
end

# Remove unused components strategically
def remove_unused_components do
  components_to_remove = [
    "lib/my_app_web/components/core/phone_input_component.ex",
    "lib/my_app_web/components/core/progress_indicator_component.ex",
    "lib/my_app_web/components/core/user_type_card_component.ex",
    "lib/my_app_web/components/core/date_picker_component.ex"
  ]

  # Only remove if truly unused - verify with grep first
  Enum.each(components_to_remove, &File.rm!/1)
end
```

### 2. LiveView Testing Patterns

Write comprehensive tests for LiveView interactions:

```elixir
# test/my_app_web/live/user_registration_live_test.exs
defmodule MyAppWeb.UserRegistrationLiveTest do
  use MyAppWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "multi-step registration flow" do
    test "job seeker completes 3-step registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # Step 1: User type selection
      lv
      |> element("[data-testid='job-seeker-card']")
      |> render_click()

      assert has_element?(lv, "[data-step='2']")

      # Step 2: Personal information
      lv
      |> form("#user-form", user: %{
        "first_name" => "John",
        "last_name" => "Doe",
        "email" => "john@example.com",
        "password" => "password123",
        "date_of_birth" => "1990-01-01"
      })
      |> render_submit()

      assert has_element?(lv, "[data-step='3']")

      # Step 3: Work information
      lv
      |> form("#user-form", user: %{
        "medical_role" => "nurse",
        "department" => "emergency"
      })
      |> render_submit()

      # Should redirect to confirmation
      assert_redirect(lv, ~p"/users/confirm")
    end

    test "employer completes 2-step registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # Step 1: User type selection
      lv
      |> element("[data-testid='employer-card']")
      |> render_click()

      assert has_element?(lv, "[data-step='2']")

      # Step 2: Company information
      lv
      |> form("#user-form", user: %{
        "first_name" => "Jane",
        "last_name" => "Smith",
        "email" => "jane@company.com",
        "password" => "password123",
        "company_name" => "Healthcare Corp"
      })
      |> render_submit()

      assert_redirect(lv, ~p"/users/confirm")
    end
  end

  describe "navigation and validation" do
    test "handles back navigation between steps", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # Navigate to step 2
      lv |> element("[data-testid='job-seeker-card']") |> render_click()
      assert has_element?(lv, "[data-step='2']")

      # Go back to step 1
      lv |> element("[data-testid='back-button']") |> render_click()
      assert has_element?(lv, "[data-step='1']")
    end

    test "validates required fields per step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv |> element("[data-testid='job-seeker-card']") |> render_click()

      # Submit incomplete form
      lv
      |> form("#user-form", user: %{"first_name" => ""})
      |> render_submit()

      # Should stay on same step with error
      assert has_element?(lv, "[data-step='2']")
      assert has_element?(lv, ".phx-form-error")
    end
  end

  describe "responsive components" do
    test "mobile language switcher works", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      # Test mobile language dropdown
      lv
      |> element("[data-testid='mobile-language-selector']")
      |> render_click()

      assert has_element?(lv, "[data-testid='language-dropdown']")

      # Select German
      lv
      |> element("[data-testid='language-de']")
      |> render_click()

      # Should see German text
      assert has_element?(lv, ~s|[data-testid="welcome-text"]:fl-contains("Willkommen")|)
    end
  end
end
```

### 3. Component Testing Strategies

Test components through integration rather than isolation:

```elixir
# test/my_app_web/components/core/timer_test.exs
defmodule MyAppWeb.Components.Core.TimerTest do
  use MyAppWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  # Test timer through parent LiveView, not in isolation
  describe "countdown timer in email confirmation" do
    test "displays countdown and switches to link when expired", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/confirm?token=#{user.confirmation_token}")

      # Timer should be visible initially
      assert has_element?(lv, "[data-timer-display]", "Resend in")

      # Simulate timer expiration via JavaScript hook
      lv
      |> element("#countdown-timer")
      |> render_hook("timer_expired")

      # Link should now be visible
      assert has_element?(lv, "[data-timer-link]", "Resend")
      refute has_element?(lv, "[data-timer-display]")
    end
  end
end
```

### 4. Test Selector Optimization

Use semantic attributes over styling classes:

```elixir
# BAD: Fragile selectors based on styling
test "user can select job seeker type", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/users/register")

  # Fragile - breaks when Tailwind classes change
  lv
  |> element(".bg-white.border.border-gray-200.rounded-lg:first-child")
  |> render_click()
end

# GOOD: Semantic test attributes
test "user can select job seeker type", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/users/register")

  # Stable - independent of styling changes
  lv
  |> element("[data-testid='job-seeker-card']")
  |> render_click()
end
```

```heex
<!-- Add semantic test attributes to components -->
<div
  data-testid="job-seeker-card"
  class="bg-white border border-gray-200 rounded-lg p-6"
  phx-click="select_user_type"
  phx-value-type="job_seeker"
>
  <h3 data-testid="card-title">Job Seeker</h3>
  <p data-testid="card-description">Looking for healthcare positions</p>
</div>
```

### 5. Coverage Threshold Management

Set and maintain precise coverage targets:

```json
// coveralls.json
{
  "coverage_threshold": 90.9,
  "minimum_coverage": 90,
  "skip_files": ["test/", "lib/my_app/application.ex", "lib/my_app_web.ex"],
  "treat_no_relevant_lines_as_covered": true
}
```

```bash
# Measure coverage precisely
mix coveralls.json

# Find exact coverage percentage
jq '.total_coverage' cover/excoveralls.json

# Find files pulling down coverage
jq '.source_files[] | select(.covered_percent < 90) | {name: .name, coverage: .covered_percent}' cover/excoveralls.json
```

### 6. CI Integration for Coverage

Maintain coverage in continuous integration:

```yaml
# .github/workflows/test.yml
name: Test
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.15"
          otp-version: "26"

      - name: Install dependencies
        run: mix deps.get

      - name: Run tests with coverage
        run: mix coveralls.json

      - name: Check coverage threshold
        run: |
          COVERAGE=$(jq '.total_coverage' cover/excoveralls.json)
          echo "Coverage: $COVERAGE%"
          if (( $(echo "$COVERAGE < 90" | bc -l) )); then
            echo "Coverage $COVERAGE% is below threshold of 90%"
            exit 1
          fi

      - name: Upload coverage to Codecov
        uses: codecov/codecov-action@v3
        with:
          file: ./cover/excoveralls.json
```

### 7. Testing Complex UI Interactions

Handle challenging UI scenarios effectively:

```elixir
# Testing modals and overlays
test "country dropdown works correctly", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/users/register")

  lv |> element("[data-testid='job-seeker-card']") |> render_click()

  # Open country dropdown
  lv |> element("#user_country") |> render_click()

  # Select Switzerland (should be default)
  lv
  |> element("#user_country option[value='CH']")
  |> render_click()

  # Verify selection without following redirect
  assert has_element?(lv, "#user_country option[value='CH'][selected]")
end

# Testing patch navigation
test "sign up link navigates correctly", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/users/log_in")

  # Click sign up link
  lv
  |> element("a", "Sign up as employer")
  |> render_click()

  # Use assert_patch for LiveView navigation
  assert_patch(lv, "/users/register/employer")
end
```

## Considerations

### Strategic Component Removal

- **Verify unused status**: Always grep for usage before removing components
- **Check imports**: Look for both direct usage and module imports
- **Test impact**: Ensure tests still pass after component removal
- **Documentation**: Update any references in documentation

### Test Quality vs. Quantity

- **Meaningful coverage**: Focus on testing business logic, not just hitting percentages
- **Integration over unit**: Test components through their usage contexts
- **User journey coverage**: Test complete workflows, not just individual functions
- **Error scenarios**: Test validation, error handling, and edge cases

### Performance Considerations

- **Async tests**: Use async: true when possible for faster test execution
- **Selective testing**: Don't test every possible UI interaction
- **Mock external services**: Use Mox for external dependencies
- **Database cleanup**: Use appropriate test fixtures and cleanup strategies

### Maintenance Strategy

- **CI integration**: Fail builds when coverage drops below threshold
- **Regular audits**: Periodically review uncovered lines for opportunities
- **Refactoring impact**: Consider coverage when refactoring code
- **Team education**: Ensure team understands testing best practices

## Example Usage

From the BemedaPersonal onboarding feature implementation:

```elixir
# Before optimization: 89.3% coverage
# Issues:
# - 4 unused components (phone_input, progress_indicator, etc.)
# - Missing tests for mobile language switcher
# - Incomplete LiveView navigation testing

# Step 1: Remove unused components
File.rm!("lib/bemeda_personal_web/components/core/phone_input_component.ex")
File.rm!("lib/bemeda_personal_web/components/core/progress_indicator_component.ex")
File.rm!("lib/bemeda_personal_web/components/core/user_type_card_component.ex")
File.rm!("lib/bemeda_personal_web/components/core/date_picker_component.ex")

# Step 2: Add missing tests
test "mobile language switcher works" do
  # Test previously untested mobile UI component
end

test "handles patch navigation correctly" do
  # Test LiveView navigation patterns
end

# Step 3: Optimize test selectors
# Replace Tailwind class selectors with semantic attributes
# Use data-testid attributes for stable test targeting

# Result: 90.9% coverage achieved
# Coverage increased by 1.6 percentage points through strategic optimization
```

Results achieved:

- **Precise target hitting**: Achieved exactly 90.9% coverage
- **Eliminated dead code**: Removed 4 unused components
- **Improved test stability**: Semantic selectors resilient to styling changes
- **CI integration**: Automated coverage checking in build pipeline

## Related Recipes

- **Figma-to-Code Workflow with MCP**: For implementing testable UI components
- **Semantic Component API Design**: For creating easily testable component interfaces
- **Phoenix LiveView Testing Patterns**: For comprehensive LiveView test strategies
