# phoenix

Phoenix is a web development framework built with Elixir that implements the server-side Model View Controller (MVC) pattern. It provides high developer productivity and high application performance by combining familiar architecture patterns with real-time capabilities and pre-compiled templates. The framework offers built-in channels for real-time features, and developers familiar with Rails or Django will recognize many components and concepts.

Phoenix is built on top of Plug, a specification for composable HTTP modules, and integrates seamlessly with Ecto for data modeling and database operations. The framework supports multiple databases including PostgreSQL, MySQL, MSSQL, and SQLite, with PostgreSQL as the default. Phoenix emphasizes code organization, type safety through pattern matching, and developer ergonomics.

## Quick Start

### Installation

Phoenix v1.8.9 offers two primary methods for creating new applications:

**Express Installation (Recommended):**

```bash
curl https://new.phoenixframework.org/myapp | sh
```

Windows PowerShell:

```bash
curl.exe -fsSO https://new.phoenixframework.org/myapp.bat; .\myapp.bat
```

**Using mix phx.new:**

```bash
mix phx.new hello
```

### Initial Setup

After generating your project:

```bash
cd hello
mix ecto.create
mix phx.server
```

Your application will be accessible at http://localhost:4000.

By default, the generator includes Ecto, Phoenix.HTML, TailwindCSS, and Phoenix.LiveView. You can exclude these with flags like `--no-ecto`, `--no-html`, or `--no-live`.

## Documentation Sections

- [Routing & URLs](phoenix-1.8.9-routing.md)
- [Controllers & Actions](phoenix-1.8.9-controllers.md)
- [Channels & Real-Time](phoenix-1.8.9-channels.md)
- [LiveView & Reactive UIs](phoenix-1.8.9-liveview.md)
- [Plug & Middleware](phoenix-1.8.9-plug.md)
- [Ecto & Data Modeling](phoenix-1.8.9-ecto.md)
- [Testing & Quality Assurance](phoenix-1.8.9-testing.md)
- [Deployment & Production](phoenix-1.8.9-deployment.md)

---

**Version:** 1.8.9
**Source:** [phoenix.hexdocs.pm](https://phoenix.hexdocs.pm/1.8.9/)
**Generated:** 2026-08-07
