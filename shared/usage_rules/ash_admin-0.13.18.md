# ash_admin

AshAdmin is a super-admin UI dashboard for Ash Framework applications, built with Phoenix LiveView. It provides a production-ready administrative interface for managing Ash resources with automatic CRUD operations, resource configuration, and security integration.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
{:ash_admin, "~> 0.13"}
```

Run installer (recommended):

```bash
mix igniter.install ash_admin
```

### Router Setup

Add to your router (scope WITHOUT a second argument prefix):

```elixir
scope "/" do
  pipe_through [:browser]
  ash_admin "/admin"
end
```

### Domain Configuration

Add `AshAdmin.Domain` extension to each domain:

```elixir
use Ash.Domain,
  extensions: [AshAdmin.Domain]

admin do
  show? true
end
```

### Resource Configuration

Add `AshAdmin.Resource` extension to resources you want managed:

```elixir
use Ash.Resource,
  domain: YourDomain,
  extensions: [AshAdmin.Resource]

admin do
  actor? true  # Mark your user/actor resource
end
```

### Access

Visit `/admin` (or your configured path) in your application. Start server with `mix phx.server`.

## Core Concepts

### Admin Dashboard

- Auto-generates CRUD interface for configured resources
- Real-time updates via Phoenix LiveView
- Automatic form generation from resource attributes
- Resource relationships and associations displayed
- Pagination and filtering built-in

### Resource Configuration

The `AshAdmin.Resource` DSL allows:

- **`actor?`** - Mark resource as the authentication actor/user resource
- **`show?`** - Display resource in admin interface
- Field-level configuration for visibility and editability
- Custom column mappings and display options

### Domain Integration

The `AshAdmin.Domain` DSL controls:

- **`show?`** - Display domain in admin dashboard
- Domain-wide visibility settings
- Resource grouping and organization

## Configuration

### Route-Level Options

```elixir
ash_admin "/admin" [, opts]
```

**Key options**:

- `:csp_nonce_assign_key` - Custom CSP nonce assignment for Content Security Policy headers
- Authentication piping via `on_mount` hooks

### Security Configuration

With AshAuthentication, pipe through authentication:

```elixir
scope "/" do
  pipe_through [:browser]
  ash_admin "/admin", AshAuthentication.Phoenix.LiveSession.opts(
    on_mount: [{ExampleWeb.LiveUserAuth, :admin_only}]
  )
end
```

Define role checks in LiveUserAuth to verify admin status before access.

### Content Security Policy (CSP)

If your app uses CSP headers:

- Use `:csp_nonce_assign_key` option to assign custom nonces
- Prevents stylesheet/script blocking in admin dashboard
- Configure CSP with appropriate directives for LiveView

### Resource-Level Options

In resource `admin` block:

```elixir
admin do
  actor? true              # User/actor resource
  show? true               # Visible in dashboard
  # Field-level configuration available
end
```

## Best Practices

### Security CRITICAL

**AshAdmin has NO built-in security.** Protect routes with:

1. **Authentication middleware** - Use `AshAuthentication.Phoenix.LiveSession.opts`
2. **Authorization policies** - Leverage Ash policies for fine-grained access control
3. **Role-based access** - Implement admin-only role checks in `on_mount` hooks
4. **NEVER expose publicly** - Always pipe through authentication layers

### Configuration

- Use Igniter installer for standard setup
- Configure only resources you want admin-managed
- Set `show? false` for sensitive resources
- Mark actor resource with `actor? true` for proper user context

### Policies and Permissions

- AshAdmin respects Ash policies for actions
- Policies automatically restrict what users can do
- Test policy rules before deploying admin interface
- Use Ash policy DSL to control CRUD operation access

### Performance

- Paginate resource listings
- Filter by attributes intelligently
- Avoid displaying very large datasets without filtering
- Use Ash's built-in pagination features

### CSP Headers

If using Content Security Policy:

1. Configure `:csp_nonce_assign_key` in route options
2. Ensure CSP directives allow LiveView scripts
3. Test admin interface after CSP deployment

---

**Version:** 0.13.18
**Source:** [hexdocs.pm/ash_admin](https://hexdocs.pm/ash_admin/)
**Generated:** 2025-10-28
