# phoenix_live_view - Navigation & Routing

## Defining Live Routes

Phoenix LiveView routes are defined in your router using the `live/4` macro:

```elixir
scope "/", MyAppWeb do
  # Simple route
  live "/", HomeLive

  # With path parameter
  live "/articles/:id", ArticleLive

  # With action (same LiveView, multiple states)
  live "/articles", ArticleLive.Index, :index
  live "/articles/new", ArticleLive.Index, :new
  live "/articles/:id/edit", ArticleLive.Index, :edit
end
```

All `live` routes respond to HTTP `GET` requests. The action parameter represents different UI states within the same LiveView.

## Push vs. Patch Navigation

### push_patch/2: Update Current LiveView

Use when you want to stay in the same LiveView but update URL parameters:

```elixir
def handle_event("change_tab", %{"tab" => tab}, socket) do
  {:noreply, push_patch(socket, to: ~p"/?tab=#{tab}")}
end
```

Effects:

- Current LiveView **stays mounted** (state preserved)
- Only `handle_params/3` callback fires (not `mount/3`)
- URL updates in browser
- Minimal diffs transmit (scroll position preserved)
- Faster than navigate

Use case: Tab switching, pagination, sorting, filtering within the same page.

### push_navigate/2: Navigate to Different LiveView

Use when moving to a different LiveView or completely different page state:

```elixir
def handle_event("go_to_article", %{"id" => id}, socket) do
  {:noreply, push_navigate(socket, to: ~p"/articles/#{id}")}
end
```

Effects:

- Current LiveView **unmounts**
- New LiveView **mounts** (fresh state)
- Full initialization: `mount/3` + `handle_params/3`
- Full page reload transition (shows `phx-loading` class)
- Heavier than patch

Use case: Moving between different pages, switching content sections, logging in/out.

### Link Component

Use `<.link>` for user-initiated navigation:

```heex
<!-- HTTP navigation (full page reload) -->
<.link href={~p"/articles"}>Articles</.link>

<!-- Live navigation (WebSocket) -->
<.link navigate={~p"/articles"}>Articles</.link>

<!-- Live patch (same view, update params) -->
<.link patch={~p"/?page=2"}>Next Page</.link>

<!-- Replace history without adding entry -->
<.link patch={~p"/?tab=2"} replace>Tab 2</.link>
```

## The handle_params/3 Callback

This callback fires whenever parameters change via patching, and also on initial mount before first render:

```elixir
def handle_params(params, url, socket) do
  case socket.assigns.live_action do
    :index -> {:noreply, load_items(socket, params)}
    :show -> {:noreply, load_item(socket, params)}
    :edit -> {:noreply, load_form(socket, params)}
  end
end

defp load_items(socket, params) do
  page = String.to_integer(params["page"] || "1")
  items = MyContext.list_items(page: page)
  assign(socket, :items, items, :page, page)
end
```

**Key pattern**: Load static data in `mount/3`, handle parameter-driven data in `handle_params/3`.

Example: A blog reader loads the user in mount but handles comment pagination in handle_params:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :current_user, get_current_user())}
end

def handle_params(params, _url, socket) do
  page = params["page"] || "1"
  comments = MyContext.list_comments(socket.assigns.post_id, page: page)
  {:noreply, assign(socket, :comments, comments)}
end
```

## live_session: Grouped Routes

Group related LiveViews together to enable WebSocket-only navigation without HTTP requests:

```elixir
live_session :default, on_mount: MyAppWeb.UserAuth do
  live "/", HomeLive
  live "/about", AboutLive
end

live_session :admin, on_mount: MyAppWeb.AdminAuth do
  live "/admin", AdminDashboardLive
  live "/admin/users", AdminUsersLive
end
```

Effects:

- Navigation within a `live_session` uses WebSocket (fast, no HTTP)
- Navigation between `live_session` groups forces full page reload (security boundary)
- `on_mount` hooks run before `mount/3` for shared setup

**Critical security note**: Authorization checks run in `on_mount` hooks, not plugs. Since WebSocket navigation bypasses the plug pipeline, you must verify permissions explicitly in the LiveView:

```elixir
def mount(_params, _session, socket) do
  # Verify authorization in mount, not just plugs
  if authorized?(socket.assigns.current_user) do
    {:ok, socket}
  else
    {:error, {:redirect, to: "/"}}
  end
end
```

## on_mount Hooks

Hooks execute before `mount/3`, useful for shared initialization:

```elixir
live_session :authenticated, on_mount: MyAppWeb.EnsureAuth do
  live "/dashboard", DashboardLive
  live "/profile", ProfileLive
end
```

Hook implementation:

```elixir
defmodule MyAppWeb.EnsureAuth do
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(user_id)
        {:cont, assign_new(socket, :current_user, fn -> user end)}
    end
  end
end
```

Use `assign_new/3` to avoid redundant lookups if the parent already set the assign.

## Query Parameters

Query parameters are included in the `params` map:

```elixir
# URL: /articles?sort=title&order=asc
def handle_params(params, _url, socket) do
  sort_by = params["sort"] || "date"
  order = params["order"] || "desc"
  items = MyContext.list_articles(sort_by: sort_by, order: order)
  {:noreply, assign(socket, :items, items)}
end
```

Use `push_patch/2` to update query parameters without reloading:

```heex
<.link patch={~p"/?sort=title&order=asc"}>By Title</.link>
```

## Root Layout & Page Titles

The root layout doesn't update during live navigation (it's static). For dynamic page titles:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :page_title, "Home")}
end
```

Reference in root layout:

```heex
<title>{@page_title}</title>
```

Or use the `live_title/1` component for prefixes/suffixes:

```heex
<.live_title>
  {@page_title}
</.live_title>
```

## Navigation Constraints

- Only LiveViews defined directly in the router support live navigation (not nested views or controllers)
- Use `push_navigate` to go to a LiveView, `href` links for controllers
- Different `live_session` groups require full page reloads (security boundary)

---

[← Back to main](main-index.md)
**Version:** 1.1.32
