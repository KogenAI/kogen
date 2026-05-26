# Phoenix

Phoenix is a web development framework written in Elixir that implements the server-side Model View Controller (MVC) pattern. It combines high developer productivity with high application performance through pre-compiled templates, real-time channels, and a layered architecture that separates concerns. Phoenix is built on the Elixir runtime, providing fault tolerance and soft real-time communication capabilities suitable for modern web applications.

## Quick Start

Install Phoenix using the installer:

```bash
mix escript.install hex phx_new
phx.new my_app
cd my_app
mix phx.setup
mix phx.server
```

Access the application at `http://localhost:4000`. The generated application includes PostgreSQL integration via Ecto, asset compilation via esbuild and Tailwind CSS, and test infrastructure with ExUnit.

## Documentation Sections

- [Request Lifecycle & Routing](phoenix-1.8.7-routing.md) — Endpoints, routers, controllers, and request flow
- [Views & Templates](phoenix-1.8.7-views.md) — HEEx templates, function components, and presentation logic
- [Ecto & Database Layer](phoenix-1.8.7-ecto.md) — Schema generation, changesets, migrations, and data validation
- [Real-Time with Channels](phoenix-1.8.7-channels.md) — WebSocket communication, PubSub, and bi-directional messaging
- [Testing](phoenix-1.8.7-testing.md) — ExUnit integration, controller tests, and test organization
- [Asset Management](phoenix-1.8.7-assets.md) — JavaScript bundling, CSS compilation, and static files
- [Telemetry & Monitoring](phoenix-1.8.7-telemetry.md) — Event-driven observability and metrics collection
- [Deployment](phoenix-1.8.7-deployment.md) — Production setup, secrets management, and release configuration

---

**Version:** 1.8.7
**Source:** [hexdocs.pm/phoenix](https://hexdocs.pm/phoenix/)
**Generated:** 2026-05-09
