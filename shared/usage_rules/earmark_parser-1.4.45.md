# earmark_parser

EarmarkParser is a pure Elixir markdown parser with no external dependencies. It parses markdown into an AST (Abstract Syntax Tree) and supports Markdown 1.6 with common extensions like GitHub Flavored Markdown features, task lists, tables, and footnotes.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:earmark_parser, "~> 1.4"}
  ]
end
```

### Basic Usage

```elixir
iex> EarmarkParser.parse("# Hello\n\nThis is **bold**")
{:ok, ast, []}

iex> {:ok, ast, messages} = EarmarkParser.parse("# Title")
```

Parse markdown into an AST that you can transform or render:

```elixir
{:ok, ast, warnings} = EarmarkParser.parse(markdown_text)

# ast is a list of tuples representing block and inline elements
# warnings is a list of parsing issues (optional, empty for valid markdown)
```

## Core Concepts

### AST Structure

EarmarkParser produces an Elixir AST with tuples of form `{tag, attributes, content, metadata}`:

- **Block elements**: paragraphs, headings, lists, code blocks, blockquotes, tables
- **Inline elements**: emphasis, strong, links, images, code spans
- **Leaf nodes**: plain text strings

Example AST for `"# Heading\n\nParagraph"`:

```elixir
[
  {"h1", [], ["Heading"], %{}},
  {"p", [], ["Paragraph"], %{}}
]
```

### Supported Markdown Features

- Headings (1-6 levels with `#` syntax)
- Emphasis and strong (`*italic*`, `**bold**`)
- Links and images (`[text](url)`, `![alt](src)`)
- Code blocks (indented and fenced with ` ``` `)
- Inline code (`` `code` ``)
- Lists (ordered, unordered, nested)
- Blockquotes (`> quote`)
- Tables (GitHub Flavored Markdown)
- Strikethrough (`~~text~~`)
- Footnotes (`[^1]`, `[^1]: definition`)
- Task lists (`- [ ] item`, `- [x] completed`)

## Configuration

### Parse Options

```elixir
EarmarkParser.parse(markdown, options)
```

Common options:

- `:breaks` (boolean) - Convert soft line breaks to `<br/>` tags (default: `false`)
- `:code_class_prefix` (string) - Prefix for fenced code block classes (default: `"language-"`)
- `:footnotes` (boolean) - Enable footnote parsing (default: `true`)
- `:gfm` (boolean) - Enable GitHub Flavored Markdown extensions (default: `true`)
- `:parse_config` (map) - Advanced parsing options

Example with options:

```elixir
{:ok, ast, messages} = EarmarkParser.parse(text, breaks: true, gfm: true)
```

### Return Value

`EarmarkParser.parse/2` returns a tuple:

- `{:ok, ast, messages}` - Successful parse with optional warnings
- `ast` is a list of block-level elements
- `messages` is a list of warning/error tuples like `{:error, line, description}`

## Best Practices

### AST Transformation

Process the AST to render or transform markdown:

```elixir
def render_ast(ast) do
  Enum.map(ast, &render_element/1)
end

defp render_element({"p", _attrs, content, _meta}) do
  render_inline(content)
end

defp render_element({"h1", _attrs, content, _meta}) do
  "<h1>#{render_inline(content)}</h1>"
end

defp render_inline(content) when is_list(content) do
  Enum.map(content, &render_inline/1) |> Enum.join()
end

defp render_inline(text) when is_binary(text), do: text

defp render_inline({"strong", _attrs, content, _meta}) do
  "<strong>#{render_inline(content)}</strong>"
end
```

### Error Handling

Always handle the warnings list:

```elixir
case EarmarkParser.parse(user_input) do
  {:ok, ast, []} ->
    {:ok, render(ast)}

  {:ok, ast, warnings} ->
    # Log warnings but still process
    Enum.each(warnings, &log_warning/1)
    {:ok, render(ast)}

  {:error, _ast, errors} ->
    {:error, errors}
end
```

### Common Patterns

**Sanitize untrusted markdown:**

```elixir
# Parse first, then filter/sanitize the AST before rendering
{:ok, ast, _} = EarmarkParser.parse(user_content)
safe_ast = sanitize_ast(ast)
render(safe_ast)
```

**Extract plain text from markdown:**

```elixir
def extract_text(ast) do
  Enum.map(ast, &extract_text_element/1) |> Enum.join(" ")
end

defp extract_text_element({_tag, _attrs, content, _meta}) when is_list(content) do
  Enum.map(content, &extract_text_element/1) |> Enum.join(" ")
end

defp extract_text_element(text) when is_binary(text), do: text
```

**Pretty-print AST for debugging:**

```elixir
{:ok, ast, _} = EarmarkParser.parse(markdown)
IO.inspect(ast, pretty: true)
```

### Gotchas & Caveats

- **Line tracking**: The AST includes line numbers in metadata; use for error reporting
- **Nested lists**: Lists can be deeply nested; recursion required for full traversal
- **Inline vs block**: Inline elements (strong, emphasis) nest inside block content; structure is `{tag, attrs, [inline_content], meta}`
- **Raw HTML**: By default, raw HTML blocks are parsed as such; sanitize if rendering user input
- **Performance**: EarmarkParser is fast but large documents may benefit from streaming approaches

---

**Version:** 1.4.45  
**Source:** https://hexdocs.pm/earmark_parser/1.4.45  
**Generated:** 2026-06-17
