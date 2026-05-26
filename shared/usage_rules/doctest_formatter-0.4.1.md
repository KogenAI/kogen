# doctest_formatter

Automatic formatter for Elixir doctests that standardizes prompt syntax and code formatting within documentation examples. Integrates seamlessly with `mix format` as a plugin.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
{:doctest_formatter, "~> 0.4.1", runtime: false}
```

Update `.formatter.exs`:

```elixir
[
  plugins: [DoctestFormatter.Plugin],
  # ... other formatter config
]
```

**Requirements**: Elixir 1.13.2 or later

### Basic Usage

Run standard format command:

```bash
mix format
```

The formatter automatically processes all doctests in your project, standardizing prompt syntax and code formatting.

## Core Concepts

### Prompt Standardization

The formatter enforces consistent prompt conventions:

- **First line**: Always uses `iex>` for the initial prompt
- **Continuation lines**: Always uses `...>` for subsequent lines
- **Consistency**: Ensures uniform formatting across entire codebase

### Example Transformation

Input (inconsistent):

```elixir
iex> 1 + 1
iex> |> Enum.map(&(&1 * 2))
```

Output (standardized):

```elixir
iex> 1 + 1
...> |> Enum.map(&(&1 * 2))
```

### Scope

- Formats Elixir code within doctests
- Normalizes test prompts and responses
- Works only with string and sigil literals
- Integrates with existing `mix format` configuration

## Configuration

### In `.formatter.exs`

```elixir
[
  plugins: [DoctestFormatter.Plugin],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Standard formatter options apply to doctest code
  line_length: 120,
  dot_formatter_opts: [...]
]
```

The formatter inherits line length and other formatter options from main configuration.

### Conditional Execution

The formatter only processes files included in `.formatter.exs` input patterns. Adjust `inputs` to control which files are formatted.

## Best Practices

### Known Limitations and Workarounds

1. **Double-Escaped Quotes** (`"\""`)
   - **Problem**: Cannot parse doctests containing escaped quote characters
   - **Workaround**: Use the `~S` sigil for raw strings:

   ```elixir
   @doc ~S"""
   iex> inspect("\"")
   "\""
   """
   ```

2. **Dynamic Values**
   - **Limitation**: Only formats static string and sigil literals
   - **Workaround**: Avoid interpolated strings (`#{...}`) and dynamic module attributes in doctests
   - **Example**: Hardcode expected values instead of computed ones

3. **Plugin Conflicts**
   - **Problem**: May conflict with other plugins due to AST parsing/regeneration
   - **Solution**: Test formatter with full plugin suite; adjust plugin order if needed

### Writing Doctest-Friendly Code

1. **Keep doctest examples simple** - avoid complex control flow that's hard to format
2. **Use sigils for special strings** - `~S`, `~W`, `~r` for raw strings, words, regexes
3. **Test with `mix test`** - verify doctest examples actually run correctly
4. **Commit formatted results** - run `mix format` before committing to maintain consistency

### Interaction with Other Tools

- **Works with**: `mix format` command and formatter plugins
- **Compatible with**: ExUnit doctest runner (`doctest/1`)
- **Avoid mixing**: Multiple doctest formatters or conflicting AST-modifying plugins

---

**Version:** 0.4.1
**Source:** [hexdocs.pm/doctest_formatter](https://hexdocs.pm/doctest_formatter/)
**Generated:** 2025-10-28
