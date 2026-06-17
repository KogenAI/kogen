# yaml_elixir

A lightweight YAML parser for Elixir that wraps the Erlang yamerl parser, enabling robust YAML parsing in Elixir applications.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [
    {:yaml_elixir, "~> 2.12"}
  ]
end
```

Run `mix deps.get`.

### Basic Usage

Parse YAML from a string:

```elixir
yaml = "name: John\nage: 30\nenabled: true"
{:ok, data} = YamlElixir.read_from_string(yaml)
# Returns: %{"name" => "John", "age" => 30, "enabled" => true}
```

Parse from a file:

```elixir
{:ok, config} = YamlElixir.read_from_file("config.yml")
```

## Core Concepts

### Two Main Entry Points

**`YamlElixir.read_from_string/2`**

- Parses YAML content from a string
- Returns `{:ok, term}` or `{:error, reason}`
- Accepts options as second argument

**`YamlElixir.read_from_file/2`**

- Parses YAML content from a file path
- Returns `{:ok, term}` or `{:error, reason}`
- Same options as string parsing

### Return Values

All parsing functions return tuples:

- Success: `{:ok, parsed_data}` where parsed_data is typically a map
- Error: `{:error, error_details}`

Always pattern match on both cases in production code:

```elixir
case YamlElixir.read_from_file("app.yml") do
  {:ok, config} -> use_config(config)
  {:error, reason} -> handle_error(reason)
end
```

## Configuration

### Common Options

**`:atoms`** - Convert string keys prefixed with `:` to Elixir atoms:

```elixir
yaml = "name: :app_name\nversion: :v1"
{:ok, data} = YamlElixir.read_from_string(yaml, atoms: true)
# %{name: :app_name, version: :v1}
```

⚠️ **Warning**: Use atoms carefully—they are never garbage collected. Avoid atoms from untrusted input.

**`:maps_as_keywords`** - Convert maps to keyword lists:

```elixir
{:ok, data} = YamlElixir.read_from_string(yaml, maps_as_keywords: true)
```

**`:merge_anchors`** - Resolve YAML anchors and aliases:

```elixir
yaml = """
defaults: &defaults
  timeout: 30
  retries: 3
production:
  <<: *defaults
  timeout: 60
"""
{:ok, data} = YamlElixir.read_from_string(yaml, merge_anchors: true)
# production map now includes defaults merged with overrides
```

### Default Behavior

Without options, yaml_elixir:

- Converts maps to standard Elixir maps
- Keeps string keys (no atom conversion)
- Parses basic YAML types: strings, numbers, booleans, null, lists, maps

## Sigil Support

Use the `~y` sigil for inline YAML:

```elixir
config = ~y"""
database:
  host: localhost
  port: 5432
"""
# Returns parsed map directly (not a tuple)
```

With the `a` modifier for atoms:

```elixir
config = ~y"""
mode: :development
debug: true
"""a
# Keys and values prefixed with : become atoms
```

Note: The sigil returns the parsed data directly, not a `{:ok, data}` tuple.

## Best Practices

### 1. Always Handle Errors

```elixir
def load_config(path) do
  case YamlElixir.read_from_file(path) do
    {:ok, config} -> {:ok, validate_config(config)}
    {:error, reason} -> {:error, "Config load failed: #{inspect(reason)}"}
  end
end
```

### 2. Validate After Parsing

YAML doesn't enforce schema. Validate the structure:

```elixir
def parse_config(path) do
  with {:ok, raw} <- YamlElixir.read_from_file(path),
       :ok <- validate_required_keys(raw, ~w[database server]),
       :ok <- validate_types(raw) do
    {:ok, raw}
  else
    error -> {:error, error}
  end
end
```

### 3. Avoid Atoms from Untrusted Sources

Never use `atoms: true` on user-supplied YAML:

```elixir
# ❌ UNSAFE - untrusted input
{:ok, data} = YamlElixir.read_from_string(user_input, atoms: true)

# ✅ SAFE - keep as strings
{:ok, data} = YamlElixir.read_from_string(user_input)
```

### 4. Use Merge Anchors for Config Inheritance

```yaml
# config.yml
defaults: &defaults
  log_level: info
  timeout: 30

development:
  <<: *defaults
  debug: true

production:
  <<: *defaults
  log_level: warn
  timeout: 60
```

### 5. Type Conversions

- YAML `null` → `nil`
- YAML `true`/`false` → `true`/`false`
- YAML numbers → integers or floats
- YAML quoted strings → strings
- YAML unquoted values → inferred types

### 6. Handle Large Files

For large YAML files, parsing may take time. Consider:

```elixir
def load_config_async(path) do
  Task.async(fn ->
    YamlElixir.read_from_file(path)
  end)
  |> Task.await(timeout_ms)
end
```

## Common Pitfalls

**Unexpected Type Conversions**

- `123` becomes integer 123, not string "123"
- `yes`/`no` are not standard YAML booleans (use `true`/`false`)
- `1.0e2` becomes float 100.0

**Indentation Issues**

- YAML is indentation-sensitive; use consistent spaces (not tabs)
- Misaligned content silently fails to parse or parses incorrectly

**Keys Becoming Atoms Unexpectedly**

- Without `atoms: true`, `:key` remains string `:key`, not atom `:key`
- This can cause unexpected map access patterns

**Merge Not Working**

- YAML anchors/aliases need `merge_anchors: true` to be processed
- Default behavior preserves raw anchor syntax without merging

---

**Version:** 2.12.2  
**Source:** [hexdocs.pm/yaml_elixir](https://hexdocs.pm/yaml_elixir)  
**Generated:** 2026-06-17
