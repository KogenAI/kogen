# phoenix - Deployment and Production

## Core Deployment Steps

Deploying a Phoenix application involves three primary phases:

### 1. Secure Your Secrets

Store sensitive data in environment variables instead of hardcoding credentials. Phoenix loads these at startup:

```elixir
# config/runtime.exs (runs at startup in all environments)
config :myapp, MyappWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true

config :myapp, Myapp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true

config :myapp, MyappWeb.Mailer,
  api_key: System.get_env("SENDGRID_API_KEY")
```

Generate secret key:

```bash
mix phx.gen.secret
# Copy the output and set as SECRET_KEY_BASE environment variable
```

### 2. Compile Assets

Process and digest JavaScript and stylesheets for production serving:

```bash
MIX_ENV=prod mix assets.deploy
```

This generates:

- Minified CSS and JavaScript
- Cache manifest (`priv/static/cache_manifest.json`)
- Digested filenames for HTTP caching

### 3. Start the Production Server

Launch the application in production mode:

```bash
PORT=4001 MIX_ENV=prod mix phx.server
```

## Complete Deployment Script

A minimal production deployment:

```bash
#!/bin/bash
set -e

export MIX_ENV=prod

# Install dependencies
mix deps.get --only prod

# Compile application
mix compile

# Process assets
mix assets.deploy

# Run database migrations
mix ecto.migrate

# Start the server
PORT=4001 mix phx.server
```

For Docker deployments:

```dockerfile
FROM elixir:latest AS build

WORKDIR /app

# Copy dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copy source
COPY . .

# Compile
RUN MIX_ENV=prod mix compile

# Assets
RUN MIX_ENV=prod mix assets.deploy

# Runtime stage
FROM elixir:latest

WORKDIR /app
COPY --from=build /app/_build/prod ./
COPY --from=build /app/config ./config
COPY --from=build /app/lib ./lib
COPY --from=build /app/priv ./priv

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["mix", "phx.server"]
```

## Multi-Server Clustering

When deploying across multiple machines, consider transport and state management:

### Websocket Transport (Recommended)

WebSocket maintains a connection with a specific server—works naturally across load balancers with sticky sessions.

### Long-Polling Transport

Requires coordination between servers since clients don't maintain persistent connections. Options:

1. **Sticky Sessions** — Load balancer routes same user to same server

   ```nginx
   # Nginx configuration
   upstream app {
     least_conn;
     server app1:4000;
     server app2:4000;
     server app3:4000;
   }
   ```

2. **Erlang VM Clustering** — Connect Elixir nodes directly

   ```bash
   # Node 1
   iex --sname app1 -S mix phx.server

   # Node 2 (connects to node 1)
   iex --sname app2 -S mix phx.server
   ```

3. **Redis PubSub Adapter** — External coordination
   ```elixir
   # config/prod.exs
   config :myapp, Myapp.PubSub,
     adapter: Phoenix.PubSub.Redis,
     url: System.get_env("REDIS_URL")
   ```

## Environment Variables

Essential variables for production:

```bash
# Required
SECRET_KEY_BASE=<generated-value>
DATABASE_URL=ecto://<user>:<password>@<host>/<database>
PORT=4000

# Optional but recommended
LOG_LEVEL=info
POOL_SIZE=10
REDIS_URL=redis://localhost:6379
PHX_HOST=example.com
```

## Production Checklist

- [ ] Set `SECRET_KEY_BASE` from `mix phx.gen.secret`
- [ ] Configure `DATABASE_URL` with production database
- [ ] Set `PHX_HOST` to your domain (for URL generation)
- [ ] Set `PORT` (usually 4000)
- [ ] Run migrations before starting: `mix ecto.migrate`
- [ ] Set `MIX_ENV=prod`
- [ ] Compile assets: `mix assets.deploy`
- [ ] Use external PubSub (Redis) for multi-node setups
- [ ] Configure SSL/TLS at load balancer or with `force_ssl: true`
- [ ] Set appropriate log levels
- [ ] Monitor application health and errors

## Official Deployment Guides

Phoenix provides guides for:

- **Elixir Releases** — Self-contained compiled binaries
- **Gigalixir** — Elixir-specific hosting platform
- **Fly.io** — Container-based deployment
- **Heroku** — Traditional PaaS (legacy support)

Community platforms with guides:

- Render
- Railway
- DigitalOcean App Platform

## Monitoring and Logging

### LiveDashboard

Real-time application monitoring in production:

```elixir
# config/prod.exs
config :myapp, MyappWeb.Endpoint,
  url: [host: "example.com", port: 443, scheme: "https"],
  # ... other config

# Conditional LiveDashboard (only if admin user)
if System.get_env("ENABLE_DASHBOARD") == "true" do
  config :phoenix_live_dashboard, :metrics_history,
    metrics_history: [storage: {PhoenixLiveDashboard.Storage.ETS, max_key_size: 100}]

  config :myapp, MyappWeb.Router,
    enable_dashboard: true
end
```

### Application Logging

Configure logging in production:

```elixir
# config/prod.exs
config :logger, level: :info

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :module]
```

## Database Considerations

### Connection Pooling

Tune for production workloads:

```elixir
# config/prod.exs
config :myapp, Myapp.Repo,
  url: System.get_env("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true,
  # Connection timeout in milliseconds
  connect_timeout: 5000,
  # SQL queries timeout
  timeout: 15000
```

Pool size guidance:

- `pool_size = num_connections = total_app_instances * connections_per_instance`
- For single app with default settings: 10-20
- Scale up with more app instances

### Backup and Recovery

- Automated daily backups
- Point-in-time recovery capability
- Tested restore procedures
- Separate backup storage

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
