# Recipe: ETS-Based Content Caching Patterns

## Problem

Database queries for content-heavy endpoints can become performance bottlenecks, especially for:

- Markdown/HTML content generation that involves formatting
- Index pages aggregating multiple records
- API responses with complex data transformation
- Read-heavy workloads where content doesn't change frequently

Traditional caching solutions (Redis, Memcached) add infrastructure complexity and network latency.

## Solution

Use ETS (Erlang Term Storage) for in-memory caching with TTL expiration and cache-first patterns. ETS provides sub-microsecond lookup times and is built into the BEAM VM.

## Implementation

### Step 1: Core Cache Module

```elixir
defmodule MyApp.ContentCache do
  @moduledoc """
  ETS-based in-memory cache with TTL expiration and cache-first patterns.

  Provides automatic cache invalidation, concurrent safe operations,
  and graceful degradation on cache failures.
  """

  require Logger

  @cache_table :content_cache
  @ttl_minutes 5
  @ttl_ms @ttl_minutes * 60 * 1000

  @type cache_key :: {atom(), term(), integer()}
  @type content :: String.t()

  def get_or_generate(type, key_data, generator_fn) do
    cache_key = build_cache_key(type, key_data)
    ensure_cache_table()

    case lookup_cache(cache_key) do
      {:hit, content} ->
        Logger.debug("Cache hit for #{inspect(cache_key)}")
        content

      :miss ->
        Logger.debug("Cache miss for #{inspect(cache_key)}")
        content = generator_fn.()
        store_cache(cache_key, content)
        content
    end
  end

  # Cache-first patterns for performance
  def get_cached_content(type, identifier) do
    lookup_cached_entries([
      {{{type, identifier, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  def clear_all do
    case :ets.info(@cache_table) do
      :undefined -> :ok
      _info -> :ets.delete_all_objects(@cache_table)
    end
    :ok
  end

  def clear_by_type(type) do
    case :ets.info(@cache_table) do
      :undefined -> :ok
      _info ->
        :ets.select_delete(@cache_table, [
          {{{type, :_, :_}, :_, :_}, [], [true]}
        ])
    end
    :ok
  end

  # Private functions

  defp lookup_cached_entries(ets_match_spec) do
    ensure_cache_table()

    case :ets.select(@cache_table, ets_match_spec) do
      [] -> :miss
      entries -> find_most_recent_valid_entry(entries)
    end
  rescue
    ArgumentError -> :miss
  end

  defp find_most_recent_valid_entry(entries) do
    current_time = System.system_time(:millisecond)

    most_recent_valid_entry =
      entries
      |> Enum.filter(fn {_content, timestamp} ->
           current_time - timestamp < @ttl_ms
         end)
      |> Enum.sort_by(fn {_content, timestamp} -> timestamp end, :desc)
      |> List.first()

    case most_recent_valid_entry do
      nil -> :miss
      {content, _timestamp} -> {:hit, content}
    end
  end

  defp build_cache_key(:single, %{id: id, updated_at: updated_at}) do
    {:single, id, timestamp_key(updated_at)}
  end

  defp build_cache_key(:index, items) when is_list(items) do
    # Create composite key based on items and their update times
    hash = items
           |> Enum.map(fn item -> {item.id, timestamp_key(item.updated_at)} end)
           |> :erlang.phash2()

    {:index, hash}
  end

  defp timestamp_key(%{year: y, month: m, day: d, hour: h, minute: min}) do
    # Timestamp key that changes every minute for additional invalidation
    y * 100_000_000 + m * 1_000_000 + d * 10_000 + h * 100 + min
  end

  defp ensure_cache_table do
    case :ets.info(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set])
          :ok
        rescue
          ArgumentError -> :ok  # Table created by another process
        end
      _info -> :ok
    end
  end

  defp lookup_cache(cache_key) do
    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, content, timestamp}] ->
        if System.system_time(:millisecond) - timestamp < @ttl_ms do
          {:hit, content}
        else
          # Expired entry - delete it
          :ets.delete(@cache_table, cache_key)
          :miss
        end
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store_cache(cache_key, content) do
    timestamp = System.system_time(:millisecond)

    try do
      :ets.insert(@cache_table, {cache_key, content, timestamp})
      :ok
    rescue
      ArgumentError ->
        # Table doesn't exist, ensure it exists and retry once
        ensure_cache_table()
        :ets.insert(@cache_table, {cache_key, content, timestamp})
        :ok
    end
  end
end
```

### Step 2: Cache-First Controller Pattern

