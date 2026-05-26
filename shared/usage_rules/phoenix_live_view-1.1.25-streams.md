# phoenix_live_view - Streams & Large Collections

## Streams Overview

Streams efficiently manage large, dynamic collections by tracking individual items on the client via unique IDs. Instead of re-rendering the entire list, updates apply only to changed items. Use streams for unbounded lists, infinite scrolling, and real-time feeds.

Initialize a stream in mount:

```elixir
def mount(_params, _session, socket) do
  items = load_initial_items()
  {:ok, stream(socket, :items, items)}
end
```

In templates, render with `phx-update="stream"`:

```heex
<ul phx-update="stream" id="items-container">
  <li :for={{id, item} <- @streams.items} id={"item-#{id}"}>
    <p><%= item.name %></p>
    <button phx-click="delete-item" phx-value-id={id}>Delete</button>
  </li>
</ul>
```

Access stream data as `@streams.items`, which is a list of tuples `{unique_id, item}`. The ID must match the HTML element's `id` attribute.

## Stream Insert & Delete

Add items to a stream:

```elixir
def handle_event("add-item", %{"name" => name}, socket) do
  item = %{id: unique_id(), name: name, created_at: DateTime.utc_now()}
  {:noreply, stream_insert(socket, :items, item)}
end
```

`stream_insert/4` appends the item by default. Use `:at` to insert at a specific position:

```elixir
stream_insert(socket, :items, item, at: 0)  # Insert at beginning
```

Remove items:

```elixir
def handle_event("delete-item", %{"id" => id}, socket) do
  {:noreply, stream_delete(socket, :items, id)}
end
```

Replace items:

```elixir
def handle_event("update-item", %{"id" => id, "name" => name}, socket) do
  item = %{id: id, name: name}
  {:noreply, stream_insert(socket, :items, item)}
end
```

## Stream Configuration

Control stream behavior with `stream_configure/3`:

```elixir
socket = stream_configure(socket, :items, dom_id: "item-", inserts: :prepend, deletes: :remove)
```

**Options:**

- `dom_id` - DOM ID prefix (default: item name)
- `inserts` - `:append` (default) or `:prepend` for new items
- `deletes` - `:remove` (default) or `:hide` (hides without removing)

## Stream Async

Load items asynchronously with `stream_async/3`:

```elixir
def mount(_params, _session, socket) do
  socket = stream_async(socket, :items, fn -> {:ok, load_items()} end)
  {:ok, socket}
end
```

This starts a task to load items. When complete, they automatically populate the stream. Handle errors:

```elixir
def handle_async(:items, {:exit, _reason}, socket) do
  {:noreply, put_flash(socket, :error, "Failed to load items")}
end
```

## Infinite Scrolling

Combine `phx-viewport-bottom` with stream insertion for infinite scrolling:

```heex
<div id="item-list" phx-viewport-bottom="load-more">
  <ul phx-update="stream" id="items">
    <li :for={{id, item} <- @streams.items} id={"item-#{id}"}>
      <%= item.name %>
    </li>
  </ul>
</div>
```

Handle the event:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, page: 1) |> stream(socket, :items, load_page(1))}
end

def handle_event("load-more", _value, socket) do
  page = socket.assigns.page + 1
  items = load_page(page)
  {:noreply,
    socket
    |> assign(:page, page)
    |> stream(socket, :items, items)}
end
```

## Stream Item Requirements

Each item in a stream must:

1. Have a unique identifier (typically `:id` field)
2. Be a map or struct
3. Include all fields needed for rendering

```elixir
item = %{id: unique_id(), name: "Item", status: "active"}
stream_insert(socket, :items, item)
```

## Efficient DOM Updates

Streams minimize DOM updates by tracking changes per item:

- **Insert** - adds one DOM element
- **Delete** - removes one DOM element
- **Replace** - updates only the changed element

Without streams, updates to any item force re-rendering the entire list in the template. Streams apply targeted updates to the exact items that changed.

## Stream with Filters & Sorting

Manage filtered views by tracking source and view separately:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> stream(:all_items, load_all_items())
   |> stream(:filtered_items, filter_items(load_all_items(), "active"))}
end

def handle_event("filter", %{"status" => status}, socket) do
  all_items = socket.assigns.all_items
  filtered = filter_items(all_items, status)
  {:noreply, stream(socket, :filtered_items, filtered)}
end
```

## Edge Cases

**Duplicates:** Inserting an item with an ID that already exists replaces the existing item.

**Removed parent:** If the stream container is removed from the DOM, the stream stops functioning until it's re-added.

**Large initial loads:** For > 500 items, use pagination or `stream_async` to avoid blocking the initial render.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
