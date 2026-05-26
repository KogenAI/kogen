# phoenix_live_view - LiveComponents and Composition

## LiveComponent Fundamentals

LiveComponents are stateful UI components that compartmentalize state, markup, and events for sharing across LiveViews. Unlike function components (which are pure), LiveComponents have their own lifecycle and run within the parent LiveView's process, allowing internal state management and event handling.

**Use LiveComponents when:**

- A piece of UI needs its own local state (counters, modals, forms)
- Multiple instances of the same component exist (list items, tabs)
- You need independent event handling per component instance

**Use function components for:**

- Reusable HTML patterns without state (buttons, cards, wrappers)
- Simple presentational UI
- Generic DOM abstraction

## Lifecycle Phases

LiveComponents follow a three-stage initialization sequence:

**First render:** `mount/1` → `update/2` → `render/1`

**Subsequent parent updates:** `update/2` → `render/1`

### Mount Phase

`mount/1` is called once when the component first appears, receiving a dedicated socket:

```elixir
defmodule MyAppWeb.Live.UserComponent do
  use Phoenix.LiveComponent

  def mount(socket) do
    {:ok, assign(socket, :expanded, false)}
  end
end
```

**Key point:** Mount receives a component-specific socket, not the parent's.

### Update Phase

`update/2` is invoked with assigns from `live_component/1`, merging data into the socket:

```elixir
def update(%{"user" => user}, socket) do
  {:ok, assign(socket, :user, user)}
end
```

Assigns not explicitly defined are automatically merged. Override this by setting in `mount/1`:

```elixir
def mount(socket) do
  {:ok, assign(socket, user: nil)}
end

def update(assigns, socket) do
  {:ok, assign(socket, assigns)}
end
```

### Update Many (Batch Optimization)

For efficiency with multiple component instances, implement `update_many/1` instead of `update/2`:

```elixir
def update_many(assigns_list) do
  # Load all user IDs at once to avoid N+1
  user_ids = Enum.map(assigns_list, & &1.user_id)
  users = Repo.all(from u in User, where: u.id in ^user_ids)
  users_map = Map.new(users, &{&1.id, &1})

  Enum.map(assigns_list, fn assigns ->
    {:ok, assign(assigns_socket, user: users_map[assigns.user_id])}
  end)
end
```

**Use when:** Rendering many components (pagination, lists) to avoid N+1 queries.

### Render Phase

`render/1` generates the component's template:

```heex
<div class="user-card">
  <h3><%= @user.name %></h3>
  <p><%= @user.email %></p>
  <button phx-click="toggle" phx-target={@myself}>
    Details
  </button>

  <%= if @expanded do %>
    <p><%= @user.bio %></p>
  <% end %>
</div>
```

**Constraint:** Components require a single root HTML tag.

## Event Handling

Components receive client events via `handle_event/3` when elements include `phx-target={@myself}`. The special assign `@myself` provides an internal reference to the component instance:

```elixir
def handle_event("toggle", _params, socket) do
  {:noreply, update(socket, :expanded, &!(&1))}
end
```

### Cross-Component Targeting

Target other components using CSS selectors:

```heex
<button phx-click="delete" phx-target="#user-13">Delete</button>
```

Or target multiple components:

```heex
<button phx-click="reset" phx-target=".modal, .form">Reset All</button>
```

## State Management Patterns

### Pattern 1: LiveView as Source of Truth

The parent LiveView manages all data; components act as presentation. Changes in one component notify the parent via `send self()`:

```elixir
# Component
def handle_event("toggle", _params, socket) do
  send(self(), {:user_updated, socket.assigns.user})
  {:noreply, socket}
end

# Parent LiveView
def handle_info({:user_updated, user}, socket) do
  {:noreply, assign(socket, :users, update_in(socket.assigns.users, fn users ->
    Enum.map(users, &(&1.id == user.id ? user : &1))
  end))}
end
```

**Pros:** Single source of truth, easier debugging
**Cons:** Parent must manage all component state

### Pattern 2: LiveComponent as Source of Truth

Each component loads and manages its own data via `update_many/1`. Parent uses `send_update/3` when distributed changes occur:

```elixir
# Component loads its own data
def update_many(assigns_list) do
  user_ids = Enum.map(assigns_list, & &1.user_id)
  users = Repo.all(from u in User, where: u.id in ^user_ids)

  Enum.map(assign_list, fn assigns ->
    {:ok, assign(assigns_socket, user: users_map[assigns.user_id])}
  end)
end

# Parent triggers updates after API calls
{:ok, user} = API.update_user(user)
send_update(MyAppWeb.Live.UserComponent, id: user.id, user: user)
```

**Pros:** Efficient, components own their data
**Cons:** Harder to keep in sync across instances

## Important Constraints

- **Single root tag required:** Wrapping multiple top-level elements breaks targeting
- **Always pass `module` and `id`:** LiveView needs these to identify and maintain component state
- **Don't pass entire parent assigns:** Only include necessary data to avoid unnecessary updates and large socket copies
- **Avoid generic DOM abstraction:** Don't use LiveComponents as generic wrappers (e.g., `<Card>`) with `@inner_block`—use function components instead

## Rendering LiveComponents

In the parent template:

```heex
<.live_component module={MyAppWeb.Live.UserComponent} id={user.id} user={user} />
```

With a list:

```heex
<div id="users" phx-update="stream">
  <.live_component
    :for={{user_id, user} <- @streams.users}
    module={MyAppWeb.Live.UserComponent}
    id={user_id}
    user={user}
  />
</div>
```

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
