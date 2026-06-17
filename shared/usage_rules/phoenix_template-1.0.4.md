# phoenix_template

Phoenix Template is a lightweight templating engine for Phoenix applications, providing an efficient way to render dynamic HTML with a clean, composable syntax.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_template, "~> 1.0.4"}
  ]
end
```

Run `mix deps.get` to install.

### Basic Usage

Templates are typically stored in `lib/myapp_web/templates/` or `priv/templates/` and rendered using:

```elixir
Phoenix.Template.render_to_string(MyAppWeb.PageView, "index.html", assigns)
```

Template files use `.html` or `.html.eex` extensions. Use `<%= %>` for expression interpolation:

```html
<h1><%= @title %></h1>
<p><%= @description %></p>
```

## Core Concepts

### Template Engines

Phoenix Template supports multiple rendering engines:

- **EEX** (Embedded Elixir): default templating with `<%= %>` syntax
- **Text**: plain text templates
- **Custom**: register custom engines

### View Modules

Views organize template rendering. Assign variables in the controller:

```elixir
def index(conn, _params) do
  render(conn, "index.html", title: "Home", items: @items)
end
```

Access assigned values in templates with `@variable` syntax:

```html
<ul>
  <%= for item <- @items do %>
  <li><%= item %></li>
  <% end %>
</ul>
```

### Helpers

Define reusable markup functions in view modules:

```elixir
defmodule MyAppWeb.PageView do
  def welcome_message(user_name) do
    "Welcome, #{user_name}!"
  end
end
```

Call helpers from templates:

```html
<p><%= welcome_message(@current_user.name) %></p>
```

### Layout Templates

Layouts wrap pages. Define in `templates/layout/`:

```html
<!-- app.html -->
<!DOCTYPE html>
<html>
  <head>
    <title>MyApp</title>
  </head>
  <body>
    <%= @inner_content %>
  </body>
</html>
```

Specify layout in controller:

```elixir
render(conn, "index.html", layout: {MyAppWeb.LayoutView, "app.html"})
```

## Configuration

### Engine Registration

Register custom engines in config:

```elixir
# config/config.exs
config :phoenix_template, :engines,
  html: Phoenix.Template.Engines.HTML
```

### Template Format

Define template format and location:

```elixir
# In view module
use Phoenix.View,
  root: "lib/myapp_web/templates",
  namespace: MyAppWeb
```

### Assigns

Pass assigns safely to templates:

```elixir
# Controller
render(conn, "show.html",
  title: @page_title,
  user: @current_user,
  posts: @posts
)
```

Access in template with `@` prefix. All assigns are HTML-escaped by default.

## Best Practices

### Use HTML-Safe Values

Mark trusted HTML safe to prevent escaping:

```elixir
# In view or controller
Phoenix.HTML.raw("<b>Bold</b>")
```

### Template Organization

- Place layout templates in `templates/layout/`
- Group related templates in subdirectories
- Keep templates focused and small
- Extract complex logic to view helpers

### Avoid Logic in Templates

Keep templates for presentation only:

```html
<!-- GOOD -->
<%= format_date(@created_at) %>

<!-- AVOID -->
<%= @created_at |> DateTime.to_date() |> Date.to_string() %>
```

### Use Components (v1.6+)

For v1.0.4, use traditional view helpers. Prepare for future component migration.

### Conditional Rendering

Use `if`/`else` in templates:

```html
<%= if @user do %>
<p>Hello, <%= @user.name %></p>
<% else %>
<p>Please log in</p>
<% end %>
```

### Iteration

Loop with `for` comprehension:

```html
<table>
  <%= for post <- @posts do %>
  <tr>
    <td><%= post.title %></td>
    <td><%= post.author %></td>
  </tr>
  <% end %>
</table>
```

### Cache Template Compilation

Templates are compiled to modules. Development mode recompiles on changes; production serves compiled versions.

### Internationalization

Use `gettext` for translations:

```elixir
# In view or template
require Gettext
Gettext.dgettext(MyAppWeb.Gettext, "templates", "Hello")
```

## Common Pitfalls

### Escaping and XSS

By default, all template expressions are HTML-escaped. Only use `Phoenix.HTML.raw()` for trusted content:

```elixir
# SAFE: escaped
<%= @user_input %>

# DANGEROUS: use only for trusted content
<%= raw(@admin_html) %>
```

### Missing Assigns

Undefined `@variable` raises an error. Always pass required assigns from controller.

### Template Not Found

Ensure template file exists at expected path and controller specifies correct view module.

### Circular Dependencies

Avoid importing views into templates. Use explicit helper functions instead.

## Version Notes

**v1.0.4** is stable for basic templating. Key features:

- EEX engine with safe HTML escaping
- Layout wrapping
- View module helpers
- Multiple template engines support

Upgrade to v1.6+ for Phoenix LiveView components and modern component-based patterns.

---

**Version:** 1.0.4  
**Source:** https://hexdocs.pm/phoenix_template  
**Generated:** 2026-06-17
