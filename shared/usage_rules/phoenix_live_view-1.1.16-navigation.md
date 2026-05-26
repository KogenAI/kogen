# phoenix_live_view - Navigation and Routing

## Navigation Methods

Phoenix LiveView supports three distinct navigation strategies with different behavior and use cases:

**HTTP Navigation:**
Uses traditional `href` attributes and full page reloads. Works universally but drops the WebSocket connection and re-mounts the entire page. Use for complete page transitions or when LiveView isn't available (graceful degradation).

**Live Navigation:**
Uses `navigate` attribute on client and `push_navigate/2` on server to mount new LiveViews within the same session while preserving layout. Maintains WebSocket connection and existing state in parent components. The URL changes but the page layout persists, making it ideal for transitioning between different feature pages within the same application.

```heex
<.link navigate={~p"/users/#{@user.id}"}>View User</.link>
```

Server-side equivalent:

```elixir
def handle_event("goto_user", %{"id" => id}, socket) do
  {:noreply, push_navigate(socket, to: ~p"/users/#{id}")}
end
```

**Live Patching:**
Uses `patch` attribute on client and `push_patch/2` on server to update the current LiveView's URL without mounting a new one. Sends only minimal diffs and maintains scroll position. Perfect for filtering, pagination, and dynamic URL state changes without full re-renders.

```heex
<.link patch={~p"/posts?page=#{@page + 1}"}>Next</.link>
```

Server-side:

```elixir
def handle_event("next_page", _params, socket) do
  {:noreply, push_patch(socket, to: ~p"/posts?page=#{socket.assigns.page + 1}")}
end
```

## Navigation Callback: handle_params/3

The `handle_params/3` callback executes after mount and after every patch operation. It receives parameters, URL, and socket. This callback handles query parameter-dependent state:

```elixir
def handle_params(%{"page" => page}, _url, socket) do
  page_num = String.to_integer(page)
  posts = fetch_posts(page: page_num)
  {:noreply, assign(socket, :posts, posts, :page, page_num)}
end
```

**Critical Pattern:**
Data should always load in `mount/3` for base information (user details, configuration). Load only query-dependent data in `handle_params/3` (filters, page numbers, search results). This prevents redundant database queries when patches fire repeatedly.

## Routing Constraints

Only LiveViews directly defined in routers can utilize live navigation and patching. Multiple LiveViews rendered via `live_render/3` cannot access `push_navigate` and `push_patch` functionality, as this ensures navigation safety through router-guaranteed routing.

## Link Components

Phoenix provides `Phoenix.Component.link/1` for all navigation types. The component intelligently selects navigation method based on attributes:

```heex
<%# Full page reload %>
<.link href={~p"/page"}>Link</.link>

<%# Live navigation (mount new LiveView) %>
<.link navigate={~p"/page"}>Link</.link>

<%# Live patch (update current LiveView) %>
<.link patch={~p"/page"}>Link</.link>
```

Common attributes:

- `class` - CSS classes for styling
- `method` - HTTP method for href links (post, delete, etc.)
- `replace` - Replace browser history instead of pushing

## URL Generation and Verification

Use verified routes (`~p`) for type-safe URL generation. These prevent invalid routes and catch routing errors at compile time:

```elixir
# Valid route with verification
<.link navigate={~p"/users/#{@user.id}"}>User</.link>

# Also works in callbacks
push_navigate(socket, to: ~p"/dashboard")
```

Never concatenate strings for routes, as this loses verification safety and breaks refactoring.

## State Preservation During Navigation

Live navigation preserves parent component state while mounting new child LiveViews. This enables seamless transitions between pages while keeping shared layout state (sidebar, user menu, etc.) persistent.

Push patch maintains all state and adds URL parameters, ideal for:

- Pagination (update page parameter)
- Filtering (update filter parameters)
- Search (update search query parameter)
- Sorting (update sort parameter)

Push navigate creates fresh mount, clearing state. Use when:

- Transitioning to different sections (users to products)
- Mounting components with different initialization
- Resetting complex state between features

## Query Parameters and Dynamic Routing

Extract parameters in handle_params to drive dynamic content:

```elixir
def handle_params(%{"search" => query}, _url, socket) do
  results = search_posts(query)
  {:noreply, assign(socket, :results, results, :query, query)}
end

def handle_params(_params, _url, socket) do
  {:noreply, socket}
end
```

Multiple parameter patterns enable different code paths. Always provide a catch-all clause for routes without expected parameters.

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
