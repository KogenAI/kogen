# Recipe: Phoenix Cucumber BDD Setup

## Problem

How to implement comprehensive BDD testing in Phoenix/Elixir projects using Cucumber, providing executable business specifications that bridge technical and non-technical stakeholders.

## Solution

Use the official Cucumber library for Elixir (0.4.1+) with proper infrastructure setup, organized feature files, and domain-specific step definitions that integrate seamlessly with existing ExUnit test infrastructure.

## Implementation

### Step 1: Add Cucumber Dependency

```elixir
# mix.exs
defp deps do
  [
    {:cucumber, "~> 0.4.1", only: :test},
    # ... other deps
  ]
end
```

### Step 2: Configure Test Helper

```elixir
# test/test_helper.exs

# Detect BDD mode - check if running BDD tests
bdd_mode? = "--only" in System.argv() and "bdd" in System.argv()

# Exclude feature and bdd tests by default
ExUnit.start(exclude: [:feature, :bdd])

# BDD-specific setup
if bdd_mode? do
  Cucumber.compile_features!()
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
else
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)
end
```

**Why shared sandbox mode?** BDD tests need to share database state across multiple processes (test process + Phoenix server).

### Step 3: Create Directory Structure

```bash
test/
├── features/
│   ├── job_seeker/           # Organize by user role
│   │   ├── job_application.feature
│   │   └── resume_management.feature
│   ├── employer/
│   │   ├── job_posting.feature
│   │   └── company_profile.feature
│   ├── admin/
│   │   └── dashboard.feature
│   ├── visitor/
│   │   └── user_registration.feature
│   └── step_definitions/
│       ├── authentication_steps.exs
│       ├── job_steps.exs
│       ├── application_steps.exs
│       └── common_steps.exs
```

### Step 4: Write Feature Files

```gherkin
# test/features/job_seeker/job_application.feature
@bdd
Feature: Job Application Submission
  As a job seeker
  I want to apply for jobs
  So that I can find employment

  Scenario: Apply for a job with cover letter
    Given I am logged in as a "job_seeker"
    And there is a job posting for "Senior Nurse"
    When I visit the job details page
    And I click "Apply Now"
    And I fill in "Cover Letter" with "I am very interested"
    And I submit the application
    Then I should see "Application submitted successfully"
    And the application should be saved in the database
```

**Critical:** Always tag with `@bdd` to enable exclusion by default.

### Step 5: Implement Step Definitions

```elixir
# test/features/step_definitions/authentication_steps.exs
defmodule AuthenticationSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import MyAppWeb.ConnCase

  # CRITICAL: Extract parameters via %{args: [...]}
  step "I am logged in as a {string}", %{args: [role]} = context do
    user = create_user_for_role(role)
    conn = build_conn() |> log_in_user(user)

    # CRITICAL: Always return {:ok, context} tuple
    {:ok, Map.merge(context, %{current_user: user, conn: conn})}
  end
end

# test/features/step_definitions/job_steps.exs
defmodule JobSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "there is a job posting for {string}", %{args: [title]} = context do
    job = create_job_posting(%{title: title})
    {:ok, Map.put(context, :job, job)}
  end

  step "I visit the job details page", context do
    # Use context from previous steps
    job = context[:job]
    # Navigate to job page
    {:ok, context}
  end

  # Multiple parameters
  step "I fill in {string} with {string}", %{args: [field, value]} = context do
    # Implementation
    {:ok, context}
  end
end
```

**Key patterns:**

- Use specific names to avoid collisions: "employer submits job posting" not "submit form"
- Extract params: `%{args: [param1, param2]}`
- Return tuple: `{:ok, updated_context}`
- Pass data between steps via context map

### Step 6: Create Mix Alias for BDD Tests

```elixir
# mix.exs
defp aliases do
  [
    "test.bdd": [
      "ecto.drop --quiet",
      "ecto.create --quiet",
      "ecto.migrate --quiet",
      fn args ->
        port = System.get_env("PORT_TEST") ||
          raise "PORT_TEST environment variable must be set"

        System.put_env("FEATURE_TESTS", "true")
        System.put_env("PW_TIMEOUT", "2000")

        # Run tests
        Mix.Task.run("test", ["--only", "bdd" | args])

        # Cleanup: Kill test server
        System.cmd("lsof", ["-ti", "tcp:#{port}"])
        |> case do
          {pids, 0} ->
            String.split(pids, "\n", trim: true)
            |> Enum.each(fn pid ->
              System.cmd("kill", ["-9", pid])
            end)
          _ -> :ok
        end
      end
    ]
  ]
end
```

### Step 7: Create Cleanup Script (Alternative)

