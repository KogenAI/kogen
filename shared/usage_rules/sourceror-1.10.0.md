# sourceror

Sourceror is a utility library for working with Elixir source code. It enables developers to parse, analyze, and modify Elixir code while preserving comments and formatting—capabilities essential for building codemods and refactoring tools.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:sourceror, "~> 1.10"}
  ]
end
```

Run `mix deps.get` to install.

### Basic Usage

Parse Elixir source code and manipulate it:

```elixir
source = """
def hello do
  IO.puts("world")
end
"""

# Parse source into AST with comments preserved
ast = Sourceror.parse_string!(source)

# Transform the AST
transformed = Macro.postwalk(ast, fn node -> node end)

# Convert back to source code
Sourceror.to_string(transformed)
```

## Core Concepts

### Extended AST with Comments

Sourceror augments standard Elixir AST by attaching comment metadata to nodes. Comments are stored in node metadata through two fields:

- **`:leading_comments`** - Comments directly above nodes or on the same line
- **`:trailing_comments`** - Comments inside nodes that don't introduce child elements

This preserves the original source structure when applying transformations.

### Parsing Functions

- **`parse_string/2`** - Converts complete source code into AST with comment metadata
- **`parse_expression/2`** - Parses single expressions line-by-line (useful for partial parsing)
- Both accept options for customization

### Traversal Methods

- **`prewalk/2-3`** - Pre-order depth-first traversal; processes parents before children
- **`postwalk/2-3`** - Post-order depth-first traversal; processes children before parents
- **`traverse/3`** - Custom traversal with more control
- **Zipper implementation** - Sophisticated AST navigation for complex transformations

### Code Patching

Instead of reconstructing entire files, Sourceror uses patch-based modification:

- **`patch_string/2`** - Applies targeted text replacements to source code
- Patches specify line/column ranges and replacement text
- Applied bottom-up to avoid conflicts from line/column shifts
- **`Sourceror.Patch`** module provides common patching operations
- Preserves original formatting outside changed areas

### Converting Back to Source

- **`to_string/2`** - Converts AST back to formatted code
- **`quoted_to_algebra/2`** - Converts AST to algebra documents for custom formatting

## Configuration

### Parse Options

`parse_string/2` accepts options like:

- `:line` - Starting line number
- `:column` - Starting column number
- `:file` - Filename for error messages

### Patch Options

When applying patches via `patch_string/2`:

- Patches are applied bottom-up automatically
- Text ranges use line/column coordinates from AST
- Replacement can be static text or a function

### Comment Manipulation

Comment metadata is a map containing:

- `:line` - Comment line number
- `:column` - Comment column position
- `:text` - Comment content (with `#` prefix)
- EOL count information

Use `append_comments/3` and `prepend_comments/3` to modify comment metadata.

## Best Practices

### 1. Preserve Comments in Transformations

Always account for comments when modifying AST. Use Sourceror's comment metadata rather than stripping comments during transformation.

```elixir
# Good: Preserves comment structure
ast |> Macro.postwalk(fn node -> transform_while_preserving_comments(node) end)

# Avoid: Loses comments
ast |> Macro.postwalk(fn node -> transform_blindly(node) end)
```

### 2. Use Patches for Precision

For targeted changes, prefer patch-based modifications over full AST reconstruction. Patches preserve surrounding formatting.

```elixir
# Good: Surgical patch application
source
|> Sourceror.parse_string!()
|> Sourceror.patch_string([{range, replacement}])

# Less ideal: Full reconstruction loses formatting
source
|> Sourceror.parse_string!()
|> full_transform()
|> Sourceror.to_string()
```

### 3. Leverage Zipper for Complex Navigation

For sophisticated transformations, use Sourceror's Zipper implementation to navigate and modify nested structures contextually.

### 4. Bottom-Up Patch Application

When applying multiple patches, remember they're processed bottom-up. This prevents line/column shifting issues when multiple changes affect the same region.

### 5. Understand Comment Classification

Distinguish between leading and trailing comments in your transformations:

- Leading comments apply to the node itself
- Trailing comments represent internal structure

This classification affects how comments move when nodes are reorganized.

### 6. No External Dependencies

Sourceror has no dev/prod dependencies, making it lightweight for integration into other tools and build systems.

### 7. Build Codemods Systematically

When building refactoring tools:

1. Parse source with `parse_string!`
2. Traverse and identify patterns with `postwalk/prewalk`
3. Collect necessary transformations
4. Apply via `patch_string` for surgical precision
5. Convert back with `to_string`

---

**Version:** 1.10.0
**Source:** [hexdocs.pm/sourceror](https://hexdocs.pm/sourceror/)
**Generated:** 2025-10-28
