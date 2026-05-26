---
description: Convert loose scenario descriptions into properly formatted Gherkin feature files
argument-hint: [scenario description]
---

Transform natural language test scenarios into structured Gherkin feature files.

**STEP 1: Parse Input**

Extract from user's description:

- **Feature name** — business area/functionality being tested
- **User type** — job seeker, employer, admin, or visitor
- **Core workflow** — main user actions
- **Expected outcomes** — what should happen
- **Edge cases** — error conditions or alternative paths

**STEP 2: Determine Feature File Location**

```
test/features/
├── authentication/
├── job_management/
├── job_applications/
├── user_profiles/
├── company_management/
├── search_and_discovery/
└── notifications/
```

**STEP 3: Structure Gherkin Scenarios**

```gherkin
Feature: [Business capability]
  As a [user type]
  I want to [goal]
  So that [business value]

Background:
  Given the application is running
  And I am on the homepage

@[tag]
Scenario: [Specific behavior description]
  Given [preconditions and context]
  When [user actions]
  Then [expected outcomes]
```

Required tags: `@smoke`, `@regression`, `@error_handling`, `@job_seeker`/`@employer`/`@admin`, `@slow`

**STEP 4: Apply BDD Best Practices**

- One behavior per scenario
- User-focused language — no technical implementation details
- Concrete examples — specific data, not abstract placeholders
- Readable by stakeholders

**STEP 5: Create Feature File**

Use Write tool to create `.feature` file.

**STEP 6: Generate Step Definition Template**

```elixir
defmodule BemedaPersonalWeb.Features.AuthenticationSteps do
  use Cucumber.StepDefinition

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import BemedaPersonal.AccountsFixtures

  step "I am logged in as {string}", %{args: [user_type]} = context do
    user = user_fixture(%{user_type: String.to_existing_atom(user_type)})
    conn = log_in_user(build_conn(), user)

    updated_context = context
    |> Map.put(:conn, conn)
    |> Map.put(:current_user, user)

    {:ok, updated_context}
  end

  step "I visit the login page", context do
    {:ok, view, _html} = live(context.conn, ~p"/users/log_in")
    {:ok, Map.put(context, :view, view)}
  end

  step "I should see {string}", %{args: [text]} = context do
    html = render(context.view)
    assert html =~ text
    {:ok, context}
  end
end
```

**Key Cucumber patterns:**

1. Step defs in `test/features/step_definitions/*.exs`
2. Feature files in `test/features/domain/*.feature`
3. Context is a map — pass data between steps via context
4. Parameters in args — `%{args: [param1, param2]}`
5. Each step MUST return `{:ok, context}` tuple
6. Test helper order: `ExUnit.start()` THEN `Cucumber.compile_features!()`

**Requirements:**

- MUST create actual files — use Write tool
- Follow existing project patterns
- Tag appropriately
- Provide next steps: `mix test --only @tag`
