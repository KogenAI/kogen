# phoenix_live_view - Event Bindings & Client Interaction

## Overview

Phoenix LiveView uses DOM element bindings (phx- attributes) to capture user interactions and send them to the server where `handle_event/3` processes them. The framework provides rich event handling without requiring custom JavaScript.

## Core Event Bindings

### Click Events

**phx-click**: Sends click event to the server

```heex
<button phx-click="delete">Delete</button>
<a phx-click="navigate-away">Go</a>
```

Value priority (in order):

1. JavaScript command from `JS.push/3`
2. `phx-value-*` attributes passed as a map
3. Element value property (for forms)
4. Custom metadata from LiveSocket config

Example with values:

```heex
<button phx-click="edit" phx-value-id={@item.id} phx-value-tab="details">
  Edit
</button>

<!-- Server receives: {"id" => "123", "tab" => "details"} -->
```

**phx-click-away**: Triggers when clicking outside an element

```heex
<div phx-click-away="close-modal">
  <button phx-click="stop-propagation">Keep Open</button>
</div>
```

Useful for dismissing dropdowns or modals.

### Form Events

**phx-change**: Fires on any form field change

```heex
<form phx-change="validate">
  <input type="text" name="title" />
  <input type="email" name="email" />
</form>
```

Sends entire form's data to the server each time any field changes. Ideal for real-time validation and filtering.

**phx-submit**: Fires on form submission

```heex
<form phx-change="validate" phx-submit="save">
  <input type="text" name="title" />
  <button type="submit">Save</button>
</form>
```

Submits form data. The form becomes read-only during submission to prevent duplicates.

**phx-disable-with**: Shows loading state on submit

```heex
<button type="submit" phx-disable-with="Saving...">Save</button>
```

Text changes during submission, button disables, then restores on acknowledgment.

### Focus/Blur Events

**phx-focus / phx-blur**: Element-level focus changes

```heex
<input type="text" phx-focus="field-focused" phx-blur="field-blurred" />
```

**phx-window-focus / phx-window-blur**: Page-level focus detection

```heex
<div phx-window-focus="app-focused" phx-window-blur="app-blurred">
  Content
</div>
```

Useful for pausing updates when the browser tab is inactive.

### Keyboard Events

**phx-keydown / phx-keyup**: Keyboard events

```heex
<input type="text" phx-keydown="on-key" />
```

⚠️ **Note**: Keyboard events don't work on form inputs. Use `phx-change` on the form instead.

**phx-key**: Filter events to specific keys

```heex
<input type="text" phx-keydown="on-enter" phx-key="enter" />
<input type="text" phx-keydown="on-escape" phx-key="escape" />
```

Supported keys: `enter`, `escape`, `tab`, `space`, `pageup`, `pagedown`, `home`, `end`, `arrow_left`, `arrow_right`, `arrow_up`, `arrow_down`.

## Rate Limiting

### Debounce

Delays event emission by specified milliseconds or until blur. Default: 300ms.

```heex
<!-- Waits 500ms of inactivity before sending search -->
<input type="text" name="query" phx-change="search" phx-debounce="500" />

<!-- Sends when field loses focus (after any delay) -->
<input type="text" name="query" phx-change="search" phx-debounce="blur" />
```

Good for search inputs, autocomplete, and validation that hits the database.

### Throttle

Emits immediately, then rate-limits further emissions. Default: 300ms.

```heex
<!-- Sends click immediately, then ignores for 300ms -->
<button phx-click="like" phx-throttle="300">Like</button>

<!-- Allows 1 scroll event per 200ms -->
<div phx-viewport-bottom="load-more" phx-throttle="200">
  Items...
</div>
```

Good for clicks, likes, and scroll events where you want immediate response but want to prevent spam.

## Advanced DOM Features

### phx-update: Control Patching Behavior

```heex
<!-- Default: patch the element -->
<div phx-update="patch">Updated content</div>

<!-- Replace entire element -->
<div phx-update="replace">Replaced entirely</div>

<!-- Stream mode for efficient list updates -->
<div :for={item <- @items} :key={item.id} phx-update="stream">
  {item.name}
</div>

<!-- Ignore server updates -->
<div phx-update="ignore">Never changes</div>
```

### phx-mounted / phx-remove: Lifecycle Hooks

```heex
<!-- Run JS commands when element enters DOM -->
<div phx-mounted={JS.show()}>
  Animated in...
</div>

<!-- Run JS commands when element removed -->
<div phx-remove={JS.hide()}>
  Animated out...
</div>
```

### Scroll Pagination

**phx-viewport-top / phx-viewport-bottom**: Detect container edges

```heex
<div id="items-container" phx-viewport-bottom="load-more" phx-throttle="500">
  <div :for={item <- @items}>{item}</div>
</div>
```

Fires when the specified edge reaches the viewport. Throttle prevents excessive events. Perfect for infinite scrolling.

### Connection State Awareness

**phx-connected / phx-disconnected**: Respond to connection changes

```heex
<!-- Show only when connected -->
<div phx-connected={JS.show()} phx-disconnected={JS.hide()}>
  Live indicators...
</div>
```

Useful for displaying connection status or disabling live features offline.

## Event Handler Signature

All events route to `handle_event/3`:

```elixir
def handle_event(event_name, params, socket) do
  case event_name do
    "delete" ->
      {:noreply, assign(socket, :message, "Deleted")}

    "validate" ->
      {:noreply, assign(socket, :errors, validate(params))}

    _ ->
      {:noreply, socket}
  end
end
```

- **event_name**: String from `phx-click="name"`, etc.
- **params**: Map of `phx-value-*` attributes and form data
- **socket**: Current LiveView state

## Preventing Default Behavior

Use JavaScript hooks to prevent default submission:

```javascript
export default {
  mounted() {
    this.el.addEventListener("submit", (e) => {
      if (!shouldSubmit()) {
        e.preventDefault();
      }
    });
  },
};
```

Or use `phx-trigger-action="true"` on forms to submit to HTTP routes after LiveView validation.

---

[← Back to main](phoenix_live_view-1.1.32.md)
**Version:** 1.1.32
