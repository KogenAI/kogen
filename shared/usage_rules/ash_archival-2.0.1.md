# ash_archival

An Ash extension that provides a push-button solution for soft deleting records instead of destroying them. When you destroy a record, it gets archived using an `archived_at` attribute, allowing data recovery and maintaining referential integrity.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
{:ash_archival, "~> 2.0.1"}
```

Add to `.formatter.exs`:

```elixir
import_deps: [..., :ash_archival]
```

### Basic Setup

Enable archival on any resource:

```elixir
use Ash.Resource,
  extensions: [..., AshArchival.Resource]
```

Once enabled, calling `destroy` on a record will archive it (set `archived_at` timestamp) instead of deleting it permanently.

## Core Concepts

### Soft Deletion vs Hard Deletion

- **Soft Deletion**: Records are marked as archived with an `archived_at` timestamp but remain in the database
- **Preservation**: Original data is preserved for auditing, recovery, and referential integrity
- **Base Filter**: By default, queries exclude archived records (`is_nil(archived_at)`)
- **Unarchiving**: Previously archived records can be restored using unarchival functionality

### Archive Configuration

Configure archival behavior in your resource:

```elixir
archive do
  archive_related([:comments, :tags])
  archive_related_authorize?(false)
end
```

**Key Options:**

- `archive_related(:field_name)` - Automatically archive related records when parent is archived
- `archive_related_authorize?(false)` - Skip authorization checks on related records (recommended)

### Base Filter Benefits

Enable base filtering for database-level optimization:

```elixir
resource do
  base_filter expr(is_nil(archived_at))
end

postgres do
  base_filter_sql "(archived_at IS NULL)"
end
```

Set `base_filter? true` in archive configuration to:

- Exclude archived items from unique indexes
- Exclude archived items from custom indexes
- Prevent check constraints from applying to archived records
- Improve query performance automatically

## Configuration

### Resource-Level Setup

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    extensions: [..., AshArchival.Resource]

  attributes do
    # archived_at is added automatically by AshArchival.Resource
  end

  archive do
    # Optional: configure which related records to archive
    archive_related([:comments])
    # Control authorization on related record archival
    archive_related_authorize?(false)
  end
end
```

### Database Configuration

When using Ash PostgreSQL, define base filter SQL for optimal indexing:

```elixir
postgres do
  table "posts"
  base_filter_sql "(archived_at IS NULL)"
end
```

### Authorization Behavior

- **Default**: Authorization checks are enforced when archiving related records
- **Recommended**: Set `archive_related_authorize?(false)` to archive all related records regardless of actor permissions
- **Use Case**: When you want parent archival to cascade regardless of access control

## Best Practices

### 1. Always Enable Base Filtering

Use base filters in your postgres configuration to ensure archived records are excluded from indexes and constraints by default:

```elixir
postgres do
  base_filter_sql "(archived_at IS NULL)"
end
```

### 2. Plan Related Record Archival

Explicitly declare which relationships should be archived when the parent is archived:

```elixir
archive do
  archive_related([:comments, :tags, :attachments])
  archive_related_authorize?(false)
end
```

### 3. Handle Unarchiving Carefully

When unarchiving records, consider:

- Whether all related records should be unarchived
- If unarchival requires special permissions
- Data consistency implications

### 4. Maintain Audit Trails

Keep `archived_at` attributes in queries for auditing purposes:

```elixir
# View archive history
Post |> Ash.Query.select([:id, :title, :archived_at])
```

### 5. Use Composite Queries for Reporting

Create separate queries for archived vs active records when needed:

```elixir
# Active records (implicit via base_filter)
Post |> Ash.Query.limit(10)

# All records including archived
Post |> Ash.Query.filter(true) |> Ash.Query.limit(10)
```

### 6. Version Upgrades

If upgrading from 1.x to 2.0:

- Review the upgrade guide for breaking changes
- Test archival behavior in development
- Ensure database migrations are applied

---

**Version:** 2.0.1
**Source:** [hexdocs.pm/ash_archival](https://hexdocs.pm/ash_archival/)
**Generated:** 2025-10-28
