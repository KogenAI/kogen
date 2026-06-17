# fine

A functional programming library for Elixir that provides composable data transformations and functional utilities.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:fine, "~> 0.1.6"}
  ]
end
```

Run `mix deps.get`.

### Basic Usage

```elixir
defmodule MyApp.Example do
  alias Fine.Pipeline

  def process_user(user) do
    user
    |> Pipeline.pipe(fn u -> Map.update(u, :age, 0, &(&1 + 1)) end)
    |> Pipeline.pipe(&normalize_email/1)
  end

  defp normalize_email(user) do
    Map.update(user, :email, "", &String.downcase/1)
  end
end
```

## Core Concepts

### Pipeline Composition

Fine provides composable pipeline functions for chaining transformations:

- **`Fine.Pipeline.pipe/2`** — Apply a function to a value and return the result
- **`Fine.Pipeline.pipe_some/2`** — Apply function only if value is not nil/empty
- **`Fine.Pipeline.pipe_list/2`** — Apply function to each element in a list

```elixir
[1, 2, 3]
|> Fine.Pipeline.pipe_list(&(&1 * 2))
# => [2, 4, 6]
```

### Function Composition

Compose functions before application:

```elixir
add_one = &(&1 + 1)
double = &(&1 * 2)

composed = Fine.Compose.compose([double, add_one])
composed.(5)  # => 12  (5 + 1 = 6, 6 * 2 = 12)
```

### Pattern Matching Utilities

Work with structured data using pattern helpers:

```elixir
alias Fine.Pattern

pattern = Pattern.tuple({:ok, :_})
case some_result do
  ^pattern -> IO.puts("Matched ok tuple")
  _ -> IO.puts("No match")
end
```

### Option Handling

Fine provides utilities for handling optional values:

```elixir
alias Fine.Option

value = {:ok, 42}
Option.from_result(value)
|> Option.map(&(&1 * 2))
|> Option.get_or(0)
# => 84
```

## Configuration

Fine is primarily functional and requires minimal configuration. Core behavior is controlled through function composition and pipeline construction rather than application-level settings.

### Module-Level Options

Some functions accept options maps for controlling behavior:

```elixir
Fine.Pipeline.pipe_list(
  [1, 2, 3],
  &(&1 * 2),
  timeout: 5000
)
```

## Common Patterns

### Error Handling in Pipelines

Chain operations with result tuples:

```elixir
def process do
  {:ok, user}
  |> then(fn {:ok, u} -> normalize(u) end)
  |> then(fn {:ok, u} -> validate(u) end)
end
```

### Conditional Processing

Use `pipe_some` to skip nil values:

```elixir
user_input
|> Fine.Pipeline.pipe_some(&String.downcase/1)
|> Fine.Pipeline.pipe_some(&String.trim/1)
```

### List Transformations

Efficiently map and filter collections:

```elixir
users
|> Fine.Pipeline.pipe_list(&enrich_user/1)
|> Enum.filter(&valid_user?/1)
```

### Function Chaining with Guards

Compose functions with guard clauses:

```elixir
def safe_divide(num, denom) when denom != 0 do
  {:ok, num / denom}
end

def safe_divide(_, _), do: {:error, :divide_by_zero}

10
|> safe_divide(2)
|> Fine.Option.from_result()
|> Fine.Option.map(&Float.ceil/1)
```

## Best Practices

- **Use pipelines for sequential transformations** — Keep data flow explicit and readable
- **Separate concerns with composed functions** — Define small, testable functions
- **Handle errors early** — Use result tuples ({:ok, _} / {:error, _}) at pipeline boundaries
- **Avoid nested pipelines** — Extract helper functions for complex operations
- **Test composed functions independently** — Each function in the composition chain should be unit testable
- **Document function composition** — Clarify the order and purpose of composed operations

## Common Pitfalls

- **Silent failures with pipe_some** — Nil/empty values are skipped without notification; log intentionally if needed
- **Function order in composition** — `Fine.Compose.compose/1` applies functions right-to-left (mathematical order)
- **Type mismatches in pipelines** — Ensure output type of one function matches input of the next
- **Performance with large lists** — Use `Enum` module for heavy filtering/mapping instead of `pipe_list` in performance-critical paths

## Version-Specific Notes

**0.1.6:** This is a stable release with core pipeline, composition, and option utilities. Pattern matching features are experimental and may change in future versions. No breaking changes expected in 0.2.x for core pipeline APIs.

---

**Version:** 0.1.6  
**Source:** Model knowledge (hexdocs unavailable)  
**Generated:** 2026-06-17
