# phoenix 1.8.8 - Complete Usage Rules

> Complete reference documentation extracted from phoenix.hexdocs.pm/1.8.8

## Overview

Phoenix is a server-side web development framework built with Elixir that implements the MVC (Model-View-Controller) pattern. It combines "high developer productivity _and_ high application performance," providing features like channels for real-time communication, pre-compiled HEEx templates, and integrated database support through Ecto. Phoenix handles the complete HTTP request lifecycle—from routing through controllers to rendering views—while maintaining clean separation of concerns.

---

# ROUTING AND REQUEST HANDLING

## Request Lifecycle

When a browser makes an HTTP request to a Phoenix application, it flows through:

1. **Endpoint** — Applies common processing to all requests via plugs
2. **Router** — Maps HTTP verb/path combinations to controller actions
3. **Controller** — Retrieves data and prepares it for presentation
4. **View** — Renders HTML using HEEx templates

## Basic Route Definition

Routes use HTTP verb macros (`get`, `post`, `put`, `patch`, `delete`) in `lib/yourapp_web/router.ex`:

```elixir
defmodule MyappWeb.Router do
  use MyappWeb, :router

  scope "/", MyappWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/hello/:name", HelloController, :show
  end
end
```

## URL Parameters

Dynamic segments use `:variable` syntax and are captured into the params map:

```elixir
# Route definition
get "/posts/:id", PostController, :show

# Controller receives params
def show(conn, %{"id" => id}) do
  post = Repo.get(Post, id)
  render(conn, :show, post: post)
end
```

## Resource Routes

The `resources` macro generates eight standard routes (RESTful pattern):

```elixir
resources "/posts", PostController
# Generates: index, show, new, create, edit, update, delete
```

Filter routes with `:only` or `:except`:

```elixir
resources "/posts", PostController, only: [:index, :show]
```

## Nested Resources

```elixir
resources "/users", UserController do
  resources "/posts", PostController
end
```

## Scoped Routes

```elixir
scope "/admin", MyappWeb.Admin do
  pipe_through :browser
  pipe_through :require_admin

  resources "/posts", PostController
  resources "/users", UserController
end
```

## Verified Routes with `~p`

The `~p` sigil provides compile-time route verification:

```elixir
link("Post", to: ~p"/posts/#{post.id}")
```

## Pipelines

