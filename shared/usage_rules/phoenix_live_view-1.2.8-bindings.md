# phoenix_live_view - DOM Bindings & Interactions

## Core Concept

Phoenix LiveView supports DOM element bindings for client-server interaction. When a binding is triggered, LiveView sends a message over the socket that's handled server-side via the `handle_event` callback.

## Click Events

### phx-click

Trigger events on element click:

```heex
<button phx-click="delete" phx-value-id={@record.id}>Delete</button>
```

- **Sends**: Event with phx-value-\* attributes as params
- **Use case**: Button actions, toggle states, confirmations

### phx-click-away

Trigger when user clicks outside the element:

```heex
<div phx-click-away="close-menu">
  <ul>Menu items...</ul>
</div>
```

### Sending Values with Click Events

Use `phx-value-*` attributes to pass data to the server:

```heex
<button phx-click="update" phx-value-status="active" phx-value-id="123">
  Mark Active
</button>
```

Handler receives: `%{"status" => "active", "id" => "123"}`

## Focus & Blur Events

Detect element focus changes:

```heex
<input
  type="text"
  phx-focus="field_focused"
  phx-blur="field_blurred"
  phx-value-field="username"
/>
```

### Window-Level Focus Events

```heex
<div phx-window-focus="page_focused" phx-window-blur="page_blurred">
  Content
</div>
```

- `phx-window-focus`: Page tab becomes active
- `phx-window-blur`: Page tab becomes inactive

## Keyboard Events

### phx-keydown & phx-keyup

Capture keyboard input:

```heex
<input
  type="text"
  phx-keydown="key_pressed"
  phx-keyup="key_released"
/>
```

### phx-key for Specific Keys

Filter events to specific keys:

```heex
<input
  type="text"
  phx-keydown="submit"
  phx-key="enter"
/>

<input
  type="text"
  phx-keyup="search"
  phx-key="/"
/>
```

Supported key names: `enter`, `escape`, `space`, `pageup`, `pagedown`, etc.

### Window Keyboard Events

```heex
<div phx-window-keydown="global_key" phx-key="escape">
  Close on Escape press
</div>
```

## Scroll Events

Enable infinite pagination by detecting scroll positions:

```heex
<div id="infinite-scroll" phx-viewport-top="load_top" phx-viewport-bottom="load_more">
  <div :for={item <- @items}><%= item.title %></div>
</div>
```

- `phx-viewport-top`: Container reaches top of viewport
- `phx-viewport-bottom`: Container reaches bottom of viewport

## Rate Limiting

Control event frequency with two mechanisms:

### phx-debounce

Delays event emission by specified milliseconds or until blur:

```heex
<input
  type="text"
  phx-change="search"
  phx-debounce="500"
/>
```

- `phx-debounce="500"`: Wait 500ms after last keystroke
- `phx-debounce="blur"`: Emit only when field loses focus

### phx-throttle

Immediately fires, then rate-limits subsequent events:

```heex
<input
  type="text"
  phx-change="track"
  phx-throttle="1000"
/>
```

- Fires first change immediately
- Subsequent changes within 1000ms are ignored
- After delay, next change fires

## Advanced Features

### DOM Patching (phx-update)

Control how updated elements are rendered:

```heex
<div id="items" phx-update="stream">
  <div :for={{id, item} <- streams(@items)} id={id}>
    <%= item.name %>
  </div>
</div>
```

Options:

- `replace` (default): Replace entire element
- `stream`: Prepend/append in collections
- `ignore`: Don't update from server (for third-party integrations)

### Connection State (phx-connected & phx-disconnected)

React to connection status changes:

```heex
<div phx-connected={JS.hide()} phx-disconnected={JS.show()}>
  <span class="offline">Offline</span>
</div>
```

## JavaScript Commands (Phoenix.LiveView.JS)

Execute client-side operations without server round trips:

```heex
<button phx-click={JS.toggle(to: "#menu")}>
  Toggle Menu
</button>

<button phx-click={JS.show(to: "#modal") |> JS.focus(to: "#input")}>
  Open Modal
</button>
```

Common commands:

- `JS.toggle/1`: Toggle CSS class or visibility
- `JS.show/1`, `JS.hide/1`: Show/hide elements
- `JS.add_class/1`, `JS.remove_class/1`: Manage classes
- `JS.focus/1`: Focus element
- `JS.push/1`: Push event to server
- `JS.navigate/1`: Navigate without page reload

---

[← Back to main](phoenix_live_view-1.2.8.md)
**Version:** 1.2.8
