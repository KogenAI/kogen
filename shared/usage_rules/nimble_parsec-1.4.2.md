# nimble_parsec

NimbleParsec is a lightweight, performant parser combinator library for Elixir that compiles parsers directly into efficient binary-matching code. Unlike traditional parser combinators that interpret at runtime, NimbleParsec generates optimized Elixir clauses, producing zero-dependency parsers suitable for library distribution.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:nimble_parsec, "~> 1.4"}
  ]
end
```

### Basic Parser

```elixir
defmodule DateParser do
  import NimbleParsec

  # Define a simple date parser: YYYY-MM-DD
  defparsec :date,
    integer(4)
    |> ignore(string("-"))
    |> integer(2)
    |> ignore(string("-"))
    |> integer(2)
end

# Usage
DateParser.date("2024-06-17")
# => {:ok, [2024, 6, 17], "", %{}, {1, 0}, 10}
```

## Core Concepts

### Parser Combinators

Parsers are composed using combinator functions that build a pipeline:

- **`string(s)`** - Match a literal string
- **`integer(n)`** - Parse n-digit integer
- **`float()`** - Parse floating point number
- **`char(c)`** or **`ascii_char()`** - Match single character
- **`repeat(parser)`** - Match zero or more occurrences
- **`times(parser, n)`** - Match exactly n occurrences
- **`optional(parser)`** - Match zero or one occurrence
- **`choice([p1, p2, ...])`** - Try alternatives in order
- **`lookahead(parser)`** - Assert without consuming
- **`ignore(parser)`** - Match but discard from results

### Parser Definition Macros

- **`defparsec/2` or `defparsec/3`** - Define a public parser function that compiles to optimized code
- **`defparsecp/2` or `defparsecp/3`** - Define a private parser function
- **`defcombinatorp/2`** - Define a reusable combinator (does not compile; returns a parser value)

```elixir
defcombinatorp :digit, ascii_char([?0..?9])

defparsec :integer_literal,
  digit |> repeat(digit) |> map({String, :to_integer, [[]]})
```

### Return Value

Successful parsers return:

```elixir
{:ok, results, remaining_input, metadata, {line, col}, byte_offset}
```

Failed parsers return:

```elixir
{:error, reason, rest, context, {line, col}, byte_offset}
```

## Configuration

### Handling Whitespace

Use `ignore()` to skip whitespace or delimiters:

```elixir
defparsec :csv_entry,
  string(~S(")) |> string("\r\n")
```

### Named Results and Labels

Add descriptive error messages:

```elixir
defparsec :email,
  string("user") |> string("@") |> string("domain.com")
  |> label("valid email format")
```

### Recursive Parsers

Use `parsec()` to call other parsers (enables recursion without infinite compilation):

```elixir
defcombinatorp :expression,
  choice([
    integer(1..9),
    parsec(:term)
  ])

defparsec :term,
  string("(") |> parsec(:expression) |> string(")")
```

### Post-Processing with `map()`

Transform parsed results:

```elixir
defparsec :number,
  integer(1..9)
  |> map({String, :to_integer, []})
```

## Best Practices

### 1. Organize Large Parsers

For complex grammars, use helper modules:

```elixir
defmodule Lexer.Keywords do
  import NimbleParsec

  def keyword, do: choice([string("if"), string("then"), string("else")])
end

defmodule Parser do
  import NimbleParsec
  alias Lexer.Keywords

  defparsec :statement,
    Keywords.keyword() |> string(" ") |> parsec(:expression)
end
```

### 2. Manage Compilation Time

Large parsers increase compilation time. Mitigate with:

- Use `defcombinatorp` for reusable sub-parsers instead of inlining
- Split grammar into multiple modules
- Reference sub-parsers via `parsec()` calls
- Avoid deeply nested `choice([...])` with many alternatives

### 3. Effective Error Messages

Label critical parsing points for better debugging:

```elixir
defparsec :quoted_string,
  ignore(string("\""))
  |> repeat(
    choice([
      ~S(\") |> ignore(string("\"")),
      utf8_char([])
    ])
  )
  |> label("quoted string")
  |> ignore(string("\""))
```

### 4. Binary-Safe Parsing

NimbleParsec works with UTF-8 and binary data:

```elixir
defparsec :utf8_word,
  repeat(utf8_char(not: [?\s, ?\n]))
  |> ignore(string(" "))
```

### 5. Avoid Common Pitfalls

- **Greedy consumption**: `repeat()` is greedy; use `optional()` with `choice()` for non-greedy patterns
- **Left recursion**: Not directly supported; refactor with `repeat()` or `times()`
- **Performance**: Prefer specific character ranges (`ascii_char([?a..?z])`) over generic `utf8_char()`
- **No side effects**: Parsers are pure functions; store results and process separately

### 6. Testing Parsers

Test for success and failure cases:

```elixir
test "parses valid date" do
  assert {:ok, [2024, 6, 17], "", _, _, _} = DateParser.date("2024-06-17")
end

test "rejects invalid date" do
  assert {:error, _, _, _, _, _} = DateParser.date("2024-13-01")
end
```

## Advanced Patterns

### Stateful Parsing with Context

While parsers are pure, you can extract context information:

```elixir
defparsec :variable,
  ascii_char([?a..?z]) |> repeat(ascii_char([?a..?z0..?9]))
  |> traverse({Parser, :validate_var, []})
```

### Combining with Other Libraries

NimbleParsec works well with transformation libraries:

```elixir
defparsec :json_number,
  optional(string("-")) |> repeat(ascii_char([?0..?9]))
  |> map({String, :to_integer, []})
```

### Handling Whitespace Flexibly

```elixir
defcombinatorp :space, repeat(ascii_char([?\s, ?\t, ?\n, ?\r]))

defparsec :expression,
  parsec(:term)
  |> parsec(:space)
  |> string("+")
  |> parsec(:space)
  |> parsec(:term)
```

---

**Version:** 1.4.2  
**Source:** [hexdocs.pm/nimble_parsec](https://hexdocs.pm/nimble_parsec)  
**Generated:** 2026-06-17
