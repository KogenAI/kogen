# Phoenix 1.8.1 - Controllers & Actions

## Core Concept

Controllers are intermediary modules that handle HTTP requests. Their functions—called actions—receive requests from the router, gather necessary data, and invoke the view layer or return responses. Controllers receive two parameters: `conn` (the connection struct holding request information) and `params` (HTTP request parameters as a map).

## Standard RESTful Actions

Phoenix conventionally uses seven RESTful actions:

```elixir
defmodule HelloWeb.PostController do
  use HelloWeb, :controller

  # Lists all posts
  def index(conn, _params) do
    posts = Repo.all(Post)
    render(conn, "index.html", posts: posts)
  end

  # Shows a single post
  def show(conn, %{"id" => id}) do
    post = Repo.get!(Post, id)
    render(conn, "show.html", post: post)
  end

  # Displays form for creating a post
  def new(conn, _params) do
    changeset = Post.changeset(%Post{})
    render(conn, "new.html", changeset: changeset)
  end

  # Saves new post to storage
  def create(conn, %{"post" => post_params}) do
    changeset = Post.changeset(%Post{}, post_params)
    case Repo.insert(changeset) do
      {:ok, post} ->
        conn
        |> put_flash(:info, "Post created successfully.")
        |> redirect(to: ~p"/posts/#{post}")
      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  # Displays form for editing a post
  def edit(conn, %{"id" => id}) do
    post = Repo.get!(Post, id)
    changeset = Post.changeset(post)
    render(conn, "edit.html", post: post, changeset: changeset)
  end

  # Updates post data
  def update(conn, %{"id" => id, "post" => post_params}) do
    post = Repo.get!(Post, id)
    changeset = Post.changeset(post, post_params)
    case Repo.update(changeset) do
      {:ok, post} ->
        conn
        |> put_flash(:info, "Post updated successfully.")
        |> redirect(to: ~p"/posts/#{post}")
      {:error, changeset} ->
        render(conn, "edit.html", post: post, changeset: changeset)
    end
  end

  # Removes post from storage
  def delete(conn, %{"id" => id}) do
    post = Repo.get!(Post, id)
    Repo.delete(post)
    conn
    |> put_flash(:info, "Post deleted successfully.")
    |> redirect(to: ~p"/posts")
  end
end
```

## Rendering Responses

Controllers support multiple rendering approaches:

```elixir
# HTML template rendering
def show(conn, %{"id" => id}) do
  post = Repo.get!(Post, id)
  render(conn, "show.html", post: post)
end

# JSON API responses
def show(conn, %{"id" => id}) do
  post = Repo.get!(Post, id)
  json(conn, post)
end

# Plain text responses
def metrics(conn, _params) do
  text(conn, "application metrics here")
end

# Custom status codes
def create(conn, %{"user" => user_params}) do
  changeset = User.changeset(%User{}, user_params)
  case Repo.insert(changeset) do
    {:ok, user} ->
      conn
      |> put_status(:created)
      |> json(user)
    {:error, changeset} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: changeset.errors})
  end
end
```

## Connection Functions

Key functions for managing responses:

```elixir
# Flash messages for user feedback
put_flash(conn, :info, "Operation successful")
put_flash(conn, :error, "Something went wrong")

# HTTP status codes
put_status(conn, 200)
put_status(conn, :created)
put_status(conn, :not_found)

# Redirects
redirect(conn, to: ~p"/posts")
redirect(conn, external: "https://example.com")

# Response headers
put_resp_header(conn, "x-custom", "value")

# Response body transmission
send_resp(conn, 200, "Hello World")
```

## Pattern Matching Parameters

Extract and match parameters directly in function signatures:

```elixir
# Pattern match on specific keys
def show(conn, %{"id" => id}) do
  # id is extracted and bound
end

# Match optional parameters with defaults
def index(conn, %{"page" => page} = params) do
  page = String.to_integer(page)
end

def index(conn, params) do
  # Default: page = 1
end

# Multiple function clauses
def update(conn, %{"post" => post_params, "post_id" => id}) do
  # POST body parsing
end
```

## Error Handling

Handle errors gracefully with Ecto results:

```elixir
def create(conn, %{"post" => post_params}) do
  case Repo.insert(Post.changeset(%Post{}, post_params)) do
    {:ok, post} ->
      conn
      |> put_flash(:info, "Post created")
      |> redirect(to: ~p"/posts/#{post}")
    {:error, changeset} ->
      render(conn, "new.html", changeset: changeset)
  end
end
```

Use `Repo.get!/2` to raise exceptions on missing records, or `Repo.get/2` to return `nil` for optional lookups.

## Best Practices

- Use seven RESTful actions as the standard pattern
- Keep actions focused on a single responsibility
- Extract business logic into context modules (not directly in controllers)
- Use `render/3` for HTML responses and `json/2` for APIs
- Add flash messages for user feedback on create/update/delete operations
- Use `put_status/2` for appropriate HTTP status codes
- Use pattern matching in function signatures for clear parameter handling
- Delegate data fetching to Ecto queries in context modules

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