```bash
#!/bin/bash
# scripts/bdd_test.sh

export FEATURE_TESTS=true
export PW_TIMEOUT=2000

SCRIPT_PID=$$
TEST_PORT=${PORT_TEST:?PORT_TEST must be set}

# Database reset
echo "🗄️  Resetting test database..."
MIX_ENV=test mix ecto.drop --quiet 2>/dev/null || true
MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --quiet
echo "  Database reset complete ✓"

# Cleanup function
cleanup_on_exit() {
    echo -e "\n🧹 Cleaning up test server..."
    if lsof -ti tcp:${TEST_PORT} > /dev/null 2>&1; then
        lsof -ti tcp:${TEST_PORT} | xargs kill -9 2>/dev/null || true
    fi
}

trap cleanup_on_exit EXIT

# Kill existing server
if lsof -ti tcp:${TEST_PORT} > /dev/null 2>&1; then
    lsof -ti tcp:${TEST_PORT} | xargs kill -9 2>/dev/null || true
fi

# Run tests
mix test --color --only bdd "$@"
TEST_EXIT_CODE=$?

exit $TEST_EXIT_CODE
```

## Considerations

### Database Setup

- **Automatic reset required:** BDD tests need clean database state
- **Shared sandbox mode:** Multiple processes (test + server) need database access
- **Handle in script:** Database reset in mix alias or bash script, not in tests

### Step Definition Best Practices

- **Avoid collisions:** Use domain-specific step names ("employer posts job" vs "post job")
- **Context passing:** Use map to pass data between steps
- **Tuple returns:** Always `{:ok, context}`, never bare context
- **Parameter extraction:** Via `%{args: [param]}` pattern matching

### Running Tests

- **Default exclusion:** BDD tests excluded by default (like feature tests)
- **Use alias:** `mix test.bdd` handles cleanup automatically
- **Individual files:** `mix test test/features/step_definitions/job_steps.exs` during development
- **Never:** `mix test --only bdd` without cleanup (leaves server running)

### Common Pitfalls

1. **Using `--include bdd`** instead of `--only bdd` (runs ALL + BDD, not just BDD)
2. **Forgetting `{:ok, }` wrapper** on step returns
3. **Global step names** causing collisions across domains
4. **Missing database reset** between runs
5. **Not cleaning up test server** after runs

### When to Use BDD

- **Living documentation:** Business stakeholders need readable specs
- **Critical workflows:** User journeys that define business value
- **Communication:** Bridge gap between technical and non-technical teams
- **NOT for everything:** Complement existing tests, don't replace them

### Integration with Existing Tests

- **Unit tests:** Still write ExUnit tests for contexts/schemas
- **LiveView tests:** Still write integration tests for LiveViews
- **Feature tests:** Can coexist with Playwright browser tests
- **BDD tests:** For executable specifications and stakeholder communication

## Example Usage

### Complete Workflow Example

```gherkin
# test/features/employer/job_posting.feature
@bdd
Feature: Job Posting Management
  As an employer
  I want to post and manage job listings
  So that I can attract qualified candidates

  Scenario: Create a new job posting
    Given I am logged in as an "employer"
    When I navigate to "New Job Posting"
    And I fill in the job details:
      | Title       | Senior Nurse Position    |
      | Location    | Zurich                   |
      | Type        | Full-time                |
      | Description | Looking for experienced nurse |
    And I submit the job posting
    Then I should see "Job posted successfully"
    And the job should be visible in my listings
    And the job should appear in public job search

  Scenario: Edit existing job posting
    Given I am logged in as an "employer"
    And I have posted a job for "Junior Nurse"
    When I navigate to my job listings
    And I click "Edit" on the "Junior Nurse" posting
    And I change the title to "Experienced Nurse"
    And I save the changes
    Then I should see "Job updated successfully"
    And the updated title should be "Experienced Nurse"
```

```elixir
# test/features/step_definitions/employer_steps.exs
defmodule EmployerSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  step "I navigate to {string}", %{args: [page]} = context do
    conn = context[:conn]
    path = page_path(page)
    {:ok, view, _html} = live(conn, path)
    {:ok, Map.put(context, :view, view)}
  end

  step "I fill in the job details:", %{table: table} = context do
    view = context[:view]

    # Convert table to map
    attrs = table
    |> Enum.map(fn [key, value] -> {String.downcase(key), value} end)
    |> Enum.into(%{})

    # Fill form
    view
    |> form("#job-form", job: attrs)
    |> render_change()

    {:ok, context}
  end

  step "I submit the job posting", context do
    view = context[:view]

    view
    |> form("#job-form")
    |> render_submit()

    {:ok, context}
  end

  step "the job should be visible in my listings", context do
    user = context[:current_user]
    jobs = MyApp.Jobs.list_jobs_for_employer(user.id)

    assert length(jobs) > 0
    {:ok, context}
  end
end
```

## Related Recipes

- [Phoenix Feature Test Setup](phoenix-feature-test-setup.md)
- [Browser Test Organization](browser-test-organization.md)
- [Phoenix Async Feature Testing with LiveView](phoenix-async-feature-test-liveview.md)
- [Flaky Test Fix](flaky-test-fix.md)
