# Recipe: ETS-based Session Storage for PoCs

## Problem

Need temporary, in-memory data storage for proof-of-concept applications without the complexity of database schemas, migrations, and persistence. Ideal for rapid prototyping where data doesn't need to survive server restarts and you want to focus on validation over production-ready infrastructure.

## Solution

Use ETS (Erlang Term Storage) tables managed by a GenServer for temporary session-based storage. This provides fast, concurrent access to data with automatic cleanup capabilities, perfect for PoC validation phases.

## Implementation

### 1. ETS Manager GenServer

```elixir
defmodule MyApp.SessionStore do
  @moduledoc """
  ETS-based session storage for temporary data in PoC applications.

  Provides fast, in-memory storage with automatic cleanup and
  concurrent access patterns suitable for validation phases.
  """

  use GenServer
  require Logger

  @cleanup_interval :timer.minutes(5)
  @session_ttl :timer.hours(2)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS tables for different data types
    tables = %{
      sessions: :ets.new(:sessions, [:set, :public, :named_table]),
      processing: :ets.new(:processing_status, [:set, :public, :named_table]),
      metrics: :ets.new(:validation_metrics, [:set, :public, :named_table])
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("SessionStore initialized with tables: #{inspect(Map.keys(tables))}")
    {:ok, %{tables: tables, start_time: System.monotonic_time(:millisecond)}}
  end

  # Public API functions
  def store_session(session_id, data) when is_binary(session_id) do
    timestamp = System.system_time(:second)
    :ets.insert(:sessions, {session_id, data, timestamp})
    Logger.debug("Stored session data for #{session_id}")
    :ok
  end

  def get_session(session_id) when is_binary(session_id) do
    case :ets.lookup(:sessions, session_id) do
      [{^session_id, data, _timestamp}] ->
        {:ok, data}
      [] ->
        {:error, :not_found}
    end
  end

  def delete_session(session_id) when is_binary(session_id) do
    :ets.delete(:sessions, session_id)
    :ets.delete(:processing_status, session_id)
    Logger.debug("Deleted session #{session_id}")
    :ok
  end

  def store_processing_status(session_id, status) when is_binary(session_id) do
    timestamp = System.system_time(:second)
    :ets.insert(:processing_status, {session_id, status, timestamp})
    :ok
  end

  def get_processing_status(session_id) when is_binary(session_id) do
    case :ets.lookup(:processing_status, session_id) do
      [{^session_id, status, timestamp}] ->
        {:ok, %{status: status, updated_at: timestamp}}
      [] ->
        {:error, :not_found}
    end
  end

  def store_metrics(key, value) do
    timestamp = System.system_time(:second)
    :ets.insert(:validation_metrics, {key, value, timestamp})
    :ok
  end

  def get_all_metrics do
    :ets.tab2list(:validation_metrics)
    |> Enum.map(fn {key, value, timestamp} ->
      %{key: key, value: value, timestamp: timestamp}
    end)
  end

  def get_stats do
    %{
      sessions: :ets.info(:sessions, :size),
      processing: :ets.info(:processing_status, :size),
      metrics: :ets.info(:validation_metrics, :size),
      uptime_minutes: div(System.monotonic_time(:millisecond) - get_start_time(), 60_000)
    }
  end

  # Internal functions
  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup_expired_sessions do
    now = System.system_time(:second)
    cutoff = now - @session_ttl

    # Clean up expired sessions
    expired_sessions =
      :ets.tab2list(:sessions)
      |> Enum.filter(fn {_id, _data, timestamp} -> timestamp < cutoff end)
      |> Enum.map(fn {id, _data, _timestamp} -> id end)

    Enum.each(expired_sessions, &delete_session/1)

    if length(expired_sessions) > 0 do
      Logger.info("Cleaned up #{length(expired_sessions)} expired sessions")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp get_start_time do
    case GenServer.call(__MODULE__, :get_start_time) do
      start_time when is_integer(start_time) -> start_time
      _ -> System.monotonic_time(:millisecond)
    end
  end

  @impl true
  def handle_call(:get_start_time, _from, %{start_time: start_time} = state) do
    {:reply, start_time, state}
  end
end
```

### 2. Application Supervisor Integration

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... existing children
      MyApp.SessionStore,
      # ... other children
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 3. Helper Module for Common Patterns

```elixir
defmodule MyApp.SessionHelper do
  @moduledoc """
  Convenience functions for common session storage patterns.
  """

  alias MyApp.SessionStore

  def generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  def with_session(session_id, fun) when is_function(fun, 1) do
    case SessionStore.get_session(session_id) do
      {:ok, data} -> fun.(data)
      {:error, :not_found} -> {:error, :session_not_found}
    end
  end

  def update_session(session_id, fun) when is_function(fun, 1) do
    case SessionStore.get_session(session_id) do
      {:ok, data} ->
        updated_data = fun.(data)
        SessionStore.store_session(session_id, updated_data)
        {:ok, updated_data}

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  def create_session_with_data(initial_data \\ %{}) do
    session_id = generate_session_id()
    SessionStore.store_session(session_id, initial_data)
    {:ok, session_id}
  end

  def track_processing_step(session_id, step, metadata \\ %{}) do
    status = %{
      step: step,
      started_at: System.system_time(:second),
      metadata: metadata
    }
    SessionStore.store_processing_status(session_id, status)
  end

  def complete_processing_step(session_id, step, result) do
    case SessionStore.get_processing_status(session_id) do
      {:ok, %{status: current_status}} ->
        updated_status = Map.merge(current_status, %{
          step: step,
          completed_at: System.system_time(:second),
          result: result,
          status: :completed
        })
        SessionStore.store_processing_status(session_id, updated_status)

      _ ->
        # Create new status if none exists
        status = %{
          step: step,
          completed_at: System.system_time(:second),
          result: result,
          status: :completed
        }
        SessionStore.store_processing_status(session_id, status)
    end
  end
end
```

