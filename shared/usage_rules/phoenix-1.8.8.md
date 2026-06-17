# phoenix

Phoenix is a production-grade web framework for Elixir that provides a full-stack solution for building web applications and APIs. Built on top of Plug, Phoenix offers powerful abstractions for routing, controllers, real-time communication via LiveView and WebSockets, and seamless Ecto database integration. The framework emphasizes developer productivity, testability, and performance through composable middleware pipelines and a strong convention-over-configuration approach.

Phoenix 1.8.8 introduces improvements to the development experience, asset management, and real-time features. It's designed for both traditional server-rendered applications with HTML templates and modern JSON APIs, supporting deployment scenarios from monoliths to distributed microservices.

## Quick Start

Install Phoenix by adding it to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:phoenix, "~> 1.8.8"}
  ]
end
```

Generate a new Phoenix application:

```bash
mix phx.new my_app
cd my_app
mix setup
mix phx.server
```

Access your app at `http://localhost:4000`.

For JSON-only APIs:

```bash
mix phx.new my_api --no-html --no-assets
```

## Documentation Sections

- [Routing & URL Generation](phoenix-1.8.8-routing.md) — Route definitions, verified routes, resource routing, and pipeline organization
- [Controllers & Rendering](phoenix-1.8.8-controllers.md) — Controller actions, response rendering, status codes, and request handling
- [Components & Templates](phoenix-1.8.8-components.md) — Function components, HEEx syntax, layouts, and UI composition
- [LiveView & Real-Time](phoenix-1.8.8-liveview.md) — Interactive applications, WebSocket connections, state management, and event handling
- [Plug Middleware](phoenix-1.8.8-plug.md) — Composable middleware, integration points, and request transformation
- [Database & Ecto Integration](phoenix-1.8.8-ecto.md) — Schema definition, changesets, queries, and data validation
- [JSON APIs & Error Handling](phoenix-1.8.8-json.md) — REST API scaffolding, JSON rendering, error responses, and API-only applications
- [Security & Best Practices](phoenix-1.8.8-security.md) — XSS prevention, CSRF protection, SQL injection mitigation, and authorization patterns

---

**Version:** 1.8.8  
**Source:** [hexdocs.pm/phoenix](https://hexdocs.pm/phoenix/1.8.8)  
**Generated:** 2026-06-17
