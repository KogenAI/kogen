# phoenix - JSON APIs & Error Handling

## Building JSON APIs

Phoenix Framework supports building Web APIs with JSON by default. The framework treats JSON responses as first-class citizens through view modules, parameter handling, and error rendering.

### JSON API Scaffolding

Generate complete API infrastructure with the `mix phx.gen.json` command:

```bash
mix phx.gen.json Links Url urls title:string description:text
```

This generates:

- Web layer: JSON views and controllers for rendering API responses
- Context layer: Business logic for querying and persisting data
- Database layer: Schema and migrations
- Tests: Integration tests for API endpoints

### Minimal API Application

For API-only projects without HTML or assets:

```bash
mix phx.new my_api --no-html --no-assets --no-mailer
```

## JSON Rendering

### View Modules

Views convert domain objects into simple Elixir maps that Phoenix encodes to JSON using the Jason library:

```elixir
defmodule HelloWeb.UrlJSON do
  alias Hello.Links.Url

  def index(%{urls: urls}) do
    %{data: render_many(urls, __MODULE__, "url.json")}
  end

  def show(%{url: url}) do
    %{data: render_one(url, __MODULE__, "url.json")}
  end

  def url(%Url{} = url) do
    %{
      id: url.id,
      title: url.title,
      description: url.description,
      inserted_at: url.inserted_at
    }
  end

  def error(%{changeset: changeset}) do
    %{errors: translate_errors(changeset)}
  end
end
```

The `render_many/3` and `render_one/3` helpers apply a rendering function across collections or single items.

### JSON Controller Actions

Controllers generate JSON responses automatically when the `:json` format is requested:

```elixir
defmodule HelloWeb.UrlController do
  use HelloWeb, :controller

  def index(conn, _params) do
    urls = Links.list_urls()
    render(conn, :index, urls: urls)
  end

  def show(conn, %{"id" => id}) do
    url = Links.get_url!(id)
    render(conn, :show, url: url)
  end

  def create(conn, %{"url" => url_params}) do
    case Links.create_url(url_params) do
      {:ok, url} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/urls/#{url}")
        |> render(:show, url: url)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(HelloWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end
end
```

### Content Negotiation

Configure router pipelines to handle format negotiation:

```elixir
pipeline :api do
  plug :accepts, ["json"]
end

scope "/api" do
  pipe_through :api
  resources "/urls", UrlController
end
```

Clients request JSON via the `Accept: application/json` header or `?_format=json` query parameter.

## Parameter Handling

Request parameters merge from multiple sources with this priority:

1. Path parameters (`:id` in routes)
2. Request body parameters (POST/PUT body)
3. Query parameters (URL query string)

Access each source separately:

```elixir
def create(conn, params) do
  # params: merged from all sources
  path_params = conn.path_params        # from route :id
  body_params = conn.body_params        # POST/PUT body
  query_params = conn.query_params      # ?key=value
end
```

## Error Management

### Validation Errors

Changesets define validation rules; when validation fails, the API returns structured error information:

```elixir
defmodule HelloWeb.ChangesetJSON do
  def error(%{changeset: changeset}) do
    %{errors: translate_errors(changeset)}
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

Response example:

```json
{
  "errors": {
    "title": ["can't be blank"],
    "description": ["is too short (minimum is 5 characters)"]
  }
}
```

### Error Fallback Pattern

Controllers can centralize error handling using the `action_fallback` macro. This delegates error responses to specialized fallback controllers:

```elixir
defmodule HelloWeb.FallbackController do
  use HelloWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(HelloWeb.ErrorJSON)
    |> render(:error, %{message: "Resource not found"})
  end

  def call(conn, {:error, changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(HelloWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end
end

defmodule HelloWeb.UrlController do
  use HelloWeb, :controller
  action_fallback HelloWeb.FallbackController

  def show(conn, %{"id" => id}) do
    url = Links.get_url(id)
    case url do
      nil -> {:error, :not_found}
      url -> render(conn, :show, url: url)
    end
  end
end
```

This pattern reduces code duplication and centralizes API error responses.

## Status Codes and Headers

### HTTP Status Codes

Set appropriate status codes for API responses:

```elixir
# Success
put_status(conn, :ok)               # 200
put_status(conn, :created)          # 201
put_status(conn, :no_content)       # 204

# Client errors
put_status(conn, :bad_request)      # 400
put_status(conn, :unauthorized)     # 401
put_status(conn, :forbidden)        # 403
put_status(conn, :not_found)        # 404

# Server errors
put_status(conn, :unprocessable_entity)  # 422
put_status(conn, :internal_server_error) # 500
```

### Response Headers

```elixir
# Location header for created resources
put_resp_header(conn, "location", ~p"/api/urls/#{url.id}")

# Content type (usually automatic)
put_resp_content_type(conn, "application/json")

# CORS headers
put_resp_header(conn, "access-control-allow-origin", "*")
```

## Common API Patterns

### List with Pagination

```elixir
def index(conn, %{"page" => page, "per_page" => per_page}) do
  page = String.to_integer(page)
  per_page = String.to_integer(per_page)

  paginated_urls = Links.list_urls(offset: (page - 1) * per_page, limit: per_page)
  total = Links.count_urls()

  render(conn, :index, urls: paginated_urls, total: total, page: page)
end
```

### Filtering

```elixir
def index(conn, %{"status" => status}) do
  urls = Links.list_urls(status: status)
  render(conn, :index, urls: urls)
end
```

### Bulk Operations

```elixir
def create_batch(conn, %{"urls" => urls_params}) do
  case Links.create_many(urls_params) do
    {:ok, urls} ->
      render(conn, :created_batch, urls: urls)
    {:error, errors} ->
      conn
      |> put_status(:unprocessable_entity)
      |> render(:errors, errors: errors)
  end
end
```

## Best Practices

- **Use generators**: `mix phx.gen.json` scaffolds tested, production-ready API code.
- **Consistent response format**: Wrap all JSON responses in consistent envelopes (e.g., `{data: [...], errors: [...]}`).
- **Meaningful status codes**: Use HTTP status codes semantically to indicate success, client errors, and server errors.
- **Document error responses**: Provide clear error messages and error codes for API consumers to handle failures gracefully.
- **Validation before persistence**: Validate changesets before database operations to catch errors early.
- **Implement pagination**: For list endpoints, provide pagination parameters to prevent overwhelming responses.

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
