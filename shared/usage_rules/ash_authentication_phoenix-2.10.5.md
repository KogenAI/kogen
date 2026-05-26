# ash_authentication_phoenix

Phoenix integration library for Ash Authentication framework, providing prebuilt authentication UI components, routing helpers, and controller patterns for rapid authentication implementation in Phoenix applications.

## Quick Start

### Installation (Igniter - Recommended)

```bash
mix igniter.install ash_authentication_phoenix
```

Automatically installs dependencies and generates configuration files.

### Manual Router Setup

Add to `lib/app_web/router.ex`:

```elixir
defmodule AppWeb.Router do
  use Phoenix.Router
  use AshAuthentication.Phoenix.Router
  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :load_from_session  # Session-based auth
  end

  pipeline :api do
    plug :load_from_bearer   # Bearer token auth
  end

  scope "/", AppWeb do
    pipe_through :browser
    sign_in_route()
    sign_out_route()
    auth_routes()
  end
end
```

### Controller Implementation

Create `lib/app_web/auth_controller.ex`:

```elixir
defmodule AppWeb.AuthController do
  use AshAuthentication.Phoenix.Controller

  def success(conn, _activity, _user, _token) do
    redirect(conn, to: "/")
  end

  def failure(conn, _activity, _reason) do
    redirect(conn, to: "/sign-in")
  end

  def sign_out(conn, _user) do
    redirect(conn, to: "/sign-in")
  end
end
```

## Core Concepts

**Authentication Strategies**: Base password authentication with configurable identity field (typically email).

**Built-in Routes**: Automatically generated endpoints:

- `/sign-in` - Login and registration LiveView
- `/sign-out` - Session logout
- `/auth/user/password/*` - Password reset routes

**Plugs for Session Management**:

- `:load_from_session` - Load authenticated user from session (browser)
- `:load_from_bearer` - Load authenticated user from Authorization header (API)

**Component Library**: Prebuilt UI components for authentication flows with Tailwind styling.

**Reset Password Workflow**: Resettable authentication requires sender module extending `AshAuthentication.Sender` and email templates for delivery.

## Configuration

### Formatter Configuration

Add to `.formatter.exs`:

```elixir
[
  import_deps: [:ash_authentication_phoenix],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
```

### Tailwind Integration

Configure component CSS in `assets/tailwind.config.js`:

```javascript
content: ["../deps/ash_authentication_phoenix/**/*.*ex"];
```

### Theme Support

For daisyUI styling, configure route helpers:

```elixir
auth_routes(overrides: AshAuthentication.Phoenix.Overrides.DaisyUI)
```

### Password Reset Configuration

In your Ash resource:

```elixir
defmodule App.Accounts.User do
  defmodule Strategies.Password do
    use AshAuthentication.Strategy.Password

    resettable do
      sender(App.Accounts.UserResetSender)
    end
  end
end
```

Create sender module:

```elixir
defmodule App.Accounts.UserResetSender do
  use AshAuthentication.Sender
end
```

### Debugging

Enable authentication failure logging in development:

```elixir
# config/dev.exs
config :ash_authentication, debug_authentication_failures?: true
```

⚠️ **NEVER enable in production** - exposes personally identifiable information.

## Best Practices

1. **Use Igniter for initial setup** - Reduces configuration errors and ensures dependencies are properly installed.

2. **Separate auth controllers** - Keep authentication logic in dedicated controller modules following the `AshAuthentication.Phoenix.Controller` behavior.

3. **Handle failure gracefully** - Implement proper redirects and error messaging in controller failure callbacks.

4. **Secure password reset** - Use email-based reset workflows with time-limited tokens rather than insecure methods.

5. **Environment-specific debugging** - Keep debug flags disabled in production to prevent PII leakage in logs.

6. **Delegate to components** - Use provided LiveView components for sign-in/registration rather than custom implementations.

7. **Test authentication flows** - Verify both success and failure paths, including edge cases like expired reset tokens.

---

**Version:** 2.10.5
**Source:** [hexdocs.pm/ash_authentication_phoenix](https://hexdocs.pm/ash_authentication_phoenix/)
**Generated:** 2025-10-28
