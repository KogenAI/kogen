# phoenix_live_view - JavaScript Interoperability

## LiveSocket Initialization

Establish client-server communication by creating a `LiveSocket` instance in your application's main JavaScript entry point:

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

**Key configuration options:**

- **`bindingPrefix`** — Customizes the namespace for Phoenix bindings; default is `"phx-"`. Change to enable multiple LiveSocket instances with different prefixes.
- **`params`** — Passes connection parameters to the view's `mount/3` callback; can be an object or function returning an object
- **`hooks`** — Object mapping hook names to hook classes for `phx-hook` elements
- **`uploaders`** — Object mapping uploader names to direct-to-cloud file upload handlers
- **`metadata`** — Function that returns an object sent with every event (useful for context like scroll position or form state)

## Client Hooks via `phx-hook`

Hooks provide lifecycle callbacks for managing DOM elements and client state:

```heex
<div phx-hook="MyHook" id="my-element">Content</div>
```

```javascript
Hooks.MyHook = {
  mounted() {
    console.log("Element mounted in DOM");
  },
  beforeUpdate() {
    console.log("About to receive server update");
  },
  updated() {
    console.log("Server update applied");
  },
  destroyed() {
    console.log("Element removed from DOM");
  },
  disconnected() {
    console.log("WebSocket disconnected");
  },
  reconnected() {
    console.log("WebSocket reconnected");
  },
};

let liveSocket = new LiveSocket("/live", Socket, { hooks: Hooks });
```

## Lifecycle Callback Details

**`mounted()`** — Invoked after the element is added to the DOM and the server mount completes. Perfect for initializing third-party libraries (maps, charts, editors).

**`beforeUpdate()`** — Executes synchronously before server-driven DOM updates. Useful for capturing scroll position or input focus.

**`updated()`** — Runs after the server applies DOM changes. Useful for triggering animations or reinitializing JavaScript libraries.

**`destroyed()`** — Called when the element is removed from the DOM. Clean up event listeners and external resources.

**`disconnected()` / `reconnected()`** — React to WebSocket connection state changes for UI indicators or disabling interactions.

## Hook API Methods

Within hooks, access these methods:

**`this.pushEvent(event, payload, callback)`** — Send data to the LiveView:

```javascript
Hooks.Search = {
  mounted() {
    this.el.addEventListener("input", (e) => {
      this.pushEvent("search", { query: e.target.value }, (reply) => {
        console.log("Got results:", reply);
      });
    });
  },
};
```

**`this.handleEvent(event, callback)`** — Listen for server-pushed events:

```javascript
Hooks.Notifications = {
  mounted() {
    this.handleEvent("notify", ({ message }) => {
      alert(message);
    });
  },
};
```

**`this.js()`** — Access DOM manipulation commands for effects and transitions:

```javascript
Hooks.Modal = {
  mounted() {
    this.js()
      .show(transition: "fade-in")
      .then(() => console.log("visible"))
  }
}
```

**`this.upload(name, files)`** — Inject files into an uploader:

```javascript
Hooks.FileDropzone = {
  mounted() {
    this.el.addEventListener("drop", (e) => {
      e.preventDefault();
      this.upload("files", Array.from(e.dataTransfer.files));
    });
  },
};
```

## Server-to-Client Communication

Push events from the server using `push_event/3`:

```elixir
def handle_event("search", %{"query" => query}, socket) do
  results = Repo.search(query)
  {:reply, %{"results" => results}, socket}
end
```

Or broadcast to all connected clients via `push_event/3` from `handle_info`:

```elixir
def handle_info({:broadcast, data}, socket) do
  {:noreply, push_event(socket, "update", data)}
end
```

Receive events on the client with the `phx:` prefix:

```javascript
window.addEventListener("phx:update", (e) => {
  let { id, name } = e.detail;
  let el = document.getElementById(id);
  if (el) el.textContent = name;
});
```

## Colocated Hooks

Define hooks alongside component markup using `Phoenix.LiveView.ColocatedHook`:

```heex
<div id="my-hook" phx-hook="MyHook">Content</div>

<script>
Hooks.MyHook = {
  mounted() { console.log("mounted") }
}
</script>
```

This pattern works in `.heex` files and eliminates separate hook file management for simple interactions.

## DOM Manipulation via JS Commands

Both client hooks and `push_event/3` replies provide `js()` method for building command chains:

**Visual effects:**

```javascript
this.js()
  .show(transition: "fade-in", time: 300)
  .hide(transition: "fade-out", delay: 100)
  .toggle(to: "show")
```

**Class operations:**

```javascript
this.js()
  .add_class("active", to: "#nav")
  .remove_class("disabled", to: ".btn")
  .toggle_class("expanded", to: "#sidebar")
```

**Attribute manipulation:**

```javascript
this.js()
  .set_attribute("disabled", "true", to: "button")
  .remove_attribute("aria-label", to: "[data-role=dialog]")
```

**Navigation:**

```javascript
this.js()
  .push("save", {data: value})
  .navigate(to: "/users/123")
  .patch(to: "/search?q=#{value}")
```

Commands integrate seamlessly with server-side DOM patching, ensuring UI consistency.

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
