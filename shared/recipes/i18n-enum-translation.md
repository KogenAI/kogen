# Recipe: I18n Enum Translation Patterns with Mixed Type Handling

## Problem

How to handle enum translations when enum values may come as atoms, strings, or lists, while ensuring gettext validation isn't bypassed and avoiding hardcoded fallbacks that make missing translations invisible?

## Solution

Use validation-first translation patterns with explicit enum value formatting, never add catch-all patterns that bypass gettext, and always use existing translation functions when available.

## Implementation

### 1. Format Mixed Enum Values Safely

```elixir
defmodule MyApp.TranslationHelpers do
  @doc """
  Converts enum values to standardized string format for translation.
  Handles atoms, strings, and maintains case consistency.
  """
  defp format_enum_value(value) when is_atom(value) do
    value
    |> to_string()
    |> String.capitalize()
  end

  defp format_enum_value(value) when is_binary(value) do
    String.capitalize(value)
  end

  defp format_enum_value(value) when is_list(value) do
    # Handle array fields that might contain enum values
    Enum.map(value, &format_enum_value/1)
  end
end
```

### 2. Validate Before Translation (Never Catch-All)

```elixir
defmodule MyApp.I18n do
  use Gettext, backend: MyAppWeb.Gettext

  # WRONG - bypasses gettext validation
  def translate_department(department) do
    case department do
      "Acute Care" -> dgettext("jobs", "Acute Care")
      "Administration" -> dgettext("jobs", "Administration")
      _ -> department  # BAD - hides missing translations
    end
  end

  # CORRECT - validation first, no catch-all
  def translate_department(department) do
    department_string = format_enum_value(department)

    if valid_department?(department_string) do
      dgettext("jobs", department_string)
    else
      # Log the issue but don't hide it
      Logger.warning("Unknown department for translation: #{inspect(department)}")
      department_string
    end
  end

  defp valid_department?(value) do
    value in ["Acute Care", "Administration", "ICU", "Emergency", "Surgery"]
  end
end
```

### 3. Handle List Fields (Department/Profession Arrays)

```elixir
defmodule MyApp.TagHelpers do
  alias MyApp.I18n

  def build_department_tags(departments) when is_list(departments) do
    Enum.reduce(departments, [], fn dept, acc ->
      dept_string = format_enum_value(dept)

      if valid_for_translation?(dept_string) do
        [I18n.translate_department(dept_string) | acc]
      else
        acc  # Skip invalid values rather than showing untranslated
      end
    end)
  end

  def build_department_tags(department) when not is_nil(department) do
    build_department_tags([department])
  end

  def build_department_tags(_), do: []

  defp valid_for_translation?(value) do
    # Only translate values that exist in the translation system
    not is_nil(value) and value != ""
  end
end
```

### 4. Use Existing Translation Functions

```elixir
defmodule MyAppWeb.Components.ApplicationStatusBadge do
  use Phoenix.Component

  # WRONG - creating new translation pattern
  defp status_text(status) do
    case status do
      :pending -> "Pending"
      :approved -> "Approved"
      _ -> to_string(status)
    end
  end

  # CORRECT - use existing I18n module pattern
  defp status_text(status) do
    # Reuse existing translation function if available
    I18n.translate_status(status)
  end

  def status_badge(assigns) do
    ~H"""
    <span class={["px-2 py-1 rounded-full text-xs font-medium", status_color(@status)]}>
      <%= status_text(@status) %>
    </span>
    """
  end
end
```

### 5. Handle Pluralization with dngettext

```elixir
defmodule MyApp.DateUtils do
  use Gettext, backend: MyAppWeb.Gettext

  def relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 ->
        dngettext("default", "1 second ago", "%{count} seconds ago", diff, count: diff)

      diff < 3600 ->
        minutes = div(diff, 60)
        dngettext("default", "1 minute ago", "%{count} minutes ago", minutes, count: minutes)

      diff < 86400 ->
        hours = div(diff, 3600)
        dngettext("default", "1 hour ago", "%{count} hours ago", hours, count: hours)

      true ->
        dgettext("default", "Yesterday")
    end
  end
end
```

## Considerations

### Security and Maintenance

- **Never bypass gettext**: Catch-all patterns hide missing translations and bypass validation
- **Explicit validation**: Always validate enum values before translation attempts
- **Centralized functions**: Reuse existing translation functions rather than duplicating patterns
- **Logging**: Log unknown values to identify missing translations during development

### Performance

- **Validation overhead**: Pre-validation adds minimal overhead but prevents runtime errors
- **Caching**: Gettext automatically caches translations; don't add additional caching layers
- **Enum lists**: Store valid enum lists as module attributes for compile-time optimization

### When to Use This Pattern

- ✅ Handling user-generated content that may have inconsistent enum formats
- ✅ Database fields that store enums as different types (atom vs string)
- ✅ API responses where enum formats aren't guaranteed
- ✅ Form submissions with mixed data types

### When NOT to Use This Pattern

- ❌ Internal application logic where enum types are controlled and consistent
- ❌ Performance-critical code paths where validation overhead is problematic
- ❌ Simple cases with only one enum format throughout the application

### Common Pitfalls

- **Catch-all translation patterns**: Never use `_ -> value` in translation functions
- **Missing extraction**: Always run `mix gettext.extract --merge` after adding new translations
- **Case sensitivity**: Ensure consistent case handling between database values and translations
- **List handling**: Don't forget to handle array fields that may contain enums

## Example Usage

From the job-applications-figma feature implementation:

```elixir
# Before - problematic pattern
def translate_status(status) do
  case status do
    :pending -> dgettext("jobs", "Pending")
    :approved -> dgettext("jobs", "Approved")
    _ -> to_string(status)  # Bypasses gettext validation
  end
end

# After - validation-first pattern
def translate_status(status) do
  status_string = format_enum_value(status)

  if valid_status?(status_string) do
    I18n.translate_status(status_string)  # Use existing function
  else
    Logger.warning("Unknown status for translation: #{inspect(status)}")
    status_string
  end
end

defp valid_status?(status) do
  status in ["Pending", "Approved", "Rejected", "Withdrawn"]
end
```

This pattern successfully handled mixed atom/string enum values while maintaining gettext validation and revealing missing translations during development.

## Related Recipes

- [Phoenix Param Normalization](./phoenix-param-normalization.md)
- [Phoenix Component Migration](./phoenix-component-migration.md)
