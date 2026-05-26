# phoenix_html

Phoenix.HTML provides core building blocks for safe HTML generation, form handling, and lightweight JavaScript enhancements in Phoenix applications. The library emphasizes security through automatic HTML escaping by default while allowing intentional bypass when needed.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_html, "~> 4.3"}
  ]
end
```

### Basic HTML Safety

```elixir
# Automatic escaping (safe by default)
iex> Phoenix.HTML.html_escape("<hello>")
{:safe, "&lt;hello&gt;"}

# Mark content as intentionally safe
iex> Phoenix.HTML.raw("<b>Bold</b>")
{:safe, "<b>Bold</b>"}

# Convert safe result to string
iex> Phoenix.HTML.safe_to_string({:safe, "<p>text</p>"})
"<p>text</p>"
```

## Core Concepts

### HTML Safety Mechanism

Phoenix.HTML uses a `{:safe, iodata}` tuple to represent content that won't be escaped. All user input is escaped by default; use `raw/1` only for trusted content.

### Escaping Functions

- **`html_escape/1`** - Escapes HTML entities (`<`, `>`, `&`, `"`, `'`)
- **`javascript_escape/1`** - Escapes content for JavaScript string insertion
- **`css_escape/1`** - Escapes strings for use as CSS identifiers
- **`attributes_escape/2`** - Escapes HTML attributes with special handling for `:data`, `:aria`, `:phx`, `:class`, and `:id` attributes

### Form Handling

The `Phoenix.HTML.Form` module provides utilities for building secure forms:

- **`Form` struct** - Represents a form with `action`, `source`, `params`, `errors`, and field metadata
- **`input_value/2`** - Retrieves field values (checks changes → parameters → defaults)
- **`input_name/2`** - Generates field names (e.g., `"user[first_name]"`)
- **`input_id/2-3`** - Creates unique field IDs, with optional value attachment for radio buttons
- **`options_for_select/3`** - Generates `<option>` elements for select fields
- **`input_validations/2`** - Returns HTML validation attributes from input type

### Form Field Access

Access fields using bracket notation (atom or string):

```elixir
form[field]        # Returns FormField struct with id, name, value, errors
form["field_name"] # String access works too
```

### JavaScript Enhancement

The `priv/static/phoenix_html.js` library provides:

- **`data-confirm`** attribute - Shows confirmation dialogs before action
- **`data-method`** attribute - Converts links to HTTP methods (POST, PUT, DELETE)

## Configuration

### Custom Form Data

Implement `Phoenix.HTML.FormData` protocol to convert custom data structures into Form structs:

```elixir
defimpl Phoenix.HTML.FormData, for: MyStruct do
  def to_form(data, opts) do
    # Return Form struct
  end
end
```

### JavaScript Customization

Listen to `phoenix.link.click` events for custom behaviors:

```javascript
document.addEventListener("phoenix.link.click", (event) => {
  // Custom handling
});
```

## Best Practices

### Security

1. **Always use default escaping** - Never assume user input is safe
2. **Mark intentional HTML carefully** - Use `raw/1` only for trusted content (templates, fixtures)
3. **Escape output in different contexts** - Use appropriate escape function (HTML, JS, CSS)

### Form Patterns

1. **Use bracket notation** - `form[field]` is preferred over direct struct access
2. **Handle validation attributes** - Use `input_validations/2` to enforce constraints
3. **Leverage input_changed?** - Compare form states to detect modifications
4. **Normalize values** - Use `normalize_value/2` for proper type handling (datetime, checkbox, textarea)

### Field Generation

1. **Generate field names consistently** - `input_name/2` handles proper nesting automatically
2. **Create unique IDs** - `input_id/2-3` prevents ID collisions in complex forms
3. **Build select options** - `options_for_select/3` handles value matching and HTML generation

### Performance

1. **Precompile escaping** - Escape values once, reuse the safe result
2. **Batch form field processing** - Use form access patterns rather than manual struct manipulation
3. **Minimize raw/1 usage** - Each `raw/1` bypasses safety checks; use sparingly

---

**Version:** 4.3.0
**Source:** [hexdocs.pm/phoenix_html](https://hexdocs.pm/phoenix_html/)
**Generated:** 2025-10-28
