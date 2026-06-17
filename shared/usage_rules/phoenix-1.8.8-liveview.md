# phoenix - LiveView & Real-Time

## Core Concept

LiveView enables interactive web applications by maintaining server-side state while delivering real-time updates through WebSockets. LiveViews are processes that receive events, update their state, and render updates to a page as diffs. This eliminates the need for traditional client-side JavaScript while maintaining a responsive user experience.

Traditional controller-view architecture requires full page reloads or client-side code for interactivity. LiveView consolidates these concerns into unified processes that maintain state and automatically re-render changed content, minimizing data transmission and complexity.

## Essential Lifecycle Callbacks

### mount/3

Initializes the LiveView process. Called once when the view starts and again if the socket assigns change.

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, temperature: 72, humidity: 45)}
end
```

Access URL parameters:

```elixir
def mount(%{"room_id" => room_id}, _session, socket) do
  room = Rooms.get_room!(room_id)
  {:ok, assign(socket, room: room)}
end
```

### render/1

Defines the template displayed to the user. Uses HEEx syntax with event bindings.

```elixir
def render(assigns) do
  ~H"""
  <div>
    <p>Temperature: <%= @temperature %>°F</p>
    <button phx-click="inc_temperature">+</button>
    <button phx-click="dec_temperature">-</button>
  </div>
  """
end
```

### handle_event/3

Processes client-side interactions triggered by event bindings.

```elixir
def handle_event("inc_temperature", _value, socket) do
  {:noreply, update(socket, :temperature, &(&1 + 1))}
end

def handle_event("search", %{"query" => query}, socket) do
  results = Db.search(query)
  {:noreply, assign(socket, results: results)}
end

def handle_event("delete_item", %{"id" => id}, socket) do
  Item.delete(id)
  {:noreply, update(socket, :items, &Enum.reject(&1, fn i -> i.id == id end))}
end
```

### handle_params/3

Responds to URL changes (navigation without page reload).

```elixir
def handle_params(%{"page" => page}, _uri, socket) do
  items = Items.paginate(String.to_integer(page))
  {:noreply, assign(socket, items: items, page: page)}
end
```

Called after mount and whenever route parameters change.

### handle_info/2

Handles internal process messages from other processes (timers, database updates, PubSub messages).

```elixir
def handle_info({:item_created, item}, socket) do
  {:noreply, update(socket, :items, &[item | &1])}
end

def handle_info(:tick, socket) do
  {:noreply, update(socket, :counter, &(&1 + 1))}
end
```

## DOM Interactions & Event Bindings

LiveView uses declarative bindings that automatically transmit user events to the server:

### Click Events

```html
<button phx-click="increment">Click Me</button>
<a href="#" phx-click="load_more">Load More</a>
```

### Form Submissions

```html
<form phx-submit="save">
  <input name="title" type="text" />
  <button>Save</button>
</form>
```

Handle with event params:

```elixir
def handle_event("save", %{"title" => title}, socket) do
  {:ok, post} = Posts.create(%{title: title})
  {:noreply, assign(socket, post: post)}
end
```

### Input Tracking

Bind input changes in real-time:

```html
<input type="text" phx-change="search" name="query" />
```

```elixir
def handle_event("search", %{"query" => query}, socket) do
  results = if byte_size(query) > 2, do: db_search(query), else: []
  {:noreply, assign(socket, results: results)}
end
```

### Blur and Focus

```html
<input type="email" phx-blur="validate_email" name="email" />
<input type="text" phx-focus="on_focus" />
```

## State Management

Assign values to socket to make them available in templates:

```elixir
# Set state
{:noreply, assign(socket, :title, "New Title")}

# Update existing state
{:noreply, update(socket, :count, &(&1 + 1))}

# Set multiple assigns
{:noreply, assign(socket, title: "Hello", count: 10)}

# Update with map
{:noreply, assign(socket, Map.take(params, ["title", "body"]))}
```

State lives only on the server. Only HTML diffs are sent to the browser, reducing bandwidth and keeping logic secure.

## Common Patterns

### CRUD Operations

```elixir
defmodule HelloWeb.PostLive do
  use HelloWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, posts: Posts.all())}
  end

  def render(assigns) do
    ~H"""
    <ul>
      <.post :for={post <- @posts} post={post} />
    </ul>
    <.form :let={f} for={@changeset} phx-submit="save">
      <!-- form fields -->
    </.form>
    """
  end

  def handle_event("save", %{"post" => params}, socket) do
    case Posts.create(params) do
      {:ok, post} ->
        {:noreply, update(socket, :posts, &[post | &1])}
      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
```

### List Filtering and Pagination

```elixir
def handle_event("filter", %{"category" => category}, socket) do
  posts = if category == "", do: Posts.all(), else: Posts.by_category(category)
  {:noreply, assign(socket, posts: posts, filter: category)}
end
```

## Scaffolding with Generators

Generate complete CRUD LiveView implementations:

```bash
mix phx.gen.live Blog Post posts title:string body:text
```

Creates:

- LiveView module with mount, render, handle_event, handle_params
- HTML templates
- Tests with assertions
- Routes in router

## Performance Considerations

- LiveView assigns are sent as diffs, only changed content is transmitted
- Server-side state reduces JavaScript complexity and bundle size
- Leverage `phx-debounce` to reduce event frequency from rapid input changes
- Use `phx-throttle` to rate-limit frequent events
- Separate long-running operations into background jobs to keep LiveView responsive

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
