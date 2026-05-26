# phoenix_live_view - Navigation and Routing

## Navigation Methods

Phoenix LiveView provides three navigation strategies for different use cases:

### Push Patch: Navigate Within the Same LiveView

`push_patch/2` updates the URL without leaving the current LiveView, triggering `handle_params/3`:

```elixir
def handle_event("apply_filter", %{"category" => cat}, socket) do
  {:noreply, push_patch(socket, to: ~p"/products?category=#{cat}")}
end

def handle_params(%{"category" => category}, _uri, socket) do
  products = Repo.get_products(category)
  {:noreply, assign(socket, :products, products)}
end
```

**Use for:**

- Filtering, sorting, pagination
- Bookmarkable UI states
- Keeping the LiveView process alive
- Maintaining component state

### Push Navigate: Transition to Another LiveView

`push_navigate/2` moves to a different LiveView within the same session, with `mount/3` and `handle_params/3` called on the new view:

```elixir
def handle_event("show_details", %{"id" => id}, socket) do
  {:noreply, push_navigate(socket, to: ~p"/products/#{id}")}
end
```

**Use for:**

- Moving between different pages/sections
- Creating separate process instances
- Isolating component state per page

### Redirect: Full Page Load

`redirect/2` performs a full page reload, useful for external destinations or POST endpoints:

```elixir
def handle_event("go_external", _params, socket) do
  {:noreply, redirect(socket, to: "https://external.site")}
end

def handle_event("export", _params, socket) do
  {:noreply, redirect(socket, to: ~p"/export/csv")}
end
```

**Use for:**

- External URLs
- HTTP controller endpoints (form submissions, downloads)
- Logout flows
- One-time operations requiring POST

## Flash Messages

`put_flash/3` stores temporary user notifications that persist across redirects:

```elixir
def handle_event("save", params, socket) do
  case create_user(params) do
    {:ok, user} ->
      socket = put_flash(socket, :info, "User created successfully!")
      {:noreply, push_navigate(socket, to: ~p"/users/#{user.id}")}

    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

Clear a flash type:

```elixir
clear_flash(socket, :info)
```

Or clear all:

```elixir
clear_flash(socket)
```

Render flash in the layout:

```heex
<%= if live_flash(@flash, :info) do %>
  <div class="alert alert-info">
    <%= live_flash(@flash, :info) %>
  </div>
<% end %>
```

## Router Configuration

### Declaring LiveViews

In `router.ex`:

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router

  scope "/", MyAppWeb do
    pipe_through :browser

    live "/products", Live.Products
    live "/products/:id", Live.ProductDetails
    live "/admin", Live.Admin, as: :admin_dashboard
  end
end
```

**Optional parameters with defaults:**

```elixir
live "/search", Live.Search, as: :search
# Matches /search and /search?q=foo
```

### On Mount Hooks

Attach hooks to run before `mount/3`:

```elixir
live "/protected", Live.Protected, on_mount: :ensure_authenticated

def on_mount(:ensure_authenticated, _params, session, socket) do
  if Map.has_key?(session, :user_id) do
    {:cont, assign(socket, user_id: session["user_id"])}
  else
    {:halt, redirect(socket, to: "/login")}
  end
end
```

Chain multiple hooks:

```elixir
live "/admin", Live.Admin, on_mount: [{:admin_layout, :ensure_admin}, :set_timezone]
```

## Handling URL Parameters

Parameters arrive in `handle_params/3` with the full URI available:

```elixir
def handle_params(params, uri, socket) do
  # params: %{"id" => "123", "page" => "2"}
  # uri: "/products/123?page=2"

  page = String.to_integer(params["page"] || "1")
  {:noreply, assign(socket, :page, page)}
end
```

### Nested Routes

Access nested parameters:

```elixir
live "/users/:user_id/posts/:id", Live.Post

def handle_params(%{"user_id" => user_id, "id" => id}, _uri, socket) do
  post = Repo.get_post(user_id, id)
  {:noreply, assign(socket, :post, post)}
end
```

## State Preservation Across Navigation

### With `push_patch` (same LiveView)

State is preserved unless explicitly changed:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :filters, %{}, :results, [])}
end

def handle_params(%{"category" => cat}, _uri, socket) do
  # :filters persists from previous state
  results = Repo.search(cat, socket.assigns.filters)
  {:noreply, assign(socket, :results, results)}
end
```

### With `push_navigate` (different LiveView)

State is lost; only URL parameters and session data are available:

```elixir
# Old LiveView
def handle_event("go", _params, socket) do
  {:noreply, push_navigate(socket, to: ~p"/new-page")}
end

# New LiveView mount
def mount(params, session, socket) do
  # :filters is gone; use params/session only
  {:ok, socket}
end
```

To pass data between LiveViews, use:

- URL query parameters (small, bookmarkable)
- Session data (user context)
- Database/cache (large payloads)
- PubSub (real-time coordination)

## Browser History

Both `push_patch` and `push_navigate` update browser history, allowing back/forward buttons to work:

```elixir
# URL becomes /products?sort=name
push_patch(socket, to: ~p"/products?sort=name")

# Browser back button returns to previous URL
```

Disable history update with `replace: true`:

```elixir
push_patch(socket, to: ~p"/products", replace: true)
```

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
