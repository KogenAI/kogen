# lazy_html

LazyHTML is an Elixir library for rendering HTML templates with support for lazy evaluation and efficient streaming. It provides a lightweight approach to HTML generation with composable, reusable components.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:lazy_html, "~> 0.1.11"}
  ]
end
```

Run `mix deps.get`.

### Basic Usage

```elixir
defmodule MyApp.Templates do
  use LazyHTML

  def hello(name) do
    html do
      div class: "greeting" do
        h1 do: "Hello, #{name}!"
        p do: "Welcome to LazyHTML"
      end
    end
  end
end

# Render to string
MyApp.Templates.hello("Alice") |> to_string()
```

## Core Concepts

### HTML Builder DSL

LazyHTML provides a DSL for constructing HTML trees declaratively:

```elixir
html do
  doctype()
  head do
    title do: "My Page"
    meta charset: "utf-8"
  end
  body do
    header do
      nav do
        a href: "/" do: "Home"
        a href: "/about" do: "About"
      end
    end
    main do
      article do
        h1 do: "Post Title"
        p do: "Post content here"
      end
    end
    footer do: "© 2026"
  end
end
```

### Lazy Evaluation

Templates are built lazily, allowing efficient rendering of large documents:

```elixir
# Templates are evaluated only when converted to string
template = html do
  div do: "Content"
end

# Safe to compose without immediate evaluation
rendered = template |> to_string()
```

### Component Composition

Create reusable components by defining functions:

```elixir
def card(title, content) do
  div class: "card" do
    h2 do: title
    p do: content
  end
end

def cards(items) do
  div class: "card-grid" do
    for item <- items do
      card(item.title, item.content)
    end
  end
end

# Usage
cards([
  %{title: "Card 1", content: "Content 1"},
  %{title: "Card 2", content: "Content 2"}
])
```

### Attribute Handling

Attributes are passed as keyword lists:

```elixir
def button(text, opts \\ []) do
  button class: "btn #{opts[:class]}", id: opts[:id] do
    text
  end
end

# Conditional attributes
def link(text, href, external: true) do
  a href: href, target: "_blank", rel: "noopener noreferrer" do
    text
  end
end

def link(text, href, _) do
  a href: href do: text
end
```

### Embedding Strings and Values

Use `do:` blocks for simple content, or nest blocks for complex structures:

```elixir
def user_profile(user) do
  div class: "profile" do
    h1 do: user.name
    p do: "Email: #{user.email}"
    p do: "Bio: #{user.bio}"
  end
end
```

## Configuration

LazyHTML is minimal and requires no configuration. All behavior is controlled through DSL patterns in template definitions.

### Rendering Options

Convert templates to various formats:

```elixir
# To string (default)
template |> to_string()

# To iolist (efficient for output)
template |> to_iolist()

# For Phoenix/Plug integration
{:safe, html_string} = template |> Phoenix.HTML.safe_to_string()
```

### Streaming

LazyHTML supports streaming for large responses:

```elixir
# In a Phoenix controller
def show(conn, _params) do
  template = render_large_template()
  conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_chunked(200)
    |> stream_template(template)
end

defp stream_template(conn, template) do
  template
  |> to_iolist()
  |> Enum.each(&chunk(conn, &1))
  conn
end
```

## Best Practices

### 1. Use Functions for Templates

Encapsulate templates in named functions for clarity and reusability:

```elixir
# Good
def page_header(user) do
  header do
    h1 do: user.name
  end
end

# Less ideal
header do
  h1 do: user.name
end
```

### 2. Separate Layout from Content

Create a layout wrapper and compose views into it:

```elixir
def layout(title, content) do
  html do
    head do
      title do: title
    end
    body do
      render(content)
    end
  end
end

def index_page(items) do
  layout("Items", div do
    for item <- items do
      div do: item.name
    end
  end)
end
```

### 3. Escape User Input

Always escape strings from untrusted sources:

```elixir
# Automatic by default
def comment(text) do
  div class: "comment" do
    p do: text  # Safely escaped
  end
end

# For raw HTML (use sparingly)
def raw_content(html_string) do
  div do
    raw(html_string)  # Mark as safe
  end
end
```

### 4. Leverage Elixir's Control Flow

Use standard Elixir patterns within templates:

```elixir
def user_list(users, admin: is_admin) do
  ul do
    for user <- users do
      li do
        span do: user.name
        if is_admin do
          button do: "Delete"
        end
      end
    end
  end
end

def conditional_panel(show_advanced) do
  section do
    h2 do: "Settings"
    if show_advanced do
      div do: render_advanced_settings()
    else
      div do: render_basic_settings()
    end
  end
end
```

### 5. Performance Considerations

- Build templates as functions, not in controller code
- Use lazy evaluation for large lists
- Stream responses for heavy templates
- Avoid nested for loops; flatten data when possible

```elixir
# Less efficient
for user <- users do
  for item <- user.items do
    render_item(item)
  end
end

# Better - flatten at data layer
all_items = Enum.flat_map(users, &Map.get(&1, :items))
for item <- all_items do
  render_item(item)
end
```

### 6. Phoenix Integration

LazyHTML integrates seamlessly with Phoenix templates:

```elixir
# In a Phoenix view module
defmodule MyApp.PageView do
  use MyApp, :view
  use LazyHTML

  def render("index.html", assigns) do
    html do
      div do
        h1 do: @title
        render_items(@items)
      end
    end
  end

  def render_items(items) do
    ul do
      for item <- items do
        li do: item.name
      end
    end
  end
end
```

### 7. Common Pitfalls

- **Forgetting `do:` for text nodes:** Always use `do:` or a do-block
- **Mixing string concatenation:** Use the DSL consistently
- **Over-nesting:** Keep template depth reasonable for readability
- **Not using function parameters:** Pass data as function arguments, not globals

## Version Notes

Version 0.1.11 is an early release. Key characteristics:

- Stable for basic HTML generation
- Limited streaming support in early releases
- No caching of compiled templates
- Works with Phoenix 1.3+ and Elixir 1.5+
- Minimal dependencies

---

**Version:** 0.1.11  
**Source:** https://hexdocs.pm/lazy_html  
**Generated:** 2026-06-17
