# phoenix - Controllers and Views

## Controllers Overview

Controllers are Elixir modules that handle HTTP requests. Each action is a function accepting `conn` (request connection) and `params` (URL/form parameters), returning a response.

```elixir
defmodule MyappWeb.PostController do
  use MyappWeb, :controller

  def index(conn, _params) do
    posts = Repo.all(Post)
    render(conn, :index, posts: posts)
  end

  def show(conn, %{"id" => id}) do
    post = Repo.get!(Post, id)
    render(conn, :show, post: post)
  end
end
```

## Action Naming Conventions

While you can name actions anything, Phoenix conventions include:

| Action   | Purpose                         | HTTP Method |
| -------- | ------------------------------- | ----------- |
| `index`  | List all resources              | GET         |
| `show`   | Display single resource         | GET         |
| `new`    | Show form for creating resource | GET         |
| `create` | Process form submission         | POST        |
| `edit`   | Show form for editing resource  | GET         |
| `update` | Process edit form submission    | PUT/PATCH   |
| `delete` | Remove a resource               | DELETE      |

## Rendering Responses

### Render HTML Templates

```elixir
# Renders lib/myapp_web/controllers/page_html/index.html.heex
def index(conn, _params) do
  render(conn, :index)
end

# Pass variables to template
def show(conn, %{"id" => id}) do
  post = Repo.get!(Post, id)
  render(conn, :show, post: post)
end
```

In templates, access via `@variable`:

```heex
<h1><%= @post.title %></h1>
<p><%= @post.body %></p>
```

### Render JSON

```elixir
def index(conn, _params) do
  posts = Repo.all(Post)
  json(conn, posts)
end

# Custom JSON response
def create(conn, params) do
  case create_post(params) do
    {:ok, post} -> json(conn, %{data: post, status: "created"})
    {:error, changeset} -> json(conn, %{errors: changeset.errors})
  end
end
```

### Render Plain Text

```elixir
def text_response(conn, _params) do
  text(conn, "Hello, World!")
end
```

## Redirecting

Redirect to other routes using verified routes:

```elixir
def create(conn, %{"post" => post_params}) do
  case Repo.insert(Post.changeset(%Post{}, post_params)) do
    {:ok, post} ->
      conn
      |> put_flash(:info, "Post created!")
      |> redirect(to: ~p"/posts/#{post.id}")
    {:error, changeset} ->
      render(conn, :new, changeset: changeset)
  end
end
```

External redirects:

```elixir
redirect(conn, external: "https://example.com")
```

## Flash Messages

Temporarily store messages that persist across a redirect:

```elixir
conn
|> put_flash(:info, "Post created successfully!")
|> redirect(to: ~p"/posts")

# In template, display with Phoenix.Component.flash/1
<.flash kind={:info} flash={@flash} />
```

Flash message types:

- `:info` — General information (blue)
- `:warning` — Warnings (yellow)
- `:error` — Errors (red)

## Response Customization

Manipulate low-level response details:

```elixir
def custom_response(conn, _params) do
  conn
  |> put_resp_content_type("text/csv")
  |> put_status(201)
  |> send_resp(200, "Custom response body")
end

def not_found(conn, _params) do
  put_status(conn, :not_found)
end
```

## Views and Templates

Phoenix 1.8 uses function components and HEEx for templates. Views are modules that organize rendering logic:

```elixir
defmodule MyappWeb.PostHTML do
  use MyappWeb, :html

  def index(assigns) do
    ~H"""
    <h1>Posts</h1>
    <%= for post <- @posts do %>
      <div>
        <h2><%= post.title %></h2>
        <p><%= post.body %></p>
      </div>
    <% end %>
    """
  end

  def show(assigns) do
    ~H"""
    <h1><%= @post.title %></h1>
    <p><%= @post.body %></p>
    """
  end
end
```

## Layouts

Layouts wrap template content with shared HTML structure:

```heex
<!-- lib/myapp_web/components/layouts/root.html.heex -->
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title><%= @page_title %></title>
  </head>
  <body>
    <header>Navigation</header>
    <%= @inner_content %>
    <footer>Footer</footer>
  </body>
</html>
```

Set layout in controller:

```elixir
def index(conn, _params) do
  conn
  |> put_layout(html: MyappWeb.Layouts)
  |> render(:index)
end
```

## Function Components

Reusable template components using `slot` and assigns:

```elixir
defmodule MyappWeb.Components do
  use Phoenix.Component

  attr :label, :string, required: true
  attr :type, :string, default: "text"

  def input(assigns) do
    ~H"""
    <div>
      <label><%= @label %></label>
      <input type={@type} />
    </div>
    """
  end

  slot :inner_block, required: true
  attr :class, :string, default: ""

  def card(assigns) do
    ~H"""
    <div class={["card", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end

# Usage in templates
<.input label="Username" />
<.card class="highlight">
  Card content
</.card>
```

## Template Syntax

HEEx combines HTML with Elixir:

```heex
<!-- Interpolation -->
<p><%= @variable %></p>

<!-- Conditionals -->
<%= if @user do %>
  <p>Welcome, <%= @user.name %>!</p>
<% end %>

<!-- Iteration -->
<ul>
  <%= for item <- @items do %>
    <li><%= item.name %></li>
  <% end %>
</ul>

<!-- Verified route links -->
<a href={~p"/posts/#{@post.id}"}>View Post</a>

<!-- Comments -->
<%!-- This won't render --%>
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
