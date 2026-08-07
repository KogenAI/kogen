# phoenix - Controllers & Actions

## Core Concept

Phoenix controllers serve as intermediary modules between routers and views. Their functions—called actions—respond to HTTP requests by gathering data and either rendering templates or returning responses like JSON. Controllers follow a simple pattern-matching design for clean, explicit code.

## Standard Action Conventions

Phoenix follows REST conventions for action naming:

- **index**: displays all items of a resource type
- **show**: renders a single item by ID
- **new**: displays a form for creating items
- **create**: processes and saves new item data
- **edit**: retrieves an item and displays it in an edit form
- **update**: processes and saves edited item data
- **delete**: removes an item from storage

Following these conventions makes your codebase predictable and consistent.

## Action Signatures

Every action receives two parameters:

1. **conn**: A struct containing request details (host, path, port, query string, parameters)
2. **params**: A map of HTTP request parameters

Pattern matching on parameters is recommended for clean, explicit code:

```elixir
def create(conn, %{"post" => post_params}) do
  # post_params is already extracted from the params map
  # ...
end
```

This pattern extracts nested parameters directly in the function signature.

## Rendering HTML Templates

Template rendering is the standard approach for returning HTML:

```elixir
def show(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  render(conn, :show, post: post)
end
```

Pass data to templates using keyword arguments. The view receives these as assigns prefixed with `@`:

```elixir
render(conn, :show, messenger: messenger, receiver: receiver)
```

In the template, access as `@messenger` and `@receiver`.

## Alternative Rendering

**Text responses:**

```elixir
def health(conn, _params) do
  text(conn, "OK")
end
```

**JSON responses:**

```elixir
def index(conn, _params) do
  users = Repo.all(User)
  json(conn, users)
end
```

**Raw HTML without templates:**

```elixir
def special(conn, _params) do
  conn
  |> put_resp_content_type("text/html")
  |> send_resp(200, "<h1>Custom HTML</h1>")
end
```

## Passing Data to Templates

Multiple approaches work depending on your preference:

**Keyword arguments (most readable):**

```elixir
render(conn, :show, messenger: messenger)
```

**Pipe with assign:**

```elixir
conn |> assign(:key, value) |> render(:show)
```

**Multiple assigns chained:**

```elixir
conn
|> assign(:messenger, "Alice")
|> assign(:receiver, "Bob")
|> render(:show)
```

The assigns become available as `@messenger` and `@receiver` in the template.

## Redirection

Redirects use verified routes for security and maintainability:

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

For external redirects:

```elixir
redirect(conn, external: "https://example.com")
```

## Flash Messages

Flash messages are temporary user communications that persist across a single redirect:

```elixir
conn
|> put_flash(:error, "Something went wrong")
|> redirect(to: ~p"/posts")
```

Display flash messages in your layout template using:

```elixir
<.flash_group flash={@flash} />
```

Common flash keys are `:info`, `:warning`, and `:error`.

## Connection State

The `conn` parameter represents the connection state. Transform it through the pipeline:

```elixir
conn
|> assign(:current_user, user)
|> put_resp_header("x-custom", "value")
|> render(:show)
```

Every function must return a transformed `conn` struct—this is what gets sent to the browser.

## Best Practices

- **Pattern match parameters**: Extract expected parameters in the function signature
- **Use verified routes**: Always use `~p"/path"` for redirects and route generation
- **Handle errors explicitly**: Return error responses with appropriate HTTP status codes
- **Keep actions focused**: Each action should do one thing—fetch data, validate input, or render
- **Use changesets for data**: Leverage Ecto changesets for validation before persistence
