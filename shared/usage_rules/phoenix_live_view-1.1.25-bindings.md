# phoenix_live_view - Event Bindings & Interactions

## Click Events

`phx-click` sends click events to the server. Assign values with `phx-value-*` attributes:

```heex
<button phx-click="inc">Increment</button>
<button phx-click="delete" phx-value-id={item.id}>Delete</button>
```

Handle them in `handle_event/3`:

```elixir
def handle_event("inc", _value, socket) do
  {:noreply, update(socket, :count, &(&1 + 1))}
end

def handle_event("delete", %{"id" => id}, socket) do
  Repo.delete!(Repo.get(Item, id))
  {:noreply, assign(socket, :items, load_items())}
end
```

Use `phx-click-away` to detect clicks outside an element—useful for closing dropdowns:

```heex
<div id="dropdown" phx-click-away="close-dropdown">
  <button phx-click="toggle-dropdown">Menu</button>
  <ul :if={@dropdown_open}>
    <li><a href="#">Option 1</a></li>
  </ul>
</div>
```

## Focus & Blur Events

`phx-focus` and `phx-blur` fire when elements gain or lose focus:

```heex
<input name="email" phx-focus="email-focused" phx-blur="email-blurred" />
```

Use `phx-window-focus` and `phx-window-blur` for page-level detection:

```heex
<div phx-window-blur="hide-unsaved-changes" phx-window-focus="show-status">
  ...
</div>
```

## Key Events

`phx-keydown` and `phx-keyup` handle key presses. Filter specific keys with `phx-key`:

```heex
<input phx-keyup="search" phx-key="Enter" />
<input phx-keydown="handle-arrow" phx-key="ArrowUp" />
```

Use window-level key events:

```heex
<div phx-window-keydown="global-shortcut" phx-key="ctrl+s">...</div>
```

**Note:** Key events do not work on form inputs; use form bindings instead.

## Scroll Events

`phx-viewport-top` and `phx-viewport-bottom` detect when container edges enter the viewport. Ideal for infinite scrolling:

```heex
<div id="item-list" phx-viewport-bottom="load-more">
  <ul phx-update="stream">
    <li :for={{id, item} <- @streams.items} id={"item-#{id}"}>
      <%= item.name %>
    </li>
  </ul>
</div>
```

When the bottom of the list enters the viewport, `load-more` event fires:

```elixir
def handle_event("load-more", _value, socket) do
  items = load_next_page(socket.assigns.page)
  {:noreply, stream(socket, :items, items)}
end
```

## Rate Limiting

### Debounce

Delays event emission until either the debounce period expires or the user blurs the element:

```heex
<input phx-change="search" phx-debounce="300" />
<input phx-keyup="search" phx-debounce="blur" />
```

Default debounce is 300ms. Use "blur" to wait until the user leaves the field.

### Throttle

Emits immediately, then rate-limits subsequent events:

```heex
<div phx-window-scroll="scroll-position" phx-throttle="500"></div>
```

Fires on first scroll, then at most once every 500ms. Different form changes reset debounce timers.

## DOM Update Strategies

`phx-update` controls how elements update:

- **replace** (default) - replaces the entire element with new HTML
- **stream** - efficiently manages large collections (see streams guide)
- **ignore** - ignores template updates, preserves DOM state

```heex
<ul phx-update="stream">
  <li :for={{id, item} <- @streams.items} id={"item-#{id}"}>
    <%= item.name %>
  </li>
</ul>
```

## Lifecycle Events

`phx-mounted` runs JavaScript when an element mounts:

```heex
<input phx-mounted={JS.focus()} />
```

`phx-remove` runs JavaScript before element removal:

```heex
<div phx-remove={JS.transition("fade-out")}>
  Content that fades out on removal
</div>
```

## JavaScript Interoperability

The `Phoenix.LiveView.JS` module enables client-side operations from HEEx:

```heex
<button phx-click={JS.show(to: "#modal", transition: "fade-in")}>
  Show Modal
</button>
```

Compose commands:

```heex
<button phx-click={
  JS.push("save")
  |> JS.remove_class("unsaved", to: ".form")
  |> JS.show(to: "#success")
}>
  Save
</button>
```

Common JS commands: `JS.push`, `JS.show`, `JS.hide`, `JS.toggle`, `JS.add_class`, `JS.remove_class`, `JS.transition`, `JS.focus`, `JS.exec`.

## Custom Hooks

Integrate JavaScript libraries via `phx-hook`:

```heex
<input id="color-picker" phx-hook="ColorPicker" />
```

```javascript
// assets/js/color_picker.js
const ColorPicker = {
  mounted() {
    this.el.addEventListener("change", (e) => {
      this.pushEvent("color-picked", { color: e.target.value });
    });
  },
  updated() {},
};
export default ColorPicker;
```

Hooks have lifecycle callbacks: `mounted()`, `updated()`, `destroyed()`, `disconnected()`, `reconnected()`.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
