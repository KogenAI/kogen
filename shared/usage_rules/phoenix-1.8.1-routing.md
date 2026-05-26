# Phoenix 1.8.1 - Routing & Request Handling

## Core Concepts

The Phoenix router serves as the central hub for applications, matching HTTP requests to controller actions and managing pipeline transformations. Routing happens in the router file at `lib/hello_web/router.ex`. Phoenix routers compile routes into highly optimized pattern-matching case statements at compile time, enabling both performance and verified route checking.

## HTTP Verb Macros

Phoenix provides macros corresponding to HTTP verbs:

```elixir
# Basic route definitions
get "/posts", PostController, :index
post "/posts", PostController, :create
put "/posts/:id", PostController, :update
patch "/posts/:id", PostController, :update
delete "/posts/:id", PostController, :delete
```

Available verbs: GET, POST, PUT, PATCH, DELETE, OPTIONS, CONNECT, TRACE, and HEAD. Using macros enables compile-time optimization and support for verified route checking.

## Resources & CRUD Operations

The `resources` macro generates standard CRUD operations automatically:

```elixir
resources "/users", UserController
# Generates: index, create, show, edit, update, delete, new routes
```

Filter generated routes with `:only` or `:except` options:

```elixir
resources "/posts", PostController, only: [:index, :show]
resources "/admin", AdminController, except: [:delete]
```

## Verified Routes with Sigils

Use the `~p` sigil for compile-time route validation:

```elixir
<.link href={~p"/posts/#{post.id}"}>View Post</.link>
```

The `~p` sigil ensures paths stay synchronized with router definitions, catching broken links and invalid routes at compile time rather than at runtime.

## Path Parameters

Parameters in routes are extracted as a map in controller params:

```elixir
# Router
get "/posts/:id", PostController, :show

# Controller
def show(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  render(conn, "show.html", post: post)
end
```

Multiple parameters work the same way:

```elixir
get "/users/:user_id/posts/:post_id", PostController, :show
# Params: %{"user_id" => "1", "post_id" => "42"}
```

## Scopes for Organization

Scopes group routes under common path prefixes and pipelines:

```elixir
scope "/admin", HelloWeb.Admin do
  pipe_through :browser
  resources "/reviews", ReviewController
  resources "/users", UserController
end
```

Scopes also enable namespace separation for controller modules, helping organize large applications.

## Pipelines for Cross-Cutting Concerns

Pipelines apply sequences of plugs to route groups:

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

scope "/", HelloWeb do
  pipe_through :browser
  resources "/posts", PostController
end

scope "/api", HelloWeb.Api do
  pipe_through :api
  resources "/posts", PostController
end
```

Default pipelines include `:browser` and `:api`. Custom pipelines handle authentication, authorization, and other concerns. Pipelines can be composed by using `pipe_through` multiple times.

## Request Flow

1. HTTP request arrives at the router
2. Router matches against defined routes using compiled pattern matching
3. Matched route's pipeline executes (applies plugs in sequence)
4. Controller action executes with transformed connection
5. Response sent to client

## Best Practices

- Use `resources` macro for RESTful operations rather than defining routes manually
- Use `~p` sigil in templates and redirects to ensure route consistency
- Keep pipelines focused on single responsibilities (browser vs API)
- Organize large routers with scopes for clarity and module organization
- Define custom pipelines for authentication-required routes
- Use meaningful parameter names (`:user_id`, `:post_id`) for clarity

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
