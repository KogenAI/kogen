# ash_authentication

Elixir authentication library providing a turn-key solution for Ash Framework applications. Offers multiple authentication strategies (password, OAuth2, magic links) with built-in features for token management, user confirmation, and audit logging.

## Quick Start

### Installation

**Using Igniter (recommended):**

```bash
mix igniter.install ash_authentication --auth-strategy magic_link,password
mix igniter.install ash_authentication_phoenix --auth-strategy magic_link,password
```

**Manual setup:**

```elixir
# mix.exs
{:ash_authentication, "~> 4.0"}

# .formatter.exs
import_deps: [:ash_authentication]
```

### Basic Setup

1. **Create Token Resource** with `AshAuthentication.TokenResource` extension
2. **Configure User Resource** with `AshAuthentication` extension
3. **Add Supervisor** to supervision tree:
   ```elixir
   {AshAuthentication.Supervisor, otp_app: :my_app}
   ```

## Core Concepts

### Authentication Strategies

**Password Strategy** - Local database authentication

- Identity field (email, username)
- Hashed password validation
- Configure via `mix ash_authentication.add_strategy`

**OAuth2 Strategy** - External provider integration

- Built-in providers: Apple, Auth0, GitHub, Google, OIDC, Slack
- Custom OAuth2 services supported
- HTTP adapter configurable (default: Finch)

**Magic Link Strategy** - Single-use token via email

- Token-based authentication
- Requires email delivery mechanism
- Automatic token expiration

### Core Resources

**User Resource** requirements:

- `AshAuthentication` extension enabled
- Email attribute (for magic links, confirmations)
- Hashed password attribute (for password strategy)
- Token generation enabled (for stateful auth)

**Token Resource** requirements:

- `AshAuthentication.TokenResource` extension
- PostgreSQL `citext` extension installed
- Handles token generation, storage, expiration

### User and Subject Conversion

- `AshAuthentication.user_to_subject(user)` → URI-like subject string
- `AshAuthentication.subject_to_user(subject)` → User record retrieval
- `AshAuthentication.authenticated_resources()` → Discover all auth-enabled resources

## Configuration

### Extension Configuration

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource, ...

  extensions [AshAuthentication]

  authentication do
    strategies do
      password :password do
        identity_field :email
        hashed_password_field :hashed_password
      end
    end

    tokens do
      enabled? true
      token_resource MyApp.Accounts.Token
      signing_secret "your-secret-not-in-git"
    end
  end
end
```

### Token Configuration

Set `token_resource` to your Token resource for session/API authentication. Signing secret must not be version-controlled—use environment variables.

### HTTP Adapter Setup

For OAuth2 strategies:

```elixir
config :ash_authentication, :http_adapter, {Assent.HTTPAdapter.Finch, ...}
```

### Policy Integration

Apply `AshAuthentication.Checks.AshAuthenticationInteraction` policy checks to protect authenticated resources from unauthorized access.

### Framework Integration

**Phoenix:** Use `ash_authentication_phoenix` package for plug integration and pre-built forms.

**Other frameworks:** Use `AshAuthentication.Plug` to handle HTTP authentication endpoints.

## Best Practices

1. **Environment Variables** - Store signing secrets and OAuth credentials in `.env`, never in code
2. **Token Expiration** - Set reasonable token TTLs; use `LogOutEverywhere` add-on for security
3. **Confirmation Flows** - Use `Confirmation` add-on for email verification before login
4. **Audit Logging** - Enable `AuditLog` add-on to track authentication events
5. **Policy Guards** - Always use authentication checks on protected resources
6. **Multiple Strategies** - Combine password + OAuth for better UX
7. **Testing** - Mock `user_to_subject` and `subject_to_user` in tests
8. **Magic Links** - Use for passwordless flows; ensure email delivery is reliable
9. **OAuth Scopes** - Request minimal required scopes from providers
10. **Token Cleanup** - Supervisor manages periodic token expiration cleanup

---

**Version:** 4.10.0
**Source:** [hexdocs.pm/ash_authentication](https://hexdocs.pm/ash_authentication/)
**Generated:** 2025-10-28
