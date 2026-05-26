# ash_paper_trail

AshPaperTrail is the extension for keeping an audit log of changes to your Ash resources. It provides automatic version tracking, change history, and actor association for all modifications to your data.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:ash_paper_trail, "~> 0.5.6"}
```

Update `.formatter.exs`:

```elixir
[
  import_deps: [:ash, :ash_paper_trail],
  # ...
]
```

### Basic Resource Setup

```elixir
defmodule MyApp.Posts.Post do
  use Ash.Resource,
    domain: MyApp.Posts,
    extensions: [AshPaperTrail.Resource]

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :content, :string
    attribute :published, :boolean, default: false
  end
end
```

### Domain Configuration

Add extension to your domain:

```elixir
defmodule MyApp.Posts do
  use Ash.Domain,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end
end
```

## Core Concepts

### Change Tracking Modes

**`:changes_only`** (Recommended)

- Records only attributes that changed
- Smallest storage footprint
- Best for high-volume updates
- Use when you care about what changed, not previous complete state

**`:snapshot`**

- Records all attribute values every change
- Complete state preservation
- Larger storage requirements
- Use when you need full historical snapshots

**`:full_diff`**

- Shows before/after values for each changed attribute
- Helpful for detailed change auditing
- Balance between storage and detail

### Automatic Version Resource

AshPaperTrail automatically generates a `Version` resource:

- Named `MyApp.Posts.Post.Version` (based on parent)
- Stores: `resource_id`, `resource_type`, `changes`, `action`, `timestamp`, `actor_id`
- Automatically indexed for efficient querying
- Queryable through standard Ash read actions

### Tracking Control

**Ignore specific attributes:**

```elixir
paper_trail do
  ignore_attributes [:inserted_at, :updated_at, :cache_key]
end
```

**Ignore specific actions:**

```elixir
paper_trail do
  ignore_actions [:destroy, :refresh]
end
```

**Skip version when unchanged:**

```elixir
Post
  |> Ash.Changeset.new()
  |> Ash.Changeset.for_create(:create, input)
  |> Ash.Changeset.put_context(:skip_version_when_unchanged?, true)
  |> MyApp.Posts.create()
```

### Actor Association

Track who made changes:

```elixir
paper_trail do
  belongs_to_actor? true
  actor_attribute :user_id
end
```

Then provide actor context:

```elixir
Post
  |> Ash.Changeset.for_update(:update, input)
  |> Ash.Changeset.put_context(:actor, current_user)
  |> MyApp.Posts.update()
```

## Configuration

### Resource DSL Options

- **`primary_key_type`**: UUID type for version resource (`:uuid`, `:uuid_v7`)
- **`change_tracking_mode`**: `:snapshot`, `:changes_only`, or `:full_diff`
- **`store_action_name?`**: Include action name in version records (default: false)
- **`ignore_attributes`**: List of attributes to never track
- **`ignore_actions`**: List of actions that don't create versions
- **`belongs_to_actor?`**: Enable actor tracking
- **`actor_attribute`**: Custom actor relationship name

### Domain DSL Options

- **`include_versions?`**: Expose version resources in domain (default: false)
- **`skip_default_actions?`**: Don't auto-generate read actions on versions

## Best Practices

### When to Use Each Tracking Mode

Use **`:changes_only`** for:

- High-frequency updates (thousands per day)
- Queries focused on "what changed"
- Cost-conscious storage
- Production systems with audit requirements

Use **`:snapshot`** for:

- Critical data (financial, legal)
- Compliance requirements needing full state
- Lower update frequency
- When you need exact point-in-time snapshots

Use **`:full_diff`** for:

- Debugging complex state changes
- User-facing change logs
- Systems needing detailed before/after

### Storage Considerations

```elixir
# Compact tracking - ignores unimportant fields
paper_trail do
  change_tracking_mode :changes_only
  ignore_attributes [:updated_at, :cache_key, :sync_token]
  ignore_actions [:refresh_cache]
end
```

### Querying Versions

```elixir
# Get all versions of a post
Post.Version
  |> Ash.Query.filter(resource_id == post.id)
  |> MyApp.Posts.read!()

# Get recent changes with actor names
Post.Version
  |> Ash.Query.filter(resource_id == post.id)
  |> Ash.Query.sort(inserted_at: :desc)
  |> Ash.Query.limit(10)
  |> MyApp.Posts.read!()
  |> Enum.map(&{&1.action, &1.changes, &1.actor})
```

### Multitenancy

Tenant strategies automatically apply to version resources:

```elixir
paper_trail do
  change_tracking_mode :changes_only
end
```

Version resource inherits parent's multitenancy configuration.

### Destroy Action Handling

For PostgreSQL databases:

- Option 1: Disable versioning on destroys with `ignore_actions [:destroy]`
- Option 2: Implement soft deletes instead of hard deletes
- Option 3: Use Ash mixins with `on_delete: :delete` for version cleanup

### Performance Tips

1. **Use `:changes_only`** to minimize version record size
2. **Index on resource_id and resource_type** for faster version queries
3. **Archive old versions** periodically to maintain query performance
4. **Use `skip_version_when_unchanged?`** for update-heavy operations where nothing changed

### Integration with GraphQL

Expose versions through GraphQL:

```elixir
field :versions, list_of(:post_version) do
  resolve(fn post, _, _ ->
    versions = MyApp.Posts.Post.Version
      |> Ash.Query.filter(resource_id == post.id)
      |> MyApp.Posts.read!()
    {:ok, versions}
  end)
end
```

---

**Version:** 0.5.6
**Source:** [hexdocs.pm/ash_paper_trail](https://hexdocs.pm/ash_paper_trail/)
**Generated:** 2025-10-28
