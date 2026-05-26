# sweet_xml

A thin wrapper around Erlang's `:xmerl` that simplifies XML parsing in Elixir. Converts char lists or xmlElement records into native Elixir values (maps, lists, strings, integers, floats, and combinations thereof).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:sweet_xml, "~> 0.7.5"}]
end
```

Note: Linux users may need to install the `erlang-xmerl` package separately.

### Basic Usage

```elixir
import SweetXml

xml_str = "<root><name>Example</name></root>"
doc = parse(xml_str)
result = doc |> xpath(~x"//name/text()"s)  # Returns "Example"
```

## Core Concepts

### The ~x Sigil

XPath expressions use the `~x` sigil with modifiers to control output:

| Modifier | Effect                                                   |
| -------- | -------------------------------------------------------- |
| (none)   | Returns xmlText, xmlAttribute, xmlPI, or xmlComment      |
| `e`      | Returns entity (xmlElement) for chaining                 |
| `l`      | Forces list return; without it, only first match returns |
| `k`      | Returns Keyword instead of Map                           |
| `s`      | Converts char lists to strings                           |
| `S`      | Soft string: converts to string or returns ""            |
| `o`      | Optional: allows missing paths, returns nil              |
| `i`      | Converts values to integers                              |
| `I`      | Soft integer: converts to integer or returns 0           |
| `f`      | Converts values to floats                                |
| `F`      | Soft float: converts to float or returns 0.0             |

Modifiers stack: `~x"//path"sli` for string list with integer elements.

### XPath Queries

Extract text content:

```elixir
doc |> xpath(~x"//element/text()")     # First match only
doc |> xpath(~x"//element/text()"l)    # All matches as list
```

Extract attributes:

```elixir
doc |> xpath(~x"//element/@attr"l)     # All attr values
```

### Mapping to Structures

Nest XPath specs to build complex maps:

```elixir
doc |> xpath(
  ~x"//item"l,
  name: ~x"./name/text()"s,
  price: ~x"./price/text()"f,
  tags: ~x"./tag/text()"sl
)
```

Returns:

```elixir
[
  %{"name" => "Item1", "price" => 19.99, "tags" => ["tag1", "tag2"]},
  %{"name" => "Item2", "price" => 29.99, "tags" => ["tag3"]}
]
```

### Using xmap

For top-level structure definitions:

```elixir
doc |> xmap(
  items: [
    ~x"//items/item"l,
    name: ~x"./name/text()"s,
    price: ~x"./price/text()"f
  ],
  total: ~x"//total/text()"f
)
```

Returns:

```elixir
%{
  "items" => [...],
  "total" => 199.99
}
```

## Configuration

### Namespace Support

For documents with XML namespaces, parse with `namespace_conformant: true`:

```elixir
doc = parse(xml_str, namespace_conformant: true)

result = doc |> xpath(
  ~x"//ff:item/ff:name/text()"s
  |> add_namespace("ff", "http://example.com/ns")
)
```

### Security Options

When processing untrusted XML:

```elixir
parse(xml_str, dtd: :none)           # Disable DTD processing
stream_tags(stream, tags, dtd: :none)
```

## Best Practices

### Transform Values

Use `transform_by` for custom conversions:

```elixir
doc |> xpath(
  ~x"//name/text()"s
  |> transform_by(&String.upcase/1)
)
```

Create reusable parsers with transform_by:

```elixir
parse_item = fn node ->
  xmap(node,
    name: ~x"./name/text()"s,
    price: ~x"./price/text()"f
  )
end

doc |> xpath(~x"//item"l |> transform_by(parse_item))
```

### Stream Large Files

For memory efficiency with large XML documents:

```elixir
File.stream!("large.xml")
|> stream_tags([:item])
|> Stream.map(fn {_, elem} -> xpath(elem, ~x"./id/text()"i) end)
|> Enum.to_list
```

Prevent memory leaks with discard:

```elixir
stream_tags(stream, [:item], discard: [:item])
```

### Defensive Parsing

Always use soft modifiers (`S`, `I`, `F`) for optional/untrusted data:

```elixir
# Returns nil if missing or invalid
xpath(doc, ~x"//optional/value"oS)

# Returns 0 if missing or non-numeric
xpath(doc, ~x"//count"I)
```

### Avoid Common Pitfalls

- XPath support is limited to **XPath 1.0** — verify your expressions work with libxml2
- Without the `l` modifier, nested lists collapse to first element only
- Char lists (`'string'`) need `s` modifier to convert to binaries
- Large documents should use `stream_tags` to avoid loading entire XML into memory

---

**Version:** 0.7.5  
**Source:** [hexdocs.pm/sweet_xml](https://hexdocs.pm/sweet_xml/)  
**Generated:** 2026-04-25
