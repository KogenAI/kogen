# lazy_html

LazyHTML is an Elixir library for efficient parsing and querying of HTML documents. It maintains documents in native memory format and executes CSS selectors in native code, leveraging Lexbor—a high-performance C-based HTML parser. This enables fast, memory-efficient HTML processing without converting to intermediate Elixir structures.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:lazy_html, "~> 0.1.10"}
```

Run `mix deps.get`.

### Basic Parsing

Parse HTML fragments (without wrapping in `<html>`, `<head>`, `<body>`):

```elixir
lazy_html = LazyHTML.from_fragment("<div><a href='/page'>Link</a></div>")
```

Parse complete documents (auto-wraps with missing tags):

```elixir
doc = LazyHTML.from_document("<h1>Title</h1><p>Content</p>")
```

### Querying

Use CSS selectors to find elements:

```elixir
lazy_html = LazyHTML.from_fragment("<div><a href='#'>Link</a></div>")
links = LazyHTML.query(lazy_html, "a")
# Returns: [LazyHTML node for <a> element]
```

Use bracket notation (Access protocol) for inline queries:

```elixir
links = lazy_html["a"]
titles = lazy_html["h1"]
```

### Extracting Data

Extract attribute values:

```elixir
hrefs = LazyHTML.attribute(links, "href")
# Returns: ["#"] or ["..."] depending on content
```

Extract text content:

```elixir
text = LazyHTML.text(links)  # Text from matched nodes
text = LazyHTML.text(links, separator: " | ")  # Custom separator
```

## Core Concepts

### Native Format Efficiency

LazyHTML keeps documents in native C format (Lexbor) as long as possible. Operations execute in native code, avoiding expensive conversions to Elixir terms. Batched operations process multiple queries/extractions efficiently.

### Lazy Nodes

Query results return lazy node references, not full Elixir structures. These nodes support:

- Further CSS queries (chain operations)
- Attribute extraction
- Text content retrieval
- Serialization back to HTML
- Conversion to Elixir trees (when needed)

### CSS Selectors

Standard CSS3 selectors are supported:

```elixir
lazy_html["div.class"]        # Class selector
lazy_html["p#id"]             # ID selector
lazy_html["a[href^='http']"]  # Attribute selector
lazy_html["ul > li"]          # Child combinator
lazy_html["div span"]         # Descendant combinator
```

### Bidirectional Conversion

Convert between formats:

```elixir
# Lazy node → HTML string
html = LazyHTML.to_html(node)

# Lazy node → Elixir tree
tree = LazyHTML.to_tree(node)

# HTML string → Lazy node
node = LazyHTML.from_fragment(html)
```

## Configuration

LazyHTML has minimal configuration. Key parsing options:

### Fragment vs Document

- **`from_fragment/1`**: Parses HTML segments; preserves structure as-is. Use for partial HTML.
- **`from_document/1`**: Parses complete documents; auto-adds missing structural tags (`<html>`, `<head>`, `<body>`). Use for full pages.

### Text Extraction Options

- **`LazyHTML.text(nodes)`**: Concatenate text from all matching nodes.
- **`LazyHTML.text(nodes, separator: " ")`**: Join text with a custom separator.

### Query Options

All query and attribute operations work on:

- Single nodes
- Lists of nodes (batched)
- Nested lazy results (chain queries)

## Best Practices

### Use Lazy Evaluation

Keep results in lazy format. Only convert to Elixir terms when necessary:

```elixir
# Good: stays lazy until serialization
links = lazy_html["a[href]"]
hrefs = LazyHTML.attribute(links, "href")

# Avoid: premature conversion
tree = LazyHTML.to_tree(lazy_html)
hrefs = extract_from_tree(tree)  # Unnecessary work
```

### Chain Selectors Efficiently

Query chains on lazy results are efficient:

```elixir
# Efficiently find nested elements
items = lazy_html["div.container"]["li"]
```

### Handle Large Documents

For large HTML documents, process in chunks or use scoped queries:

```elixir
# Query specific sections first, then drill down
sections = lazy_html["section"]
Enum.each(sections, fn section ->
  items = LazyHTML.query(section, "article")
  # Process items
end)
```

### Batch Operations

Extract multiple attributes or text values in one pass:

```elixir
links = lazy_html["a"]
hrefs = LazyHTML.attribute(links, "href")
texts = LazyHTML.text(links)
# Both queries execute efficiently on the native structure
```

### Convert Only When Needed

Use `to_tree/2` or `to_html/2` only when integrating with Elixir code that requires native terms:

```elixir
# Keep lazy for queries and API responses
response = %{links: LazyHTML.attribute(lazy_html["a"], "href")}

# Convert only for complex Elixir transformations
tree = LazyHTML.to_tree(node)  # Only if pattern matching on tree structure
```

---

**Version:** 0.1.10  
**Source:** [hexdocs.pm/lazy_html](https://hexdocs.pm/lazy_html/)  
**Generated:** 2026-04-25
