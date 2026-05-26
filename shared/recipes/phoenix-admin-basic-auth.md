# Recipe: HTTP Basic Authentication for Admin Routes

## Problem

Need to secure admin routes with simple HTTP Basic Authentication using environment variables for credentials, with proper security measures and logging.

## Solution

Create a dedicated plug for HTTP Basic Authentication with secure credential comparison, unauthorized attempt logging, and environment-based configuration. Use a separate router pipeline for admin routes.

## Implementation

### 1. Create AdminAuth Plug

```elixir
defmodule YourAppWeb.AdminAuth do
  @moduledoc """
  Provides HTTP Basic Authentication for admin routes.

  Credentials are configured in config/config.exs with defaults:
  - username: "admin"
  - password: "admin"

  Can be overridden via environment variables in runtime.exs:
  - ADMIN_USERNAME
  - ADMIN_PASSWORD
  """

  import Plug.Conn
  require Logger

  @realm "Admin Dashboard"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case authenticate(conn) do
      :ok ->
        conn

      :error ->
        log_unauthorized_attempt(conn)
        send_unauthorized_response(conn)
    end
  end

  @spec authenticate(Plug.Conn.t()) :: :ok | :error
  defp authenticate(conn) do
    username = Application.get_env(:your_app, :admin)[:username]
    password = Application.get_env(:your_app, :admin)[:password]

    with {:ok, credentials} <- extract_credentials(conn),
         :ok <- verify_credentials(credentials, username, password) do
      :ok
    else
      _error -> :error
    end
  end

  @spec extract_credentials(Plug.Conn.t()) :: {:ok, {String.t(), String.t()}} | :error
  defp extract_credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> decode_basic_auth(encoded)
      _no_auth -> :error
    end
  end

  @spec decode_basic_auth(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  defp decode_basic_auth(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2) do
      {:ok, {username, password}}
    else
      _invalid -> :error
    end
  end

  @spec verify_credentials({String.t(), String.t()}, String.t(), String.t()) :: :ok | :error
  defp verify_credentials({provided_username, provided_password}, username, password) do
    if Plug.Crypto.secure_compare(provided_username, username) &&
         Plug.Crypto.secure_compare(provided_password, password) do
      :ok
    else
      :error
    end
  end

  @spec log_unauthorized_attempt(Plug.Conn.t()) :: :ok
  defp log_unauthorized_attempt(conn) do
    remote_ip_string =
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()

    Logger.warning("Unauthorized admin access attempt from #{remote_ip_string}")
  end

  @spec send_unauthorized_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp send_unauthorized_response(conn) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
```

### 2. Configure Admin Credentials

```elixir
# config/config.exs
config :your_app, :admin,
  username: "admin",
  password: "admin"

# config/runtime.exs
config :your_app, :admin,
  username: System.get_env("ADMIN_USERNAME") || "admin",
  password: System.get_env("ADMIN_PASSWORD") || "admin"
```

### 3. Add Admin Pipeline to Router

```elixir
# lib/your_app_web/router.ex
defmodule YourAppWeb.Router do
  use YourAppWeb, :router

  # ... existing pipelines ...

  pipeline :admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {YourAppWeb.Layouts, :admin}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug YourAppWeb.AdminAuth
  end

  # ... existing routes ...

  scope "/admin", YourAppWeb do
    pipe_through :admin

    live "/dashboard", AdminLive.Dashboard, :dashboard
  end
end
```

### 4. Create Admin Layout (Optional)

```elixir
# lib/your_app_web/components/layouts/admin.html.heex
<!DOCTYPE html>
<html lang="en" class="[scrollbar-gutter:stable]">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <.live_title suffix=" · Admin">
      <%= assigns[:page_title] || "Admin Dashboard" %>
    </.live_title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    <!-- Add Chart.js CDN if needed for dashboards -->
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
    </script>
  </head>
  <body class="bg-gray-50 antialiased">
    <%= @inner_content %>
  </body>
</html>
```

## Considerations

### Security

- **Use Plug.Crypto.secure_compare/2** for credential verification to prevent timing attacks
- **Log unauthorized attempts** with IP addresses for security monitoring
- **Use environment variables** for production credentials, never hardcode them
- **Separate admin layout** prevents leaking admin-specific assets to regular users

### Performance

- **Minimal overhead** - HTTP Basic Auth is lightweight compared to session-based authentication
- **No session storage** required - credentials sent with each request
- **Cache-friendly** - no server-side state to maintain

### Deployment

- **Environment variables** must be set in production: `ADMIN_USERNAME`, `ADMIN_PASSWORD`
- **HTTPS required** in production - HTTP Basic Auth sends credentials in Base64 (not encrypted)
- **Strong passwords** recommended for production environments

### Testing

```elixir
# test/your_app_web/plugs/admin_auth_test.exs
defmodule YourAppWeb.AdminAuthTest do
  use YourAppWeb.ConnCase

  test "allows access with correct credentials" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Basic #{Base.encode64("admin:admin")}")
      |> YourAppWeb.AdminAuth.call([])

    refute conn.halted
  end

  test "denies access with incorrect credentials" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Basic #{Base.encode64("wrong:credentials")}")
      |> YourAppWeb.AdminAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "denies access without credentials" do
    conn = YourAppWeb.AdminAuth.call(build_conn(), [])

    assert conn.halted
    assert conn.status == 401
  end
end
```

## Example Usage

From the BemedaPersonal admin dashboard implementation - secured admin routes with environment-based credentials, proper logging, and dedicated admin layout with Chart.js CDN integration.

## Related Recipes

- [Phoenix Feature Test Setup](phoenix-feature-test-setup.md) - Testing authenticated admin routes
- [Phoenix Verified Routes Dynamic](phoenix-verified-routes-dynamic.md) - Admin route helpers
