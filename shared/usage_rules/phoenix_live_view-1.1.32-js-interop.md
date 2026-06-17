# phoenix_live_view - JavaScript Interoperability

## LiveSocket Initialization

Set up the client-side connection in your app layout:

```javascript
// assets/js/app.js
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
```

The LiveSocket establishes the WebSocket connection and enables all interactive features.

## LiveSocket Configuration Options

```javascript
const liveSocket = new LiveSocket("/live", Socket, {
  // Connection parameters sent to mount/3
  params: { _csrf_token: csrfToken, user_id: 123 },

  // Enable/disable debug logging
  hooks: HookNamespace,

  // DOM binding prefix (default: "phx-")
  bindingPrefix: "phx-",

  // Custom metadata sent with events
  metadata: {
    keydown: (e) => ({ key: e.key, code: e.code }),
    keyup: (e) => ({ key: e.key, code: e.code }),
  },

  // Direct-to-cloud upload handlers
  uploaders: {
    S3: (entries) => {
      /* return signed URLs */
    },
  },

  // Event interception
  onBeforeElUpdated: (from, to) => {
    /* validate updates */
  },
  onNodeAdded: (node) => {
    /* react to additions */
  },
});
```

## Client Hooks

Hooks provide lifecycle callbacks for custom JavaScript:

```javascript
// assets/js/hooks.js
const Hooks = {
  MyHook: {
    mounted() {
      console.log("Hook mounted!");
      this.element.innerHTML = "Custom content";
    },

    updated() {
      console.log("Element was updated");
    },

    beforeUpdate() {
      // Synchronous only - runs before update
      console.log("About to update");
    },

    destroyed() {
      console.log("Element removed from DOM");
    },

    disconnected() {
      console.log("Lost connection to server");
    },

    reconnected() {
      console.log("Reconnected!");
    },
  },
};
```

Register hooks in LiveSocket:

```javascript
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
});
```

Use in templates:

```heex
<div phx-hook="MyHook">
  Content
</div>
```

## Hook Helper Methods

Hooks have access to server communication and DOM manipulation:

### pushEvent(eventName, payload, callback)

Send custom events to the server:

```javascript
MyHook: {
  mounted() {
    this.pushEvent("custom-event", { data: "test" }, (reply) => {
      console.log("Server replied:", reply);
    });
  }
}
```

Server-side handler:

```elixir
def handle_event("custom-event", %{"data" => data}, socket) do
  {:reply, %{"status" => "received"}, socket}
end
```

### handleEvent(eventName, callback)

Listen for server-pushed events:

```javascript
MyHook: {
  mounted() {
    this.handleEvent("server-event", (payload) => {
      console.log("Got event from server:", payload);
    });
  }
}
```

Server-side push:

```elixir
push_event(socket, "server-event", %{message: "Hello from server"})
```

### this.el & this.pushEventTo

Reference the hook element and target specific components:

```javascript
MyHook: {
  mounted() {
    this.el.addEventListener("click", () => {
      this.pushEventTo("#component-id", "component-event", {});
    });
  }
}
```

## Colocated Hooks

Modern Phoenix supports embedding hooks directly in templates:

```heex
<div id="my-element">
  Content
</div>

<script :type={Phoenix.LiveView.ColocatedHook}>
  export default {
    mounted() {
      console.log("Hook mounted:", this.el);
    }
  }
</script>
```

This reduces file fragmentation and keeps component logic together.

## JS Commands

Execute DOM manipulations and navigation from the server:

### Server-Side (Elixir)

```elixir
def handle_event("click", _params, socket) do
  {:noreply,
   push_event(socket, "js-exec", %{
     to: "#modal",
     cmd: "show"
   })}
end

# Or use JS module
import Phoenix.LiveView.JS

def handle_event("open-modal", _params, socket) do
  {:noreply,
   socket
   |> JS.show(to: "#modal")
   |> JS.focus(to: "#input")
   |> push_event("js-exec", %{})}
end
```

### Client-Side (JavaScript)

```javascript
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {
    MyComponent: {
      mounted() {
        // Available JS commands
        this.js()
          .show()           // Show element
          .hide()           // Hide element
          .toggle()         // Toggle visibility
          .addClass("active")
          .removeClass("inactive")
          .toggleClass("open")
          .setAttribute("data-state", "ready")
          .removeAttribute("disabled")
          .toggleAttribute("aria-expanded")
          .transition(millis)  // CSS transition
          .transition([[property, value], ...], millis)
          .push("event-name", {payload})
          .navigate({href: "/path"})
          .patch({href: "/path"})
          .exec(js_func)
      }
    }
  }
});
```

In templates, use `phx-mounted` to trigger JS commands:

```heex
<div phx-mounted={JS.show(transition: {"ease-out duration-300", "opacity-0", "opacity-100"})}>
  Animated in...
</div>
```

## Server-Pushed Events

Send events from the server without waiting for client action:

```elixir
defmodule MyAppWeb.DashboardLive do
  def mount(_params, _session, socket) do
    if connected?(socket) do
      MyApp.PubSub.subscribe("dashboard-updates")
    end
    {:ok, assign(socket, :status, "pending")}
  end

  def handle_info({:update, data}, socket) do
    {:noreply, push_event(socket, "dashboard-update", data)}
  end
end
```

Client-side listener:

```javascript
Hooks.Dashboard = {
  mounted() {
    this.handleEvent("dashboard-update", (payload) => {
      console.log("Dashboard updated:", payload);
      document.querySelector(".status").textContent = payload.status;
    });
  },
};
```

## Combining Hooks and Bindings

Hooks augment but don't replace standard bindings. Use hooks for complex behavior:

```heex
<form id="my-form" phx-change="validate" phx-submit="save" phx-hook="FormManager">
  <input name="title" />
  <button type="submit">Save</button>
</form>

<script :type={Phoenix.LiveView.ColocatedHook}>
  export default {
    mounted() {
      // Enhance standard bindings
      this.el.addEventListener("submit", (e) => {
        if (!confirm("Save changes?")) {
          e.preventDefault();
        }
      });
    }
  }
</script>
```

## Regular (Non-LiveView) Pages

Hooks work on static pages if LiveSocket is connected. However, server-dependent features require a LiveView:

```heex
<!-- Regular controller page -->
<div phx-hook="Analytics">
  <!-- Hook works, can use hooks and JS commands -->
</div>

<!-- But phx-change, phx-click won't work without a LiveView -->
```

For static pages, use the `liveSocket.js()` interface:

```javascript
const js = liveSocket.js();
js.show(to: "#banner");
```

## Common Patterns

**Show/hide loading states**:

```javascript
MyComponent: {
  mounted() {
    this.handleEvent("loading-start", () => {
      this.el.classList.add("opacity-50");
    });

    this.handleEvent("loading-end", () => {
      this.el.classList.remove("opacity-50");
    });
  }
}
```

**Form validation feedback**:

```javascript
FormHook: {
  mounted() {
    this.el.addEventListener("input", (e) => {
      this.pushEvent("validate-field", {
        name: e.target.name,
        value: e.target.value
      });
    });
  }
}
```

**Track user presence**:

```javascript
PresenceHook: {
  mounted() {
    this.pushEvent("user-online", {});
  },
  destroyed() {
    this.pushEvent("user-offline", {});
  }
}
```

---

[← Back to main](phoenix_live_view-1.1.32.md)
**Version:** 1.1.32
