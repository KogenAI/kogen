# live_debugger

LiveDebugger is a browser-based debugging tool for Phoenix LiveView applications. It provides developers with a visual interface to inspect component hierarchies, examine assigns, trace callbacks, and highlight components during development.

## Quick Start

### Installation

Add to your `mix.exs` as a dev-only dependency:

```elixir
{:live_debugger, "~> 0.4.0", only: :dev}
```

### Enable in Your App

Add to your root layout file (`lib/my_app_web/components/layouts/root.html.heex`):

```heex
<%= Application.get_env(:live_debugger, :live_debugger_tags) %>
```

Alternatively, use Igniter for automatic setup:

```bash
mix igniter.install live_debugger
```

### Access LiveDebugger

Once your development server is running, access the debugger at:

```
http://localhost:4007
```

## Core Concepts

### Components Tree

Displays the hierarchical structure of LiveComponents within a LiveView. The tree:

- Shows the root LiveView and all child LiveComponents identified by CIDs (Component IDs)
- Updates automatically when component state changes
- Auto-collapses when displaying many elements
- Does NOT show nested LiveViews (they operate as separate processes)

### Key Features

**Assigns Inspection** - Examine assigns for both LiveViews and LiveComponents in real-time

**Callback Tracing** - Monitor and trace callback executions to understand component lifecycle and interactions

**Component Highlighting** - Visually highlight components within the running application for direct identification

**Elements Inspection** - Inspect page elements and their associated LiveView/LiveComponent context

**Nested LiveView Navigation** - Access child LiveViews through a flattened sidebar structure with parent navigation links

## Configuration

### Browser Features

Control which features are injected into your application:

```elixir
# Disable all injection
config :live_debugger, :browser_features?, false

# Disable debug button only
config :live_debugger, :debug_button?, false

# Disable component highlighting
config :live_debugger, :highlighting?, false
```

### Network Configuration

**Custom Port** (default: 4007):

```elixir
config :live_debugger, :port, 4007
```

**Custom Host** (default: 127.0.0.1):

```elixir
config :live_debugger, :host, "127.0.0.1"
```

**External URL** (for containerized environments):

```elixir
config :live_debugger, :external_url, "http://localhost:9007"
```

## Best Practices

### Security

**Dev-Only Dependency** - Never include LiveDebugger in production. Keep it strictly as a `:dev` dependency.

**Content Security Policy** - If using CSP headers, add LiveDebugger's host to your allowed list in development:

```
"http://127.0.0.1:4007"
```

### Performance

- **Code Reload Tracing** - Be aware that enabling code reload tracing has performance implications. Use selectively for specific debugging sessions.
- **Distributed Deployments** - A configurable setup delay supports multi-node environments where trace initialization timing matters.

### Workflow Tips

- **Component Highlighting** - Use the highlighting feature to visually identify which components correspond to DOM elements
- **Assigns Inspection** - Regularly check assigns to verify data flow between parent and child components
- **Tree Navigation** - Reference the Components Tree when debugging nested component interactions
- **Callback Monitoring** - Enable callback tracing when diagnosing unexpected behavior in component lifecycle

---

**Version:** 0.4.1
**Source:** [hexdocs.pm/live_debugger](https://hexdocs.pm/live_debugger/)
**Generated:** 2025-10-28
