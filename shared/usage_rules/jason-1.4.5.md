# jason

Blazing fast JSON parser and generator in pure Elixir. Jason provides robust JSON encoding and decoding with extensive configuration options for handling keys, strings, floats, and pretty-printing.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:jason, "~> 1.4"}]
end
```

### Basic Encoding

```elixir
iex> Jason.encode!(%{"name" => "Alice", "age" => 30})
"{\"name\":\"Alice\",\"age\":30}"

iex> Jason.encode_to_iodata!([1, 2, 3])
["[", "1", ",", "2", ",", "3", "]"]
```

### Basic Decoding

```elixir
iex> Jason.decode!("{\"name\":\"Bob\",\"age\":25}")
%{"name" => "Bob", "age" => 25}

iex> Jason.decode("{\"invalid\"", keys: :atoms)
{:error, %Jason.DecodeError{position: 11, token: nil, reason: :unexpected_end_of_input}}
```

## Core Concepts

### Encoding

- **`encode/2`** — Returns `{:ok, string}` or `{:error, error}`
- **`encode!/2`** — Raises on error
- **`encode_to_iodata/2`** — Returns iodata (preferred for IO operations like file writes or HTTP responses)
- **`encode_to_iodata!/2`** — Iodata variant with exceptions

Iodata is more efficient than strings for direct I/O since it avoids intermediate binary concatenation.

### Decoding

- **`decode/2`** — Returns `{:ok, term}` or `{:error, error}`
- **`decode!/2`** — Raises on error

Both variants support options for controlling how keys, strings, floats, and objects are handled.

## Configuration

### Decode Options

**Keys:**

- `:strings` (default) — Parse keys as strings
- `:atoms` — Convert keys to atoms (⚠️ security risk with untrusted data; atoms are never garbage collected)
- `{:atom, :safe}` — Convert only existing atoms (prevents DoS)
- Custom function — Apply `fn key -> ... end` to transform keys

**Strings:**

- `:copy` (default) — Copy string data into new binaries
- `:reference` — Reference existing binary data (faster for large strings)

**Floats:**

- `:native` (default) — Use Elixir's native float parsing
- `{:decimal, mod}` — Parse floats as Decimal struct for precision (requires `:decimal` dependency)

**Objects:**

- `:maps` (default) — Decode as `%{...}` maps
- Custom module — Implement `Jason.Decoder` protocol for custom object types

```elixir
Jason.decode!("{\"x\":1.5}", floats: {:decimal, Decimal})
%{"x" => Decimal.new("1.5")}

Jason.decode!("{\"name\":\"alice\"}", keys: {:atom, :safe})
%{name: "alice"}
```

### Encode Options

**Escape modes:**

- `:json` (default) — Standard JSON escaping (handles newlines, quotes, etc.)
- `:javascript` — JavaScript-safe escaping (also escapes `/`)
- `:html` — HTML-safe escaping (escapes `<`, `>`, `&`)
- `:unicode` — Escapes non-ASCII characters

**Map handling:**

- `:maps` (default) — Fast, naive encoding (doesn't check duplicate keys)
- `:maps_strict` — Validates no duplicate keys; slower

**Pretty printing:**

- `:indent` — Spaces per indentation level (default `2`)
- `:spaces` — Spaces around colons/commas (default `0`)

```elixir
Jason.encode_to_iodata!(%{"name" => "Alice"}, pretty: true, indent: 2)
["{\n", "  ", "\"name\"", ":", " ", "\"Alice\"", "\n", "}"]

Jason.encode!(%{"script" => "<script>"}, escape: :html)
"{\"script\":\"\\u003cscript\\u003e\"}"
```

## Best Practices

**Use `encode_to_iodata` for I/O:** When writing to files, sockets, or HTTP responses, prefer `encode_to_iodata/2` over `encode/2` to avoid unnecessary string concatenation overhead.

**Avoid `:atoms` on untrusted data:** Never parse user-controlled JSON with `keys: :atoms`. Use `keys: {:atom, :safe}` to parse only existing atoms, or apply custom key transformation functions.

**Choose appropriate float handling:** For financial or scientific data requiring precision, use `{:decimal, Decimal}` option. For performance-critical applications, stick with native floats.

**Use reference mode for large strings:** When decoding large JSON payloads with many string values, `strings: :reference` avoids copying and improves memory efficiency (safe since JSON strings are immutable).

**Escape modes for context:** Use `:html` escape mode when embedding JSON in HTML templates, `:javascript` for inline JavaScript, and `:unicode` only when ASCII compatibility is required.

**Pretty-printing for development only:** Enable pretty-printing with `:pretty` option during development/debugging, but disable for production APIs to minimize payload size.

**Validate before casting keys:** When using custom key transformation functions, validate against a whitelist of acceptable keys to prevent injection attacks.

---

**Version:** 1.4.5
**Source:** [hexdocs.pm/jason](https://hexdocs.pm/jason/)
**Generated:** 2026-05-09
