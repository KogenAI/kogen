# phoenix_live_view - Event Bindings and Interactions

## Click and Button Events

**phx-click:**
Sends click events to the server. All clicks on elements with phx-click trigger the callback. Values can be passed multiple ways with this priority: JS.push value → phx-value-\* attributes → element value.

```heex
<button phx-click="increment" phx-value-amount="5">Add 5</button>
<div phx-click="select" phx-value-id="123">Item</div>
```

The handler receives:

```elixir
def handle_event("increment", %{"amount" => "5"}, socket) do
  {:noreply, assign(socket, :count, socket.assigns.count + 5)}
end
```

**phx-click-away:**
Fires when clicking outside an element. Useful for closing dropdowns, modals, and popovers without explicit close buttons. The click itself doesn't propagate to inner elements.

```heex
<div phx-click-away="close_menu" class="dropdown">
  <button>Toggle</button>
  <.menu :if={@show_menu} />
</div>
```

## Focus and Blur Events

**phx-focus/phx-blur:**
Element-level events triggered when specific elements gain or lose focus:

```heex
<input phx-focus="focused" phx-blur="blurred" />
```

**phx-window-focus/phx-window-blur:**
Page-level focus events fired when entire browser window regains or loses focus. Useful for pausing animations or stopping polling during page inactivity.

```heex
<div phx-window-focus="page_active" phx-window-blur="page_inactive" />
```

## Keyboard Events

**phx-keydown/phx-keyup:**
Trigger on keyboard press and release. Include optional `phx-key` attribute to filter specific keys:

```heex
<%# All keys %>
<input phx-keydown="key_pressed" />

<%# Specific keys %}
<input phx-keydown="search" phx-key="enter" />
<input phx-keyup="submit" phx-key="escape" />
```

Key names: "enter", "escape", "backspace", "tab", etc. Combine multiple keys with plus: `phx-key="ctrl+k"`.

**phx-window-keydown/phx-window-keyup:**
Page-level keyboard events for global hotkeys and shortcuts:

```heex
<div phx-window-keydown="global_search" phx-key="cmd+k" />
```

## Form Events

**phx-change:**
Fires on any form input modification. All form fields serialize to the params map. Preferred for validation and real-time feedback.

**phx-submit:**
Fires on form submission. Use for operations with side effects. Both can be bound on the same form with different handlers.

```heex
<form phx-change="validate" phx-submit="save">
  <input name="title" />
  <button>Save</button>
</form>
```

## Rate Limiting and Performance

**phx-debounce:**
Delays event emission until user stops interacting. Prevents excessive server calls during rapid typing or scrolling:

```heex
<input phx-change="search" phx-debounce="500" />
```

Special value "blur" debounces until the input loses focus, useful for search boxes that fire on blur instead of per keystroke.

**phx-throttle:**
Limits event frequency to specified milliseconds. Default 300ms if no value provided. Unlike debounce, throttle sends events at intervals during continued interaction:

```heex
<div phx-scroll="load_more" phx-throttle="1000" />
```

Debounce for search/autocomplete (fire once when done typing). Throttle for scroll/resize events (fire periodically during interaction).

## DOM Update Control

**phx-update:**
Controls how elements update when server sends diffs:

- `replace` (default) - Replace entire element
- `stream` - Manage large collections efficiently with minimal DOM operations
- `ignore` - Don't update this element (except data attributes)

```heex
<ul phx-update="stream" id="items">
  <li :for={{_id, item} <- @streams.items}>
    <%= item.name %>
  </li>
</ul>
```

## Lifecycle Bindings

**phx-mounted:**
JavaScript event fired when element added to DOM. Enables client-side initialization without hooks:

```heex
<div phx-mounted="InitChart" />
```

**phx-remove:**
Executes commands when element removed. Useful for cleanup operations:

```heex
<div phx-remove={JS.push("item_removed")} />
```

**phx-connected/phx-disconnected:**
Fire when LiveView connection established or lost. Useful for UI state (loading indicators, error messages):

```heex
<div class="disconnected" phx-connected={JS.hide()} phx-disconnected={JS.show()} />
```

## Infinite Scroll

**phx-viewport-top/phx-viewport-bottom:**
Fire when element scrolls into view at top or bottom of viewport. Perfect for infinite scroll and lazy loading:

```heex
<div phx-viewport-bottom="load_more_posts" id="page-bottom" />
```

Pairs with server-side pagination to load additional content as user scrolls.

## Server-Side Event Handling

All bindings route to `handle_event/3`:

```elixir
def handle_event(event_name, params_map, socket) do
  {:noreply, socket}  # Or {:reply, reply_value, socket}
end
```

Pattern match on event names for clarity:

```elixir
def handle_event("increment", %{"amount" => amount}, socket) do
  new_count = socket.assigns.count + String.to_integer(amount)
  {:noreply, assign(socket, :count, new_count)}
end

def handle_event(event, _params, _socket) do
  raise "Unknown event: #{event}"
end
```

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
