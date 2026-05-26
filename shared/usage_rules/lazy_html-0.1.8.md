# lazy_html

Efficient HTML parsing and querying library for Elixir using Lexbor, a fast dependency-free C HTML engine. LazyHTML keeps documents in native memory format with lazy evaluation, executing CSS selectors in native code for browser-standard compliance and high performance.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [{:lazy_html, "~> 0.1.8"}]
end
```

### Basic Usage

Parse HTML and query with CSS selectors:

```elixir
lazy_html = LazyHTML.from_fragment("""
  <div>
    <a href="https://elixir-lang.org">Elixir</a>
    <a href="https://www.erlang.org">Erlang</a>
  </div>
""")

# Query elements
hyperlinks = LazyHTML.query(lazy_html, "a")

# Extract attributes
LazyHTML.attribute(hyperlinks, "href")
# Returns: ["https://elixir-lang.org", "https://www.erlang.org"]

# Extract text content
LazyHTML.text(hyperlinks)
# Returns: ["Elixir", "Erlang"]
```

## Core Concepts

### Parsing Functions

- **`from_document/1`** - Parses complete HTML documents, automatically adds missing `<html>`, `<head>`, `<body>` tags
- **`from_fragment/1`** - Parses HTML fragments without adding extra wrapper tags

### Querying Functions

- **`query/2`** - Finds all elements matching a CSS selector
- **`query_by_id/2`** - Locates elements by their `id` attribute
- **`filter/2`** - Filters root nodes by CSS selector

### Data Extraction

- **`attribute/2`** - Retrieves attribute values (returns list of values)
- **`text/1`** - Extracts text content from elements
- **`tag/1`** - Gets HTML tag names

### Conversion Functions

- **`to_html/2`** - Serializes LazyHTML back to HTML strings
- **`to_tree/2`** - Converts to Elixir tree data structures
- **`from_tree/1`** - Builds LazyHTML from Elixir tree data

## Configuration

### Parsing Options

LazyHTML supports the following options during parsing:

- **`skip_whitespace_nodes`** - When enabled, whitespace-only text nodes are excluded from results, providing cleaner output

Example with options:

```elixir
lazy_html = LazyHTML.from_fragment(html_string, skip_whitespace_nodes: true)
```

### Protocol Support

LazyHTML integrates with Elixir's standard protocols:

- **`Inspect`** - Pretty-prints nodes for debugging
- **`Access`** - Enables bracket notation for CSS selectors
- **`Enumerable`** - Allows iteration with `Enum` functions

## Best Practices

### Using Access Protocol

Leverage bracket notation for cleaner query syntax:

```elixir
# Using Access protocol (cleaner)
lazy_html["strong, em"]

# Equivalent to
LazyHTML.query(lazy_html, "strong, em")
```

### Batched Operations

All operations process multiple nodes efficiently:

```elixir
# This extracts attributes from all matching elements at once
links = lazy_html["a"]
hrefs = LazyHTML.attribute(links, "href")  # Returns list of all href values
```

### Enumeration Over Results

Use `Enum` functions to process query results:

```elixir
results = lazy_html["article"]

# Map over results
Enum.map(results, &LazyHTML.text/1)

# Filter results
Enum.filter(results, fn node ->
  LazyHTML.attribute(node, "class") == ["featured"]
end)
```

### Text Extraction Strategies

- `LazyHTML.text/1` - Extracts all text content from an element and its children
- Chain with `Enum.map/2` to get text from multiple elements

### Memory Efficiency

LazyHTML keeps documents in native format until conversion is needed. Only convert to HTML or tree structures when necessary:

```elixir
# Efficient - stays in native format during querying
parsed = LazyHTML.from_fragment(large_html)
results = parsed["div.important"]
text_data = LazyHTML.text(results)

# Only convert when exporting
html_output = LazyHTML.to_html(results)
```

### Handling Missing Elements

Query operations return empty LazyHTML structs if no matches found. Use guards or pattern matching:

```elixir
case LazyHTML.query(doc, ".nonexistent") do
  lazy_html when lazy_html == %{} -> "No matches"
  results -> LazyHTML.text(results)
end
```

---

**Version:** 0.1.8
**Source:** [hexdocs.pm/lazy_html](https://hexdocs.pm/lazy_html/)
**Repository:** [github.com/dashbitco/lazy_html](https://github.com/dashbitco/lazy_html)
**License:** Apache 2.0 by Dashbit
**Generated:** 2025-10-28
