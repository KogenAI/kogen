# makeup

A syntax highlighting library for Elixir that provides a flexible, extensible system for tokenizing and rendering code. Makeup uses Pygments-style lexers and formatters to highlight code across multiple output formats (HTML, ANSI terminal, etc.).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:makeup, "~> 1.2"},
    {:makeup_elixir, "~> 0.16"},  # optional: Elixir lexer
    {:makeup_html, "~> 0.1"}       # optional: HTML formatter
  ]
end
```

### Basic Usage

```elixir
# Highlight Elixir code to HTML
code = "defmodule Hello do\n  def world, do: :ok\nend"
Makeup.highlight(code, lexer: Makeup.Lexers.ElixirLexer)

# Specify output format
Makeup.highlight(code, lexer: Makeup.Lexers.ElixirLexer, formatter: Makeup.Formatters.HTMLFormatter)
```

## Core Concepts

### Lexers

Lexers tokenize source code into tagged tokens (token type + value). Each language has a dedicated lexer:

- **ElixirLexer** - Highlights Elixir syntax
- **ErlangLexer** - Highlights Erlang syntax
- **PlainTextLexer** - No highlighting, preserves input

Example custom lexer:

```elixir
defmodule MyLexer do
  def lex(text) do
    text
    |> String.split(" ")
    |> Enum.map(&{:keyword, &1})
  end
end
```

### Formatters

Formatters convert token streams into output representations. Built-in formatters:

- **HTMLFormatter** - Produces HTML with CSS classes for styling
- **ANSIFormatter** - Outputs terminal ANSI escape codes
- **RawFormatter** - Returns raw token list

```elixir
# HTML with custom style options
Makeup.highlight(code,
  lexer: Makeup.Lexers.ElixirLexer,
  formatter: Makeup.Formatters.HTMLFormatter,
  formatter_options: [css_class: "highlight"]
)
```

### Tokens

Tokens are tuples `{token_type, token_value}` where:

- `token_type` - Atom category (`:keyword`, `:string`, `:comment`, etc.)
- `token_value` - String content

```elixir
# Token stream example
[
  {:keyword, "defmodule"},
  {:whitespace, " "},
  {:name_class, "Hello"},
  {:operator, "do"},
  {:newline, "\n"}
]
```

## Configuration

### Formatter Options

HTMLFormatter accepts options:

```elixir
Makeup.highlight(code,
  lexer: Makeup.Lexers.ElixirLexer,
  formatter: Makeup.Formatters.HTMLFormatter,
  formatter_options: [
    css_class: "highlight",        # CSS class for wrapper
    line_numbers: true,            # Display line numbers
    style: :default                # Color scheme
  ]
)
```

ANSIFormatter options:

```elixir
Makeup.highlight(code,
  lexer: Makeup.Lexers.ElixirLexer,
  formatter: Makeup.Formatters.ANSIFormatter,
  formatter_options: [
    style: :autumn                 # Terminal color scheme
  ]
)
```

### Available Styles

- `:default` - Standard highlighting
- `:autumn` - Warm earth tones
- `:murphy` - Blue-based palette
- `:monokai` - Dark high-contrast

Configure globally in `config.exs`:

```elixir
config :makeup,
  default_lexer: Makeup.Lexers.ElixirLexer,
  default_formatter: Makeup.Formatters.HTMLFormatter
```

## Best Practices

### 1. Cache Lexer Compilation

Lexers compile on first use. For repeated highlighting, store the lexer:

```elixir
lexer = Makeup.Lexers.get_lexer_by_name("elixir")

Enum.each(code_snippets, &Makeup.highlight(&1, lexer: lexer))
```

### 2. Error Handling

Makeup gracefully handles unknown or malformed code:

```elixir
# Returns highlighted output even with syntax errors
Makeup.highlight("invalid (( code", lexer: Makeup.Lexers.ElixirLexer)
```

### 3. Phoenix Integration

Use in templates with safe HTML:

```elixir
# In controller
code = "IO.puts(:hello)"
highlighted = Makeup.highlight(code, lexer: Makeup.Lexers.ElixirLexer)

# In template
<%= raw(highlighted) %>
```

### 4. Performance Considerations

- Highlight large blocks server-side, not in hot paths
- Cache formatted output when code is static
- Use `RawFormatter` for intermediate storage, apply HTML formatting later

```elixir
# Cache tokens, format on demand
defmodule CodeCache do
  def get_tokens(code, lang) do
    cache_key = :crypto.hash(:sha256, code) |> Base.encode16()

    case fetch_from_cache(cache_key) do
      {:ok, tokens} -> tokens
      :miss ->
        lexer = Makeup.Lexers.get_lexer_by_name(lang)
        tokens = Makeup.lex(code, lexer: lexer)
        store_in_cache(cache_key, tokens)
        tokens
    end
  end
end
```

### 5. Fallback for Unsupported Languages

```elixir
def safe_highlight(code, language) do
  lexer = Makeup.Lexers.get_lexer_by_name(language)

  try do
    Makeup.highlight(code, lexer: lexer)
  rescue
    _ -> Makeup.highlight(code, lexer: Makeup.Lexers.PlainTextLexer)
  end
end
```

### 6. Custom Token Styling

Define CSS for token types in your stylesheet:

```css
.highlight .k {
  color: #0066cc;
  font-weight: bold;
} /* keywords */
.highlight .s {
  color: #00aa00;
} /* strings */
.highlight .c {
  color: #999999;
  font-style: italic;
} /* comments */
```

## Common Pitfalls

- **Forgetting to depend on language lexers**: Installing just `:makeup` provides no lexers. Add language-specific dependencies like `:makeup_elixir`.
- **HTML escaping issues**: Always use `raw()` in templates when rendering highlighted HTML; otherwise escaping breaks styling.
- **Performance with huge code blocks**: Lexing massive files (>50KB) can block. Process in background jobs.
- **Mixing formatter output**: Don't pipe HTML formatter output to ANSI formatter; they're independent transformations.

---

**Version:** 1.2.1
**Source:** [makeup on hexdocs](https://makeup.hexdocs.pm)
**Generated:** 2026-06-17
