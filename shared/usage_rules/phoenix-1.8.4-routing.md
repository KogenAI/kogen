# phoenix - Routing & Routes

## Core Router Concepts

The Phoenix router (`lib/<app>_web/router.ex`) is the central hub for all HTTP requests. It matches incoming requests to controller actions, applies pipelines of plugs for request preprocessing, and enables compile-time route verification. Routes are compiled into an optimized case-statement pattern-matched by the Erlang VM for maximum performance.

## Route Definition

Routes use HTTP verb macros corresponding to standard REST conventions:

```elixir
defmodule HelloWeb.Router do
  use HelloWeb, :router

  scope "/", HelloWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/users/:id", UserController, :show
    post "/users", UserController, :create
    put "/users/:id", UserController, :update
    patch "/users/:id", UserController, :update
    delete "/users/:id", UserController, :delete
  end
end
```

## RESTful Resources

The `resources` macro generates eight standard RESTful routes automatically:

```elixir
resources "/users", UserController
```

Expands to:

- `GET /users` → `index` (list all)
- `GET /users/new` → `new` (show new form)
- `POST /users` → `create` (persist)
- `GET /users/:id` → `show` (display one)
- `GET /users/:id/edit` → `edit` (show edit form)
- `PATCH/PUT /users/:id` → `update` (modify)
- `DELETE /users/:id` → `delete` (remove)

Filter routes with `:only` and `:except` options:

```elixir
resources "/posts", PostController, only: [:index, :show]
resources "/pages", PageController, except: [:new, :create, :edit, :update, :delete]
```

## Verified Routes with the ~p Sigil

Phoenix provides compile-time route verification through the `~p` sigil. This catches routing errors before runtime:

```elixir
~p"/users"                    # => "/users"
~p"/users/17"                 # => "/users/17"
~p"/users/17?admin=true"      # => "/users/17?admin=true"
url(~p"/users")               # => "http://localhost:4000/users" (full URL)
```

Dynamic segments are constructed:

```elixir
user_id = 42
~p"/users/#{user_id}"         # => "/users/42"
~p"/users/#{user_id}/posts"   # => "/users/42/posts"
```

## Nested Resources

Represent hierarchical relationships in routes:

```elixir
resources "/users", UserController do
  resources "/posts", PostController
end
```

Creates routes like `/users/17/posts` and `/users/17/posts/1`. Access nested IDs in controller params as `params["user_id"]` and `params["id"]`.

## Route Scopes

Group routes under common prefixes and apply shared pipelines:

```elixir
scope "/api", HelloWeb.Api do
  pipe_through :api

  resources "/users", UserController
  resources "/posts", PostController
end

scope "/admin", HelloWeb.Admin do
  pipe_through [:browser, :admin_auth]

  resources "/settings", SettingController
end
```

## Pipelines and Plugs

Pipelines are sequences of plugs applied to route groups. Define them at router scope:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {HelloWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end
```

Apply pipelines to scopes:

```elixir
scope "/", HelloWeb do
  pipe_through :browser
  get "/", PageController, :index
end

scope "/api", HelloWeb do
  pipe_through :api
  get "/users", UserController, :index
end
```

## Forward Macro

Delegate all requests matching a path prefix to a specific plug module:

```elixir
forward "/uploads", MyApp.UploadController
```

This is useful for serving static files, handling webhooks from external services, or delegating to sub-routers.

## Match and Wildcard Routes

Define catch-all routes that match any path:

```elixir
match :*, "/*path", HelloWeb.PageController, :not_found
```

Wildcard `*path` captures remaining segments as a list. Place catch-all routes at the end to avoid shadowing more specific routes.

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
