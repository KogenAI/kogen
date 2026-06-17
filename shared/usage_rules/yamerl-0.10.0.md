# yamerl

Yamerl is a pure Erlang YAML and JSON parser with no external dependencies. It supports YAML 1.1, YAML 1.2, and JSON documents, offering both simplicity and stability through its Erlang implementation.

## Quick Start

### Installation

Add to your `rebar.config`:

```erlang
{deps, [
  {yamerl, "0.10.0"}
]}.
```

Or in your Elixir `mix.exs`:

```elixir
defp deps do
  [
    {:yamerl, "~> 0.10.0"}
  ]
end
```

### Basic Usage

Start the application:

```erlang
application:start(yamerl).
```

Parse a YAML string:

```erlang
Documents = yamerl_constr:string("key: value").
```

Parse from a file:

```erlang
Documents = yamerl_constr:file("config.yaml").
```

Parse from Elixir:

```elixir
:yamerl_constr.string("key: value")
```

## Core Concepts

### Parser Architecture

Yamerl consists of four main modules:

- **yamerl** - High-level wrapper functions (`decode/1-2`, `decode_file/1-2`)
- **yamerl_constr** - Core constructor with string/file/streaming parsing
- **yamerl_parser** - Low-level YAML parsing engine
- **yamerl_yamler_compat** - Compatibility layer for migration from yamler library

### Output Modes

#### Simple Mode (Default)

Returns plain Erlang/Elixir native types. Recommended for most use cases:

```erlang
yamerl_constr:string("key: value").
% Returns: [#{<<"key">> => <<"value">>}]
```

Maps use binary keys by default. The result is always a list, even for single documents.

#### Detailed Mode

Returns records with metadata (line numbers, columns, original presentation):

```erlang
yamerl_constr:string("key: value", [{detailed_constr, true}]).
% Returns: [{yamerl_node_map, ..., Metadata, [Key, Value]}]
```

Access metadata using:

- `yamerl_constr:node_line/1` - Line number
- `yamerl_constr:node_column/1` - Column number
- `yamerl_constr:get_pres_details/1` - Presentation info

### Supported YAML Schemas

Control YAML version and type resolution with the `schema` option:

| Schema     | Description                                     |
| ---------- | ----------------------------------------------- |
| `failsafe` | Only strings, sequences, and mappings           |
| `json`     | JSON compatibility (no YAML 1.1 booleans/nulls) |
| `core`     | YAML 1.1 core types (default)                   |
| `yaml11`   | Full YAML 1.1 support                           |

```erlang
yamerl_constr:string(Content, [{schema, yaml11}]).
```

### Stream Processing

Parse large files or continuous data streams:

```erlang
% Initialize state
{ok, State} = yamerl_constr:new([{detailed_constr, false}]),

% Feed chunks
{ok, NextState} = yamerl_constr:next_chunk(State, DataChunk),

% Finalize
{ok, Documents} = yamerl_constr:last_chunk(NextState).
```

## Configuration

### Parser Options

All parsing functions accept a second argument with options list:

```erlang
yamerl_constr:string(Content, Options)
```

#### Key Options

| Option                             | Type    | Default | Purpose                                     |
| ---------------------------------- | ------- | ------- | ------------------------------------------- |
| `{detailed_constr, Bool}`          | boolean | false   | Return detailed records with metadata       |
| `{schema, Schema}`                 | atom    | core    | YAML schema (failsafe, json, core, yaml11)  |
| `{ignore_unrecognized_tags, Bool}` | boolean | false   | Ignore unknown YAML tags instead of failing |
| `{keep_duplicate_keys, Bool}`      | boolean | false   | Preserve duplicate keys in maps             |
| `{node_mods, Modules}`             | list    | []      | Custom node type modules                    |

### Node Modules

Register custom node type processors:

```erlang
yamerl_constr:string(Content, [{node_mods, [my_node_mod]}]).
```

Custom modules handle conversion of YAML nodes to Erlang types.

### Encoding Detection

File parsing automatically detects and handles:

- UTF-8, UTF-16 (LE/BE), UTF-32 (LE/BE)
- BOM (Byte Order Mark) detection
- Defaults to UTF-8 if no BOM present

