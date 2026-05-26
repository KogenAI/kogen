# Phoenix 1.8.1 - Production Deployment

## Pre-Deployment Checklist

Phoenix applications require three essential preparation phases for production:

1. **Secrets Management** - Secure sensitive data access
2. **Asset Compilation** - Build and digest frontend assets
3. **Server Startup** - Run application with proper environment

## Secrets Management

All Phoenix applications contain sensitive data requiring protection:

```elixir
# config/runtime.exs - Load secrets from environment
import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

  config :hello, HelloWeb.Endpoint,
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      transport_options: [socket_opts: [:inet6]]
    ],
    secret_key_base: secret_key_base

  database_url =
    System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@localhost/hello_prod
    """

  config :hello, Hello.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

Store sensitive credentials in environment variables:

- `SECRET_KEY_BASE` - Session encryption key
- `DATABASE_URL` - Database connection string
- API keys and tokens
- OAuth credentials

## Asset Compilation

Build and digest JavaScript and stylesheets for production:

```bash
# Deploy assets with fingerprinting
mix assets.deploy
```

This command:

- Minifies JavaScript and CSS
- Adds content hash to filenames (cache-busting)
- Compiles static assets
- Generates manifest for asset serving

## Server Startup

Start the Phoenix server in production mode:

```bash
export PORT=4001
export MIX_ENV=prod
export SECRET_KEY_BASE="your-generated-secret"
export DATABASE_URL="postgresql://user:pass@host/db"

# Create or migrate database
mix ecto.create
mix ecto.migrate

# Start server
mix phx.server
```

Or use Elixir releases for containerized/systemd deployments:

```bash
# Build release
MIX_ENV=prod mix release

# Start release
_build/prod/rel/hello/bin/hello start
```

## Production Configuration

Essential configuration for production environments:

```elixir
config :hello, HelloWeb.Endpoint,
  url: [host: "example.com", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true
```

## Multi-Machine Deployment Considerations

For applications running across multiple servers, clustering and session management are critical:

> "If you want Long-Polling to work properly, your application must either implement Erlang clustering, use alternative pub/sub adapters like Redis, or enforce sticky sessions."

Long-polling sends repeated requests; without these mechanisms, users may connect to different machines and lose channel subscriptions.

### Solutions for Multi-Server Setup

**Erlang Clustering**:

```elixir
config :hello, :clustering,
  topologies: [
    epmd: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"node1@host1", :"node2@host2"]]
    ]
  ]
```

**Redis Pub/Sub Adapter**:

```elixir
config :hello, :pubsub,
  adapter: Phoenix.PubSub.Redis,
  name: :hello_pubsub,
  node_name: node_name(),
  url: System.get_env("REDIS_URL")
```

**Sticky Sessions**:

Configure load balancer to route user sessions to the same server throughout their lifetime.

## Deployment Platforms

Official tutorials available for:

- **Elixir Releases** - Generic containerized deployments
- **Gigalixir** - Elixir-focused platform
- **Fly.io** - Modern container deployment
- **Heroku** - Legacy platform support

Community-supported options:

- Render
- Railway
- DigitalOcean

## Environment-Specific Configuration

Use `config/` directory for environment configuration:

```
config/
├── config.exs          # All environments
├── dev.exs             # Development overrides
├── prod.exs            # Production overrides
├── test.exs            # Test overrides
└── runtime.exs         # Runtime environment variables
```

```elixir
# config/prod.exs
import Config

config :hello, HelloWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [hsts: true]

config :logger, level: :info

# config/runtime.exs
import Config

if config_env() == :prod do
  # Load production-specific secrets
end
```

## Database Migrations in Production

Migrate database before starting application:

```bash
# Create database if needed
mix ecto.create

# Run pending migrations
mix ecto.migrate

# Check migration status
mix ecto.migrations
```

For zero-downtime deployments, ensure migrations are backwards-compatible:

- Add columns with defaults before removing
- Rename columns in separate deployments
- Use database constraints for new validations

## Monitoring & Logging

Configure logging for production visibility:

```elixir
config :logger,
  level: :info,
  backends: [{:console, []}, {File.Logger, :file}]

# Log to files
config :logger, File.Logger,
  path: "/var/log/hello/error.log",
  level: :error
```

Monitor application metrics:

- Request latency and throughput
- Error rates and types
- Database connection pool usage
- Memory consumption

## SSL/TLS Configuration

Enable HTTPS in production:

```elixir
config :hello, HelloWeb.Endpoint,
  url: [host: "example.com", port: 443, scheme: "https"],
  force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]
```

## Health Checks

Implement health check endpoint for load balancers:

```elixir
# In router
scope "/", HelloWeb do
  get "/health", HealthController, :status
end

# Health check controller
def status(conn, _params) do
  json(conn, %{status: "ok"})
end
```

## Best Practices

- Use environment variables for all secrets
- Run database migrations before starting application
- Enable HTTPS in production
- Implement health check endpoints
- Monitor application logs and metrics
- Use Elixir releases for containerized deployments
- Ensure backwards-compatible migrations
- Test deployment process in staging environment
- Use sticky sessions or Redis for multi-server setups
- Keep dependencies updated
- Implement rate limiting and DDoS protection
- Use CDN for static assets

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
