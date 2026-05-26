# Recipe: Caddy Dynamic Routing via Admin API

## Problem

You need to dynamically add and remove reverse proxy routes to Caddy at runtime (e.g., per-tenant or per-app subdomain routing) without restarting Caddy or editing its config file. You also need routes to survive platform restarts and not conflict with a wildcard catch-all route.

## Solution

Use Caddy's Admin API at `http://localhost:2019` to manage routes:

- **Add** routes at position 0 so they take precedence over wildcard routes
- **Tag** each route with `@id` for idempotent targeted deletion
- **Re-register** all routes on platform startup (Caddy Admin API is memory-only — routes don't survive Caddy restarts)
- **Set `X-Forwarded-Proto: https`** in every reverse proxy handler — required for Phoenix/LiveView behind TLS termination

## Implementation

```elixir
defmodule MyApp.Caddy do
  require Logger

  @admin_url "http://localhost:2019"

  @spec add_route(app :: map()) :: :ok | {:error, term()}
  def add_route(app) do
    route = %{
      # @id tag enables idempotent targeted deletion via /id/{name}
      "@id" => "app-#{app.slug}",
      "match" => [%{"host" => ["#{app.slug}.example.com"]}],
      "handle" => [
        %{
          "handler" => "reverse_proxy",
          "upstreams" => [%{"dial" => "127.0.0.1:#{app.port}"}],
          "headers" => %{
            "request" => %{
              # CRITICAL: without this, Phoenix/LiveView redirects to HTTP
              "set" => %{"X-Forwarded-Proto" => ["https"]}
            }
          }
        }
      ],
      # terminal: true stops Caddy from trying other routes on match
      "terminal" => true
    }

    # Insert at position 0 so specific routes take precedence over wildcard *.example.com
    case Req.post("#{@admin_url}/config/apps/http/servers/srv0/routes/0", json: route) do
      {:ok, %{status: 200}} -> :ok
      {:ok, resp} -> {:error, "Caddy returned #{resp.status}: #{inspect(resp.body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_route(app :: map()) :: :ok | {:error, term()}
  def remove_route(app) do
    # Delete by @id tag — idempotent (404 treated as success)
    case Req.delete("#{@admin_url}/id/app-#{app.slug}") do
      {:ok, %{status: 200}} -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec register_all_routes() :: :ok
  def register_all_routes do
    # Re-register on startup — Caddy Admin API is memory-only
    MyApp.Apps.list_running_apps()
    |> Enum.each(fn app ->
      case add_route(app) do
        :ok ->
          Logger.info("Registered Caddy route for #{app.slug}")

        {:error, reason} ->
          Logger.error("Failed to register route for #{app.slug}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
```

### Call on application startup

```elixir
# In application.ex — after Repo and ProcessManager are started:
children = [
  MyApp.Repo,
  MyApp.Apps.ProcessManager,
  # Re-register routes AFTER apps are started
  {Task, fn ->
    MyApp.Apps.ProcessManager.reattach_running_apps()
    MyApp.Caddy.register_all_routes()
  end},
  MyAppWeb.Endpoint
]
```

### Caddyfile configuration

```caddyfile
# DO NOT add *.example.com wildcard to Caddyfile — it breaks per-app dynamic routes
# Only add the global wildcard TLS configuration if needed for cert provisioning
example.com {
  tls {
    dns cloudflare {env.CLOUDFLARE_API_TOKEN}
  }
}

# The Admin API must be enabled (it is by default on localhost:2019)
```

## Considerations

- **No wildcard in Caddyfile**: If you have `*.example.com` in the Caddyfile as a static route, it will conflict with Admin API dynamic routes. Caddy uses static config routes AFTER dynamic ones, but the wildcard can still interfere. Use the Admin API exclusively for per-app routing.
- **Position 0 insertion**: `POST /config/apps/http/servers/srv0/routes/0` inserts at the front of the routes array. This is essential when you have a wildcard catch-all — specific routes must come first.
- **`@id` tag is mandatory for deletion**: Without the `@id` field, you can't target-delete a specific route later. Always set it to something unique like `app-{slug}`.
- **Admin API is memory-only**: Caddy reloads and restarts wipe all Admin API routes. Your application must re-register all active routes on startup.
- **`X-Forwarded-Proto` is required**: Phoenix checks this header to determine the request scheme. Without it, `use_secure_browser_headers` and LiveView WebSocket connections will redirect to HTTP even when the client used HTTPS.
- **Caddy reload via `systemctl` wipes routes**: After `sudo systemctl reload caddy`, call `register_all_routes` immediately.
- **Server name `srv0`**: The default Caddy server name. Verify with `curl http://localhost:2019/config/` if your setup differs.

## Example Usage

```elixir
# After provisioning a new app and starting its process:
:ok = MyApp.Caddy.add_route(app)

# After stopping/deleting an app:
:ok = MyApp.Caddy.remove_route(app)

# On platform startup (called from application.ex Task):
MyApp.Caddy.register_all_routes()
```

## Related Recipes

- `phoenix-release-deployment.md` — Phoenix release build and deployment
