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

- Module name and location
- Required imports (fixtures, helpers)
- Step definition stubs for the scenarios
- Context management patterns
- Integration with existing Phoenix/Playwright infrastructure

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
- **Provide next steps** - Show user how to implement the step definitions

This command bridges the gap between informal test ideas and structured BDD implementation, making it easy to convert business requirements into executable specifications.
