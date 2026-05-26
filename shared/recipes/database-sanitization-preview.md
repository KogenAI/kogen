# Recipe: Database Sanitization for Preview Apps

## Problem

How to provide realistic production-like data for preview apps and development environments while protecting user privacy and sensitive information? Manual data creation is time-consuming and doesn't reflect real-world usage patterns.

## Solution

Implement an automated system that:

1. Sanitizes production database dumps by anonymizing sensitive data
2. Preserves all relationships and realistic data patterns
3. Automatically restores sanitized data in preview environments
4. Provides safety checks to prevent accidental production data exposure

## Implementation

### 1. Data Sanitization Script

Create a script that anonymizes sensitive data in-place:

```elixir
# priv/repo/sanitize_prod_data.exs

# Safety checks
if System.get_env("MIX_ENV") == "prod" do
  raise "Cannot run sanitization in production environment!"
end

alias YourApp.Repo
import Ecto.Query

# Check if we have user data to sanitize
user_count = Repo.aggregate("users", :count, :id)

if user_count == 0 do
  raise "No users found in database. Please restore production dump first."
end

# Run sanitization in a transaction
Repo.transaction(fn ->
  # Stream through users for memory efficiency
  from(u in "users", select: [:id])
  |> Repo.stream()
  |> Stream.with_index(1)
  |> Stream.each(fn {%{id: id}, index} ->
    # Anonymize user data
    from(u in "users",
      update: [
        set: [
          email: fragment("'user' || ? || '@example.com'", u.id),
          name: fragment("'User ' || ?", u.id),
          # Add other fields as needed
        ]
      ],
      where: u.id == ^id
    )
    |> Repo.update_all([])

    # Progress tracking
    if rem(index, 100) == 0 do
      IO.write("\rProgress: #{index}/#{user_count}")
    end
  end)
  |> Stream.run()

  # Delete sensitive tokens
  Repo.delete_all("users_tokens")
end)
```

### 2. Database Restoration Script

Create an optimized restoration script:

```bash
#!/bin/bash
# priv/repo/restore_sanitized_dump.sh

set -e

DUMP_FILE="${1:-sanitized.dump}"
DATABASE="${2:-$DATABASE_URL}"

# Phase 1: Restore schema only
echo "Restoring database schema..."
pg_restore \
    --dbname="$DATABASE" \
    --no-owner \
    --no-privileges \
    --schema-only \
    --clean \
    --if-exists \
    "$DUMP_FILE"

# Phase 2: Restore data
echo "Restoring data..."
pg_restore \
    --dbname="$DATABASE" \
    --no-owner \
    --no-privileges \
    --data-only \
    --disable-triggers \
    "$DUMP_FILE"

# Phase 3: Optimize
echo "Optimizing database..."
psql "$DATABASE" -c "
SET session_replication_role = DEFAULT;
SET maintenance_work_mem = '256MB';
ANALYZE;
VACUUM;
"
```

### 3. Automatic Restoration in Release Module

Integrate with deployment pipeline:

```elixir
# In your Release module
def migrate do
  load_app()

  for repo <- repos() do
    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        # Check if database has application tables
        if should_restore_sanitized_dump?(repo) do
          restore_sanitized_dump(repo)
        end

        # Run normal migrations
        Ecto.Migrator.run(repo, :up, all: true)
      end)
  end
end

defp should_restore_sanitized_dump?(repo) do
  has_s3_config?() and database_is_empty?(repo)
end

defp database_is_empty?(repo) do
  case repo.query("SELECT COUNT(*) FROM users", []) do
    {:ok, %{rows: [[0]]}} -> true
    {:ok, %{rows: [[_count]]}} -> false
    {:error, _error} -> true
  end
rescue
  _error -> true
end

defp restore_sanitized_dump(repo) do
  database_url = get_database_url(repo)
  {bucket, dump_file, temp_file} = get_dump_config()

  try do
    download_dump_from_s3(bucket, dump_file, temp_file)
    restore_dump_to_database(temp_file, database_url)
  after
    File.rm(temp_file)
  end
end
```

### 4. Docker Container Requirements

Add necessary tools to your Dockerfile:

```dockerfile
# Install PostgreSQL client and AWS CLI
RUN apt-get update -y && \
    apt-get install -y postgresql-client python3 python3-pip && \
    pip3 install awscli && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*
```

### 5. GitHub Workflows Integration

Add required environment variables:

```elixir
# In your GitHub workflows
secrets: "AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }} AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }} BUCKET_NAME=${{ secrets.BUCKET_NAME }} DATABASE_DUMP_FILE=${{ vars.DATABASE_DUMP_FILE }}"
```

## Considerations

### Security

- **Never run sanitization on production**: Use environment checks
- **Irreversible anonymization**: Ensure data cannot be de-anonymized
- **Delete sensitive tokens**: Remove all authentication tokens
- **Use dedicated storage**: Store sanitized dumps separately from production data

### Performance

- **Stream processing**: Use Ecto.Repo.stream() for large datasets
- **Phased restoration**: Separate schema, data, and index creation
- **Memory optimization**: Set appropriate PostgreSQL memory settings
- **Progress tracking**: Show progress for long-running operations

### Maintenance

- **Regular updates**: Keep sanitization rules current with schema changes
- **Verification**: Test sanitized data doesn't contain sensitive information
- **Automation**: Integrate with CI/CD pipeline for preview apps
- **Monitoring**: Track sanitization success/failure rates

### Data Integrity

- **Preserve relationships**: Maintain foreign key relationships
- **Realistic patterns**: Keep data patterns that reflect real usage
- **Selective preservation**: Keep non-sensitive data (like code snippets) as-is
- **Consistent anonymization**: Use deterministic anonymization where possible

## Example Usage

From the ElixirDrops project implementation:

```bash
# 1. Restore production dump locally
pg_restore --no-owner -d myapp_dev production.dump

# 2. Run sanitization
mix run priv/repo/sanitize_prod_data.exs

# 3. Create sanitized dump
pg_dump -Fc --no-owner myapp_dev > sanitized.dump

# 4. Upload to object storage
aws s3 cp sanitized.dump s3://bucket/_db/sanitized.dump

# 5. Preview apps automatically restore on deployment
```

The system automatically detects empty databases in preview environments and downloads/restores the sanitized dump, providing realistic data without manual intervention.

## Related Recipes

- **Database Migration Strategies**: For handling schema changes during restoration
- **Environment-Specific Configuration**: For managing different deployment environments
- **Object Storage Integration**: For reliable dump storage and retrieval
