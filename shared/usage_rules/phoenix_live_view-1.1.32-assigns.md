# phoenix_live_view - State Management & Assigns

## Understanding Assigns

All state in a LiveView lives in `socket.assigns`—a map containing application data. Data is referenced in templates using the `@` prefix:

```elixir
# In Elixir code
assigns.user.name

# In template
@user.name
```

Server-side state remains private; only what renders to the template is sent to the client. This means you can store large datasets, database connections, or secrets in assigns without exposing them.

## Change Tracking (The Core Optimization)

LiveView's efficiency comes from intelligent change tracking. When you update an assign:

1. LiveView detects which assigns changed
2. Templates are re-executed only for changed sections
3. Only the minimal HTML diff transmits to the client
4. Unchanged DOM remains untouched (preserves focus, scroll, etc.)

Example: If only `@user.name` changes in this template:

```heex
<h1>{@user.name}</h1>
<p>{@user.id}</p>
```

Only the `<h1>` content is recomputed and sent—the paragraph is skipped. This works across multiple template files and function components.

## Critical Anti-Patterns to Avoid

### 1. Never Load Data Inside Templates

```elixir
# ❌ WRONG - Breaks change tracking
<%= for user <- Repo.all(User) do %>
  {user.name}
<% end %>

# ✅ CORRECT - Load in mount/handle_event
def mount(_params, _session, socket) do
  {:ok, assign(socket, :users, Repo.all(User))}
end
```

Template execution should be pure—no I/O operations, no side effects.

### 2. Avoid Creating Variables in Templates

```heex
<% sum = @x + @y %>  <!-- ❌ Disables tracking -->
<div>{sum}</div>
```

Instead, compute in Elixir and assign:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :sum, socket.assigns.x + socket.assigns.y)}
end
```

Or use a function:

```heex
<div>{sum_values(@x, @y)}</div>
```

### 3. Don't Use Generic Map Functions on Assigns

```elixir
# ❌ WRONG - Breaks change tracking
assigns = Map.put(assigns, :sum, value)

# ✅ CORRECT - Use assign/2 or assign/3
assigns = assign(assigns, :sum, value)
```

`assign/2-3` properly tracks the change; `Map.put/3` doesn't.

### 4. Never Spread All Assigns to Child Components

```heex
<!-- ❌ Re-renders everything -->
<.card_header {assigns} />

<!-- ✅ Pass specific assigns -->
<.card_header title={@title} subtitle={@subtitle} />
```

Spreading `assigns` disables granular tracking because LiveView can't tell which nested assigns might have changed. Exception: use `{card_header(assigns)}` for regular function calls (not components).

### 5. Avoid Computed Variables at Top of render/1

```elixir
def render(assigns) do
  # ❌ WRONG
  sum = assigns.x + assigns.y

  ~H"""
  {sum}
  """
end
```

This pattern loses change tracking. Instead:

```elixir
def render(assigns) do
  {:ok, assign(assigns, :sum, assigns.x + assigns.y)}
end
```

Or compute in mount/handle_event and reference `@sum` in template.

## Proper Assign Management

### Use assign/2-3 for Updates

```elixir
# Single assign
assign(socket, :user, user)

# Multiple assigns
assign(socket, user: user, admin: true, permissions: perms)
```

### Use assign_new/3 for Lazy Defaults

Prevents redundant database lookups when parent and child LiveViews both need current_user:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign_new(socket, :current_user, fn -> get_current_user() end)}
end
```

The function only executes if `:current_user` isn't already assigned.

### Use update/3 for Modifications

```elixir
# Increment counter
update(socket, :counter, &(&1 + 1))

# Append to list
update(socket, :items, &(&1 ++ [new_item]))
```

## Comprehension Optimization

Use the `:key` attribute on comprehensions for efficient collection rendering:

```heex
<section :for={post <- @posts} :key={post.id}>
  <h1>{expand_title(post.title)}</h1>
</section>
```

Without `:key`, inserting items causes unnecessary re-renders of subsequent elements. The `:key` helps LiveView's DOM patching stay efficient.

For very large collections (thousands of items), use `Phoenix.LiveView.stream/4` instead of comprehensions—it only renders visible items and handles DOM updates more efficiently.

## Derived Values

For computed data (sums, filters, aggregations), calculate in your callback and assign:

```elixir
def handle_event("filter", params, socket) do
  filtered_items = Enum.filter(socket.assigns.items, &matches?(&1, params))
  {:noreply, assign(socket, :filtered_items, filtered_items)}
end
```

Then reference `@filtered_items` in templates. This ensures change tracking works correctly and computation happens server-side.

## Common Patterns

**Conditional rendering with change tracking**:

```heex
<%= if @show_details do %>
  <div>{detailed_info(@user)}</div>
<% end %>
```

When only `@show_details` changes, the conditional section updates but not other parts.

**Nested object updates**:

```elixir
# Update nested field
user = %{socket.assigns.user | name: new_name}
assign(socket, :user, user)
```

LiveView tracks nested changes. If only the user's name changed, only that field's template gets re-executed.

---

[← Back to main](phoenix_live_view-1.1.32.md)
**Version:** 1.1.32
