# phoenix_live_view - Navigation & Routing

## Navigation Functions

LiveView provides three navigation functions with different behaviors:

### push_patch/2

Stay in the same LiveView, update URL and parameters. Triggers `handle_params/3`:

```elixir
def handle_event("filter", %{"status" => status}, socket) do
  {:noreply, push_patch(socket, to: ~p"/items?status=#{status}")}
end

def handle_params(%{"status" => status}, _uri, socket) do
  items = load_items(status)
  {:noreply, assign(socket, :items, items, :filter, status)}
end
```

Use for filtering, sorting, pagination within the same LiveView. The user's scroll position is preserved on most browsers.

### push_navigate/2

Switch to a different LiveView. Triggers mount and handle_params on the new view:

```elixir
def handle_event("goto-profile", %{"user_id" => id}, socket) do
  {:noreply, push_navigate(socket, to: ~p"/users/#{id}")}
end
```

Use for moving between different pages/views. The browser doesn't fully reload; only the LiveView process changes.

### redirect/2

Full page reload via HTTP. Use sparingly for external URLs or after authentication:

```elixir
def handle_event("logout", _value, socket) do
  {:noreply, redirect(socket, to: ~p"/logout")}
end

def handle_event("goto-external", _value, socket) do
  {:noreply, redirect(socket, to: "https://example.com")}
end
```

redirect always performs a full page reload. Use for external URLs, authentication redirects, or moving to non-LiveView pages.

## Flash Messages

Display temporary notifications across navigation:

```elixir
def handle_event("save", %{"user" => params}, socket) do
  case Accounts.create_user(params) do
    {:ok, user} ->
      {:noreply,
       socket
       |> put_flash(:info, "User created successfully")
       |> push_navigate(to: ~p"/users/#{user.id}")}
    {:error, changeset} ->
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

Flash messages persist across `push_navigate` and `redirect`. Display them in templates:

```heex
<div :if={flash = Phoenix.Flash.get(@flash, :info)} id="info-flash">
  <p><%= flash %></p>
  <button phx-click="lv:clear-flash" phx-value-key="info">×</button>
</div>

<div :if={flash = Phoenix.Flash.get(@flash, :error)} id="error-flash">
  <p><%= flash %></p>
</div>
```

The `phx-click="lv:clear-flash"` removes the flash without calling `handle_event/3`.

## URL Parameters

Handle URL parameters in `handle_params/3`:

```elixir
def handle_params(%{"page" => page}, _uri, socket) do
  page_num = String.to_integer(page)
  items = load_items(page_num)
  {:noreply, assign(socket, :items, items, :page, page_num)}
end

def handle_params(_params, _uri, socket) do
  {:noreply, assign(socket, :page, 1)}
end
```

`handle_params/3` fires:

1. After `mount/3` completes (initial connection)
2. When URL changes via `push_patch/2`
3. When user navigates with back/forward buttons

Use pattern matching to handle specific params. The second argument is the full URI for logging.

## Session Data

Session data persists across LiveView changes:

```elixir
# In mount
def mount(_params, session, socket) do
  user_id = session["user_id"]
  {:ok, assign(socket, :user_id, user_id)}
end

# After push_navigate to another LiveView
# The new LiveView receives the same session
```

Session is set during the initial HTTP request and cannot change within LiveView. Store authentication info there.

## Preserve State Across Navigation

State in socket assigns is lost on `push_navigate`. To preserve state, store in session or use temporary storage:

```elixir
# Option 1: Store in session via redirect
redirect(socket, to: ~p"/next?ref=#{current_path(socket)}")

# Option 2: Store in browser storage via JS
phx-click={
  JS.push("save-state", value: %{page: @page})
  |> JS.navigate(to: ~p"/next")
}
```

The first approach uses URL parameters; the second stores in JavaScript and restores on the next page.

## History and Back Navigation

`push_patch/2` allows back/forward button navigation. The browser history stack includes patched URLs:

```elixir
# User navigates: /items (page=1) -> /items?status=active -> /items?status=completed
# Back button goes to /items?status=active, triggering handle_params with new params
```

`push_navigate` and `redirect` add to history, allowing normal back button behavior.

## Router Integration

Define LiveView routes in your router:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  scope "/", MyAppWeb do
    pipe_through :browser

    live "/items", ItemsLive.Index
    live "/items/:id", ItemsLive.Show
    live "/items/:id/edit", ItemsLive.Form
  end
end
```

URL segments become params in `mount/3` and `handle_params/3`:

```elixir
def mount(%{"id" => id}, _session, socket) do
  item = load_item(id)
  {:ok, assign(socket, :item, item)}
end
```

## Connected vs Disconnected Navigation

`connected?/1` distinguishes initial render (disconnected) from live navigation (connected):

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Subscriptions, async operations (after initial render)
    Phoenix.PubSub.subscribe(MyApp.PubSub, "items")
  end

  {:ok, assign(socket, :items, load_items())}
end
```

On initial HTTP request, `connected?` is false. After WebSocket connects, `handle_params/3` fires with `connected?` true.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
