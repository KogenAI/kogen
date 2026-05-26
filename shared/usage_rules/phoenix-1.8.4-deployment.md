# phoenix - Deployment

## Three Core Deployment Steps

Deploying a Phoenix application requires addressing three fundamental requirements:

1. **Secret Management** — Secure storage of sensitive data (database credentials, API keys, session secrets)
2. **Asset Compilation** — Build and digest static files for efficient production serving
3. **Server Initialization** — Launch the application with proper environment configuration

## Secret Management

All sensitive data must be stored in environment variables loaded at runtime via `config/runtime.exs`, never hardcoded in configuration files.

**1. Define environment variables in `config/runtime.exs`:**

```elixir
config :hello, HelloWeb.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  url: [
    host: System.get_env("PHX_HOST", "localhost"),
    port: 443
  ]

config :hello, Hello.Repo,
  username: System.fetch_env!("DB_USER"),
  password: System.fetch_env!("DB_PASSWORD"),
  database: System.fetch_env!("DB_NAME"),
  hostname: System.fetch_env!("DB_HOST"),
  port: String.to_integer(System.get_env("DB_PORT", "5432"))
```

**2. Generate a new secret key for production:**

```bash
mix phx.gen.secret
# Output: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f
```

**3. Set environment variables in your deployment environment:**

- Docker: Use `--env` or `.env` files
- Systemd: Set in service file or environment file
- Heroku/Fly.io: Use platform dashboard or `heroku config:set KEY=value`
- Cloud platforms: Use managed secrets/environment variable services

## Asset Compilation

Compile static assets for production:

```bash
MIX_ENV=prod mix assets.deploy
```

This command:

- Builds JavaScript and CSS via your asset pipeline (Tailwind, esbuild, etc.)
- Generates a cache manifest (`priv/static/cache_manifest.json`)
- Digests files with content-based hashes for cache busting

Update `priv/static.manifest.json` in your deployment so Phoenix serves digested asset paths.

## Server Initialization

Launch the application with proper environment configuration:

```bash
export MIX_ENV=prod
export SECRET_KEY_BASE="your-generated-secret"
export DB_HOST="postgres.example.com"
export DB_USER="db_user"
export DB_PASSWORD="secure_password"
export DB_NAME="hello_prod"
export PHX_HOST="example.com"
export PORT=4001

# Run server
mix phx.server
```

Or using Elixir releases (recommended for production):

```bash
MIX_ENV=prod mix release
_build/prod/rel/hello/bin/hello start
```

## Recommended Deployment Workflow

A typical deployment script:

```bash
#!/bin/bash
set -e

MIX_ENV=prod

# 1. Fetch dependencies (production only)
mix deps.get --only prod

# 2. Compile code
mix compile

# 3. Compile and digest assets
mix assets.deploy

# 4. Prepare database
mix ecto.migrate

# 5. Start server
PORT=4001 MIX_ENV=prod mix phx.server
```

Or with Elixir releases:

```bash
#!/bin/bash
set -e

# 1. Set environment variables from secrets
export SECRET_KEY_BASE=$(cat /run/secrets/secret_key_base)
export DB_HOST=$(cat /run/secrets/db_host)
# ... set other secrets

# 2. Build release
MIX_ENV=prod mix release

# 3. Run migrations
_build/prod/rel/hello/bin/hello eval "Hello.Release.migrate"

# 4. Start application
_build/prod/rel/hello/bin/hello start
```

## Elixir Releases

Elixir releases bundle your application into a standalone package with its own Erlang runtime, simplifying deployment.

**Generate a release configuration:**

```bash
mix release.init
```

**Build the release:**

```bash
MIX_ENV=prod mix release
```

**Start the release:**

```bash
_build/prod/rel/hello/bin/hello start
```

**Management commands:**

```bash
_build/prod/rel/hello/bin/hello start          # Start application
_build/prod/rel/hello/bin/hello stop           # Stop gracefully
_build/prod/rel/hello/bin/hello restart        # Restart
_build/prod/rel/hello/bin/hello eval "Code"   # Run Elixir code
```

**Custom release tasks** in `lib/hello/release.ex`:

```elixir
defmodule Hello.Release do
  def migrate do
    load_app()
    {:ok, _} = Ecto.Migrator.with_repo(Hello.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  defp load_app do
    Application.load(:hello)
  end
end
```

Call from release: `_build/prod/rel/hello/bin/hello eval "Hello.Release.migrate"`

## Multi-Server Deployments

For applications running on multiple machines, special considerations apply to real-time features:

**Long Polling (less efficient):**

When using long polling with multiple servers, implement either:

1. **Erlang clustering** — Nodes communicate via built-in Erlang distribution (requires network connectivity)
2. **Redis PubSub** — Centralized message broker for broadcasting across nodes
3. **Sticky sessions** — Router directs client requests to the same server

Configure in `config/prod.exs`:

```elixir
# Option 1: Erlang clustering
config :hello, Hello.PubSub,
  adapter: Phoenix.PubSub.PG2

# Option 2: Redis PubSub
config :hello, Hello.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.get_env("REDIS_URL", "redis://localhost:6379")
```

**WebSockets:**

More efficient than long polling; requires a load balancer with sticky sessions or a WebSocket-aware routing layer.

## Common Deployment Platforms

Phoenix has official or community support for deploying to:

- **Elixir Releases** — Any Linux server or Docker container
- **Fly.io** — Built-in Phoenix support with `fly launch`
- **Gigalixir** — Specialized Elixir PaaS
- **Heroku** — Community buildpack available
- **Render, Railway, DigitalOcean** — Community supported

## Database Migrations in Production

Always run migrations before starting the application:

```bash
# With mix
MIX_ENV=prod mix ecto.migrate

# With release
_build/prod/rel/hello/bin/hello eval "Hello.Release.migrate"
```

For zero-downtime deployments, ensure migrations are backwards compatible (add columns before removing them, make new columns nullable before requiring them).

## Health Checks

Implement a health check endpoint for load balancers:

```elixir
defmodule HelloWeb.HealthController do
  use HelloWeb, :controller

  def check(conn, _params) do
    case Ecto.Adapters.SQL.query(Hello.Repo, "SELECT 1") do
      {:ok, _} ->
        json(conn, %{status: "ok"})
      {:error, _} ->
        conn |> put_status(503) |> json(%{status: "unhealthy"})
    end
  end
end

# In router
scope "/health", HelloWeb do
  pipe_through :api
  get "/", HealthController, :check
end
```

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
