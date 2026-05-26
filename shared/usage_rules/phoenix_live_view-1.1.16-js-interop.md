# phoenix_live_view - JavaScript Interoperability

## LiveSocket Initialization

Phoenix LiveView establishes WebSocket connection through LiveSocket. Initialize in your JavaScript entry point:

```javascript
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
```

The LiveSocket manages WebSocket state, message serialization, DOM patching, and hook lifecycle. Always initialize with CSRF token for security.

## Server-Pushed Events

The server can dispatch events to the client using `push_event/3`:

```elixir
def handle_event("analyze", _params, socket) do
  Task.start_link(fn ->
    results = analyze_data()
    Process.send(socket.transport_pid, {:results, results}, [])
  end)
  {:noreply, socket}
end
```

In the client, listen for events prefixed with `phx:`:

```javascript
window.addEventListener("phx:results", (e) => {
  const { results } = e.detail;
  updateUI(results);
});
```

The event name will be dispatched in the browser with the `phx:` prefix. Payload data available in `event.detail`.

## Client Hooks: phx-hook

Hooks provide lifecycle callbacks for DOM elements managed by LiveView. Useful for integrating third-party libraries (charts, editors, maps) and custom behavior.

```javascript
let Hooks = {};

Hooks.Chart = {
  mounted() {
    this.el.chart = new ChartLibrary(this.el, this.getChartConfig());
  },

  updated() {
    this.el.chart.updateData(this.getChartConfig());
  },

  destroyed() {
    this.el.chart?.destroy();
  },

  getChartConfig() {
    return JSON.parse(this.el.dataset.config);
  },
};

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
});
```

Lifecycle methods:

- `mounted()` - Element added to DOM after LiveView mount
- `beforeUpdate()` - Element about to be updated (must be synchronous)
- `updated()` - Element updated in DOM
- `destroyed()` - Element removed from page
- `disconnected()` - LiveView connection lost
- `reconnected()` - LiveView connection re-established

## Hook Communication Patterns

**Client → Server:**
Use `pushEvent()` to send data from client to server:

```javascript
Hooks.Editor = {
  mounted() {
    this.el.addEventListener("change", () => {
      this.pushEvent("content_changed", { content: this.el.value });
    });
  },
};
```

Server-side handler:

```elixir
def handle_event("content_changed", %{"content" => content}, socket) do
  {:noreply, assign(socket, :content, content)}
end
```

**Server → Client:**
Use `handleEvent()` to listen for server-pushed events:

```javascript
Hooks.Notifier = {
  mounted() {
    this.handleEvent("show_notification", (payload) => {
      showNotification(payload.message);
    });
  },
};
```

Server code:

```elixir
push_event(socket, "show_notification", %{message: "Data saved!"})
```

## Colocated Hooks (Phoenix 1.8+)

Embed hook logic directly in components using `<script :type={ColocatedHook}>`:

```heex
<div id="chart-container" phx-hook="MyChart">
  <!-- content -->
</div>

<script :type={ColocatedHook} id="MyChart">
export default {
  mounted() {
    this.chart = new Chart(this.el)
  },
  updated() {
    this.chart.update()
  }
}
</script>
```

Namespacing through dot notation:

```heex
<div phx-hook="Dashboard.Chart" />
<div phx-hook="Dashboard.Table" />
```

Creates namespaced hooks under `Dashboard` namespace automatically.

## Utility Methods

Hooks expose utility methods for DOM and state manipulation:

**DOM Manipulation:**

- `this.el` - Current DOM element
- `this.el.dataset` - Data attributes
- JavaScript DOM APIs fully available

**Event Communication:**

- `this.pushEvent(event, payload)` - Send to server
- `this.pushEvent(event, payload, (reply) => {})` - Send with callback
- `this.handleEvent(event, callback)` - Listen for server events

**Lifecycle Control:**

- `this.destroy()` - Trigger element destruction
- `this.liveSocket` - Access LiveSocket instance for advanced usage

## JavaScript Interop Best Practices

- Use hooks for third-party library integration, not application logic
- Keep hooks focused on DOM manipulation and library bridging
- Move application logic to server-side LiveView callbacks
- Use phx-hook naming conventions consistently (CamelCase or snake_case)
- Clean up resources in `destroyed()` to prevent memory leaks
- Test hooks independently from LiveView by mocking communication

## Common Patterns

**Third-Party Library Integration:**

```javascript
Hooks.TinyMCE = {
  mounted() {
    tinymce.init({ target: this.el });
    tinymce.get(this.el.id).onRenderUI.add(() => {
      const content = tinymce.get(this.el.id).getContent();
      this.pushEvent("editor_change", { content });
    });
  },
  destroyed() {
    tinymce.get(this.el.id)?.remove();
  },
};
```

**Real-Time Collaboration:**

```javascript
Hooks.CollaborativeEditor = {
  mounted() {
    this.handleEvent("remote_update", ({ changes }) => {
      applyRemoteChanges(changes);
    });
  },
};
```

Server broadcasts changes to all connected clients via `push_event`.

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
