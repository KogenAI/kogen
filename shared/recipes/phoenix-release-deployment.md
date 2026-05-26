# Recipe: Phoenix Release Deployment Pattern

## Problem

Deploying Phoenix applications to production without Mix installed requires specific setup for migrations, runtime configuration, and persistent file storage. Missing this setup leads to failed deployments or data loss.

## Solution

Use Phoenix releases with proper runtime configuration, migration scripts, and environment-aware file storage that persists across deployments.

## Implementation

### Step 1: Generate Release Infrastructure

```bash
# Generate release scripts (bin/server, bin/migrate)
mix phx.gen.release
```

This creates:

- `rel/overlays/bin/server` - Production server start script
- `rel/overlays/bin/migrate` - Production migration script
- `lib/your_app/release.ex` - Release module with migrate/rollback functions

### Step 2: Create Release Module

```elixir
# lib/your_app/release.ex
defmodule YourApp.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix installed.
  """
  @app :your_app

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
```

### Step 3: Environment-Aware Runtime Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  # Database configuration - fail fast with clear error
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/your_app/your_app.db
      """

  config :your_app, YourApp.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Persistent file storage outside release directory
  uploads_dir =
    System.get_env("UPLOADS_DIR") ||
      raise """
      environment variable UPLOADS_DIR is missing.
      For example: /home/deploy/your_app/uploads
      This directory must persist across deployments and be writable by the app.
      """

  config :your_app, :uploads_dir, uploads_dir

  # Secret key base
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  config :your_app, YourAppWeb.Endpoint,
    http: [port: {:system, "PORT"}],
    secret_key_base: secret_key_base

  # Enable server if PHX_SERVER=true
  if System.get_env("PHX_SERVER") do
    config :your_app, YourAppWeb.Endpoint, server: true
  end
end
```

### Step 4: Centralized Upload Directory Module

```elixir
# lib/your_app/uploads.ex
defmodule YourApp.Uploads do
  @moduledoc """
  Centralized configuration for file uploads.

  In development, uploads go to priv/static/uploads.
  In production, uploads go to a configurable directory (UPLOADS_DIR env var)
  that persists across deployments.
  """

  @spec base_dir() :: String.t()
  def base_dir do
    Application.get_env(:your_app, :uploads_dir, default_uploads_dir())
  end

  @spec images_dir() :: String.t()
  def images_dir do
    Path.join(base_dir(), "images")
  end

  @spec videos_dir() :: String.t()
  def videos_dir do
    Path.join(base_dir(), "videos")
  end

  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    File.mkdir_p!(images_dir())
    File.mkdir_p!(videos_dir())
    :ok
  end

  defp default_uploads_dir do
    Path.join([:code.priv_dir(:your_app), "static", "uploads"])
  end
end
```

### Step 5: Initialize Directories at Startup

```elixir
# lib/your_app/application.ex
defmodule YourApp.Application do
  use Application

  def start(_type, _args) do
    # Ensure upload directories exist at boot
    YourApp.Uploads.ensure_dirs!()

    children = [
      # ... your other children
    ]

    opts = [strategy: :one_for_one, name: YourApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Step 6: Production Deployment Scripts

```bash
#!/usr/bin/env bash
# deploy/07-deploy.sh - Subsequent deployments

set -e

# Load environment
source ~/.your-app-staging.env

# Build release locally
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

# Copy release to server
scp -r _build/prod/rel/your_app deploy@${STAGING_IP}:/home/deploy/your_app/releases/$(date +%s)

# Create current symlink
ssh deploy@${STAGING_IP} "ln -snf /home/deploy/your_app/releases/$(date +%s) /home/deploy/your_app/current"

# Run migrations
ssh deploy@${STAGING_IP} "/home/deploy/your_app/current/bin/migrate"

# Restart service
ssh deploy@${STAGING_IP} "sudo systemctl restart your_app"

echo "✅ Deployment complete"
```

### Step 7: Systemd Service Configuration

```bash
#!/usr/bin/env bash
# deploy/06-systemd-service.sh - Set up systemd service

cat > /tmp/your_app.service << 'EOF'
[Unit]
Description=YourApp Phoenix Server
After=network.target

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/home/deploy/your_app/current
EnvironmentFile=/etc/your_app/production.env
ExecStart=/home/deploy/your_app/current/bin/server
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=your_app

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/your_app.service /etc/systemd/system/your_app.service
sudo systemctl daemon-reload
sudo systemctl enable your_app
sudo systemctl start your_app
```

## Considerations

### Critical Requirements

- **Fail fast in runtime.exs**: Use `raise` with clear error messages for missing env vars
- **Persistent storage location**: UPLOADS_DIR must be outside release directory (survives deployments)
- **Directory initialization**: Create upload directories at application startup
- **Migration before restart**: Always run migrations before restarting the service
- **Symlink for current**: Use symlink pattern for atomic deployments

### When to Use This Pattern

✅ **Use when:**

- Deploying Phoenix to production VPS
- Need to preserve file uploads across deployments
- Want atomic deployments with rollback capability
- Using systemd for process management

❌ **Don't use when:**

- Using container orchestration (Docker/Kubernetes) - use volume mounts instead
- Using managed platforms (Heroku, Fly.io) - they handle this differently
- File uploads go to S3/object storage - no need for persistent directory

### Security Considerations

- Never commit production credentials to git
- Use strong SECRET_KEY_BASE (64+ chars from `mix phx.gen.secret`)
- Restrict upload directory permissions (`chmod 755` for app user only)
- Use systemd EnvironmentFile for secrets (not inline in service file)

## Example Usage

From the nalikutemwa staging feature:

```elixir
# Used in controllers
audio_path = Path.join(Backend.Uploads.audio_dir(), "#{uuid}.m4a")
File.cp!(upload.path, audio_path)

# Configured in runtime.exs
if config_env() == :prod do
  uploads_dir = System.get_env("UPLOADS_DIR") ||
    raise "environment variable UPLOADS_DIR is missing"
  config :backend, :uploads_dir, uploads_dir
end

# Initialized at startup
def start(_type, _args) do
  Backend.Uploads.ensure_dirs!()
  # ... rest of supervision tree
end
```

**Result**: Deployed to staging server with uploads persisting across 5+ deployments, zero data loss, atomic rollback capability.

## Related Recipes

- phoenix-channels-messagepack-flutter.md - Real-time communication
- database-sanitization-preview.md - Preparing production data for staging