```elixir
defmodule MyAppWeb.ContentController do
  use MyAppWeb, :controller

  alias MyApp.{Content, ContentCache}

  def show(conn, %{"id" => id}) do
    # Cache-first: Check cache before hitting database
    case ContentCache.get_cached_content(:single, id) do
      {:hit, cached_content} ->
        serve_content(conn, cached_content)

      :miss ->
        handle_cache_miss_for_single(conn, id)
    end
  end

  def index(conn, _params) do
    case ContentCache.get_cached_content(:index, :all) do
      {:hit, cached_content} ->
        serve_content(conn, cached_content)

      :miss ->
        handle_cache_miss_for_index(conn)
    end
  end

  # Private functions

  defp handle_cache_miss_for_single(conn, id) do
    case Content.get(id) do
      nil -> send_not_found(conn)
      item ->
        content = ContentCache.get_or_generate(:single, item, fn ->
          format_single_content(item)
        end)
        serve_content(conn, content)
    end
  end

  defp handle_cache_miss_for_index(conn) do
    items = Content.list_all()

    content = ContentCache.get_or_generate(:index, items, fn ->
      format_index_content(items)
    end)

    serve_content(conn, content)
  end

  defp serve_content(conn, content) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> text(content)
  end
end
```

### Step 3: Cache Invalidation Strategies

```elixir
defmodule MyApp.Content do
  alias MyApp.ContentCache

  def create_item(attrs) do
    case create_item_in_db(attrs) do
      {:ok, item} ->
        # Invalidate related caches
        ContentCache.clear_by_type(:index)
        {:ok, item}

      error -> error
    end
  end

  def update_item(item, attrs) do
    case update_item_in_db(item, attrs) do
      {:ok, updated_item} ->
        # Invalidate specific item and index caches
        ContentCache.clear_by_type(:single)
        ContentCache.clear_by_type(:index)
        {:ok, updated_item}

      error -> error
    end
  end

  def delete_item(item) do
    case delete_item_in_db(item) do
      {:ok, _} ->
        # Comprehensive cache invalidation
        ContentCache.clear_all()
        :ok

      error -> error
    end
  end
end
```

## Considerations

### Performance Benefits

- **Sub-microsecond Lookups**: ETS provides extremely fast key-value access
- **No Network Latency**: In-memory storage within the BEAM VM
- **Cache-First Patterns**: Skip database entirely on cache hits
- **Automatic Cleanup**: TTL expiration prevents memory leaks

### Memory Management

- **TTL Expiration**: 5-minute default prevents stale data
- **Selective Invalidation**: Clear by type or specific keys
- **Composite Keys**: Hash-based keys for complex cache scenarios
- **Memory Monitoring**: Use `:ets.info/1` to monitor table size

### Concurrency Safety

- **ETS Concurrency**: Built-in support for concurrent read/write
- **Atomic Operations**: Insert/delete operations are atomic
- **Race Condition Handling**: Graceful handling of table creation races
- **Process Independence**: Cache survives individual process crashes

### Error Handling

- **Graceful Degradation**: Cache failures fall back to database
- **Table Recreation**: Automatic table creation if missing
- **Exception Safety**: Try/rescue blocks prevent cache failures from breaking requests

## Example Usage

### Basic Content Caching

```elixir
# In controller
def show(conn, %{"id" => id}) do
  content = ContentCache.get_or_generate(:article, %{id: id}, fn ->
    article = Blog.get_article!(id)
    ArticleFormatter.to_html(article)
  end)

  render(conn, "show.html", content: content)
end
```

### Complex Index Caching

```elixir
def dashboard(conn, _params) do
  user = conn.assigns.current_user

  dashboard_data = ContentCache.get_or_generate(:dashboard, user, fn ->
    %{
      recent_posts: Blog.recent_posts_for_user(user),
      stats: Analytics.user_stats(user),
      notifications: Notifications.unread_for_user(user)
    }
    |> Jason.encode!()
  end)

  render(conn, "dashboard.html", data: Jason.decode!(dashboard_data))
end
```

### Cache Warming Strategy

```elixir
defmodule MyApp.CacheWarmer do
  alias MyApp.ContentCache

  def warm_popular_content do
    popular_items = Content.most_viewed(limit: 100)

    Task.async_stream(popular_items, fn item ->
      ContentCache.get_or_generate(:single, item, fn ->
        format_content(item)
      end)
    end, max_concurrency: 10)
    |> Stream.run()
  end
end
```

## Related Recipes

- [Phoenix File Extension Routing](phoenix-file-extension-routing.md)
- [Test Coverage Strategies](test-coverage-strategies.md)
- [Phoenix Pipeline Architecture](phoenix-pipeline-architecture.md)
