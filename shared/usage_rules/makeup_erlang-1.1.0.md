# makeup_erlang

## Overview

**makeup_erlang** is a syntax highlighting lexer for the Erlang programming language, built on top of the Makeup framework. It provides lexical analysis and tokenization of Erlang source code, enabling syntax-aware code highlighting for documentation, terminal output, and web-based displays.

This library is essential for any Elixir/Phoenix application that needs to display or highlight Erlang code snippets with proper syntax coloring and semantic token classification.

## Quick Start

### Installation

Add `makeup_erlang` to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:makeup_erlang, "~> 1.1"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

### Basic Usage

To tokenize Erlang code:

```elixir
code = "factorial(N) -> N * factorial(N-1)."

case Makeup.Lexers.ErlangLexer.root(code) do
  {:ok, tokens, _rest, _context, _position, _byte_offset} ->
    # Process tokens for highlighting
    Enum.each(tokens, fn {token_type, token_value} ->
      IO.inspect({token_type, token_value})
    end)
  {:error, reason} ->
    IO.inspect("Parsing error: #{reason}")
end
```

## Core Concepts

### Token Types

The Erlang lexer returns tokens in the format `{token_type, token_value}`, where token types include:

- `:keyword` — Erlang reserved words (e.g., `if`, `case`, `when`)
- `:atom` — Atoms and function names (e.g., `ok`, `factorial`)
- `:number` — Numeric literals (integers and floats)
- `:string` — String literals
- `:comment` — Comments starting with `%`
- `:operator` — Operators (`+`, `-`, `->`, etc.)
- `:punctuation` — Brackets, parentheses, commas

### Root-Level Parsing

The `Makeup.Lexers.ErlangLexer.root/2` function is the primary entry point for tokenizing complete Erlang code. It handles:

- Multi-line functions
- Module declarations
- Nested expressions
- Full context tracking

### Element-Level Parsing

For incremental or targeted parsing of small Erlang code fragments, use `root_element/2`. This is useful when:

- Parsing inline code samples
- Handling user-provided snippets
- Building incremental syntax checkers

## Configuration

### Common Options

Both `root/2` and `root_element/2` accept the following configuration options:

```elixir
options = [
  byte_offset: 0,           # Starting byte position (default: 0)
  line: {1, 0},            # Line number and offset tuple (default: {1, byte_offset})
  context: %{}             # Initial parsing context (default: empty map)
]

Makeup.Lexers.ErlangLexer.root(code, options)
```

### Position Tracking

Maintain accurate line and column information:

```elixir
code = "function(X) ->\n  X + 1."

# Start at line 2, column 0
Makeup.Lexers.ErlangLexer.root(code, line: {2, 0})
```

### Byte Offset Control

Set explicit starting positions for multi-file or streaming scenarios:

```elixir
# If parsing a fragment starting at byte 1024 in a larger document
Makeup.Lexers.ErlangLexer.root(fragment, byte_offset: 1024)
```

## Common Patterns

### Highlight Code in Phoenix Views

```elixir
defmodule MyApp.HighlightView do
  def highlight_erlang(code) do
    case Makeup.Lexers.ErlangLexer.root(code) do
      {:ok, tokens, _rest, _context, _position, _byte_offset} ->
        tokens
        |> Enum.map(fn {type, value} ->
          {type, HTML.escape(value)}
        end)
      {:error, _reason} ->
        [{:plain, code}]
    end
  end
end
```

### Streaming Multi-Line Code

```elixir
lines = ["module(test).", "function(X) ->", "  X + 1."]
byte_pos = 0

Enum.reduce(lines, [], fn line, acc_tokens ->
  {:ok, tokens, _rest, _ctx, _pos, _offset} =
    Makeup.Lexers.ErlangLexer.root(line, byte_offset: byte_pos)

  # Update byte_pos for next iteration
  byte_pos = byte_pos + byte_size(line) + 1  # +1 for newline

  acc_tokens ++ tokens
end)
```

### Error Handling with Position Reporting

```elixir
def tokenize_with_error_context(code) do
  case Makeup.Lexers.ErlangLexer.root(code) do
    {:ok, tokens, _rest, _context, _position, _byte_offset} ->
      {:ok, tokens}
    {:error, {line, col, msg}} ->
      {:error, "Syntax error at line #{line}, column #{col}: #{msg}"}
  end
end
```

## Best Practices

### 1. Cache Tokenized Output

Avoid re-tokenizing the same code multiple times. Cache results in a GenServer or ETS table if used frequently:

```elixir
defmodule CodeHighlighter do
  use GenServer

  def highlight(code_id, code) do
    GenServer.call(__MODULE__, {:highlight, code_id, code})
  end

  def handle_call({:highlight, code_id, code}, _from, cache) do
    case Map.fetch(cache, code_id) do
      {:ok, tokens} ->
        {:reply, tokens, cache}
      :error ->
        {:ok, tokens, _, _, _, _} = Makeup.Lexers.ErlangLexer.root(code)
        {:reply, tokens, Map.put(cache, code_id, tokens)}
    end
  end
end
```

### 2. Handle Partial/Invalid Code Gracefully

Real-world code snippets may be incomplete or syntactically invalid. Always handle errors:

```elixir
def safe_highlight(code) do
  case Makeup.Lexers.ErlangLexer.root(code) do
    {:ok, tokens, _rest, _context, _position, _byte_offset} ->
      {:ok, tokens}
    {:error, _} ->
      # Fallback: treat code as plain text
      [{:plain, code}]
  end
end
```

### 3. Reset Context Between Files

If parsing multiple independent Erlang files, reset the parsing context:

```elixir
parse_file = fn file_path ->
  code = File.read!(file_path)
  # Empty context for fresh parse
  Makeup.Lexers.ErlangLexer.root(code, context: %{})
end
```

### 4. Preserve Line and Column Information

For IDE-like features (jump to definition, error messages), always preserve position metadata:

```elixir
{:ok, tokens, _rest, _context, line_number, byte_offset} =
  Makeup.Lexers.ErlangLexer.root(code)

# Calculate column from byte_offset and line start
column = byte_offset - offset_to_line_start

IO.puts("Error at #{line_number}:#{column}")
```

## Limitations and Gotchas

### 1. Tokenization Only

makeup_erlang provides **lexical tokenization only**. It does not:

- Validate Erlang syntax semantically
- Type-check code
- Expand macros
- Resolve module references

### 2. Encoding Assumptions

The lexer assumes UTF-8 encoded input. Non-UTF-8 strings may produce unexpected results.

### 3. No Incremental Updates

Tokenize entire code blocks at once. The lexer does not support incremental token updates; re-tokenize on code changes.

### 4. Context Inheritance

Parsing context (line/column state) is **not** automatically inherited. Pass explicit options when parsing fragments:

```elixir
# Wrong: loses line/column tracking
Makeup.Lexers.ErlangLexer.root(fragment)

# Correct: maintains position
Makeup.Lexers.ErlangLexer.root(fragment, line: {10, 0}, byte_offset: 500)
```

## Version-Specific Notes

### v1.1.0

- Stable Erlang tokenization with full language support
- Performance optimized for large codebases
- Consistent token output format across all Erlang constructs
- Reliable position tracking for multi-line code

---

**Version:** 1.1.0  
**Source:** [hexdocs.pm/makeup_erlang](https://hexdocs.pm/makeup_erlang/1.1.0)  
**Generated:** 2026-06-17
