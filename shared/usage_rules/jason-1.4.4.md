# jason

**A blazing fast JSON parser and generator in pure Elixir.** Jason provides efficient encoding and decoding of JSON data with flexible configuration options for different use cases and performance requirements.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
def deps do
  [
    {:jason, "~> 1.4"}
  ]
end
```

### Basic Usage

```elixir
# Decoding JSON strings
{:ok, data} = Jason.decode("{\"name\": \"Alice\", \"age\": 30}")
# => {:ok, %{"name" => "Alice", "age" => 30}}

# Decoding with atom keys
{:ok, data} = Jason.decode(json_string, keys: :atoms)
# => {:ok, %{name: "Alice", age: 30}}

# Encoding Elixir terms to JSON
Jason.encode!(%{"name" => "Alice", "age" => 30})
# => "{\"name\":\"Alice\",\"age\":30}"

# Encoding to iodata (preferred for I/O)
Jason.encode_to_iodata!(%{"name" => "Alice"})
# => ["{\"name\":\"Alice\"}"]
```

## Core Concepts

### Decoding (JSON → Elixir)

**Basic decoding** returns `{:ok, term}` tuple:

- `Jason.decode/2` - Returns `{:ok, data}` or `{:error, reason}`
- `Jason.decode!/2` - Raises exception on error

**Key mapping options** (`:keys` parameter):

- Default: `:string` - Object keys as strings `%{"key" => value}`
- `:atoms` - Keys as atoms `%{key: value}` (⚠️ see security note below)
- Custom function - Process keys with function `keys: &String.to_atom/1`

**String handling** (`:strings` parameter):

- `:reference` (default) - Strings reference input, faster for large data
- `:copy` - Copies strings to separate memory, safer for retained data

**Numeric precision** (`:floats` parameter):

- Default: `true` - Use native Elixir floats
- `:floats` → `false` - Use `Decimal` type for arbitrary precision

**Object types** (`:objects` parameter):

- Default: `:maps` - Standard Elixir maps
- Custom decoders available via libraries

### Encoding (Elixir → JSON)

**Basic encoding** returns JSON string:

- `Jason.encode/2` - Returns `{:ok, json_string}`
- `Jason.encode!/2` - Raises exception on error
- `Jason.encode_to_iodata/2` - Returns iodata (preferred for I/O)

**Escape strategies** (`:escape` parameter):

- `:json` (default) - Standard JSON escaping
- `:javascript` - JavaScript-safe escaping (e.g., `</` becomes `<\/`)
- `:html` - HTML-safe escaping
- `:unicode` - Escape all non-ASCII characters

**Duplicate key handling** (`:maps` parameter):

- `:strict` - Raise error on duplicate keys
- `:naive` (default) - Last value wins

**Pretty printing** (`:pretty` parameter):

- `true` - Human-readable output with indentation
- `false` (default) - Compact single-line output

## Configuration

### Decode Options Example

```elixir
# Decode with atom keys and Decimal precision
Jason.decode!(json,
  keys: :atoms,
  floats: false
)

# Decode with custom key mapping
Jason.decode!(json,
  keys: &my_key_transform/1
)
```

### Encode Options Example

```elixir
# Pretty-print JSON with HTML escaping
Jason.encode!(%{data: "value"},
  pretty: true,
  escape: :html
)

# Encode to iodata for efficient I/O
Jason.encode_to_iodata!(%{name: "Alice"})
|> IO.write()
```

## Best Practices

### Security

⚠️ **CRITICAL**: Never use `:atoms` option with untrusted data. Atoms created at runtime are never garbage collected in Erlang, enabling denial-of-service attacks. Only use `:atoms` with trusted, internal JSON.

```elixir
# ✅ Safe: Trusted internal data
Jason.decode!(internal_config, keys: :atoms)

# ❌ Unsafe: Untrusted user input
Jason.decode!(user_json, keys: :atoms)
```

### Performance

- **Prefer `encode_to_iodata/2`** over `encode/2` when writing JSON to I/O (files, sockets, HTTP responses). Avoids intermediate string allocation.

```elixir
# ✅ Better - iodata goes directly to socket/file
Jason.encode_to_iodata!(data) |> my_socket.send()

# Acceptable - for return values or when string is needed
Jason.encode!(data)
```

- **Use `:strings` option carefully**: Default `:reference` is faster but only safe for short-lived data. Use `:copy` if JSON string outlives input processing.

### Error Handling

Handle both decode and encode errors explicitly:

```elixir
case Jason.decode(input) do
  {:ok, data} -> process(data)
  {:error, %Jason.DecodeError{position: pos, token: token}} ->
    Logger.error("JSON error at position #{pos}: #{inspect(token)}")
end

case Jason.encode(data) do
  {:ok, json} -> send_response(json)
  {:error, reason} -> Logger.error("Encoding failed: #{inspect(reason)}")
end
```

### Streaming and Large Files

For large JSON files, avoid loading entire content:

```elixir
# Process JSON streaming with Jalaali or JSON parser combinators
File.stream!("large.json")
|> Stream.map(&Jason.decode!/1)
|> Stream.each(&process_record/1)
|> Stream.run()
```

### Type Mapping

Understand Elixir-JSON type correspondence:

| JSON             | Elixir (decode)              | Elixir (encode)     |
| ---------------- | ---------------------------- | ------------------- |
| `null`           | `nil`                        | `nil`               |
| `true` / `false` | `true` / `false`             | `true` / `false`    |
| Numbers          | Float or Decimal             | Numbers (float/int) |
| `"string"`       | String                       | String              |
| `[...]`          | List                         | List                |
| `{...}`          | Map (keys option determines) | Map                 |

---

**Version:** 1.4.4
**Source:** [hexdocs.pm/jason](https://hexdocs.pm/jason/)
**Generated:** 2025-10-28
