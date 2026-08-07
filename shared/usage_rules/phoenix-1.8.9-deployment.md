# phoenix - Deployment & Production

## Core Deployment Steps

Deploying a Phoenix application requires three essential steps for production safety and performance:

### 1. Handle Application Secrets

All Phoenix applications have data that must be kept secure—database credentials, API keys, session secrets. Secrets should be stored in environment variables and loaded via `config/runtime.exs` at boot time.

Generate a secret key base for session encryption:

```bash
mix phx.gen.secret
```

Set required environment variables before deployment:

```bash
export SECRET_KEY_BASE="generated_secret_key"
export DATABASE_URL="postgresql://user:pass@localhost/db"
```

Load these in `config/runtime.exs`:

```elixir
config :hello, HelloWeb.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  url: [host: System.get_env("PHX_HOST"), port: 443]

config :hello, Hello.Repo,
  url: System.fetch_env!("DATABASE_URL")
```

Never commit secrets to version control or embed them in source code.

### 2. Compile Assets

Build and digest JavaScript and stylesheet assets for production:

```bash
MIX_ENV=prod mix assets.deploy
```

This command:

- Minifies and optimizes CSS and JavaScript
- Generates cache-busting hashes in filenames
- Creates a `priv/static/cache_manifest.json` for serving

The digest ensures static files can be cached aggressively while remaining fresh when updated.

### 3. Start the Server

Launch the server for production:

```bash
PORT=4001 MIX_ENV=prod mix phx.server
```

For background operation with detached mode:

```bash
PORT=4001 MIX_ENV=prod mix phx.server --erl "-detached"
```

Verify the server is running and accessible at the configured URL.

## Complete Deployment Sequence

Follow this sequence for reliable deployments:

```bash
# 1. Get dependencies and compile
MIX_ENV=prod mix do deps.get, compile

# 2. Deploy assets (compile & digest)
MIX_ENV=prod mix assets.deploy

# 3. Run database migrations (if applicable)
MIX_ENV=prod mix ecto.migrate

# 4. Start the server
PORT=4001 MIX_ENV=prod mix phx.server
```

Database migrations run once and prepare schema changes before the application starts.

## Elixir Releases

For production deployments, use Elixir releases instead of `mix phx.server`. Releases package your application as a self-contained artifact:

```bash
MIX_ENV=prod mix release
```

This creates a release that can be deployed without Elixir installed on the target machine.

Run the release:

```bash
_build/prod/rel/hello/bin/hello start
```

## Hosting Platforms

Phoenix supports deployment to multiple platforms:

**Elixir Releases** - Package applications as standalone releases for any Linux/Unix server

**Gigalixir** - Elixir-focused PaaS with simple deployment via `git push`

**Fly.io** - Modern container deployment platform with built-in clustering support

**Heroku** - Traditional platform-as-a-service with Elixir buildpack

**Render and Railway** - Community options supporting Elixir deployments

Each platform handles secrets, asset compilation, and database migrations differently—consult platform documentation for specific steps.

## Multi-Node Deployments

For clustered deployments across multiple servers:

**WebSocket Transport** (Recommended) - Maintains sticky connections naturally, no special configuration needed.

**Erlang Clustering** - Configure node discovery and cookie sharing between servers. Phoenix handles distributed PubSub automatically.

**Redis PubSub Adapter** - Use Redis as external PubSub broker for message distribution across independent servers.

```elixir
config :hello, Hello.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.get_env("REDIS_URL")
```

### Long-Polling Considerations

If using long-polling transport instead of WebSocket:

- Requires either Erlang clustering, Redis PubSub, or sticky sessions
- WebSocket is strongly recommended for better performance and fewer configuration requirements

## Environment-Specific Configuration

Use separate configuration files for different environments:

**Development** (`config/dev.exs`):

- Debug logging enabled
- No asset caching
- Hot reload enabled
- Detailed error pages

**Test** (`config/test.exs`):

- In-memory database
- Minimal logging
- No asset compilation

**Production** (`config/runtime.exs`):

- Secrets loaded from environment
- Static assets pre-compiled and digested
- Production-grade logging
- Performance optimizations enabled

## Best Practices

- **Test deployments**: Practice deployments in staging before production
- **Use environment variables**: Never hardcode secrets or configuration
- **Monitor logs**: Capture and monitor application and server logs
- **Automate migrations**: Run migrations automatically before starting new instances
- **Health checks**: Implement `/health` endpoint for load balancers
- **Graceful shutdown**: Configure timeout for outstanding requests before termination
- **Version your releases**: Track deployed versions for rollback capability
- **SSL/TLS**: Use HTTPS in production with proper certificates

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
