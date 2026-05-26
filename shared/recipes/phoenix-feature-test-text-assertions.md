# Phoenix Feature Test Text Assertion Patterns

## Problem

PhoenixTest.Playwright performs exact text matching including all whitespace, causing tests to fail when HTML contains indentation or newlines around text content.

## Solution

Use the `exact: false` option with element selectors to match text content while ignoring surrounding whitespace.

## Implementation

### Basic Text Assertions

```elixir
# ❌ WRONG - Fails due to whitespace
|> assert_has("First Job")
|> assert_has(job.title)

# ✅ CORRECT - Ignores whitespace
|> assert_has("a", text: "First Job", exact: false)
|> assert_has("h1", text: job.title, exact: false)
```

### Multiple Elements with Same Text

```elixir
# When multiple jobs appear on a page
|> assert_has("a", text: job1.title, exact: false)
|> assert_has("a", text: job2.title, exact: false)

# Verify one exists but not another
|> assert_has("a", text: remote_job.title, exact: false)
|> refute_has("a", text: office_job.title, exact: false)
```

### Button Disambiguation

When multiple buttons have the same text:

```elixir
# ❌ WRONG - Fails with "Found more than one element"
|> click_button("Filter")

# ✅ CORRECT - Use specific CSS selector
|> click(".inline-flex.items-center:has-text('Filter')")
```

### Complex UI Workarounds

When UI elements are conditionally rendered or complex:

```elixir
# ❌ WRONG - Assuming filter UI is always visible
|> click_button("Filter")
|> wait_for_element("#job_filters", timeout: 5_000)
|> fill_in("Search", with: "Nurse")

# ✅ CORRECT - Use URL parameters directly
|> visit(~p"/jobs?job_filter[search]=Nurse")
|> visit(~p"/jobs?job_filter[remote_allowed]=true")
```

### Form Validation Testing

When validation error display is uncertain:

```elixir
# ❌ WRONG - Looking for specific error elements
|> click("button[type='submit']")
|> assert_has(".error")
|> assert_has("span", text: "can't be blank")

# ✅ CORRECT - Verify form remains (validation prevented submission)
|> click("button[type='submit']")
|> wait_for_element("textarea[name='job_application[cover_letter]']", timeout: 2_000)
|> assert_has("textarea[name='job_application[cover_letter]']")
```

### Stable Element Selection

Use generic, stable selectors instead of specific classes:

```elixir
# ❌ WRONG - Specific class that may not exist
|> wait_for_element(".job-application-item", timeout: 10_000)

# ✅ CORRECT - Generic stable selectors
|> wait_for_element("main", timeout: 10_000)
|> assert_has("a", text: job.title, exact: false)
```

## Timeout Best Practices

### Avoid Excessive Timeouts

```elixir
# ❌ WRONG - Slows down test suite unnecessarily
|> wait_for_element("main", timeout: 10_000)
|> wait_for_element(".job-listing", timeout: 15_000)

# ✅ CORRECT - Use default timeouts
|> wait_for_element("main")
|> wait_for_element(".job-listing")

# ✅ OK - Only when genuinely needed
|> wait_for_element("[data-heavy-load]", timeout: 3000)
```

**Rule**: Default timeouts are sufficient for 99% of cases. Adding explicit timeouts everywhere makes tests significantly slower.

## Key Patterns

1. **Always use `exact: false`** for database/variable text assertions
2. **Specify element type** when possible: `assert_has("a", text: ..., exact: false)`
3. **Use CSS selectors** to disambiguate multiple matching elements
4. **Navigate with URL params** when UI interaction is complex
5. **Check form presence** instead of specific error elements for validation
6. **Use stable selectors** like `main` instead of specific classes

## Debugging

When text assertions fail:

```elixir
|> unwrap(fn state ->
  # Get actual text content with whitespace
  text = Frame.evaluate(state.frame_id,
    "document.querySelector('a')?.textContent"
  )
  IO.puts("Actual text: '#{text}'")  # Shows: '  First Job  '
  {:ok, state}
end)
```

## When to Apply

- Text from database fields appearing in HTML
- Dynamic content with unknown formatting
- Tests comparing expected vs actual text
- Form validation error messages
- Lists of items with similar structure

## References

- PhoenixTest.Playwright documentation
- BemedaPersonal test suite patterns
- Session: 2025-08-12 job application test fixes
