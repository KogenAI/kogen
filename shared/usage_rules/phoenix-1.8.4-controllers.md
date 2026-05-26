# phoenix - Controllers & Actions

## Controller Basics

Controllers are modules that receive HTTP requests via the router, process data through business logic, and return responses. Phoenix controllers are themselves plugs, building on Elixir's composable middleware framework. Each action receives two parameters: `conn` (the request information) and `params` (HTTP parameters).

## RESTful Actions

Standard resource controllers implement these seven actions:

```elixir
defmodule HelloWeb.UserController do
  use HelloWeb, :controller

  def index(conn, _params) do
    users = Repo.all(User)
    render(conn, :index, users: users)
  end

  def show(conn, %{"id" => id}) do
    user = Repo.get!(User, id)
    render(conn, :show, user: user)
  end

  def new(conn, _params) do
    changeset = User.changeset(%User{}, %{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Repo.insert(User.changeset(%User{}, user_params)) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "User created!")
        |> redirect(to: ~p"/users/#{user}")
      {:error, changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    user = Repo.get!(User, id)
    changeset = User.changeset(user, %{})
    render(conn, :edit, user: user, changeset: changeset)
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    user = Repo.get!(User, id)
    case Repo.update(User.changeset(user, user_params)) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "User updated!")
        |> redirect(to: ~p"/users/#{user}")
      {:error, changeset} ->
        render(conn, :edit, user: user, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Repo.get!(User, id)
    Repo.delete!(user)
    conn
    |> put_flash(:info, "User deleted!")
    |> redirect(to: ~p"/users")
  end
end
```

## Rendering Responses

**Text Response:**

```elixir
def show(conn, %{"messenger" => messenger}) do
  text(conn, "From messenger #{messenger}")
end
```

**JSON Response:**

```elixir
def show(conn, %{"messenger" => messenger}) do
  json(conn, %{id: messenger, message: "hello"})
end
```

**Template Rendering (default):**

```elixir
def show(conn, %{"messenger" => messenger}) do
  render(conn, :show, messenger: messenger)
end
```

The `render/3` looks for a template file matching the action name (`show.html.heex` for `:show` action) in the controller's view directory.

## Assigning Values to Templates

Pass data to templates via `assign/3`:

```elixir
def show(conn, %{"id" => id}) do
  user = Repo.get!(User, id)
  conn
  |> assign(:user, user)
  |> assign(:admin, current_user_admin?(conn))
  |> render(:show)
end
```

Or pipe assignments:

```elixir
def show(conn, %{"id" => id}) do
  render(conn, :show, user: Repo.get!(User, id), admin: true)
end
```

## HTTP Status and Headers

Set custom HTTP status codes:

```elixir
def create(conn, params) do
  conn
  |> put_status(201)
  |> render(:created, data: params)
end

def unauthorized(conn, _params) do
  conn
  |> put_status(401)
  |> json(%{error: "Unauthorized"})
end
```

Add custom headers:

```elixir
put_resp_header(conn, "x-custom-header", "value")
```

## Redirects with Verified Routes

Use the `~p` sigil for type-safe redirects:

```elixir
redirect(conn, to: ~p"/users/#{user.id}")
redirect(conn, to: ~p"/posts?page=2")
```

Full external redirects:

```elixir
redirect(conn, external: "https://example.com")
```

## Flash Messages

Flash messages communicate temporary information across requests (typically for success/error notifications):

```elixir
def create(conn, params) do
  case Repo.insert(Model.changeset(%Model{}, params)) do
    {:ok, resource} ->
      conn
      |> put_flash(:info, "Created successfully!")
      |> redirect(to: ~p"/resources/#{resource}")
    {:error, changeset} ->
      render(conn, :new, changeset: changeset)
  end
end
```

Access flash in templates:

```elixir
<%= if flash = get_flash(@conn, :info) do %>
  <p class="notice"><%= flash %></p>
<% end %>
```

## Controller Plugs

Apply plugs to specific controller actions:

```elixir
defmodule HelloWeb.UserController do
  use HelloWeb, :controller

  plug :require_auth when action in [:edit, :update, :delete]
  plug :load_user when action in [:show, :edit, :update, :delete]

  def show(conn, _params) do
    render(conn, :show, user: conn.assigns.user)
  end

  defp require_auth(conn, _opts) do
    if current_user(conn) do
      conn
    else
      conn
      |> put_flash(:error, "Sign in required")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp load_user(conn, _opts) do
    user = Repo.get!(User, conn.params["id"])
    assign(conn, :user, user)
  end
end
```

## Content Negotiation

Use `accepts/2` plug to handle multiple content types:

```elixir
defmodule HelloWeb.UserController do
  def show(conn, %{"id" => id}) do
    user = Repo.get!(User, id)
    render(conn, :show, user: user)
  end
end
```

The router's pipeline handles `accepts` plug:

```elixir
pipeline :api do
  plug :accepts, ["json"]
end

pipeline :browser do
  plug :accepts, ["html"]
end
```

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