## Error Handling

### Exception Handling

Yamerl throws exceptions on parse errors. Catch using the `yamerl_exception` record:

```erlang
try
  yamerl_constr:string(Content)
catch
  throw(#yamerl_exception{type = Type, text = Text}) ->
    io:format("Error (~p): ~s~n", [Type, Text])
end.
```

The `yamerl_exception` record contains:

- `type` - `error` or `warning`
- `text` - Human-readable error message (binary)
- Additional diagnostic fields

### Common Errors

- **Syntax errors** - Invalid YAML structure
- **Unrecognized tags** - Unknown YAML tag types (use `{ignore_unrecognized_tags, true}` to ignore)
- **Duplicate keys** - By default, last value wins (use `{keep_duplicate_keys, true}` to preserve)
- **Encoding errors** - Invalid UTF-8/UTF-16/UTF-32

## Best Practices

### 1. Always Handle Exceptions

```erlang
safely_parse(Content) ->
  try
    yamerl_constr:string(Content)
  catch
    throw(#yamerl_exception{text = Error}) ->
      {error, Error}
  end.
```

### 2. Expect List Results

Yamerl always returns a list of documents, even for single documents:

```erlang
% Returns [Data], not Data
[Data] = yamerl_constr:string("key: value").
```

### 3. Choose Appropriate Schema

- **core** (default) - Most compatible YAML 1.1 behavior
- **json** - If parsing JSON documents
- **yaml11** - Full YAML 1.1 support (slower)
- **failsafe** - Minimal parsing (fastest)

### 4. Use Detailed Mode Sparingly

Detailed mode with metadata has higher overhead. Use only if you need line/column information for error reporting.

### 5. Stream Processing for Large Files

For multi-megabyte YAML files, prefer streaming to avoid loading entire content into memory:

```erlang
{ok, State} = yamerl_constr:new(Options),
{ok, NewState} = process_chunks(State, InputFile),
{ok, Documents} = yamerl_constr:last_chunk(NewState).
```

### 6. Understand Type Conversions

Default core schema type handling:

- `true`/`false` → atoms
- `null` → atom `null` or empty string (schema-dependent)
- Numbers → integers or floats (auto-detected)
- Strings → binary strings (UTF-8)
- Sequences → lists
- Mappings → maps (Erlang R17+)

### 7. Validate Binary Keys

Maps use binary keys by default. When accessing:

```erlang
#{<<"key">> => Value} = Document.
```

Not:

```erlang
#{key => Value} = Document.  % Won't match
```

### 8. Avoid Re-parsing

Cache parsed YAML in application state rather than re-parsing on every request.

## Trade-offs

### Advantages

- **Pure Erlang** - No native dependencies, stable across platforms
- **YAML 1.2 support** - More modern than some alternatives
- **No external deps** - Minimal complexity and attack surface
- **Well-tested** - Mature library in production use

### Limitations

- **Performance** - Slower than NIF-based parsers (e.g., yaml-cpp wrappers)
- **Schema customization** - Limited flexibility for non-standard YAML extensions
- **No serialization** - Parse-only; cannot dump Erlang terms to YAML
- **Memory overhead** - Detailed mode with metadata increases memory usage

## Common Patterns

### Configuration File Loading

```erlang
load_config(Path) ->
  try
    [Config] = yamerl_constr:file(Path),
    {ok, Config}
  catch
    throw(#yamerl_exception{text = Error}) ->
      {error, iolist_to_binary(Error)}
  end.
```

### Merge Multiple Documents

```erlang
parse_all_docs(Content) ->
  try
    Documents = yamerl_constr:string(Content),
    {ok, Documents}
  catch
    throw(#yamerl_exception{text = Error}) ->
      {error, Error}
  end.
```

### Silent Fallback on Error

```erlang
safe_parse(Content, Default) ->
  try
    [Data] = yamerl_constr:string(Content),
    Data
  catch
    throw(_) ->
      Default
  end.
```

---

**Version:** 0.10.0  
**Source:** [hexdocs.pm/yamerl](https://hexdocs.pm/yamerl/0.10.0)  
**Generated:** 2026-06-17
