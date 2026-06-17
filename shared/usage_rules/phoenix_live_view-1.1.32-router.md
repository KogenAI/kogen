# phoenix_live_view - Router Integration & Sessions

## Router Macros

Phoenix LiveView provides three key router macros for integrating live views:

### live/4

Defines a route for a LiveView using the `live` macro:

```elixir
live "/posts", PostsLive

# With action parameter
live "/posts/:id/edit", PostLive, :edit

# With specific actions
live "/dashboard", DashboardLive, as: :dashboard

# Full syntax
live "/posts/:id", PostLive,
  name: :post,
  container: {:div, class: "container"}
```

**Parameters:**

- `path` - URL path pattern (e.g., "/posts/:id")
- `module` - LiveView module to render
- `action` - Optional action atom (becomes `@live_action` in template)
- `as` - Route name for path helpers

**Route Options:**

- `:container` - HTML wrapper element
- `:metadata` - Telemetry tracking data
- `:private` - Connection private data

**Live Action:** Passes to the LiveView as `@live_action`:

```elixir
live "/posts/:id/edit", PostLive, :edit

# In LiveView
def render(assigns) do
  case @live_action do
    :edit -> render_edit(assigns)
    :show -> render_show(assigns)
  end
end
```

### live_session/3

Groups LiveView routes to enable WebSocket-based navigation between them without full page reloads.

```elixir
live_session :authenticated do
  live "/dashboard", DashboardLive
  live "/posts", PostsLive
  live "/posts/:id", PostLive
end

live_session :public do
  live "/", HomeLive
  live "/about", AboutLive
end
```

**Critical Behavior:** Redirecting between `live_session` groups always forces a full page reload and establishes a brand new LiveView connection.

### Configuration Options

```elixir
live_session :authenticated,
  on_mount: {UserAuth, :ensure_authenticated},
  session: {"user_token", get_session(conn, :user_token)},
  root_layout: {MyApp.Layouts, :app},
  layout: false
do
  live "/dashboard", DashboardLive
end
```

**Options:**

```elixir
on_mount: {Module, :function}      # Mount callback hook
session: {"key", value}            # Session data to pass
root_layout: {Module, :layout}     # Root template layout
layout: {Module, :layout}          # Page layout
```

## Security & Authentication

### Plugs vs LiveView Navigation

**Critical Note:** Navigates _do not go through the plug pipeline_. Authorization checks must occur in the `mount/3` callback.

```elixir
# This plug won't protect live_navigate
plug :require_admin

# Instead, check in mount/3
def mount(_params, _session, socket) do
  if socket.assigns.current_user.admin? do
    {:ok, socket}
  else
    {:error, "Unauthorized"}
  end
end
```

### on_mount Hook

Use `on_mount` in `live_session` to run authentication before rendering:

```elixir
defmodule MyApp.UserAuth do
  def ensure_authenticated(socket, _session, _params) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end
end

# In router
live_session :authenticated, on_mount: {UserAuth, :ensure_authenticated} do
  live "/dashboard", DashboardLive
end
```

### Session Isolation

Different `live_session` groups isolate session data:

```elixir
live_session :admin do
  live "/admin", AdminLive
end

live_session :user do
  live "/dashboard", UserLive
end

# Navigating between groups forces full reload
```

### Custom Session Data

Pass custom data to LiveViews through sessions:

```elixir
live_session :authenticated,
  session: {
    "user_id",
    get_session(conn, :user_id),
    "preferences",
    user_preferences
  }
do
  live "/dashboard", DashboardLive
end

# In LiveView mount/3
def mount(_params, session, socket) do
  user_id = session["user_id"]
  preferences = session["preferences"]
  {:ok, assign(socket, user_id: user_id, preferences: preferences)}
end
```

## Flash Messages

Use `fetch_live_flash/2` plug to handle flash data in LiveViews:

```elixir
# In endpoint.ex or router
plug :fetch_live_flash

# In LiveView
def handle_event("save", params, socket) do
  case Accounts.update_user(params) do
    {:ok, user} ->
      {:noreply, put_flash(socket, :info, "User updated!")}
    {:error, changeset} ->
      {:noreply, assign(socket, changeset: changeset)}
  end
end

def render(assigns) do
  ~H"""
  {@flash["info"]}
  {@flash["error"]}
  """
end
```

## Route Parameters and Actions

### Path Parameters

Extract from route path:

```elixir
live "/posts/:id", PostLive, :show

# In mount/3
def mount(%{"id" => id}, _session, socket) do
  post = Posts.get!(id)
  {:ok, assign(socket, post: post)}
end
```

### Query Parameters

Handled in `handle_params/3`:

```elixir
# URL: /posts?sort=date&filter=active
def handle_params(params, _uri, socket) do
  sort = params["sort"] || "date"
  filter = params["filter"] || "all"
  {:noreply, assign(socket, sort: sort, filter: filter)}
end
```

## Container and Metadata

### Custom Container

Wrap LiveView HTML in custom element:

```elixir
live "/dashboard",
  DashboardLive,
  container: {:article, class: "dashboard", role: "main"}
```

Renders as:

```html
<article class="dashboard" role="main">
  <!-- LiveView content -->
</article>
```

### Telemetry Metadata

Attach custom data for telemetry events:

```elixir
live "/posts/:id",
  PostLive,
  metadata: %{feature: "posts", version: 1}
```

## Best Practices

**Session Organization:** Group related routes to simplify navigation:

```elixir
# Good: grouping by authentication
live_session :authenticated, on_mount: {Auth, :ensure_user} do
  live "/dashboard", DashboardLive
  live "/posts", PostsLive
  live "/posts/:id/edit", PostLive, :edit
end

live_session :public do
  live "/", HomeLive
  live "/login", LoginLive
end
```

**Consistent Authorization:** Always check authorization in `mount/3`:

```elixir
def mount(params, _session, socket) do
  if can_access?(socket.assigns.current_user, params) do
    {:ok, assign(socket, data: fetch_data(params))}
  else
    {:error, :unauthorized}
  end
end
```

**Metadata for Analytics:** Use metadata option for tracking:

```elixir
live "/posts", PostsLive, metadata: %{page: "posts_list"}
live "/posts/:id", PostLive, metadata: %{page: "post_detail"}
```

**Separate Admin Routes:** Isolate admin routes in dedicated session:

```elixir
live_session :admin,
  on_mount: {Auth, :ensure_admin},
  root_layout: {MyApp.AdminLayout, :root}
do
  live "/admin", AdminDashboardLive
  live "/admin/users", AdminUsersLive
end
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
