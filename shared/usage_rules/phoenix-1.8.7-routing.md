# Phoenix - Request Lifecycle & Routing

## Request Flow Architecture

Phoenix processes HTTP requests through a layered pipeline:

1. **Endpoint** (`Phoenix.Endpoint`) — All requests enter here, applying plugs for cross-cutting concerns like logging, session management, and CSRF protection
2. **Router** — Maps HTTP verb/path combinations to controller actions
3. **Controller** — Retrieves request data and orchestrates business logic
4. **View** — Converts structured data into rendered output (HTML, JSON, etc.)

This separation allows each layer to evolve independently. Endpoints handle infrastructure concerns, routers manage dispatch, controllers orchestrate operations, and views focus on presentation.

## Routing Basics

Routes define how URLs map to controller actions. Basic syntax:

```elixir
get "/hello", HelloController, :index
post "/users", UserController, :create
put "/users/:id", UserController, :update
delete "/users/:id", UserController, :delete
```

The router supports multiple HTTP verbs (`get`, `post`, `put`, `patch`, `delete`, `options`, `head`) and optional `:id` path segments captured as route parameters.

## Dynamic Segments

Capture URL portions as parameters using colon notation:

```elixir
get "/users/:id", UserController, :show
get "/posts/:post_id/comments/:id", CommentController, :show
```

Parameters are passed to controller actions via the `params` map. Access with pattern matching:

```elixir
def show(conn, %{"id" => id}) do
  user = Repo.get(User, id)
  render(conn, :show, user: user)
end
```

## Controllers

Controllers are Elixir modules where each action function receives two arguments:

- `conn` — Request connection, carrying request data and providing response functions
- `params` — URL parameters and form data

Actions typically call `render/2` or `render/3` to display templates. The view module is inferred from the controller name by convention—`HelloController` routes to `HelloView`.

```elixir
defmodule MyApp.HelloController do
  use MyApp, :controller

  def index(conn, _params) do
    render(conn, :index)
  end

  def show(conn, %{"messenger" => messenger}) do
    render(conn, :show, messenger: messenger)
  end
end
```

Controllers can also return other response types without rendering templates:

```elixir
def json_api(conn, _params) do
  json(conn, %{status: "ok"})
end

def redirect_away(conn, _params) do
  redirect(conn, to: "https://example.com")
end
```

## Router Organization

For large applications, organize routes into scopes and pipelines:

```elixir
scope "/api", MyApp do
  pipe_through :api

  post "/users", UserController, :create
  get "/users/:id", UserController, :show
end

scope "/admin", MyApp.Admin do
  pipe_through [:browser, :require_admin]

  resources :posts
  resources :comments
end
```

Pipelines apply plugs to all routes in the scope:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end

pipeline :require_admin do
  plug MyApp.Plugs.RequireAdmin
end
```

## Verified Routes

Phoenix provides compile-time route verification using the `~p` sigil:

```elixir
~p"/users/#{user.id}"
~p"/posts/#{post.id}/edit"
~p"/"
```

The sigil ensures routes exist at compile time, preventing broken links in views and controllers.

## Resources

For RESTful endpoints, use the `resources/2` macro:

```elixir
resources :users
```

This generates eight routes for standard CRUD operations:

| Verb   | Path            | Action  | Route name     |
| ------ | --------------- | ------- | -------------- |
| GET    | /users          | :index  | users_path     |
| GET    | /users/new      | :new    | new_user_path  |
| POST   | /users          | :create | users_path     |
| GET    | /users/:id      | :show   | user_path(id)  |
| GET    | /users/:id/edit | :edit   | edit_user_path |
| PUT    | /users/:id      | :update | user_path(id)  |
| PATCH  | /users/:id      | :update | user_path(id)  |
| DELETE | /users/:id      | :delete | user_path(id)  |

Customize with `only` and `except` options:

```elixir
resources :posts, only: [:index, :show]
resources :comments, except: [:delete]
```

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
