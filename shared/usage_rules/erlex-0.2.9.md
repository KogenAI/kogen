# erlex

Erlex is an Elixir library for parsing and generating Erlang error descriptions. It converts Erlang error terms into human-readable error messages and vice versa, making it useful for debugging, logging, and error handling in Elixir applications that interact with Erlang code.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:erlex, "~> 0.2.9"}
  ]
end
```

Run `mix deps.get`.

### Basic Usage

The core API provides two main functions for error parsing:

```elixir
# Parse an Erlang error term and get a readable description
iex> Erlex.parse_error({:error, :enoent})
"No such file or directory"

iex> Erlex.parse_error({:badarg})
"Bad argument"

iex> Erlex.parse_error({:function_clause})
"Function clause not matched"
```

## Core Concepts

### Error Parsing

Erlex converts Erlang error tuples into descriptive strings. This is particularly useful when working with NIFs, port processes, or Erlang libraries that return error terms.

**Common error tuples:**

```elixir
# File system errors
{:error, :enoent}      # No such file or directory
{:error, :eacces}      # Permission denied
{:error, :eisdir}      # Is a directory

# Function errors
:badarg                # Bad argument
:function_clause       # Pattern match failed
:undef                 # Function undefined

# Process errors
:noproc                # No such process
:already_started       # Process already started
```

### Module Structure

**`Erlex`** - Main module providing the primary API

- `parse_error/1` - Convert an Erlang error term to a string description
- `format_error/1` - Format error for output (alias for parse_error)

## Configuration

Erlex requires no configuration. It works out of the box after being added as a dependency.

## Best Practices

### Error Handling Integration

Use Erlex in error handlers to provide meaningful messages to users:

```elixir
def open_file(path) do
  case File.read(path) do
    {:ok, content} -> {:ok, content}
    {:error, reason} ->
      {:error, Erlex.parse_error({:error, reason})}
  end
end
```

### NIF Error Handling

When calling NIFs that return Erlang error atoms, parse them for logging:

```elixir
def call_nif do
  case MyNif.do_work() do
    :ok -> :ok
    error ->
      Logger.error("NIF failed: #{Erlex.parse_error(error)}")
      {:error, error}
  end
end
```

### Comprehensive Error Messages

Combine with context information for better debugging:

```elixir
def handle_error(error, context) do
  description = Erlex.parse_error(error)
  "Operation failed in #{context}: #{description}"
end
```

### Testing Error Paths

Use Erlex to verify error messages in tests:

```elixir
test "file not found error" do
  error = {:error, :enoent}
  assert Erlex.parse_error(error) == "No such file or directory"
end
```

## Common Pitfalls

### Non-standard Error Terms

Erlex handles standard Erlang errors. Custom error terms may return generic descriptions:

```elixir
# Standard errors - works well
Erlex.parse_error({:error, :enoent})

# Custom errors - may not produce meaningful output
Erlex.parse_error({:custom_error, :reason})
```

### Error Tuple Variations

Different error formats require different parsing:

```elixir
# Single atom
Erlex.parse_error(:badarg)

# Two-element tuple
Erlex.parse_error({:error, :enoent})

# Ensure consistent format before parsing
```

## Version Notes

**0.2.9** is an early version of erlex. The API is stable for basic error parsing, but future versions may expand the error dictionary and add new parsing features. Pin the version if your application depends on specific error message formatting.

---

**Version:** 0.2.9  
**Source:** https://github.com/asdf-vm/erlex  
**Generated:** 2026-06-17