### 4. LiveView Integration Pattern

```elixir
defmodule MyAppWeb.PocsLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.{SessionStore, SessionHelper}

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # Get or create session
    session_id = Map.get(session, "session_id") || SessionHelper.generate_session_id()

    # Initialize session data if new
    case SessionStore.get_session(session_id) do
      {:error, :not_found} ->
        SessionStore.store_session(session_id, %{
          created_at: System.system_time(:second),
          user_data: %{},
          processing_history: []
        })

      {:ok, _data} ->
        :ok
    end

    socket =
      socket
      |> assign(:session_id, session_id)
      |> load_session_data()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("start_processing", %{"input" => input}, socket) do
    session_id = socket.assigns.session_id

    # Store input and start processing
    SessionHelper.update_session(session_id, fn data ->
      Map.put(data, :current_input, input)
    end)

    SessionHelper.track_processing_step(session_id, :started, %{input: input})

    # Trigger async processing...
    Task.start(fn -> process_async(session_id, input) end)

    {:noreply, assign(socket, :processing, true)}
  end

  defp load_session_data(socket) do
    case SessionStore.get_session(socket.assigns.session_id) do
      {:ok, data} ->
        assign(socket, :session_data, data)

      {:error, :not_found} ->
        assign(socket, :session_data, %{})
    end
  end

  defp process_async(session_id, input) do
    # Simulate processing steps
    SessionHelper.track_processing_step(session_id, :processing, %{stage: "validation"})

    # ... do processing work ...

    SessionHelper.complete_processing_step(session_id, :completed, %{
      result: "processed_data",
      processing_time: 1.5
    })

    # Notify LiveView of completion
    Phoenix.PubSub.broadcast(MyApp.PubSub, "session:#{session_id}", :processing_complete)
  end
end
```

### 5. Metrics Collection for PoC Validation

```elixir
defmodule MyApp.ValidationMetrics do
  @moduledoc """
  Collect and analyze metrics for PoC validation.
  """

  alias MyApp.SessionStore

  def track_user_action(action, metadata \\ %{}) do
    key = "user_action:#{action}:#{System.system_time(:second)}"
    value = %{
      action: action,
      timestamp: System.system_time(:second),
      metadata: metadata
    }
    SessionStore.store_metrics(key, value)
  end

  def track_completion_rate(workflow, completed?) do
    key = "completion:#{workflow}"

    # Get existing stats or initialize
    current_stats = case SessionStore.get_session(key) do
      {:ok, stats} -> stats
      {:error, :not_found} -> %{total: 0, completed: 0}
    end

    updated_stats = %{
      total: current_stats.total + 1,
      completed: current_stats.completed + if(completed?, do: 1, else: 0),
      rate: if(current_stats.total + 1 > 0,
        do: (current_stats.completed + if(completed?, do: 1, else: 0)) / (current_stats.total + 1),
        else: 0)
    }

    SessionStore.store_session(key, updated_stats)
    updated_stats
  end

  def get_validation_summary do
    metrics = SessionStore.get_all_metrics()

    %{
      total_actions: length(metrics),
      unique_sessions: count_unique_sessions(metrics),
      common_actions: get_common_actions(metrics),
      session_stats: SessionStore.get_stats()
    }
  end

  defp count_unique_sessions(metrics) do
    metrics
    |> Enum.map(fn %{value: %{metadata: metadata}} ->
      Map.get(metadata, :session_id)
    end)
    |> Enum.filter(&(&1 != nil))
    |> Enum.uniq()
    |> length()
  end

  defp get_common_actions(metrics) do
    metrics
    |> Enum.group_by(fn %{value: %{action: action}} -> action end)
    |> Enum.map(fn {action, instances} -> {action, length(instances)} end)
    |> Enum.sort_by(fn {_action, count} -> count end, :desc)
    |> Enum.take(10)
  end
end
```

## Considerations

### When to Use

- Proof-of-concept and MVP development
- Rapid prototyping without database complexity
- User session data that doesn't need persistence
- Metrics collection for validation phases
- Temporary caching of processing results
- Development and testing environments

### When NOT to Use

- Production applications requiring data persistence
- Multi-server deployments (data isn't shared between nodes)
- Applications requiring data durability across restarts
- Large datasets that exceed memory limits
- When you need ACID transactions
- Compliance requirements for data retention

### Performance Considerations

- ETS operations are very fast (microsecond access times)
- Memory usage grows with stored data (monitor with observer)
- Automatic cleanup prevents memory leaks
- Concurrent access is naturally supported
- No disk I/O overhead
- Limited by available RAM

### Security Considerations

- Data is lost on server restart (feature, not bug for PoCs)
- No encryption at rest (data is in memory)
- Access control through application logic only
- Session IDs should be cryptographically secure
- Consider TTL for sensitive data

## Example Usage

From the YouTube Academy PoC:

```elixir
# Store quiz processing result
SessionStore.store_session(session_id, %{
  quiz_data: %{questions: questions, metadata: metadata},
  processing_time: 45.2,
  video_info: %{title: "Learn Elixir", duration: 1200}
})

# Track user completion
ValidationMetrics.track_completion_rate("quiz_generation", true)

# Get processing status
{:ok, %{status: :completed, result: result}} =
  SessionStore.get_processing_status(session_id)
```

## Related Recipes

- [Phoenix Async Feature Testing with LiveView](phoenix-async-feature-test-liveview.md) - For testing session-based features
- [External Python Tool Integration via System.cmd()](elixir-python-system-cmd.md) - Often used together for PoC processing pipelines
