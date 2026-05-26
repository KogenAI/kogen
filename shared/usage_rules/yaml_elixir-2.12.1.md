# yaml_elixir

A native Erlang YAML parser wrapped for Elixir, providing full YAML parsing and generation capabilities through the yamerl library.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:yaml_elixir, "~> 2.12"}
```

Run `mix deps.get`.

### Basic Parsing

```elixir
yaml = """
a: a
b: 1
c: true
d: ~
e: nil
"""
YamlElixir.read_from_string(yaml)
# {:ok, %{"a" => "a", "b" => 1, "c" => true, "d" => nil, "e" => "nil"}}
```

### File Parsing

```elixir
YamlElixir.read_from_file("config.yml")
# {:ok, %{...}}

YamlElixir.read_from_file!("config.yml")
# %{...} or raises YamlElixir.FileNotFoundError
```

## Core Concepts

### Function Variants

- `read_from_file(path, opts)` — returns `{:ok, data}` or `{:error, reason}`
- `read_from_file!(path, opts)` — returns data or raises exception
- `read_from_string(string, opts)` — parses YAML string
- `read_all_from_file(path, opts)` — reads multiple YAML documents
- `read_all_from_string(string, opts)` — parses multiple documents

### Type Conversion

- `null`, `~`, or `nil` → `nil`
- Boolean `true`/`false` preserved
- Numbers parsed as integers or floats
- Strings preserved as-is
- Nested structures become nested maps/lists

### Atom Keys and Values

```elixir
YamlElixir.read_from_string("key: value", atoms: true)
# {:ok, %{key: "value"}}
```

**⚠️ Warning**: Atoms are not garbage collected. Never use `atoms: true` with untrusted or dynamic input.

### Keyword Lists

Convert maps to keyword lists:

```elixir
YamlElixir.read_from_string(yaml, maps_as_keywords: true)
# {:ok, [key: "value"]}
```

### Anchors and Aliases

```yaml
default: &defaults
  timeout: 30
  retries: 3

prod:
  <<: *defaults
  debug: false
```

Enable anchor resolution:

```elixir
YamlElixir.read_from_string(yaml, merge_anchors: true)
# {:ok, %{"prod" => %{"timeout" => 30, "retries" => 3, "debug" => false}}}
```

### Sigil Support

```elixir
alias YamlElixir.Sigil

~y"""
name: example
count: 42
"""a  # 'a' modifier enables atoms

# {:ok, %{name: "example", count: 42}}
```

## Configuration

### Available Options

- `atoms: boolean` — parse keys/values starting with `:` as atoms (default: false)
- `maps_as_keywords: boolean` — return keyword lists instead of maps (default: false)
- `merge_anchors: boolean` — resolve YAML anchors and aliases (default: false)

### Multiple Documents

```elixir
yaml = """
---
doc: 1
---
doc: 2
"""

YamlElixir.read_all_from_string(yaml)
# {:ok, [%{"doc" => 1}, %{"doc" => 2}]}
```

## Best Practices

1. **Handle Errors Properly**

   ```elixir
   case YamlElixir.read_from_file(path) do
     {:ok, data} -> process(data)
     {:error, error} -> Logger.error("YAML parse error: #{inspect(error)}")
   end
   ```

2. **Atom Safety** — Use atoms only with trusted configuration files, never user input or dynamic sources.

3. **Mix Tasks** — Ensure application is started:

   ```elixir
   Application.ensure_all_started(:yaml_elixir)
   ```

4. **Flow Style Limitation** — Flow syntax (inline maps/lists with `{}` or `[]`) doesn't work with keyword list tags.

5. **Large Files** — `read_all_from_file/2` loads entire file into memory; use streaming approaches for very large YAML documents.

---

**Version:** 2.12.1
**Source:** [hexdocs.pm/yaml_elixir](https://hexdocs.pm/yaml_elixir/)
**License:** MIT
**Generated:** 2026-05-09
