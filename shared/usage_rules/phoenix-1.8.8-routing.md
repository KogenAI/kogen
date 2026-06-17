# phoenix - Routing & URL Generation

## Core Concepts

Routers are the main hubs of Phoenix applications. They match HTTP requests to controller actions, wire up real-time channel handlers, and define a series of pipeline transformations scoped to a set of routes. Routes compile into optimized case-statements with pattern matching for performance.

## Route Definition Patterns

### HTTP Verb Macros

Phoenix provides macros for each HTTP method: `get`, `post`, `put`, `patch`, `delete`, `options`, `connect`, `trace`, `head`. Basic syntax maps a path to a controller and action:

```elixir
get "/", PageController, :home
post "/users", UserController, :create
put "/posts/:id", PostController, :update
delete "/comments/:id", CommentController, :delete
```

### Resource Routes

The `resources/4` macro generates eight standard CRUD routes automatically:

```elixir
resources "/posts", PostController
# Generates: index, new, create, show, edit, update, delete
```

Filter with `:only` to include specific actions:

```elixir
resources "/posts", PostController, only: [:index, :show]
```

Or `:except` to exclude actions:

```elixir
resources "/comments", CommentController, except: [:delete]
```

### Verified Routes

Use the `~p` sigil for type-safe path generation:

```elixir
<.link href={~p"/posts/#{@post.id}"}>View Post</.link>
<.link href={~p"/posts"}>All Posts</.link>
```

The compiler catches bugs when routes change. Supports dynamic values, query strings, and external URLs via `url()`:

```elixir
~p"/users?page=#{page}&sort=#{sort}"
url(~p"/posts/#{post.id}")
```

## Scope Organization

Scopes group routes by path prefix and namespace controller modules:

```elixir
scope "/admin", HelloWeb.Admin do
  pipe_through :browser
  resources "/reviews", ReviewController
end
```

This creates routes like `/admin/reviews` with `HelloWeb.Admin.ReviewController`.

### Nested Resources

Represent hierarchical relationships with nested resource syntax:

```elixir
resources "/users", UserController do
  resources "/posts", PostController
end
```

Generates routes like `/users/:user_id/posts/:id` with automatic parameter scoping.

## Pipeline Architecture

Pipelines are plugs composed into sequences that transform connections. Define once, reuse across route scopes:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_flash
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end

pipeline :auth do
  plug HelloWeb.Authentication
end
```

Apply pipelines to route scopes:

```elixir
scope "/" do
  pipe_through [:browser, :auth]
  resources "/admin", AdminController
end

scope "/" do
  pipe_through :api
  resources "/api/posts", API.PostController
end
```

The `:browser` pipeline includes session, flash, and CSRF protection. The `:api` pipeline handles JSON content negotiation. Create custom pipelines for cross-cutting concerns like authentication, logging, or rate limiting.

## Best Practices

- Group authenticated and public routes into separate scopes to show authorization boundaries clearly.
- Create pipelines for each concern (auth, validation, logging) rather than duplicating plug logic.
- Use `:only` and `:except` to limit unused CRUD routes and keep the surface area manageable.
- Name resource routes conventionally to improve discoverability and maintain REST patterns.
- Place nested resources no more than one level deep to avoid complex URLs.

## Routing Inspection

Run `mix phx.routes` to display all defined routes, their HTTP methods, paths, and controller actions:

```bash
$ mix phx.routes
          page_path  GET   /              PageController :home
          post_path  GET   /posts         PostController :index
          post_path  GET   /posts/:id     PostController :show
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
