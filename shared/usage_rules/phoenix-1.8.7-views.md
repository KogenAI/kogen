# Phoenix - Views & Templates

## View Modules

Views are Elixir modules containing presentation logic and helper functions. Modern Phoenix uses function components with HEEx (HTML+Embedded Elixir) templates compiled directly into view modules. The view module is inferred by convention—`HelloController` uses `HelloView`.

```elixir
defmodule MyApp.HelloView do
  use MyApp, :view

  def greeting_message(name) do
    "Hello, #{name}!"
  end
end
```

View modules inherit helper functions from the `:view` macro, which provides access to routing, `render/3`, and other utilities.

## HEEx Templates

HEEx templates enable HTML authoring with embedded Elixir. They compile into function components, providing compile-time safety and efficient rendering.

### Basic Template Structure

Templates receive assigns from controllers as instance variables:

```heex
<h1><%= @title %></h1>
<p><%= @message %></p>

<%= if @user do %>
  <p>Welcome, <%= @user.name %>!</p>
<% else %>
  <p>Please log in.</p>
<% end %>
```

**Syntax rules:**

- `<%= ... %>` — Outputs the value (HTML-escaped)
- `<% ... %>` — Executes code without output
- `@variable` — Accesses assigns passed from controller
- `{...}` — Interpolates expressions within tags

### Loops

Iterate over collections:

```heex
<ul>
  <%= for user <- @users do %>
    <li><%= user.name %> - <%= user.email %></li>
  <% end %>
</ul>

<%= for {item, index} <- Enum.with_index(@items) do %>
  <p><%= index + 1 %>. <%= item %></p>
<% end %>
```

## Function Components

Reusable component functions replace the old view-based components:

```elixir
def button(assigns) do
  ~H"""
  <button class="btn btn-primary">
    <%= render_slot(@inner_block) %>
  </button>
  """
end

def card(assigns) do
  ~H"""
  <div class="card">
    <h3><%= @title %></h3>
    <%= render_slot(@inner_block) %>
  </div>
  """
end
```

**Using components:**

```heex
<.button>Click me</.button>

<.card title="Welcome">
  <p>This is the card content.</p>
</.card>
```

### Slots

Components accept content blocks as slots:

```elixir
def modal(assigns) do
  ~H"""
  <div class="modal">
    <div class="modal-header">
      <%= render_slot(@header) %>
    </div>
    <div class="modal-body">
      <%= render_slot(@inner_block) %>
    </div>
    <div class="modal-footer">
      <%= render_slot(@footer) %>
    </div>
  </div>
  """
end
```

Call with named slots:

```heex
<.modal>
  <:header>Confirm Action</:header>
  <p>Are you sure?</p>
  <:footer>
    <button>Yes</button>
    <button>No</button>
  </:footer>
</.modal>
```

## Template Assigns

Pass data from controllers to templates:

```elixir
def show(conn, %{"id" => id}) do
  user = Repo.get(User, id)
  render(conn, :show, user: user, posts: user.posts)
end
```

Access in templates:

```heex
<h1><%= @user.name %></h1>
<p><%= length(@posts) %> posts</p>
```

## Layouts

Layouts wrap content in common structure (header, footer, navigation):

```heex
<!DOCTYPE html>
<html>
  <head>
    <title><%= @page_title %></title>
  </head>
  <body>
    <nav>Navigation here</nav>
    <%= @inner_content %>
    <footer>Footer here</footer>
  </body>
</html>
```

Specify layout in controller:

```elixir
def index(conn, _params) do
  render(conn, :index, layout: {MyApp.Layouts, :app})
end
```

Or use `put_layout/2` in plugs to apply globally.

## HTML Escaping

HEEx automatically escapes HTML by default to prevent XSS attacks:

```heex
<p><%= @user_input %></p>
```

If input contains `<script>alert('xss')</script>`, it renders escaped as text. To render raw HTML (trusted content only):

```heex
<p><%= raw @trusted_html %></p>
```

Use `raw/1` sparingly and never with user-supplied data.

## Rendering Variations

Different render calls from controllers:

```elixir
# Render default template matching action name
render(conn, :index)

# Render specific template
render(conn, :custom)

# Render with assigns
render(conn, :show, user: user, posts: posts)

# Render from different view
render(conn, MyApp.OtherView, :template, assigns)

# Render JSON
json(conn, %{status: "ok", data: data})
```

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
