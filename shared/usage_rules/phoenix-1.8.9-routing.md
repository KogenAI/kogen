# phoenix - Routing & URLs

## Core Concepts

Phoenix routers are central hubs that match HTTP requests to controller actions and manage pipeline transformations. The router file (`lib/hello_web/router.ex`) organizes your application's endpoints. Routers provide compile-time verification of routes, preventing broken links and typos.

## HTTP Verbs

Phoenix provides macros for all standard HTTP methods:

- `get`, `post`, `put`, `patch`, `delete`, `options`, `connect`, `trace`, `head`

A basic route looks like:

```elixir
get "/", PageController, :home
```

This matches GET requests to "/" and dispatches to the PageController's home action.

## RESTful Resources

The `resources` macro generates eight standard RESTful routes (index, new, create, show, edit, update, delete) for a given controller:

```elixir
resources "/posts", PostController
```

This generates:

- `GET /posts` → index
- `GET /posts/new` → new
- `POST /posts` → create
- `GET /posts/:id` → show
- `GET /posts/:id/edit` → edit
- `PUT /posts/:id` → update
- `DELETE /posts/:id` → delete

Filter routes with `:only` and `:except` options:

```elixir
resources "/posts", PostController, only: [:index, :show]
resources "/comments", CommentController, except: [:delete]
```

## Verified Routes

Phoenix's `~p` sigil provides compile-time route verification, preventing broken links and typos:

```elixir
~p"/users/17"
~p"/users/17?admin=true&active=false"
url(~p"/users")  # Returns full URL with host
```

Using verified routes is strongly recommended for all route generation, as the compiler ensures they exist.

## Nested Resources

Resources can nest to represent relationships. For posts belonging to users:

```elixir
resources "/users", UserController do
  resources "/posts", PostController
end
```

This generates routes like:

- `GET /users/:user_id/posts` → posts index
- `GET /users/:user_id/posts/:id` → post show

Use nesting judiciously—deeply nested routes become difficult to maintain.

## Scopes

Group related routes under path prefixes and controller namespaces:

```elixir
scope "/admin", HelloWeb.Admin do
  pipe_through :browser
  resources "/reviews", ReviewController
end
```

This routes `/admin/reviews` to `HelloWeb.Admin.ReviewController`.

Scopes can also organize routes without changing paths:

```elixir
scope "/", HelloWeb do
  pipe_through :browser
  resources "/posts", PostController
end
```

## Pipelines

Pipelines apply plugs (middleware) to specific routes. Default pipelines include:

- `:browser` - for HTML requests (includes session and CSRF protection)
- `:api` - for API/JSON requests

```elixir
scope "/", HelloWeb do
  pipe_through :browser
  get "/", PageController, :home
end

scope "/api", HelloWeb do
  pipe_through :api
  resources "/users", Api.UserController
end
```

Create custom pipelines for specific needs:

```elixir
pipeline :admin do
  plug :browser
  plug MyApp.Plugs.Admin
end
```

## Best Practices

- **Organize by pipeline**: Group routes by their authentication/middleware requirements
- **Use verified routes**: Always use `~p"/path"` sigil for compile-time safety
- **Limit nesting**: Keep resource nesting to one or two levels maximum
- **RESTful design**: Follow REST conventions for resource-oriented routes
- **Separate concerns**: Use different scopes for API and web routes
