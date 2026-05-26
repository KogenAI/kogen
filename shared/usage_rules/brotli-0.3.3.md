# brotli

Erlang/Elixir bindings for the Brotli compression library. Provides high-performance compression and decompression with a straightforward API.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [{:brotli, "~> 0.3.3"}]
end
```

Compile with:

```bash
mix deps.get
mix compile
```

### Basic Usage

Load the module and compress data:

```elixir
iex> data = File.read!("README.md")
iex> {:ok, compressed} = :brotli.encode(data)
{:ok, <<27, 26, 3, 0, ...>>}
```

Decompress data:

```elixir
iex> :brotli.decode(compressed)
{:ok, "original data..."}
```

## Core Concepts

### Main Functions

- **`encode/1`** — Compress data in one step. Returns `{:ok, compressed_binary}` or `:error`.
- **`encode/2`** — Compress with custom encoder options. Accepts `brotli_encoder:options()` for tuning.
- **`decode/1`** — Decompress Brotli-encoded data. Returns `{:ok, decompressed}` or `:error`.
- **`decode/2`** — Decompress with custom decoder options.
- **`max_compressed_size/1`** — Calculate maximum possible compressed size for input of given byte length.
- **`version/0`** — Returns the version tuple of the underlying Brotli C library (`{major, minor, patch}`).

### Return Values

All compression/decompression functions return tagged tuples:

```elixir
{:ok, result}   # Success
:error          # Failure (invalid data, etc.)
```

## Configuration

### Encoder Options

The `encode/2` function accepts `brotli_encoder:options()` for tuning compression. Common optimization parameters include:

- **Quality**: Trade-off between compression ratio and speed.
- **Window size**: Larger windows provide better compression but use more memory.
- **Mode**: Different compression strategies for different data types.

Pass options as a map or list to `encode/2`:

```elixir
:brotli.encode(data, %{quality: 11, lgwin: 22})
```

Check `brotli_encoder` module documentation for full option reference.

### Decoder Options

The `decode/2` function similarly accepts `brotli_decoder:options()` for custom decompression tuning.

## Best Practices

### Error Handling

Always pattern match on encode/decode results:

```elixir
case :brotli.encode(data) do
  {:ok, compressed} ->
    # Process compressed data
  :error ->
    # Handle compression failure
end
```

### Size Estimation

Use `max_compressed_size/1` before allocating buffers:

```elixir
original_size = byte_size(data)
max_size = :brotli.max_compressed_size(original_size)
# Plan buffer allocation accordingly
```

### Quality vs. Speed

- **Quality 4-6**: Fast compression, lower ratio (streaming, real-time).
- **Quality 8-10**: Balanced, good for most workloads.
- **Quality 11**: Maximum compression, slower (batch operations).

### Version Checking

Check the Brotli C library version at runtime if version-specific features matter:

```elixir
{major, minor, patch} = :brotli.version()
```

### Memory Efficiency

For large data streams, consider processing in chunks rather than compressing entire files at once. Larger window sizes (`lgwin`) improve compression but increase memory usage.

---

**Version:** 0.3.3  
**Source:** [hexdocs.pm/brotli](https://hexdocs.pm/brotli/)  
**Generated:** 2026-05-09
