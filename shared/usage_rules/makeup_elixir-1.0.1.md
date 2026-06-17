# makeup_elixir

## Overview

makeup_elixir is an Elixir lexer for the Makeup syntax highlighting library. It provides tokenization and lexing of Elixir source code, enabling syntax highlighting in documentation, blogs, and other text processing pipelines. It integrates with the Makeup highlighter ecosystem to produce colored and formatted output.

## Quick Start

### Installation

Add makeup_elixir to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:makeup_elixir, "~> 1.0"}
  ]
end
```

Then run `mix deps.get`.

### Basic Usage

```elixir
# Tokenize Elixir code
{:ok, tokens, ""} = Makeup.Lexers.Elixir.tokenize("defmodule Example do\n  def hello, do: :world\nend")

# Use with Makeup for full highlighting
Makeup.highlight(code, lexer: Makeup.Lexers.Elixir)
```

## Core Concepts

### Tokenization

The Elixir lexer breaks source code into meaningful tokens with type classifications:

- Keywords (defmodule, def, if, etc.)
- Atoms and symbols
- Strings and heredocs
- Comments
- Operators
- Numbers
- Variables and identifiers

### Integration with Makeup

makeup_elixir works as a lexer plugin within the Makeup ecosystem. Once installed, Makeup automatically discovers it and can tokenize Elixir code:

```elixir
Makeup.highlight(code_string, lexer: Makeup.Lexers.Elixir)
```

### Token Output

Each token is a tuple: `{token_type, %{}, value}`

Example tokens from `def test: :ok`:

- `{:keyword, %{}, "def"}`
- `{:name, %{}, "test"}`
- `{:punctuation, %{}, ":"}`
- `{:atom, %{}, ":ok"}`

### Supported Language Features

The lexer recognizes:

- Module and function definitions
- Pattern matching and guards
- Pipes and operators
- String interpolation
- Heredocs and raw strings
- Comments (single and documentation)
- Atoms, tuples, lists, maps
- Sigils (including custom sigils)
- Charlists and escape sequences

## Configuration

### Using with Makeup Formatters

Configure output formatting through Makeup's style system:

```elixir
# In your Phoenix config or application setup
config :makeup,
  styles: [
    default: "default"
  ]
```

### Custom Styles

Pair with Makeup formatters to apply CSS classes or ANSI colors:

```elixir
Makeup.highlight(code,
  lexer: Makeup.Lexers.Elixir,
  formatter: Makeup.Formatters.HTML.HTMLFormatter
)
```

### Handling Special Cases

The lexer handles edge cases automatically:

- **String interpolation**: Correctly tokenizes expressions within `#{}` in strings
- **Nested structures**: Maps, lists, and tuples nest properly
- **Escape sequences**: Interprets escape codes in strings and charlists
- **Comments**: Treats `#` as comment start except in strings

## Best Practices

### 1. Always Assume UTF-8

Ensure source code is UTF-8 encoded. The lexer handles Unicode identifiers and atoms.

### 2. Handle Long Documents

For very large Elixir files, tokenization happens lazily. Process tokens stream-wise if memory is a concern:

```elixir
{:ok, tokens, ""} = Makeup.Lexers.Elixir.tokenize(large_code)
Enum.each(tokens, &process_token/1)
```

### 3. Pair with HTML/Terminal Formatters

Don't use raw tokens in user-facing output. Always format with Makeup formatters:

```elixir
# Good: formatted output
Makeup.highlight(code, formatter: Makeup.Formatters.HTML.HTMLFormatter)

# Avoid: raw tokens exposed to users
Makeup.Lexers.Elixir.tokenize(code)
```

### 4. Caching Tokens

For repeated highlighting of the same code:

```elixir
@cached_code "defmodule Test do end"

def format_code do
  Makeup.highlight(@cached_code, lexer: Makeup.Lexers.Elixir)
end
```

### 5. Graceful Error Handling

The lexer is forgiving and will tokenize partial or invalid Elixir as best it can:

```elixir
# Even incomplete code tokenizes without crashing
{:ok, tokens, ""} = Makeup.Lexers.Elixir.tokenize("def incomplete do")
```

## Common Pitfalls

### String Interpolation Edge Cases

Complex expressions in string interpolation may need careful handling:

```elixir
# Works correctly
"Value: #{some_var + 1}"

# Nested strings within interpolation are tokenized properly
"Nested: #{inspect("quoted")}"
```

### Heredoc Boundaries

Heredoc delimiters must match exactly. The lexer respects indentation:

```elixir
text = """
  indented content
  more content
"""
```

### Sigil Recognition

Custom sigils are recognized but their internals may be treated as strings. Standard sigils (w, r, s, c) are fully supported.

---

**Version:** 1.0.1
**Source:** https://github.com/makeup-elixir/makeup_elixir
**Generated:** 2026-06-17
