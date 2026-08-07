# phoenix_live_view - JavaScript Interoperability

## Core Setup

Phoenix LiveView enables client-server interaction through a `LiveSocket` instance that manages real-time communication between the browser and server.

### Basic Initialization

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

This establishes the WebSocket connection to `/live` endpoint with CSRF protection.

## LiveSocket Configuration Options

### Essential Options

| Option          | Type     | Purpose                                                    |
| --------------- | -------- | ---------------------------------------------------------- |
| `bindingPrefix` | String   | Customizes prefix for Phoenix bindings (default: `"phx-"`) |
| `params`        | Object   | Connection parameters passed to mount callback             |
| `hooks`         | Object   | User-defined hook callbacks                                |
| `uploaders`     | Object   | Custom file upload handlers                                |
| `metadata`      | Function | Sends additional user data with events                     |

### Configuration Example

```javascript
let liveSocket = new LiveSocket("/live", Socket, {
  bindingPrefix: "live-", // Use live- instead of phx-
  params: {
    _csrf_token: csrfToken,
    user_id: userId,
  },
  hooks: {
    MyHook: MyHookComponent,
  },
  metadata: (el, evt) => ({
    timestamp: Date.now(),
    userAgent: navigator.userAgent,
  }),
});
```

## Essential LiveSocket Methods

### Connection Management

```javascript
liveSocket.connect(); // Establish connection
liveSocket.disconnect(); // Close connection
liveSocket.reconnect(); // Reconnect after disconnect
```

### Debugging

```javascript
liveSocket.enableDebug(); // Enable debug logging
liveSocket.disableDebug(); // Disable debug logging
liveSocket.enableLatencySim(2000); // Simulate 2000ms latency
liveSocket.disableLatencySim(); // Remove latency simulation
```

## Client Hooks

Hooks attach JavaScript callbacks to HTML elements via the `phx-hook` attribute. They provide lifecycle event handling for custom client-side behavior.

### Hook Lifecycle Events

```javascript
let MyHook = {
  mounted() {
    // Called when element added to DOM
    console.log("Element mounted:", this.el);
    this.el.addEventListener("click", () => this.pushEvent("clicked"));
  },

  updated() {
    // Called when element modified by server
    this.updateUI();
  },

  destroyed() {
    // Called when element removed from page
    this.cleanup();
  },

  disconnected() {
    // Called when server connection lost
    this.showOfflineMessage();
  },

  reconnected() {
    // Called when server connection restored
    this.hideOfflineMessage();
  },
};

export default {
  MyHook,
};
```

### Hook Methods

Within hooks, use these methods to communicate:

#### pushEvent(event, payload, onReply)

Send data from client to server:

```javascript
mounted() {
  this.pushEvent("item_clicked", {item_id: 123}, (reply) => {
    console.log("Server responded:", reply)
  })
}
```

#### handleEvent(event, callback)

Receive events pushed from server:

```javascript
mounted() {
  this.handleEvent("update_ui", (data) => {
    this.el.innerHTML = data.html
  })
}
```

### Registering Hooks

```heex
<script>
  import {Socket} from "phoenix"
  import {LiveSocket} from "phoenix_live_view"
  import {MyHook} from "./hooks"

  let liveSocket = new LiveSocket("/live", Socket, {
    hooks: {MyHook}
  })
</script>

<!-- Use hook in template -->
<div phx-hook="MyHook" id="my-element">
  Content
</div>
```

## Bidirectional Communication

### Server to Client: push_event/3

Push events from server to all clients viewing a LiveView:

```elixir
def handle_event("subscribe_to_notifications", _params, socket) do
  {:noreply,
    push_event(socket, "notification", %{
      message: "New message received",
      icon: "bell"
    })
  }
end
```

Client receives as window event with `phx:` prefix:

```javascript
window.addEventListener("phx:notification", (e) => {
  showNotification(e.detail.message);
});
```

### Client to Server: pushEvent()

Send data from hook to server:

```javascript
let MyHook = {
  mounted() {
    this.pushEvent("record_view", { page: "dashboard" });
  },
};
```

Server handler:

```elixir
def handle_event("record_view", %{"page" => page}, socket) do
  Logger.info("User viewed: #{page}")
  {:noreply, socket}
end
```

## Metadata Injection

Add custom metadata to all server events:

```javascript
let liveSocket = new LiveSocket("/live", Socket, {
  metadata: (el, evt) => ({
    timestamp: Date.now(),
    userAgent: navigator.userAgent,
    locale: navigator.language,
    screen: {
      width: window.innerWidth,
      height: window.innerHeight,
    },
  }),
});
```

Server receives metadata in `handle_event`:

```elixir
def handle_event(_event, params, socket) do
  %{
    "timestamp" => ts,
    "screen" => %{"width" => w, "height" => h}
  } = params

  {:noreply, socket}
end
```

## JavaScript DOM Manipulation (JS Module)

The `Phoenix.LiveView.JS` module enables client-side operations from templates without server round trips.

### Common JS Operations

```heex
<!-- Toggle visibility -->
<button phx-click={JS.toggle(to: "#menu")}>Menu</button>

<!-- Show/Hide elements -->
<button phx-click={JS.show(to: ".modal")}>Show Modal</button>
<button phx-click={JS.hide(to: ".modal")}>Hide Modal</button>

<!-- Add/Remove CSS classes -->
<button phx-click={JS.add_class("active", to: "#tab-1")}>
  Activate Tab 1
</button>

<!-- Focus element -->
<button phx-click={JS.focus(to: "#search-input")}>
  Focus Search
</button>

<!-- Compose multiple commands -->
<button phx-click={
  JS.toggle(to: "#menu")
  |> JS.add_class("open")
  |> JS.focus(to: "#menu")
}>
  Complex Action
</button>
```

## Connection State Handling

React to connection changes with JS commands:

```heex
<div phx-connected={JS.hide()} phx-disconnected={JS.show()}>
  <div class="alert alert-warning">
    You are offline. Changes won't be saved.
  </div>
</div>
```

---

[← Back to main](phoenix_live_view-1.2.8.md)
**Version:** 1.2.8
