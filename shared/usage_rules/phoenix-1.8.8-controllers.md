# phoenix - Controllers & Rendering

## Core Concepts

Controllers are modules containing action functions that respond to HTTP requests. They build on the Plug package and serve as intermediaries between routers and views. Each action receives two parameters: `conn` (the request struct) and `params` (HTTP request parameters including query strings, body, and path segments).

```elixir
defmodule HelloWeb.PageController do
  use HelloWeb, :controller

  def home(conn, params) do
    render(conn, :home)
  end
end
```

## RESTful Action Conventions

Standard action names follow REST conventions:

| Action   | Purpose                         | HTTP Verb |
| -------- | ------------------------------- | --------- |
| `index`  | Render list of all items        | GET       |
| `show`   | Render individual item by ID    | GET       |
| `new`    | Display form for creating items | GET       |
| `create` | Save new item to data store     | POST      |
| `edit`   | Display item in edit form       | GET       |
| `update` | Save edited item                | PUT/PATCH |
| `delete` | Remove item from data store     | DELETE    |

```elixir
def index(conn, _params) do
  posts = Repo.all(Post)
  render(conn, :index, posts: posts)
end

def show(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  render(conn, :show, post: post)
end

def create(conn, %{"post" => post_params}) do
  changeset = Post.changeset(%Post{}, post_params)
  case Repo.insert(changeset) do
    {:ok, post} ->
      conn
      |> put_flash(:info, "Post created successfully")
      |> redirect(to: ~p"/posts/#{post}")
    {:error, changeset} ->
      render(conn, :new, changeset: changeset)
  end
end
```

## Rendering Methods

### Template Rendering

The primary method uses `render/2` or `render/3`:

```elixir
render(conn, :home)
render(conn, :show, post: @post)
```

The controller name determines the view module: `PageController` → `PageHTML`. Templates live in `lib/hello_web/controllers/page_html/` with `.html.heex` extension.

### Text and JSON

For simple responses without templates:

```elixir
text(conn, "Hello, World!")
json(conn, %{message: "Hello", id: 123})
```

### Multiple Formats

Support different formats by configuring view modules:

```elixir
defmodule HelloWeb.PostHTML do
  use HelloWeb, :html
  # HTML-specific components
end

defmodule HelloWeb.PostJSON do
  def show(%{post: post}) do
    %{id: post.id, title: post.title, body: post.body}
  end
end
```

Users can request formats via query parameter `?_format=json` or accept headers. Configure in router pipelines to handle format negotiation.

## Response Manipulation

### Status Codes

```elixir
put_status(conn, :not_found)
put_status(conn, 404)
```

### Content Type

```elixir
put_resp_content_type(conn, "text/plain")
put_resp_content_type(conn, "application/json")
```

### Raw Responses

```elixir
send_resp(conn, 200, "Hello, World!")
```

### Assigns for Templates

Pass data to templates via `assign/3`:

```elixir
def show(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  conn
  |> assign(:post, post)
  |> assign(:user, conn.assigns[:current_user])
  |> render(:show)
end
```

Or use a map:

```elixir
render(conn, :show, post: post, user: current_user)
```

## Navigation & Messaging

### Redirects

```elixir
redirect(conn, to: ~p"/posts")
redirect(conn, external: "https://example.com")
```

### Flash Messages

Flash messages persist across one redirect for user feedback:

```elixir
put_flash(conn, :info, "Post created successfully")
put_flash(conn, :error, "Something went wrong")
clear_flash(conn)
```

Access in templates:

```html
<%= if flash[:info] do %>
<div><%= flash[:info] %></div>
<% end %>
```

## Parameter Extraction

Use pattern matching in action signatures to extract parameters:

```elixir
def show(conn, %{"id" => id, "tab" => tab}) do
  # id and tab are automatically extracted
  render(conn, :show, id: id, tab: tab)
end

def delete(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  Repo.delete(post)
  redirect(conn, to: ~p"/posts")
end
```

Query parameters and request body parameters are merged into the `params` map automatically.

## Common Patterns

### Error Fallback

Use `action_fallback/1` to centralize error handling:

```elixir
defmodule HelloWeb.FallbackController do
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: HelloWeb.ErrorJSON)
    |> render(:error, message: "Not found")
  end
end

defmodule HelloWeb.PostController do
  action_fallback HelloWeb.FallbackController

  def show(conn, %{"id" => id}) do
    Post |> Repo.get(id) |> case do
      nil -> {:error, :not_found}
      post -> render(conn, :show, post: post)
    end
  end
end
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
