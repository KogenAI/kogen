# phoenix - Getting Started and Project Setup

## Installation Requirements

Phoenix requires three core dependencies:

1. **Elixir 1.15 or later** — The language Phoenix is written in
2. **Erlang 24 or later** — The runtime for Elixir execution
3. **PostgreSQL** — The default relational database (alternatives available via `--database` flag)

Verify your environment:

```bash
elixir -v
```

## Setting Up the Framework

Install the Phoenix generator:

```bash
mix archive.install hex phx_new
```

## Creating a New Project

### Standard Installation

```bash
mix phx.new hello
cd hello
mix deps.get
mix ecto.create
mix phx.server
```

The framework will prompt whether to install dependencies automatically.

### Express Installation (macOS/Ubuntu)

For immediate setup without manual installation:

```bash
curl https://new.phoenixframework.org/myapp | sh
```

This automatically installs Erlang, Elixir, and Phoenix, then generates a complete application with database selection (PostgreSQL, MySQL, or SQLite fallback).

## Project Generator Options

The `mix phx.new` command accepts several flags:

- `--database` — Choose database: `postgres` (default), `mysql`, `sqlite3`, `mssql`
- `--no-ecto` — Skip database setup for apps that don't need persistence
- `--no-html` — Skip HTML templates and Phoenix.HTML
- `--no-tailwind` — Exclude Tailwind CSS styling
- `--no-esbuild` — Skip JavaScript bundling
- `--no-live` — Exclude LiveView dependency
- `--live` — Explicit LiveView inclusion (recommended)

Example:

```bash
mix phx.new myapp --database mysql --no-tailwind
```

## Included Dependencies

By default, a Phoenix project bundles:

- **Ecto** — Database abstraction and migrations
- **Phoenix.HTML** — HTML helpers and form builders
- **TailwindCSS** — Utility-first CSS framework
- **Esbuild** — JavaScript bundler
- **Phoenix.LiveView** — Real-time server-rendered UI

All are optional and excludable during project generation.

## Initial Configuration

After generation, modify database credentials if needed:

```elixir
# config/dev.exs
config :hello, Hello.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hello_dev",
  stacktrace: true,
  show_sensitive_data_on_error: true
```

## Running the Development Server

```bash
mix phx.server
```

The server starts on `http://localhost:4000` by default. Code changes trigger automatic reloading thanks to inotify-tools (Linux) or native watchers (macOS/Windows).

## Common Mix Tasks

| Command                | Purpose                                          |
| ---------------------- | ------------------------------------------------ |
| `mix phx.server`       | Start development server on port 4000            |
| `mix ecto.create`      | Create the development database                  |
| `mix ecto.migrate`     | Run pending migrations                           |
| `mix ecto.rollback`    | Revert the last migration                        |
| `mix ecto.reset`       | Drop, create, and migrate database               |
| `mix phx.gen.resource` | Generate controller, view, schema, and migration |
| `mix phx.gen.auth`     | Scaffold user authentication                     |
| `mix test`             | Run test suite with ExUnit                       |

## Directory Structure

```
hello/
├── lib/
│   ├── hello/          # Business logic, schemas, contexts
│   └── hello_web/      # Web layer (controllers, views, routers)
├── test/               # Test files mirroring lib/ structure
├── config/             # Configuration files
├── priv/               # Private assets (migrations, seeds)
├── assets/             # JavaScript, CSS, and static files
└── mix.exs             # Project definition and dependencies
```

Key directories:

- `lib/hello_web/router.ex` — Route definitions
- `lib/hello_web/controllers/` — Controller modules
- `lib/hello_web/components/` — Reusable view components
- `lib/hello/repo.ex` — Database connection

## Database Setup Workflow

1. Create database: `mix ecto.create`
2. Generate resources: `mix phx.gen.resource Post posts title:string body:text`
3. Run migrations: `mix ecto.migrate`
4. Test with: `mix phx.server`

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
