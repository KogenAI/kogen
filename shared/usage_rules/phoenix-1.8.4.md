# phoenix

Phoenix is an MVC web framework written in Elixir that provides an integrated platform for building modern web applications. Built on the Erlang VM, Phoenix leverages Elixir's concurrency and fault-tolerance capabilities to deliver high-performance, scalable applications. The framework combines server-side rendering, real-time communication via WebSockets, and a comprehensive set of tools for data persistence, validation, and deployment.

Phoenix emphasizes productivity through convention over configuration, code generation, and verified routes that catch routing errors at compile time. It integrates seamlessly with Ecto for database operations, provides built-in testing infrastructure via ExUnit, and supports both traditional request-response patterns and soft real-time communication with millions of concurrent clients.

## Quick Start

**Installation Requirements:**

- Elixir 1.15 or later
- Erlang 24 or later
- PostgreSQL (default database; MySQL, MSSQL, SQLite3 supported via `--database` flag)
- On Linux: `inotify-tools` for live reloading

**Generate a new Phoenix application:**

```bash
mix archive.install hex phx_new
mix phx.new hello --database postgres
cd hello
mix ecto.create
mix phx.server
```

Visit `http://localhost:4000` to see the running application.

## Documentation Sections

- [Routing & Routes](phoenix-1.8.4-routing.md)
- [Controllers & Actions](phoenix-1.8.4-controllers.md)
- [Plugs & Middleware](phoenix-1.8.4-plugs.md)
- [Testing](phoenix-1.8.4-testing.md)
- [Ecto & Database Integration](phoenix-1.8.4-ecto.md)
- [Channels & Real-Time Communication](phoenix-1.8.4-channels.md)
- [Deployment](phoenix-1.8.4-deployment.md)

---

**Version:** 1.8.4
**Source:** [hexdocs.pm/phoenix](https://hexdocs.pm/phoenix/)
**Generated:** 2026-04-25
