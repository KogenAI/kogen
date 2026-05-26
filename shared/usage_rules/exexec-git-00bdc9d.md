# exexec

Elixir wrapper around erlexec for executing and controlling OS processes from Elixir code. Provides idiomatic Elixir interfaces with signal handling, process monitoring, and process lifecycle management.

## Quick Start

Add to `mix.exs`:

```elixir
{:exexec, "~> 0.2"}
```

Basic execution:

```elixir
# Start supervisor
Exexec.start_link()

# Run a command
{:ok, pid, os_pid} = Exexec.run("ls -la")

# Wait for completion and get result
result = receive do
  {:exit_status, ^os_pid, status} -> status
end
```

## Core Concepts

### Process Execution Modes

**run/2** — Execute command as child process, returns `{:ok, pid, os_pid}`

- Command runs independently
- Caller does not wait
- Receives exit status via message: `{:exit_status, os_pid, status}`

**run_link/2** — Execute command linked to caller process

- Caller dies if command exits (and vice versa)
- Useful for critical dependencies
- Same return format as `run/2`

**manage/2** — Take control of existing OS process

- Assumes process is already running
- Exexec monitors and can signal it
- Same message protocol as `run/2`

### Process Identification

- **Exexec pid** — Returned by `run/2`, `run_link/2`, `manage/2`; used to control process
- **OS pid** — Native operating system process ID; used in exit status messages
- Convert between them: `os_pid/1` and `pid/1`

### Signal Handling

Send signals via `kill/2`:

```elixir
Exexec.kill(pid, :sigterm)  # Graceful shutdown
Exexec.kill(pid, :sigkill)  # Force kill
```

Graceful stop with timeout:

```elixir
Exexec.stop_and_wait(pid, 5000)  # 5s timeout before sigkill
```

## Configuration

### Command Options (per execution)

- `:cd` — Working directory
- `:env` — Environment variables (merged with parent)
- `:stdin` — How to handle stdin (`:default`, `:null`)
- `:stdout` — Capture mode (`:default`, `:null`)
- `:stderr` — Capture mode (`:default`, `:null`)
- `:pty` — Allocate pseudoterminal (boolean)
- `:user` — Run as user (string)
- `:group` — Run as group (string)
- `:nice` — Process priority (integer -20 to 19)
- `:kill_timeout` — Grace period before sigkill (ms)

Example:

```elixir
Exexec.run("build.sh", cd: "/app", env: %{"NODE_ENV" => "production"})
```

### Supervisor Options

Initialize with:

```elixir
Exexec.start_link(
  debug: false,          # Enable debug output
  root: false,           # Run port as root
  limit_users: true,     # Restrict to current user
  port: "/path/to/port"  # Custom port binary
)
```

## Best Practices

### Always Start Supervisor

Exexec requires a supervisor process. Start it early in your application:

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    children = [Exexec]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Handle Exit Messages Reliably

Always receive exit status to clean up resources:

```elixir
def run_command(cmd) do
  {:ok, pid, os_pid} = Exexec.run(cmd)
  receive do
    {:exit_status, ^os_pid, status} -> status
  after
    30000 -> {:error, :timeout}
  end
end
```

### Use run_link for Critical Processes

Link the caller when process failure must cascade:

```elixir
# In a task or agent handling
Exexec.run_link("critical-service")
```

### Graceful Shutdown

Use `stop_and_wait/2` to allow graceful shutdown before force kill:

```elixir
:ok = Exexec.stop_and_wait(pid, 5000)
```

### Monitor Process Listing

Query managed processes:

```elixir
Exexec.which_children()
# Returns list of {os_pid, exexec_pid, status} tuples
```

### Isolate Environment

Use `:env` to prevent inheriting unwanted parent environment:

```elixir
Exexec.run("script.sh", env: %{"PATH" => "/usr/bin:/bin", "HOME" => "/tmp"})
```

### Exit Code Interpretation

Use `status/1` to parse exit codes:

```elixir
status = receive do {:exit_status, ^os_pid, s} -> s end
case Exexec.status(status) do
  {:exit, code} -> IO.puts("Exit code: #{code}")
  {:signal, sig} -> IO.puts("Killed by: #{sig}")
end
```

---

**Version:** git-00bdc9d
**Source:** [hexdocs.pm/exexec](https://hexdocs.pm/exexec/)
**Generated:** 2026-04-25
