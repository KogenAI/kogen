# phoenix_live_view - Navigation & URL Handling

## Navigation Methods

Phoenix LiveView enables page updates without full page reloads using the browser's pushState API. Navigation can be triggered from the client or server.

### Client-Side Navigation

Use the `Phoenix.Component.link/1` component:

```html
<!-- Patch: stay in current LiveView, update URL -->
<.link patch={~p"/posts/#{post.id}"}>
  Edit Post
</.link>

<!-- Navigate: mount new LiveView in same session -->
<.link navigate={~p"/dashboard"}>
  Dashboard
</.link>

<!-- Redirect: full page load to external URL -->
<.link href="https://external.com">
  External
</.link>
```

### Server-Side Navigation

Call navigation functions from event handlers:

```elixir
def handle_event("navigate_to_post", %{"id" => id}, socket) do
  {:noreply, push_patch(socket, to: ~p"/posts/#{id}")}
end

def handle_event("go_to_dashboard", _params, socket) do
  {:noreply, push_navigate(socket, to: ~p"/dashboard")}
end

def handle_event("exit", _params, socket) do
  {:noreply, redirect(socket, to: "https://external.com")}
end
```

## Patching vs Navigation

### Patching (push_patch/2)

Stays within the current LiveView, updating only the URL and parameters.

```elixir
push_patch(socket, to: ~p"/posts/#{post.id}")
```

**Behavior:**

- Current LiveView remains mounted
- `handle_params/3` is called with new parameters
- Socket state is preserved
- Efficient for filtering, pagination, and detail views

**Use Cases:**

- Search result filtering
- Pagination
- Detail/list views switching
- Tab navigation

**Example:**

```elixir
defmodule PostsLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, posts: [], search: "")}
  end

  def handle_params(%{"q" => q}, _uri, socket) do
    posts = Post.search(q)
    {:noreply, assign(socket, posts: posts, search: q)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/posts?q=#{q}")}
  end

  def render(assigns) do
    ~H"""
    <input phx-change="search" value={@search} />
    <ul>
      {for post <- @posts do}
        <li>{post.title}</li>
      {/for}
    </ul>
    """
  end
end
```

### Navigation (push_navigate/2)

Dismounts the current LiveView and mounts a new one within the same session.

```elixir
push_navigate(socket, to: ~p"/dashboard")
```

**Behavior:**

- Current LiveView is unmounted
- New LiveView is mounted via its `mount/3` callback
- WebSocket connection persists; no full page reload
- All socket state is lost

**Use Cases:**

- Switching between different pages/sections
- Multi-step wizards
- User authentication changes

**Example:**

```elixir
def handle_event("submit_form", params, socket) do
  case Accounts.create_user(params) do
    {:ok, user} ->
      {:noreply, push_navigate(socket, to: ~p"/users/#{user.id}")}
    {:error, changeset} ->
      {:noreply, assign(socket, changeset: changeset)}
  end
end
```

### Full Redirect (redirect/2)

Performs a complete page reload, breaking the WebSocket connection.

```elixir
redirect(socket, to: "/")
redirect(socket, external: "https://external.com")
```

**Behavior:**

- Full page reload via HTTP GET
- WebSocket connection terminates
- Browser history updated
- Suitable for external navigation

## The handle_params/3 Callback

This callback runs after `mount/3` on initial load and whenever patching occurs.

```elixir
def handle_params(params, uri, socket) do
  {:noreply, socket}
end
```

**Key Points:**

- `params` - URL path and query parameters
- `uri` - Full URI string
- Called after `mount/3` during initial render
- Called after `push_patch/2` or client patching

**Best Practice:** Load data in `mount/3`, not `handle_params/3`:

```elixir
# Correct pattern
def mount(_params, _session, socket) do
  posts = Post.all()  # Load all data
  {:ok, assign(socket, posts: posts)}
end

def handle_params(%{"q" => q}, _uri, socket) do
  # Only update assigns for changed parameters
  filtered = Enum.filter(socket.assigns.posts, &String.contains?(&1.title, q))
  {:noreply, assign(socket, search: q, results: filtered)}
end

# Avoid this pattern
def handle_params(%{"q" => q}, _uri, socket) do
  posts = Post.search(q)  # Inefficient; called on every patch
  {:noreply, assign(socket, posts: posts)}
end
```

## URL History Management

### Replace Option

Update URLs without adding browser history entries:

```elixir
push_patch(socket, to: url, replace: true)
```

**Use Cases:**

- Internal filtering states that shouldn't bloat back button history
- Search/sort operations
- Temporary navigation states

### URL Helpers

Use Phoenix path helpers for type-safe URLs:

```elixir
# Define in your app's routes or use sigil
~p"/posts/#{post.id}/edit"
~p"/dashboard?tab=analytics&period=month"
```

## Navigation Limitations

**Subcomponents:** Only routed LiveViews support live navigation. Function components and LiveComponents rendered within a view cannot use `push_patch` or `push_navigate`.

**Cross-Session Navigation:** Navigating between different `live_session` groups always forces a full page reload and establishes a new LiveView connection.

```elixir
live_session :authenticated do
  live "/dashboard", DashboardLive
end

live_session :public do
  live "/", HomeLive
end

# Navigating between these requires full page reload
push_navigate(socket, to: ~p"/")  # Forces reload
```

## Advanced Patterns

### Multi-Step Forms

Use navigation to guide users through wizard flows:

```elixir
def handle_event("next", params, socket) do
  case validate_step(socket.assigns.step, params) do
    {:ok, data} ->
      next_step = socket.assigns.step + 1
      {:noreply, push_navigate(socket, to: ~p"/wizard/#{next_step}")}
    {:error, errors} ->
      {:noreply, assign(socket, errors: errors)}
  end
end
```

### Preserving Scroll Position

Store scroll position in session for restoration:

```elixir
# In JavaScript
window.addEventListener("phx:before-navigate", () => {
  sessionStorage.setItem("scroll", window.scrollY)
})

window.addEventListener("phx:navigate", () => {
  const scroll = sessionStorage.getItem("scroll")
  if (scroll) window.scrollTo(0, parseInt(scroll))
})
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
