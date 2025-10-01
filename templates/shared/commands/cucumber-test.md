---
description: Convert loose scenario descriptions into properly formatted Gherkin feature files
argument-hint: [scenario description]
---

Transform natural language test scenarios into structured Gherkin feature files following BDD best practices.

**STEP 1: Parse User Input**

Analyze the user's scenario description to extract:

- **Feature name** - What business area/functionality is being tested
- **User type** - Job seeker, employer, admin, or visitor
- **Core workflow** - The main user actions being tested
- **Expected outcomes** - What should happen when the workflow succeeds
- **Edge cases** - Error conditions or alternative paths mentioned

**STEP 2: Determine Feature File Location**

Based on the scenario content, determine the appropriate feature file path:

```
test/features/
├── authentication/           # Login, registration, password reset
├── job_management/          # Job posting, editing, publishing
├── job_applications/        # Apply, withdraw, status tracking
├── user_profiles/           # Profile creation, editing
├── company_management/      # Company setup, team management
├── search_and_discovery/    # Job search, filtering, browsing
└── notifications/           # Email, in-app notifications
```

**STEP 3: Structure Gherkin Scenarios**

Create properly formatted scenarios using these patterns:

### Feature Header

```gherkin
Feature: [Business capability]
  As a [user type]
  I want to [goal]
  So that [business value]
```

### Background (if needed)

```gherkin
Background:
  Given the application is running
  And I am on the homepage
```

### Scenario Structure

```gherkin
@[tag]
Scenario: [Specific behavior description]
  Given [preconditions and context]
  When [user actions]
  And [additional actions if needed]
  Then [expected outcomes]
  And [additional verifications]
```

### Required Tags

- `@smoke` - Critical path scenarios
- `@regression` - Previously failed scenarios
- `@error_handling` - Error condition tests
- `@job_seeker` / `@employer` / `@admin` - User type specific
- `@slow` - Scenarios taking >5 seconds

**STEP 4: Apply BDD Best Practices**

Follow these patterns from the cucumber-bdd.md rules:

- **One behavior per scenario** - Don't test multiple workflows in one scenario
- **User-focused language** - Avoid technical implementation details
- **Concrete examples** - Use specific data, not abstract placeholders
- **Consistent step language** - Reuse common step patterns
- **Readable by stakeholders** - Non-technical people should understand

**STEP 5: Create Feature File**

Use the Write tool to create the `.feature` file with:

1. **Proper file path** - Based on Step 2 analysis
2. **Complete feature definition** - Header, background (if needed), scenarios
3. **Appropriate tags** - For test execution filtering
4. **Stakeholder-friendly language** - Business terminology, not technical jargon

**STEP 6: Generate Step Definition Template**

Create a corresponding step definition file template showing:

- Module name and location (`defmodule ProjectWeb.Features.DomainSteps`)
- **Required**: `use Cucumber.StepDefinition` at the top
- Required imports (fixtures, helpers, assertions)
- Step definition stubs using the `step` macro
- Proper parameter matching (`{string}`, `{int}`, `{float}`)
- Context management patterns (returning updated context map)
- Integration with existing Phoenix test infrastructure

**Correct Step Definition Pattern:**

```elixir
defmodule BemedaPersonalWeb.Features.AuthenticationSteps do
  use Cucumber.StepDefinition

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import BemedaPersonal.AccountsFixtures

  # Step with string parameter
  step "I am logged in as {string}", %{args: [user_type]} = context do
    user = user_fixture(%{user_type: String.to_existing_atom(user_type)})
    conn = log_in_user(build_conn(), user)

    updated_context = context
    |> Map.put(:conn, conn)
    |> Map.put(:current_user, user)

    {:ok, updated_context}
  end

  # Step without parameters
  step "I visit the login page", context do
    {:ok, view, _html} = live(context.conn, ~p"/users/log_in")
    {:ok, Map.put(context, :view, view)}
  end

  # Step with assertion
  step "I should see {string}", %{args: [text]} = context do
    html = render(context.view)
    assert html =~ text
    {:ok, context}
  end
end
```

**Example Output Structure:**

```
Created: test/features/authentication/password_reset.feature
Template: test/features/step_definitions/authentication_steps.exs
```

**Requirements:**

- **MUST create actual files** - Use Write tool to generate both feature and step template files
- **Follow existing patterns** - Match the project's current feature structure if it exists
- **Stakeholder readable** - Business language only, no technical implementation details
- **Tag appropriately** - Include relevant tags for test execution and organization
- **Use proper Cucumber syntax** - `use Cucumber.StepDefinition` and `step` macro
- **Parameter types** - Use `{string}`, `{int}`, `{float}` for capturing values
- **Context management** - Always return updated context map from steps
- **Provide next steps** - Show user how to run the tests (`mix test --only @tag`)

**Key Cucumber Patterns to Follow:**

1. **Step definitions are in `test/features/step_definitions/*.exs`** - Not in test files
2. **Feature files are in `test/features/domain/*.feature`** - Organized by domain
3. **Context is a map** - Pass data between steps via context map
4. **Parameters in args** - Access via `%{args: [param1, param2]}` pattern
5. **Return tuple** - Each step MUST return `{:ok, context}` tuple (not just context)
6. **Test helper order** - `ExUnit.start()` THEN `Cucumber.compile_features!()`

This command bridges the gap between informal test ideas and structured BDD implementation using actual Cucumber for Elixir, making it easy to convert business requirements into executable specifications.
