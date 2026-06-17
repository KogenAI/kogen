# bunt

Bunt is a minimalist library for colorizing terminal text in Elixir. It provides a simple, composable API for adding ANSI color codes to strings without dependencies or complex configuration.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:bunt, "~> 1.0"}
  ]
end
```

### Basic Usage

```elixir
# Simple coloring
Bunt.IO.puts([:red, "Error: something failed"])
Bunt.IO.puts([:green, "Success!"])

# Colors are atoms
Bunt.IO.puts([:blue, "Information"])
Bunt.IO.puts([:yellow, "Warning"])

# Nesting colors
Bunt.IO.puts([:red, "Error:", [:reset, " ", [:green, "Details"]]])
```

## Core Concepts

### Available Colors

Bunt supports the following basic ANSI colors:

- `:black`
- `:red`
- `:green`
- `:yellow`
- `:blue`
- `:magenta`
- `:cyan`
- `:white`

### Text Styling

- `:bright` - Bright/bold text
- `:underline` - Underlined text
- `:reverse` - Reversed video (inverted colors)
- `:reset` - Reset to default terminal colors

### Composable Lists

The core abstraction is passing a list of formatting atoms and strings to `Bunt.IO.puts/1`:

```elixir
# List order matters - formats apply cumulatively
Bunt.IO.puts([:bright, :red, "Bold Red Text"])

# Mix formats and content
Bunt.IO.puts([
  :blue,
  "Blue: ",
  [:reset, :green, "then green"],
  [:reset, :red, " then red"]
])
```

### Direct String Coloring

Use `Bunt.ANSI.format/1` to get the ANSI-coded string without printing:

```elixir
formatted = Bunt.ANSI.format([:red, "Error"])
# Returns string with embedded ANSI codes
IO.write(formatted)
```

## Common Patterns

### Conditional Coloring

```elixir
colors = if success, do: [:green], else: [:red]
Bunt.IO.puts([colors, "Status: #{status}"])
```

### Multiline Output with Consistent Colors

```elixir
Bunt.IO.puts([
  :blue,
  "Line 1\n",
  "Line 2\n",
  [:reset, :green, "Different color line"]
])
```

### Building Formatted Strings

```elixir
error_format = fn msg ->
  Bunt.ANSI.format([:bright, :red, msg])
end

IO.write(error_format.("Critical error!"))
```

## Configuration

Bunt does **not** require configuration. It will use ANSI codes by default on all platforms. However:

- On Windows 10+, ANSI codes are natively supported
- On older Windows versions, the codes may not render properly
- To disable colors programmatically, strip the formatting before passing to `IO.puts/1`

### Disable Colors for Non-Interactive Shells

```elixir
# Check if stdout is a TTY
if IO.isatty() do
  Bunt.IO.puts([:red, "Error"])
else
  # Fall back to plain text
  IO.puts("Error")
end
```

## Best Practices

### 1. Use Semantic Color Meanings

```elixir
# Good - colors convey meaning
success = [:green, "✓ Passed"]
error = [:red, "✗ Failed"]
warning = [:yellow, "⚠ Warning"]
```

### 2. Reset After Changes

When nesting multiple color/style changes, explicitly use `:reset` to avoid color bleeding:

```elixir
# Good - explicit reset
Bunt.IO.puts([
  :red, "Error",
  [:reset, :blue, " (Info)"]
])

# Avoid - color may bleed to next text
Bunt.IO.puts([:red, "Error", [:blue, " (Info)"]])
```

### 3. Avoid Deep Nesting

Keep list nesting shallow for readability:

```elixir
# Good - flat structure
Bunt.IO.puts([
  :red, "Error: ", :reset,
  :blue, "Details here", :reset
])

# Avoid - hard to read
Bunt.IO.puts([
  :red, "Error:", [
    :reset, [:blue, "Details"
  ]
]])
```

### 4. Terminal Detection

Always check if output is interactive before applying colors in automated tools:

```elixir
def print_status(status) do
  format = if IO.isatty(), do: [:green], else: []
  Bunt.IO.puts([format, status])
end
```

### 5. Accessibility

Not everyone can distinguish colors. Include additional markers:

```elixir
# Good - uses color + text symbol
Bunt.IO.puts([:green, "✓ ", "Test passed"])
Bunt.IO.puts([:red, "✗ ", "Test failed"])
```

## Important Gotchas

### Color Codes in Strings vs Lists

```elixir
# Correct - passes list to Bunt
Bunt.IO.puts([:red, "Text"])

# Wrong - string won't be colored
Bunt.IO.puts("[:red, Text]")  # prints literally
```

### Styles Don't Persist Across Separate Calls

```elixir
# Each call is independent
Bunt.IO.puts([:red, "Line 1"])
Bunt.IO.puts("Line 2")  # Not red - style lost

# Correct - within one call
Bunt.IO.puts([
  :red, "Line 1\n",
  "Line 2"
])
```

### Performance Note

Bunt is lightweight. String concatenation with ANSI codes is minimal overhead. Acceptable for normal CLI output; avoid coloring millions of strings in tight loops.

---

**Version:** 1.0.0
**Source:** https://hexdocs.pm/bunt/1.0.0
**Generated:** 2026-06-17
