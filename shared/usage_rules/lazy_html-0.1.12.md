# lazy_html

LazyHTML is an Elixir library for efficient parsing and querying of HTML documents. Built by Dashbit, it leverages Lexbor, a C-based HTML engine, to provide native performance without external dependencies. The library operates on a flat list of nodes with batched operations, keeping documents in native memory format and only converting to Elixir data structures when necessary.

## Quick Start

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:lazy_html, "~> 0.1.12"}
  ]
end
```

Parse HTML and query it:

```elixir
# From a string fragment
lazy_html = LazyHTML.from_fragment("<a href='url'>Link</a>")

# Query using CSS selectors
results = LazyHTML.query(lazy_html, "a")

# Extract attributes
LazyHTML.attribute(results, "href")

# Bracket notation for quick queries
lazy_html["strong, em"]
```

## Core Concepts

**Lazy Nodes**: The library keeps HTML in native memory format. Nodes remain lazy until explicitly converted to Elixir structures, providing performance benefits for large documents.

**Batch Operations**: All operations are batched by default. When you query or extract attributes, results are processed in bulk rather than one at a time, improving throughput.

**CSS Selectors**: Query syntax follows standard CSS selector patterns. The library executes selectors in native code for optimal performance.

**Document Formats**:

- `from_fragment/1` - Parse HTML fragments
- `from_document/1` - Parse complete documents
- Results are queryable LazyHTML structures

**Protocol Support**:

- **Enumerable**: Iterate over nodes with standard Enum operations
- **Access**: Use bracket notation (`lazy_html["selector"]`) for concise queries
- **Inspect**: Pretty-print nodes for debugging

## Configuration

No global configuration is required. LazyHTML behavior is controlled through function arguments:

**Query Options**:

- CSS selector strings for `LazyHTML.query/2`
- Attribute extraction with `LazyHTML.attribute/2` or `LazyHTML.attributes/2`

**Data Conversion**:

- `LazyHTML.to_tree/1` - Convert lazy nodes to nested Elixir data structures (recurses into children)
- `LazyHTML.from_tree/1` - Reconstruct LazyHTML from tree format

**Processing Methods**:

- `LazyHTML.query/2` - Find elements matching a selector
- `LazyHTML.text/1` - Extract text content
- `LazyHTML.html/1` - Get HTML representation
- `LazyHTML.parent/1` - Get parent node
- `LazyHTML.children/1` - Get child nodes

## Best Practices

**Minimize Conversions**: Keep data in LazyHTML format as long as possible. Only call `to_tree/1` when you need the nested Elixir structure or are done processing.

**Batch Your Queries**: Since operations are naturally batched, process multiple selectors or attributes in one pass rather than multiple separate operations.

**Use Bracket Notation for Simple Queries**: For straightforward CSS selectors, the bracket syntax (`html["div.class"]`) is more concise than `LazyHTML.query/2`.

**Leverage Enumerable Protocol**: Use `Enum` operations directly on query results rather than converting to lists first.

**Selector Performance**: Complex selectors are still executed in native code, but simpler, more specific selectors (e.g., `div.class` vs `div .class .class`) may have better performance on large documents.

**Handle Large Documents**: For very large HTML files, keep nodes lazy and extract only what you need. Converting the entire document to a tree simultaneously can consume significant memory.

---

**Version:** 0.1.12
**Source:** [hexdocs.pm/lazy_html](https://hexdocs.pm/lazy_html/0.1.12)
**Generated:** 2026-08-07
