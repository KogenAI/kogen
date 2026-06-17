# file_system

File system event monitoring library for Elixir. Provides cross-platform file system change notification through a unified API, abstracting platform-specific watchers (inotify on Linux, FSEvents on macOS, etc.).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:file_system, "~> 1.1.1"}
  ]
end
```

### Basic Usage

```elixir
# Start the file system watcher
{:ok, pid} = FileSystem.start_link(dirs: ["/path/to/watch"])

# Receive events
receive do
  {:file_system, :event, {path, events}} ->
    IO.inspect({path, events})
end
```

## Core Concepts

### FileSystem.start_link/1

Main entry point. Spawns a watcher process that monitors directories for changes.

**Options:**

- `dirs`: list of paths to watch (required)
- `latency`: delay in ms before reporting events (default: 0, useful for batching)
- `backend`: explicitly specify watcher backend (:inotify, :fs_events, :fsevents, etc.)

**Returns:** `{:ok, pid} | {:error, reason}`

### Event Messages

Watcher sends messages in this format:

```elixir
{:file_system, :event, {path, events}}
```

- `path`: absolute path where change occurred
- `events`: list of event atoms

**Common events:**

- `:created` – file/directory created
- `:deleted` – file/directory deleted
- `:modified` – file contents changed
- `:renamed` – file moved/renamed
- `:metadata_changed` – permissions, ownership changed
- `:unmounted` – watched volume unmounted
- `:overflow` – too many events (platform dependent)

### Supervision

Integrate with your application supervision tree:

```elixir
children = [
  {FileSystem, dirs: ["/var/data"]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Configuration

### Latency and Batching

For high-volume file operations, batch events to avoid overwhelming your process:

```elixir
{:ok, pid} = FileSystem.start_link(
  dirs: ["/source"],
  latency: 100  # Wait 100ms, coalesce events
)
```

### Multiple Directories

Watch multiple paths with a single watcher:

```elixir
FileSystem.start_link(dirs: [
  "/path/one",
  "/path/two",
  "/path/three"
])
```

### Backend Selection

Most platforms auto-detect the best backend. Override if needed:

```elixir
FileSystem.start_link(
  dirs: ["/data"],
  backend: :inotify  # Force inotify on Linux
)
```

## Best Practices

### Pattern Matching on Events

```elixir
receive do
  {:file_system, :event, {path, events}} ->
    if :modified in events do
      IO.puts("File #{path} was modified")
    end
    if :created in events do
      IO.puts("File #{path} was created")
    end
end
```

### Handling Overflow

When too many events occur, the watcher may report `:overflow`. Re-scan the directory:

```elixir
receive do
  {:file_system, :event, {_path, events}} ->
    if :overflow in events do
      IO.puts("Too many events! Perform full re-scan")
      # Re-scan directory or reset application state
    end
end
```

### Avoiding Recursive Loops

Be careful when watching directories that your application modifies. Use latency to batch writes and reduce redundant processing:

```elixir
# Good: use latency to prevent feedback loops
{:ok, _} = FileSystem.start_link(dirs: ["/output"], latency: 200)
```

### Filtering Specific File Types

The library doesn't filter events; implement filtering in your handler:

```elixir
def handle_file_event({path, events}) do
  if String.ends_with?(path, ".exs") or String.ends_with?(path, ".erl") do
    process_code_file(path, events)
  end
end
```

### Resource Cleanup

File system watchers consume OS-level resources. Stop the watcher when no longer needed:

```elixir
:ok = GenServer.stop(watcher_pid)
```

## Common Patterns

### Restart Handler on Overflow

```elixir
defp watch_with_recovery(dirs) do
  receive do
    {:file_system, :event, {_path, events}} when :overflow in events ->
      IO.warn("File system event overflow, restarting watcher")
      # Stop and restart watcher
      watch_with_recovery(dirs)

    {:file_system, :event, {path, events}} ->
      handle_change(path, events)
      watch_with_recovery(dirs)
  end
end
```

### Integration with GenServer

Typical pattern for a file watcher GenServer:

```elixir
defmodule MyApp.FileWatcher do
  use GenServer

  def start_link(dirs) do
    GenServer.start_link(__MODULE__, dirs, name: __MODULE__)
  end

  @impl true
  def init(dirs) do
    {:ok, pid} = FileSystem.start_link(dirs: dirs, latency: 100)
    {:ok, %{watcher_pid: pid}}
  end

  @impl true
  def handle_info({:file_system, :event, {path, events}}, state) do
    process_event(path, events)
    {:noreply, state}
  end

  defp process_event(path, events), do: :ok
end
```

## Platform-Specific Notes

### Linux

- Uses inotify
- Requires proper inotify limits configured in kernel
- Check `/proc/sys/fs/inotify/max_user_watches` if hitting limits

### macOS

- Uses FSEvents
- Requires allowing the Elixir/Erlang process in System Preferences (Big Sur+)
- Low latency may result in overhead; prefer latency >= 50ms

### Windows

- Uses ReadDirectoryChangesW API
- Less stable than POSIX implementations
- Overflow events are more common

## Version Notes

**1.1.1:**

- Stable cross-platform support
- Supports OTP 21+
- `:overflow` event handling is critical for production use
- No longer actively maintained; consider as stable

## Gotchas

1. **No content monitoring**: File system watchers detect inode changes, not file content. Binary comparisons require reading the file.

2. **Initial state not provided**: The watcher doesn't report existing files—only changes after start. Scan the directory initially if needed.

3. **Rename events are tricky**: Different platforms report renames differently. May appear as delete + create on some systems.

4. **Symbolic links**: Behavior varies by platform. Test thoroughly if using symlinked directories.

5. **Network file systems**: NFS, SMB, and other remote mounts may not report events reliably or at all.

---

**Version:** 1.1.1  
**Source:** https://hexdocs.pm/file_system  
**Generated:** 2026-06-17
