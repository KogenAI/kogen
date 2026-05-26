# Phoenix - Deployment

## Deployment Overview

Phoenix production deployment requires three core steps: managing application secrets through environment variables, compiling assets for browser delivery, and starting the server with proper configuration.

## Secret Management

### SECRET_KEY_BASE

Generate a unique secret for session signing and encryption:

```bash
mix phx.gen.secret
```

Store in environment variable `SECRET_KEY_BASE` and load at boot:

```elixir
# config/runtime.exs
config :my_app, MyApp.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
```

Never hardcode or commit secrets to version control. Provide during deployment via environment variables or secret management systems (AWS Secrets Manager, HashiCorp Vault, etc.).

### Database Connection

Specify database connection through `DATABASE_URL` environment variable:

```bash
export DATABASE_URL="postgresql://user:password@host:5432/database"
```

Load in runtime configuration:

```elixir
# config/runtime.exs
config :my_app, MyApp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
```

### Additional Secrets

Store API keys, external service credentials, and other secrets as environment variables:

```elixir
config :my_app, :stripe_api_key,
  System.fetch_env!("STRIPE_API_KEY")

config :my_app, :aws_access_key,
  System.fetch_env!("AWS_ACCESS_KEY_ID")
```

## Asset Compilation

Compile static assets for production:

```bash
MIX_ENV=prod mix assets.deploy
```

This task:

1. Minifies JavaScript via esbuild
2. Compiles Tailwind CSS with tree-shaking
3. Adds content-based hashes to filenames
4. Generates `priv/static/assets/cache_manifest.json`
5. Optionally gzip-compresses assets

Output appears in `priv/static/assets/`:

```
priv/static/assets/
  css/
    app.ABCD1234.css
    app.ABCD1234.css.gz
  js/
    app.WXYZ5678.js
    app.WXYZ5678.js.gz
  cache_manifest.json
```

Phoenix automatically serves digested filenames in production.

## Complete Deployment Script

A practical multi-step deployment:

```bash
#!/bin/bash
set -e

# Fetch dependencies (prod only)
mix deps.get --only prod

# Compile application
MIX_ENV=prod mix compile

# Compile assets
MIX_ENV=prod mix assets.deploy

# Run database migrations
MIX_ENV=prod mix ecto.migrate

# Start server
PORT=4001 MIX_ENV=prod mix phx.server
```

## Production Server Startup

### Standard Startup

```bash
PORT=4000 MIX_ENV=prod mix phx.server
```

This starts the server in foreground, suitable for containerized deployments (Docker, Kubernetes).

### Detached (Background)

For non-containerized deployments, start detached:

```bash
elixir --erl "-detached" -S mix phx.server
```

The server runs in background; view logs via:

```bash
tail -f /path/to/erl_crash.dump  # or application-specific log file
```

### Interactive Debugging

Start with interactive shell for RPC access:

```bash
iex -S mix phx.server
```

Or after starting, connect remotely:

```bash
iex --sname debug --cookie secret_cookie --remsh app@127.0.0.1
```

## Configuration for Multiple Nodes

When deploying across multiple machines:

### Erlang Clustering

Enable clustering for shared PubSub:

```elixir
# config/runtime.exs
if System.get_env("CLUSTERING_ENABLED") do
  config :libcluster,
    topologies: [
      k8s: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: "my-app",
          namespace: "default",
          polling_interval: 10_000
        ]
      ]
    ]
end
```

### Redis PubSub

For non-clustered deployments, use Redis as PubSub backend:

```elixir
# config/runtime.exs
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.fetch_env!("REDIS_URL")
```

### Sticky Sessions

For Long Polling transports on load-balanced deployments, ensure clients connect to the same server:

```elixir
config :my_app, MyApp.Endpoint,
  socket: [
    longpoll: [
      path: "/socket",
      period: 30_000
    ]
  ]
```

Configure load balancer to route by session cookie.

## Environment Configuration

### Development vs Production

Separate configuration by environment:

```bash
# Development
MIX_ENV=dev mix phx.server

# Production
MIX_ENV=prod mix phx.server

# Test
MIX_ENV=test mix test
```

### Runtime Secrets

Load secrets only at boot via `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

config :my_app, MyApp.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  url: [
    host: System.get_env("HOST") || "localhost",
    port: String.to_integer(System.get_env("PORT") || "4000")
  ]

config :my_app, MyApp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
```

Compile-time config in `config/config.exs` and environment-specific files (`config/dev.exs`, `config/prod.exs`) remain for non-secret settings.

## Monitoring and Health Checks

### Health Check Endpoint

Implement a simple health status endpoint:

```elixir
# lib/my_app_web/controllers/health_controller.ex
defmodule MyApp.HealthController do
  use MyApp, :controller

  def status(conn, _params) do
    status = if database_alive?() do
      :ok
    else
      :service_unavailable
    end

    json(conn, status)
  end

  defp database_alive? do
    Ecto.Adapters.SQL.query!(MyApp.Repo, "SELECT 1") != nil
  rescue
    _ -> false
  end
end

# lib/my_app_web/router.ex
scope "/" do
  pipe_through :api

  get "/health", HealthController, :status
end
```

### Metrics and Logging

Enable structured logging for production:

```elixir
config :logger,
  backends: [
    {Logger.Backends.Console, format: :json}
  ]
```

Collect telemetry metrics and export to monitoring backend (Datadog, New Relic, Prometheus).

## Release Generation

For containerized or managed deployments, generate OTP releases:

```bash
mix release
```

Creates `_build/prod/rel/my_app/` with standalone executable:

```bash
_build/prod/rel/my_app/bin/my_app start
_build/prod/rel/my_app/bin/my_app stop
_build/prod/rel/my_app/bin/my_app remote
```

## Common Issues

### Asset Digest Errors

If assets fail to load with "manifest not found" error, ensure `mix assets.deploy` ran successfully before starting the server.

### Long Polling with Multiple Nodes

Long Polling requires either Erlang clustering or Redis PubSub for message delivery across nodes. Without one, clients on different nodes won't receive broadcasts.

### Secret Rotation

For secret rotation without downtime:

1. Add new secret to environment
2. Update code to accept both old and new secrets
3. Restart server
4. Remove old secret from environment

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
