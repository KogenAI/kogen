# mime

A lightweight Elixir library for mapping MIME types to file extensions and vice versa. The `MIME` module provides utilities for working with standard and custom MIME type definitions, commonly used in web applications, file uploads, and content handling.

## Quick Start

### Installation

Add `:mime` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:mime, "~> 2.0"}
  ]
end
```

Then run `mix deps.get`.

### Basic Usage

```elixir
# Get MIME type from extension
MIME.type("html")          # => "text/html"
MIME.type("jpg")           # => "image/jpeg"
MIME.type("unknown_ext")   # => "application/octet-stream"

# Get MIME type from file path
MIME.from_path("index.html")       # => "text/html"
MIME.from_path("document.pdf")     # => "application/pdf"

# Get extensions for a MIME type
MIME.extensions("text/html")       # => ["html", "htm"]
MIME.extensions("image/jpeg")      # => ["jpeg", "jpg", "jpe"]

# Check if extension has a known MIME type
MIME.has_type?("html")             # => true
MIME.has_type?("unknown")          # => false
```

## Core Concepts

### Standard MIME Type Lookup

The library ships with a comprehensive database of standard MIME types mapped to file extensions. The most common lookups are:

- **By extension**: `MIME.type(ext)` returns the MIME type string
- **By file path**: `MIME.from_path(path)` extracts extension and returns MIME type
- **Reverse lookup**: `MIME.extensions(mime_type)` returns list of extensions

### Default Behavior

Extensions without registered MIME types default to `"application/octet-stream"`, the standard fallback for binary data.

### Multiple Extensions per MIME Type

Some MIME types have multiple extensions:

```elixir
MIME.extensions("text/plain")  # => ["txt", "asc", "pot", ...]
MIME.extensions("audio/mpeg")  # => ["mp3", "m4a"]
```

## Configuration

### Adding Custom MIME Types

Define custom MIME types in your `config/config.exs`:

```elixir
config :mime, :types, %{
  "application/custom" => ["custom", "cst"],
  "text/myformat" => ["myfmt"]
}
```

Then compile custom types into the module:

```elixir
# In config/config.exs
config :mime, :custom_types, %{
  "application/custom" => ["custom", "cst"]
}
```

**Note on Elixir < 1.15**: Older Elixir versions may require recompilation after adding custom types. Elixir 1.15+ supports dynamic recompilation via the compiler.

### Suffix Mappings

Configure file suffix mappings (e.g., `.gz`, `.br`) via application config if you need custom handling:

```elixir
config :mime, :suffixes, %{
  "gzip" => "gz",
  "brotli" => "br"
}
```

## Best Practices

### 1. Use from_path/1 for File Operations

When handling file uploads or serving files, prefer `from_path/1` over manually extracting extensions:

```elixir
# Good
{:ok, file} = File.read("document.pdf")
mime = MIME.from_path("document.pdf")

# Avoid: manual extension extraction
ext = Path.extname(path) |> String.trim_leading(".")
mime = MIME.type(ext)
```

### 2. Always Handle Unknown Extensions

The default `"application/octet-stream"` is safe, but validate MIME types in security-critical contexts:

```elixir
def serve_file(path) do
  mime = MIME.from_path(path)
  if mime == "application/octet-stream" do
    Logger.warn("Unknown MIME type for #{path}")
  end
  set_content_type(mime)
end
```

### 3. Preload Known Types in Tests

For comprehensive testing, use `MIME.known_types/0`:

```elixir
test "all known types have extensions" do
  known = MIME.known_types()
  assert map_size(known) > 500  # Sanity check
  Enum.each(known, fn {mime_type, exts} ->
    assert is_list(exts) and length(exts) > 0
  end)
end
```

### 4. Cache Common MIME Types

For high-performance scenarios, cache frequently used types:

```elixir
@common_types %{
  "html" => "text/html",
  "json" => "application/json",
  "pdf" => "application/pdf"
}

def get_mime(ext) do
  Map.get(@common_types, ext) || MIME.type(ext)
end
```

### 5. Normalize Extensions Before Lookup

Extensions are case-sensitive; normalize input:

```elixir
def mime_from_file(filename) do
  ext = filename
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()

  MIME.type(ext)
end
```

## Common Patterns

### Web Request Content-Type Header

```elixir
def send_file(conn, file_path) do
  mime = MIME.from_path(file_path)
  conn
    |> put_resp_header("content-type", mime)
    |> send_file(200, file_path)
end
```

### File Upload Validation

```elixir
def validate_upload(file_path, allowed_types) do
  mime = MIME.from_path(file_path)
  if Enum.member?(allowed_types, mime) do
    :ok
  else
    {:error, "MIME type #{mime} not allowed"}
  end
end
```

### Reverse Extension Lookup

```elixir
def suggest_extension(mime_type) do
  case MIME.extensions(mime_type) do
    [first | _] -> first
    [] -> nil
  end
end
```

## Common Pitfalls

### 1. Case Sensitivity

Extensions are case-sensitive. Always normalize:

```elixir
# Avoid
MIME.type("HTML")  # => "application/octet-stream"

# Correct
MIME.type(String.downcase("HTML"))  # => "text/html"
```

### 2. Assuming Extension Exists

Unknown extensions return the default MIME type. Validate in security contexts:

```elixir
case MIME.type(ext) do
  "application/octet-stream" -> validate_more_carefully(file)
  mime -> process_as(mime, file)
end
```

### 3. Custom Types Not Recompiled

Changes to custom MIME types in config require recompilation (pre-1.15):

```bash
mix clean
mix compile
```

### 4. Double Extension Handling

Files like `archive.tar.gz` need special handling:

```elixir
# The library handles the last extension only
MIME.from_path("archive.tar.gz")  # => "application/gzip"

# For full detection, implement custom logic
def detect_dual_extension(path) do
  if String.match?(path, ~r/\.tar\.(gz|bz2|xz)$/) do
    "application/x-tar+#{extract_compression(path)}"
  else
    MIME.from_path(path)
  end
end
```

## Version Notes

**2.0.7** is the stable LTS release with:

- Comprehensive standard MIME type database
- Support for custom type configuration
- Efficient in-memory type lookups
- Elixir 1.11+ required
- OTP 22+ recommended

The library is intentionally minimal and dependency-free, making it suitable for all Elixir/Phoenix projects.

---

**Version:** 2.0.7  
**Source:** https://hexdocs.pm/mime/2.0.7  
**Generated:** 2026-06-17
