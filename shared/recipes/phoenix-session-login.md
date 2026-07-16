# Recipe: Single-User Session Login (Shared Credential, Session Cookie)

## Problem

An internal tool, admin panel, or single-tenant app needs a login gate that
is simpler than full `mix phx.gen.auth` (no per-user accounts table, no
registration/password-reset flow) but stronger than HTTP Basic Auth — a
proper session cookie, a login form, and LiveView routes that redirect
unauthenticated visitors instead of relying on a browser credential prompt
on every request.

This is distinct from [Phoenix Admin Basic Auth](phoenix-admin-basic-auth.md):
Basic Auth re-prompts per request/browser-session with no logout and no
LiveView-aware redirect; this recipe establishes a signed session once at
login and gates both controller and LiveView routes from that session.

## Solution

A single shared credential (username + password) read from runtime env, a
`SessionController` that verifies the submitted password with
`Plug.Crypto.secure_compare/2` and puts a boolean flag in the signed
session, a `require_login` plug for controller/dead-view routes, and an
`on_mount` hook that gates LiveViews by checking the same session key and
redirecting unauthenticated mounts to the login page.

## Implementation

### 1. Configure the credential

```elixir
# config/runtime.exs
if config_env() == :prod do
  # ... existing required_env wiring ...
  config :your_app, :login,
    username: System.get_env("LOGIN_USERNAME") || raise("missing LOGIN_USERNAME"),
    password: System.get_env("LOGIN_PASSWORD") || raise("missing LOGIN_PASSWORD")
end
```

```elixir
# config/dev.exs / config/test.exs
config :your_app, :login, username: "admin", password: "devpassword"
```

### 2. SessionController

```elixir
defmodule YourAppWeb.SessionController do
  use YourAppWeb, :controller

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    render(conn, :new)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"username" => username, "password" => password}) do
    config = Application.fetch_env!(:your_app, :login)

    if valid_credentials?(username, password, config) do
      conn
      |> put_session(:logged_in?, true)
      |> configure_session(renew: true)
      |> redirect(to: ~p"/")
    else
      conn
      |> put_flash(:error, "Invalid credentials")
      |> render(:new)
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  @spec valid_credentials?(String.t(), String.t(), keyword()) :: boolean()
  defp valid_credentials?(username, password, config) do
    Plug.Crypto.secure_compare(username, config[:username]) &&
      Plug.Crypto.secure_compare(password, config[:password])
  end
end
```

### 3. `require_login` plug for dead (non-LiveView) routes

```elixir
defmodule YourAppWeb.Plugs.RequireLogin do
  @moduledoc "Redirects unauthenticated requests to the login page."

  import Plug.Conn
  import Phoenix.Controller

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if get_session(conn, :logged_in?) do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page")
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
```

### 4. `on_mount` hook gating LiveViews

```elixir
defmodule YourAppWeb.LoginAuth do
  @moduledoc "on_mount hook that redirects unauthenticated LiveView mounts to /login."

  import Phoenix.Component
  import Phoenix.LiveView

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_login, _params, session, socket) do
    if session["logged_in?"] do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page")
        |> redirect(to: "/login")

      {:halt, socket}
    end
  end
end
```

### 5. Router wiring

```elixir
# lib/your_app_web/router.ex
scope "/", YourAppWeb do
  pipe_through :browser

  get "/login", SessionController, :new
  post "/login", SessionController, :create
  delete "/logout", SessionController, :delete
end

pipeline :require_login do
  plug YourAppWeb.Plugs.RequireLogin
end

scope "/", YourAppWeb do
  pipe_through [:browser, :require_login]

  live_session :require_login, on_mount: [{YourAppWeb.LoginAuth, :require_login}] do
    live "/dashboard", DashboardLive
  end
end
```

## Testing

```elixir
defmodule YourAppWeb.SessionControllerTest do
  use YourAppWeb.ConnCase

  test "logs in with correct credentials", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "devpassword"})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :logged_in?)
  end

  test "rejects incorrect credentials", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "wrong"})
    assert html_response(conn, 200) =~ "Invalid credentials"
    refute get_session(conn, :logged_in?)
  end

  test "logout drops the session", %{conn: conn} do
    conn =
      conn
      |> post(~p"/login", %{"username" => "admin", "password" => "devpassword"})
      |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/login"
  end
end
```

LiveView gate test — mount without a session, assert redirect:

```elixir
test "redirects unauthenticated mount to /login", %{conn: conn} do
  assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard")
end
```

## Considerations

- **Single shared credential, not per-user accounts** — this is
  intentionally simpler than `phx.gen.auth`. If the app grows into
  multiple distinct users needing individual accounts, migrate to
  `phx.gen.auth` rather than bolting per-user rows onto this scheme.
- **`configure_session(renew: true)`** on login rotates the session ID,
  preventing session fixation.
- **`Plug.Crypto.secure_compare/2`**, never `==`, for credential comparison
  — a plain string comparison is subject to a timing attack.
- **HTTPS required in production** — session cookies must be `secure` (set
  via `Plug.Session` config `secure: true` for prod, already default in
  generated Phoenix endpoints when `force_ssl` is set).

## Related Recipes

- [Phoenix Admin Basic Auth](phoenix-admin-basic-auth.md) — simpler
  per-request auth with no login state; use when a browser credential
  prompt is acceptable and no LiveView gating is needed.
