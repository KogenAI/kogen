# earmark_parser

A pure Elixir markdown parser that converts markdown into an Abstract Syntax Tree (AST). EarmarkParser is the parsing engine behind Earmark, providing extensible markdown-to-AST conversion with support for standard Markdown, GitHub Flavored Markdown, and optional extensions.

## Quick Start

Add to `mix.exs`:

```elixir
{:earmark_parser, "~> 1.4"}
```

Parse markdown to AST with `as_ast/2`:

```elixir
{:ok, ast, []} = EarmarkParser.as_ast("# Hello\nMy `code` is **best**")

{status, ast, messages} = EarmarkParser.as_ast(markdown, options)
```

Returns one of three formats:

- `{:ok, ast, []}` — successful parse with no warnings
- `{:ok, ast, deprecation_messages}` — successful parse with deprecations
- `{:error, ast, error_messages}` — parse completed with errors

## Core Concepts

**AST Structure:** Markdown converts to nested tuples:

- Format: `{tag, attributes, children, metadata}`
- Tags: `:p`, `:heading`, `:strong`, `:em`, `:code`, `:link`, `:blockquote`, etc.
- Attributes: List of `{key, value}` pairs for HTML rendering
- Children: List of child nodes or text strings
- Metadata: Line numbers and source information

**Parsing Strategy:** EarmarkParser generates an intermediate representation suitable for rendering to HTML, LaTeX, or custom formats. The AST can be post-processed before final output.

**Error Handling:** All parsing returns a tuple. Check status and messages for deprecations or errors without aborting—partial ASTs are always returned.

## Configuration

**Disabled by Default (enable as needed):**

```elixir
EarmarkParser.as_ast(markdown, sub_sup: true)           # ~subscript~ and ^superscript^
EarmarkParser.as_ast(markdown, math: true)              # $...$, $$...$$, LaTeX blocks
EarmarkParser.as_ast(markdown, gfm_tables: true)        # GitHub Flavored tables
EarmarkParser.as_ast(markdown, wikilinks: true)         # [[page]] syntax
EarmarkParser.as_ast(markdown, footnotes: true)         # Footnote refs and defs
EarmarkParser.as_ast(markdown, breaks: true)            # Trailing spaces → <br/>
```

**Enabled by Default:**

```elixir
EarmarkParser.as_ast(markdown, pure_links: true)        # Auto-link URLs
```

**Convenience Option:**

```elixir
EarmarkParser.as_ast(markdown, all: true)               # Enable all optional features
```

**Code Highlighting:**

```elixir
EarmarkParser.as_ast(markdown, code_class_prefix: "lang- language-")
```

Adds language-specific CSS classes to code blocks: `<code class="lang-elixir">`.

**IAL (Inline Attribute Lists):**

Use Kramdown-style syntax to attach HTML attributes:

```markdown
# Headline {:.warning}

Paragraph {: #id .class }
```

This adds attributes to the preceding element for custom styling or scripting.

**Annotations (Experimental):**

```elixir
EarmarkParser.as_ast(markdown, annotations: "-->")
```

Embeds comments in markdown without polluting the AST.

## Best Practices

**1. Always Handle the Return Tuple**

```elixir
case EarmarkParser.as_ast(markdown) do
  {:ok, ast, []} ->
    render(ast)
  {:ok, ast, messages} ->
    IO.warn("Deprecations: #{inspect(messages)}")
    render(ast)
  {:error, ast, messages} ->
    IO.warn("Parse errors: #{inspect(messages)}")
    render(ast)
end
```

**2. Enable Only Needed Extensions**

Avoid `all: true` in production unless all extensions are required. Selective enablement is lighter and safer:

```elixir
EarmarkParser.as_ast(markdown, gfm_tables: true, footnotes: true)
```

**3. Reuse Options**

Define options as a constant to avoid repeating them:

```elixir
@parse_options [gfm_tables: true, footnotes: true, pure_links: true]

def parse(markdown) do
  {:ok, ast, _messages} = EarmarkParser.as_ast(markdown, @parse_options)
  ast
end
```

**4. Cache ASTs When Parsing Repeatedly**

AST generation is deterministic; cache for the same markdown:

```elixir
def cached_parse(markdown) do
  Cachex.fetch(:markdown_cache, markdown, fn ->
    {:ok, ast, _} = EarmarkParser.as_ast(markdown, @options)
    {:ok, ast}
  end)
end
```

**5. Post-Process ASTs for Custom Rendering**

Transform ASTs before rendering for domain-specific needs:

```elixir
def inject_analytics(ast) do
  Enum.map(ast, fn
    {:a, attrs, children, meta} ->
      {:a, [{"data-track", "link"} | attrs], children, meta}
    node -> node
  end)
end
```

**6. Validate Input Before Parsing**

For untrusted markdown, validate size to prevent DOS:

```elixir
def safe_parse(markdown) when byte_size(markdown) > 1_000_000 do
  {:error, "Markdown too large"}
end
def safe_parse(markdown) do
  EarmarkParser.as_ast(markdown)
end
```

**7. Handle Line Numbers for Diagnostics**

Metadata includes line numbers for error reporting:

```elixir
{:ok, ast, _} = EarmarkParser.as_ast(markdown)
ast
|> Enum.filter(&has_errors/1)
|> Enum.map(&extract_line/1)
|> report_issues()
```

---

**Version:** 1.4.46  
**Source:** [hexdocs.pm/earmark_parser](https://hexdocs.pm/earmark_parser/1.4.46)  
**Generated:** 2026-08-07