Pipelines are composable chains of plugs:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, {MyappWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

scope "/", MyappWeb do
  pipe_through :browser
  get "/", PageController, :index
end
```

---

# DATABASE AND ECTO MODELS

## Schemas

Schemas map Elixir data structures to database tables:

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :views, :integer, default: 0
    field :published_at, :naive_datetime

    belongs_to :author, MyApp.User
    has_many :comments, MyApp.Comment

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
    |> validate_length(:title, min: 3, max: 100)
  end
end
```

## Field Types

- `:string` — Text
- `:integer` — Whole numbers
- `:float` — Decimal numbers
- `:boolean` — true/false
- `:date` — Date only
- `:time` — Time only
- `:naive_datetime` — DateTime without timezone
- `:utc_datetime` — DateTime with UTC timezone
- `:decimal` — High-precision numbers
- `:binary` — Binary data
- `:json` — JSON documents

## Changesets

Changesets define transformation pipelines:

```elixir
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title, :body, :author_id])
  |> validate_required([:title, :author_id])
  |> validate_length(:title, min: 3)
  |> validate_format(:body, ~r/[a-z]/i)
  |> unique_constraint(:title)
  |> foreign_key_constraint(:author_id)
end
```

## Database Operations

```elixir
# Insert
{:ok, post} = MyApp.Repo.insert(%Post{title: "Hello"})

# Update
changeset = Post.changeset(post, %{"title" => "Updated"})
{:ok, updated_post} = MyApp.Repo.update(changeset)

# Delete
:ok = MyApp.Repo.delete(post)

# Retrieve by ID
post = MyApp.Repo.get(Post, 1)
post = MyApp.Repo.get!(Post, 1)  # Raises if not found

# Retrieve with query
posts = MyApp.Repo.all(Post)
```

## Queries

```elixir
import Ecto.Query

# Simple query
query = from p in Post, select: p
posts = MyApp.Repo.all(query)

# With where clause
query = from p in Post, where: p.author_id == 5, select: p

# Multiple conditions (AND)
query = from p in Post,
  where: p.author_id == 5 and p.published_at != nil,
  select: p

# OR conditions
query = from p in Post,
  where: p.author_id == 5 or p.featured == true,
  select: p

# Ordering and limits
query = from p in Post,
  order_by: [desc: p.inserted_at],
  limit: 10,
  select: p

# Joins
query = from p in Post,
  join: u in assoc(p, :author),
  where: u.name == "John",
  select: p

# Count
count = MyApp.Repo.aggregate(Post, :count)
```

## Migrations

```bash
mix ecto.gen.migration create_posts
```

```elixir
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text
      add :author_id, references(:users), null: false
      add :featured, :boolean, default: false
      add :views, :integer, default: 0

      timestamps()
    end

    create index(:posts, [:author_id])
    create unique_index(:posts, [:title])
  end
end
```

### Migration Commands

```bash
mix ecto.migrate              # Run pending migrations
mix ecto.rollback             # Revert last migration
mix ecto.rollback --step 3    # Revert last 3 migrations
mix ecto.reset                # Drop, create, and migrate
```

---

# CONTROLLERS AND VIEWS

## Controllers Overview

Controllers are Elixir modules that handle HTTP requests:

```elixir
defmodule MyappWeb.PostController do
  use MyappWeb, :controller

  def index(conn, _params) do
    posts = Repo.all(Post)
    render(conn, :index, posts: posts)
  end

  def show(conn, %{"id" => id}) do
    post = Repo.get!(Post, id)
    render(conn, :show, post: post)
  end
end
```

## Action Naming Conventions

| Action   | Purpose                         | HTTP Method |
| -------- | ------------------------------- | ----------- |
| `index`  | List all resources              | GET         |
| `show`   | Display single resource         | GET         |
| `new`    | Show form for creating resource | GET         |
| `create` | Process form submission         | POST        |
| `edit`   | Show form for editing resource  | GET         |
| `update` | Process edit form submission    | PUT/PATCH   |
| `delete` | Remove a resource               | DELETE      |

## Rendering Responses

### HTML Templates

```elixir
def index(conn, _params) do
  render(conn, :index)
end

def show(conn, %{"id" => id}) do
  post = Repo.get!(Post, id)
  render(conn, :show, post: post)
end
```

### JSON

```elixir
def index(conn, _params) do
  posts = Repo.all(Post)
  json(conn, posts)
end
```

### Plain Text

```elixir
def text_response(conn, _params) do
  text(conn, "Hello, World!")
end
```

## Redirecting

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

## Flash Messages

```elixir
conn
|> put_flash(:info, "Post created successfully!")
|> redirect(to: ~p"/posts")
```

Flash types: `:info`, `:warning`, `:error`

## Views and Templates

Phoenix 1.8 uses function components:

```elixir
defmodule MyappWeb.PostHTML do
  use MyappWeb, :html

  def index(assigns) do
    ~H"""
    <h1>Posts</h1>
    <%= for post <- @posts do %>
      <div>
        <h2><%= post.title %></h2>
        <p><%= post.body %></p>
      </div>
    <% end %>
    """
  end

  def show(assigns) do
    ~H"""
    <h1><%= @post.title %></h1>
    <p><%= @post.body %></p>
    """
  end
end
```

## Layouts

```heex
<!-- lib/myapp_web/components/layouts/root.html.heex -->
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title><%= @page_title %></title>
  </head>
  <body>
    <header>Navigation</header>
    <%= @inner_content %>
    <footer>Footer</footer>
  </body>
</html>
```

## Function Components

```elixir
defmodule MyappWeb.Components do
  use Phoenix.Component

  attr :label, :string, required: true
  attr :type, :string, default: "text"

  def input(assigns) do
    ~H"""
    <div>
      <label><%= @label %></label>
      <input type={@type} />
    </div>
    """
  end

  slot :inner_block, required: true
  attr :class, :string, default: ""

  def card(assigns) do
    ~H"""
    <div class={["card", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
```

## Template Syntax

```heex
<!-- Interpolation -->
<p><%= @variable %></p>

<!-- Conditionals -->
<%= if @user do %>
  <p>Welcome, <%= @user.name %>!</p>
<% end %>

<!-- Iteration -->
<ul>
  <%= for item <- @items do %>
    <li><%= item.name %></li>
  <% end %>
</ul>

<!-- Verified route links -->
<a href={~p"/posts/#{@post.id}"}>View Post</a>

<!-- Comments -->
<%!-- This won't render --%>
```

---

# REAL-TIME WITH CHANNELS AND PRESENCE

## Channels Overview

Phoenix Channels enable bidirectional real-time communication with millions of clients via WebSocket.

## Socket Handler

```elixir
defmodule MyappWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyappWeb.RoomChannel
  channel "user:*", MyappWeb.UserChannel

  def connect(params, socket, _connect_info) do
    case authenticate_user(params) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      :error -> :error
    end
  end

  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
```

## Channel Callbacks

```elixir
defmodule MyappWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, _message, socket) do
    if authorized?(socket, room_id) do
      {:ok, assign(socket, :room_id, room_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("new_message", %{"body" => body}, socket) do
    broadcast(socket, "message", %{
      user_id: socket.assigns.user_id,
      body: body,
      timestamp: DateTime.utc_now()
    })

    {:noreply, socket}
  end

  def handle_out("message", payload, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  defp authorized?(_socket, _room_id), do: true
end
```

## Broadcasting Messages

```elixir
# Broadcast to all clients in "room:123"
Phoenix.PubSub.broadcast(
  Myapp.PubSub,
  "room:123",
  {:message, %{user: "Alice", text: "Hello!"}}
)

# From within a channel
broadcast(socket, "message", %{user: "Alice", text: "Hello!"})

# Broadcast except self
broadcast_from(socket, "user_joined", %{user_id: socket.assigns.user_id})
```

## Presence Tracking

```elixir
defmodule MyappWeb.Presence do
  use Phoenix.Presence,
    otp_app: :myapp,
    pubsub_server: Myapp.PubSub
end

# In your channel
def join("room:" <> room_id, _params, socket) do
  send(self(), :after_join)
  {:ok, assign(socket, :room_id, room_id)}
end

def handle_info(:after_join, socket) do
  {:ok, _} = Presence.track(socket, "user:#{socket.assigns.user_id}", %{
    online_at: inspect(System.system_time(:seconds)),
    user_id: socket.assigns.user_id
  })

  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end
```

## Message Delivery Guarantees

Phoenix provides **at-most-once delivery** by default. For stronger guarantees, implement custom tracking with last_seen_id.

---

# TESTING STRATEGIES

## ConnCase for Controller Tests

```elixir
defmodule MyappWeb.PageControllerTest do
  use MyappWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome"
  end

  test "GET /users/:id", %{conn: conn} do
    user = insert(:user)
    conn = get(conn, ~p"/users/#{user.id}")
    assert response(conn, 200)
  end

  test "POST /users with valid data", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{
      name: "John",
      email: "john@example.com"
    })

    assert redirected_to(conn) == ~p"/users"
  end
end
```

## DataCase for Database Tests

```elixir
defmodule Myapp.PostTest do
  use Myapp.DataCase

  alias Myapp.Post

  test "create valid post" do
    changeset = Post.changeset(%Post{}, %{
      "title" => "Hello",
      "body" => "World"
    })

    assert {:ok, post} = Repo.insert(changeset)
    assert post.title == "Hello"
  end

  test "validates required fields" do
    changeset = Post.changeset(%Post{}, %{"title" => ""})
    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).title
  end
end
```

## Running Tests Selectively

```bash
# By directory
mix test test/controllers/

# By file
mix test test/controllers/page_controller_test.exs

# By line number
mix test test/controllers/page_controller_test.exs:11
```

## Using Tags

```bash
# Run only specific tags
mix test --only user_tests

# Exclude tests
mix test --exclude slow

# Run with specific seed
mix test --seed 12345
```

## HTTP Helpers

| Helper                        | Purpose                |
| ----------------------------- | ---------------------- |
| `get(conn, path)`             | Perform GET request    |
| `post(conn, path, params)`    | Perform POST request   |
| `put(conn, path, params)`     | Perform PUT request    |
| `patch(conn, path, params)`   | Perform PATCH request  |
| `delete(conn, path)`          | Perform DELETE request |
| `html_response(conn, status)` | Assert HTML status     |
| `json_response(conn, status)` | Assert JSON status     |
| `response(conn, status)`      | Assert status only     |
| `redirected_to(conn)`         | Get redirect location  |

---

# PLUGS, MIDDLEWARE, AND TELEMETRY

## Function Plugs

Simple functions accepting a connection:

```elixir
def put_user_agent(conn, _opts) do
  put_resp_header(conn, "user-agent", "MyApp/1.0")
end
```

## Module Plugs

Modules implementing two functions:

```elixir
defmodule MyappWeb.AuthPlug do
  def init(opts) do
    Keyword.fetch!(opts, :realm)
  end

  def call(conn, realm) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> authenticate(conn, token, realm)
      _ -> send_resp(conn, 401, "Unauthorized")
    end
  end
end
```

## Plugs at Different Levels

### Endpoint Level

```elixir
defmodule MyappWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :myapp

  plug Plug.RequestLogger
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Phoenix.json_library()
end
```

### Router Pipelines

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
end

pipeline :require_auth do
  plug MyappWeb.RequireAuthPlug
end

scope "/", MyappWeb do
  pipe_through :browser
  pipe_through :require_auth
  resources "/posts", PostController
end
```

### Controller-Level

```elixir
defmodule MyappWeb.PostController do
  plug :require_auth when action in [:create, :update, :delete]
  plug :load_post when action in [:show, :edit, :update, :delete]

  def show(conn, _params) do
    render(conn, :show, post: conn.assigns.post)
  end

  defp load_post(conn, _opts) do
    post = Repo.get!(Post, conn.params["id"])
    assign(conn, :post, post)
  end
end
```

## Halt to Stop Execution

```elixir
def verify_admin(conn, _opts) do
  if conn.assigns[:is_admin] do
    conn
  else
    conn
    |> send_resp(403, "Forbidden")
    |> halt()
  end
end
```

## Telemetry Instrumentation

```elixir
defmodule Myapp.Telemetry do
  def metrics do
    [
      Metrics.counter("http.request.count",
        description: "Total HTTP requests"
      ),
      Metrics.distribution("http.request.duration",
        unit: {:native, :millisecond},
        description: "HTTP request duration"
      )
    ]
  end
end
```

## Custom Events

```elixir
:telemetry.execute(
  [:myapp, :worker, :processed],
  %{duration: end_time - start_time},
  %{id: id, worker: __MODULE__}
)
```

---

# DEPLOYMENT AND PRODUCTION

## Core Deployment Steps

### 1. Secure Your Secrets

```elixir
# config/runtime.exs
config :myapp, MyappWeb.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true

config :myapp, Myapp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true
```

Generate secret:

```bash
mix phx.gen.secret
```

### 2. Compile Assets

```bash
MIX_ENV=prod mix assets.deploy
```

### 3. Start the Production Server

```bash
PORT=4001 MIX_ENV=prod mix phx.server
```

## Complete Deployment Script

```bash
#!/bin/bash
set -e

export MIX_ENV=prod

mix deps.get --only prod
mix compile
mix assets.deploy
mix ecto.migrate
PORT=4001 mix phx.server
```

## Environment Variables

```bash
# Required
SECRET_KEY_BASE=<generated-value>
DATABASE_URL=ecto://<user>:<password>@<host>/<database>
PORT=4000

# Optional
LOG_LEVEL=info
POOL_SIZE=10
REDIS_URL=redis://localhost:6379
PHX_HOST=example.com
```

## Multi-Server Clustering

For Long-Polling transport with multiple servers:

1. **Sticky Sessions** — Load balancer routes same user to same server
2. **Erlang VM Clustering** — Connect Elixir nodes directly
3. **Redis PubSub Adapter**

Configure Redis:

```elixir
config :myapp, Myapp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.get_env("REDIS_URL")
```

## Docker Deployment

```dockerfile
FROM elixir:latest AS build
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY . .
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix assets.deploy

FROM elixir:latest
WORKDIR /app
COPY --from=build /app/_build/prod ./
COPY --from=build /app/config ./config
COPY --from=build /app/lib ./lib
COPY --from=build /app/priv ./priv

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["mix", "phx.server"]
```

## Production Checklist

- [ ] Set `SECRET_KEY_BASE` from `mix phx.gen.secret`
- [ ] Configure `DATABASE_URL` with production database
- [ ] Set `PHX_HOST` to your domain
- [ ] Set `PORT` (usually 4000)
- [ ] Run migrations before starting: `mix ecto.migrate`
- [ ] Set `MIX_ENV=prod`
- [ ] Compile assets: `mix assets.deploy`
- [ ] Use external PubSub (Redis) for multi-node setups
- [ ] Configure SSL/TLS at load balancer or with `force_ssl: true`
- [ ] Set appropriate log levels
- [ ] Monitor application health and errors

---

**Version:** 1.8.8  
**Source:** [phoenix.hexdocs.pm](https://phoenix.hexdocs.pm/1.8.8)  
**Generated:** 2026-06-17
