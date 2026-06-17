# phoenix_live_view - Components & Reusability

## Function Components vs LiveComponents

Phoenix supports two component types:

**Function Components** (Stateless): Pure functions receiving assigns and returning rendered output. Ideal for reusable UI patterns without state management.

**LiveComponents** (Stateful): Modules running their own processes within the LiveView, managing internal state, lifecycle, and events.

## Function Components

Function components are simple Elixir functions decorated with HEEx templates.

```elixir
defmodule MyApp.UserCard do
  use Phoenix.Component

  attr :user, :map, required: true
  attr :class, :global, default: %{class: "card"}

  def card(assigns) do
    ~H"""
    <div class={@class}>
      <h3>{@user.name}</h3>
      <p>{@user.email}</p>
    </div>
    """
  end
end

# Usage
<.card user={@current_user} />
```

### Attributes

Use `attr/3` to declare component inputs with compile-time validation.

```elixir
attr :name, :string, required: true
attr :age, :integer, default: 0
attr :active, :boolean, default: true
attr :class, :global, default: %{}
attr :custom, :any
```

**Attribute Types:**

- `:string`, `:integer`, `:boolean`, `:atom` - Basic types
- Struct types - e.g., `MyModule.User`
- `:any` - Accepts any value
- `:global` - Dynamic HTML attributes (class, data-_, phx-_, aria-\*)

**Global Attributes:** When `:global` is set, merge incoming attrs into a map:

```elixir
attr :class, :global, default: %{class: "btn"}

def button(assigns) do
  ~H"""
  <button class={[@class, "px-4"]} {@rest}>
    {@inner_block}
  </button>
  """
end

# Caller can pass: class="custom" data-id="123"
```

### Slots

Slots allow components to accept content blocks from callers.

```elixir
defmodule MyApp.Modal do
  use Phoenix.Component

  slot :inner_block, required: true
  slot :header
  slot :footer

  def modal(assigns) do
    ~H"""
    <div class="modal">
      <div class="modal-header">
        {render_slot(@header)}
      </div>
      <div class="modal-body">
        {render_slot(@inner_block)}
      </div>
      <div class="modal-footer">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end
end

# Usage
<.modal>
  <:header>
    <h1>Title</h1>
  </:header>
  Content here
  <:footer>
    <button>Close</button>
  </:footer>
</.modal>
```

**Slot Attributes:** Pass data from component to slot caller:

```elixir
slot :item, default: [] do
  attr :id, :integer, required: true
  attr :name, :string, required: true
end

def list(assigns) do
  ~H"""
  <ul>
    {for item <- @items do}
      {render_slot(@item, id: item.id, name: item.name)}
    {/for}
  </ul>
  """
end

# Caller receives data with :let
<.list items={@users} let={item: %{id: id, name: name}}>
  <li><strong>{name}</strong> ({id})</li>
</.list>
```

## LiveComponents

LiveComponents are stateful modules with lifecycle callbacks, ideal for encapsulating complex interactive widgets.

```elixir
defmodule MyApp.CounterComponent do
  use Phoenix.LiveComponent

  def mount(socket) do
    {:ok, assign(socket, count: 0)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <p>Count: {@count}</p>
      <button phx-click="increment" phx-target={@myself}>+</button>
    </div>
    """
  end

  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end
end

# Render in parent LiveView
<.live_component module={CounterComponent} id="counter" />
```

### LiveComponent Lifecycle

**First Render:**

```
mount/1 → update/2 → render/1
```

**Subsequent Updates:**

```
update/2 → render/1
```

**Key Points:**

- `mount/1` fires only once when the component is first added
- `update/2` receives assigns passed from parent
- Components with identical module and ID are treated as the same instance
- Must always provide `module` and `id` attributes

### update/2 Callback

Called with assigns from parent LiveView.

```elixir
def update(assigns, socket) do
  {:ok, assign(socket, assigns)}
end
```

### handle_event/3 in LiveComponents

Target events to specific components:

```elixir
<button phx-click="click" phx-target={@myself}>
  Click me
</button>

def handle_event("click", _params, socket) do
  {:noreply, socket}
end
```

### Distributed Updates with send_update/3

Update a component from the parent LiveView or another process:

```elixir
# In parent LiveView
send_update(CounterComponent, id: "counter", count: 5)

# Update multiple components
update_many([
  {CounterComponent, id: "counter1", count: 5},
  {CounterComponent, id: "counter2", count: 10}
])
```

## Component Best Practices

**Prefer Function Components:** Use function components by default for better performance and simplicity. Only use LiveComponents when state or lifecycle management is necessary.

**Minimal Assigns:** Pass only necessary assigns to components to reduce diff sizes and improve rendering performance.

**Use update_many/1:** When rendering many LiveComponents, use `update_many/1` to batch updates and avoid N+1 queries.

**Encapsulation:** LiveComponents should focus on application concerns. Avoid using them merely for DOM abstraction or CSS organization.

**Separation of Logic:** Keep complex business logic in context modules; components should handle UI state and presentation.

```elixir
# Good: component manages UI state
<.live_component module={SearchForm} id="search" on_submit={fn q -> query(q) end} />

# Less ideal: component manages business logic
<.live_component module={ComplexDataProcessor} id="processor" />
```

## Built-in Components

Phoenix provides production-ready components in `Phoenix.Component`:

- `form` - Form builder with validation support
- `link` - Navigation with patching/navigation support
- `live_component` - Render stateful components
- `inputs_for` - Nested form inputs
- `async_result` - Display async operation state
- `focus_wrap` - Keyboard navigation wrapper
- File upload helpers - `live_file_input`

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
