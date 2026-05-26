# ash_graphql

ash_graphql is the extension for building GraphQL APIs with the Ash Framework. It automatically generates powerful, feature-complete GraphQL APIs powered by Absinthe, Elixir's premier GraphQL library. Define your domain model in Ash once, and ash_graphql derives your complete GraphQL API automatically.

## Quick Start

### Installation via Igniter (Recommended)

```bash
mix igniter.install ash_graphql
```

### Manual Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ash_graphql, "~> 1.8.3"},
    {:absinthe, "~> 1.7"},
    {:absinthe_plug, "~> 1.4"},
    {:ash, "~> 3.5"}
  ]
end
```

### Create GraphQL Schema

Create `lib/your_app/graphql_schema.ex`:

```elixir
defmodule YourApp.GraphqlSchema do
  use Absinthe.Schema
  use AshGraphql, domains: [YourApp.Domain1, YourApp.Domain2]

  query do
    # Custom queries here
  end

  mutation do
    # Custom mutations here
  end
end
```

### Connect Schema to Phoenix Router

```elixir
pipeline :graphql do
  plug AshGraphql.Plug
end

scope "/gql" do
  pipe_through [:graphql]

  forward "/playground",
    Absinthe.Plug.GraphiQL,
    schema: Module.concat(["YourApp.GraphqlSchema"]),
    interface: :playground

  forward "/",
    Absinthe.Plug,
    schema: Module.concat(["YourApp.GraphqlSchema"])
end
```

## Core Concepts

### Resources as GraphQL Types

Add `AshGraphql.Resource` extension to expose resources in GraphQL:

```elixir
defmodule YourApp.Support.Ticket do
  use Ash.Resource, extensions: [AshGraphql.Resource]

  attributes do
    uuid_primary_key :id
    attribute :subject, :string
    attribute :status, :atom, constraints: [one_of: [:open, :closed]]
  end

  graphql do
    type :ticket
  end
end
```

Generates:

```graphql
type Ticket {
  id: ID!
  subject: String
  status: TicketStatus
}

enum TicketStatus {
  OPEN
  CLOSED
}
```

### Domain-Level Configuration

Domains define the GraphQL API surface with centralized queries and mutations:

```elixir
defmodule YourApp.Support do
  use Ash.Domain, extensions: [AshGraphql.Domain]

  resources do
    resource YourApp.Support.Ticket
  end

  graphql do
    queries do
      get YourApp.Support.Ticket, :get_ticket, :read
      list YourApp.Support.Ticket, :list_tickets, :read
    end

    mutations do
      create YourApp.Support.Ticket, :create_ticket, :create
      update YourApp.Support.Ticket, :update_ticket, :update
      destroy YourApp.Support.Ticket, :destroy_ticket, :destroy
    end
  end
end
```

## Configuration

### Resource-Level GraphQL Options

| Option           | Type    | Default | Description                  |
| ---------------- | ------- | ------- | ---------------------------- |
| `type`           | atom    | —       | GraphQL type name (required) |
| `derive_filter?` | boolean | true    | Auto-generate filter inputs  |
| `derive_sort?`   | boolean | true    | Auto-generate sort inputs    |
| `hide_fields`    | list    | —       | Fields excluded from schema  |
| `show_fields`    | list    | —       | Only these fields exposed    |
| `relationships`  | list    | —       | Included relationships       |
| `depth_limit`    | integer | —       | Max query nesting depth      |

### Domain-Level GraphQL Options

| Option                | Type    | Default             | Description                       |
| --------------------- | ------- | ------------------- | --------------------------------- |
| `authorize?`          | boolean | true                | Enable authorization              |
| `root_level_errors?`  | boolean | false               | Errors in top-level array         |
| `show_raised_errors?` | boolean | false               | Show error stacktraces (dev only) |
| `error_handler`       | mfa     | DefaultErrorHandler | Custom error handler              |

### Query and Mutation Options

Available on all query/mutation definitions:

- `description` - GraphQL documentation
- `hide_inputs` - Input fields to exclude
- `modify_resolution` - Custom resolution middleware
- `complexity` - Query complexity score
- `allow_nil?` - Allow null returns (queries only)

## Best Practices

### Authorization

```elixir
# Enable authorization (default)
graphql do
  authorize? true
