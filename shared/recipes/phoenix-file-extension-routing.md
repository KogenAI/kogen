# Recipe: Phoenix File Extension Routing Patterns

## Problem

Phoenix doesn't natively support file extensions in dynamic route parameters (e.g., `/d/:id.md` doesn't work). This is a common need for:

- API endpoints with format extensions (`.json`, `.xml`, `.md`)
- SEO-friendly URLs matching Rails-style patterns
- Content-type specific routing alongside regular Phoenix routes
- LLM integration endpoints requiring clean markdown URLs

## Solution

Use Phoenix plug interceptors with binary pattern matching to handle file extension requests before they reach the router. This approach provides clean URLs while maintaining Phoenix's routing architecture.

## Implementation

### Step 1: Create Binary Pattern Matching Interceptor

```elixir
defmodule MyAppWeb.Plugs.MarkdownInterceptor do
  @moduledoc """
  Minimal interceptor that handles `.md` file extension requests.

  Only intercepts requests matching specific patterns and routes them
  to dedicated controllers. All other requests pass through unchanged.
  """

  import Plug.Conn
  alias Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.path_info do
      # Binary pattern match for exactly 8 chars + ".md"
      ["d", <<short_id::binary-size(8), ".md">>] ->
        conn
        |> put_resp_content_type("text/markdown")
        |> MyAppWeb.MarkdownController.show(%{"short_id" => short_id})
        |> halt()

      # Handle index.md pattern
      ["index.md"] ->
        conn
        |> put_resp_content_type("text/markdown")
        |> MyAppWeb.MarkdownController.index(%{})
        |> halt()

      # Pass through all other requests unchanged
      _path ->
        conn
    end
  end
end
```

### Step 2: Add Interceptor to Pipeline

```elixir
# In router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug MyAppWeb.Plugs.MarkdownInterceptor  # Add before routing
    # ... other plugs
  end

  # Alternative: Create dedicated pipeline for markdown
  pipeline :markdown do
    plug :accepts, ["markdown", "text"]
    plug :put_resp_content_type, "text/markdown"
  end

  # Regular routes continue to work normally
  scope "/", MyAppWeb do
    pipe_through :browser
    live "/d/:short_id", DropLive.Show, :show  # Coexists with .md version
  end

  # Optional: Dedicated scope for markdown pipeline
  scope "/", MyAppWeb do
    pipe_through :markdown
    get "/index.md", MarkdownController, :index
  end
end
```

### Step 3: Create Dedicated Controller

```elixir
defmodule MyAppWeb.MarkdownController do
  use MyAppWeb, :controller

  def show(conn, %{"short_id" => short_id}) do
    case MyApp.Content.get_by_short_id(short_id) do
      nil -> send_not_found(conn)
      content -> serve_markdown(conn, format_content(content))
    end
  end

  def index(conn, _params) do
    content = MyApp.Content.list_all()
    serve_markdown(conn, format_index(content))
  end

  defp serve_markdown(conn, content) do
    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> text(content)
  end

  defp send_not_found(conn) do
    conn
    |> put_status(404)
    |> text("# Content Not Found\n\nThe requested content does not exist.")
  end
end
```

## Considerations

### Performance

- **Interceptor Overhead**: Minimal - only pattern matches against path_info
- **Binary Pattern Matching**: Highly efficient for fixed-length IDs
- **Early Termination**: Uses `halt()` to prevent further processing
- **Caching**: Add ETS or other caching for content-heavy endpoints

### Security

- **Input Validation**: Binary pattern matching provides built-in size validation
- **Content-Type Headers**: Always set appropriate content types
- **XSS Prevention**: Use `x-content-type-options: nosniff` for text content

### Maintenance

- **Route Coexistence**: LiveView and controller routes work side-by-side
- **Testing Strategy**: Test interceptor independently from controllers
- **Error Handling**: Graceful fallbacks for malformed requests

## Example Usage

### Basic Pattern Matching

```elixir
# Matches exactly: /d/abc12345.md (8 chars + .md)
["d", <<short_id::binary-size(8), ".md">>]

# Matches: /api/resource.json
["api", <<resource::binary, ".json">>]

# Variable length with validation
["docs", <<filename::binary, ".md">>] when byte_size(filename) >= 3
```

### Multiple Format Support

```elixir
def call(conn, _opts) do
  case conn.path_info do
    ["api", "data.json"] ->
      serve_json(conn)

    ["api", "data.xml"] ->
      serve_xml(conn)

    ["d", <<id::binary-size(8), ".md">>] ->
      serve_markdown(conn, id)

    _path ->
      conn
  end
end
```

### Flexible ID Patterns

```elixir
# UUID pattern (36 chars)
["uuid", <<uuid::binary-size(36), ".json">>]

# Variable length with constraints
["slug", <<slug::binary, ".html">>] when byte_size(slug) > 2 and byte_size(slug) < 50
```

## Related Recipes

- [ETS Content Cache](ets-content-cache.md)
- [Phoenix Verified Routes Dynamic](phoenix-verified-routes-dynamic.md)
- [Phoenix Pipeline Architecture](phoenix-pipeline-architecture.md)