end

# Authentication with AshAuthentication
pipeline :graphql do
  plug :load_from_bearer
  plug :set_actor, :user
  plug AshGraphql.Plug
end

# Field-level authorization
field_policies do
  field_policy :salary do
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

### Error Handling

```elixir
# Custom error handler for translations
defmodule MyApp.GraphqlErrorHandler do
  def handle_error(error, _context) do
    %{error |
      message: Gettext.gettext(MyApp.Gettext, error.message)
    }
  end
end

graphql do
  error_handler {MyApp.GraphqlErrorHandler, :handle_error, []}
  show_raised_errors? false  # Never in production
end
```

### Performance Optimization

```elixir
# Set depth limits to prevent expensive queries
graphql do
  type :post
  depth_limit 5
end

# Use complexity scoring
queries do
  list YourApp.Blog.Post, :list_posts, :read do
    complexity 10
  end
end

# ash_graphql uses Ash's built-in dataloader (auto batches N+1 queries)
```

### Real-Time Subscriptions

```elixir
# Enable in config/config.exs
config :ash_graphql, :subscriptions, true

# Add to supervision tree
children = [
  MyAppWeb.Endpoint,
  {Absinthe.Subscription, MyAppWeb.Endpoint},
  AshGraphql.Subscription.Batcher
]

# Define resource subscriptions
graphql do
  subscriptions do
    subscribe :post_created do
      action_types :create
    end

    subscribe :post_updated do
      action_types :update
    end
  end
end
```

### Schema Design

```elixir
# Use PascalCase for types (converts to snake_case in Elixir)
graphql do
  type :blog_post  # Generates BlogPost in GraphQL
end

# Hide sensitive fields
graphql do
  type :user
  hide_fields [:password_hash, :internal_metadata]
end

# Be explicit with relationships
graphql do
  type :post
  relationships [:author, :comments, :tags]
end

# Use field policies for sensitive data
attributes do
  attribute :email, :string, allow_nil?: true  # Make nullable for policies
end

field_policies do
  field_policy :email do
    authorize_if actor_attribute_equals(:id, ^expr(id))
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

### Security Considerations

```elixir
# Disable introspection in production
config :absinthe, :schema, introspection: false

# Implement rate limiting
pipeline :graphql do
  plug :rate_limit_graphql
  plug AshGraphql.Plug
end

# Always validate and filter input
# Never expose internal IDs or sensitive data
graphql do
  hide_fields [:reset_token, :stripe_secret]
end

# Use authorization policies
policies do
  policy action_type(:read) do
    authorize_if always()
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

### Pagination Patterns

```elixir
# Keyset (cursor) pagination for large datasets
actions do
  read :list do
    pagination do
      keyset? true
      required? false
      default_limit 20
    end
  end
end

# Usage
query {
  listPosts(limit: 20, after: "cursor_value") {
    results { id, title }
    keyset
    hasNextPage
  }
}

# Offset pagination for simpler cases
actions do
  read :list do
    pagination do
      offset? true
      default_limit 20
    end
  end
end
```

### Monitoring and Observability

```elixir
# Configure tracing
graphql do
  trace MyApp.Tracer
end

# Use telemetry for performance monitoring
:telemetry.attach(
  "ash-graphql-handler",
  [:ash, :my_domain, :gql_mutation, :stop],
  fn event_name, measurements, metadata, _config ->
    if measurements.duration > 1_000_000_000 do
      Logger.warn("Slow mutation: #{metadata.resource_short_name}")
    end
  end,
  nil
)
```

---

**Version:** 1.8.3
**Source:** [hexdocs.pm/ash_graphql](https://hexdocs.pm/ash_graphql/)
**Generated:** 2025-10-28
