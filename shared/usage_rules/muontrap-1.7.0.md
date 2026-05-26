# muontrap

MuonTrap is a lightweight Elixir library that manages OS processes launched from Erlang/Elixir applications. It ensures child processes are properly terminated if the calling Elixir process crashes, with optional Linux cgroup support for resource containment and prevents orphaned processes.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:muontrap, "~> 1.0"}
  ]
end
```

### Basic Command Execution

Execute commands like `System.cmd/3`:

```elixir
iex> MuonTrap.cmd("echo", ["hello"])
{"hello\n", 0}
```

### Supervise Long-Running Processes

Attach daemons to supervision trees:

```elixir
children = [
  {MuonTrap.Daemon, ["my_command", ["arg1", "arg2"], options]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Core Concepts

### Process Containment

- **Automatic cleanup**: Child processes die when parent dies
- **SIGKILL escalation**: Unresponsive processes forced to terminate
- **Cgroup integration**: Linux kernel resource limits (memory, CPU)

### Supervision Modes

- **`:permanent`** — Always restart on exit (default)
- **`:transient`** — Restart only on non-zero exit codes
- **`:temporary`** — Never restart

### Key Guarantees

MuonTrap wraps system processes so that remnants don't hang around when Elixir code expects them gone. Unlike raw `System.cmd/3`, killing the parent Erlang process automatically kills OS children.

## Configuration

### Cgroup Memory Limits

First, create a cgroup:

```bash
sudo cgcreate -a $(whoami) -g memory:mycgroup
```

Limit memory to 256 MB:

```elixir
MuonTrap.cmd("memory_hog", [],
  cgroup_controllers: ["memory"],
  cgroup_base: "mycgroup",
  cgroup_sets: [{"memory", "memory.limit_in_bytes", "268435456"}])
```

### CPU Usage Constraints

Limit process to 50% CPU:

```elixir
MuonTrap.cmd("cpu_hog", [],
  cgroup_controllers: ["cpu"],
  cgroup_base: "mycgroup",
  cgroup_sets: [
    {"cpu", "cpu.cfs_period_us", "100000"},
    {"cpu", "cpu.cfs_quota_us", "50000"}
  ])
```

### Daemon Options

| Option               | Type                       | Purpose                                          |
| -------------------- | -------------------------- | ------------------------------------------------ |
| `cgroup_controllers` | `[String.t()]`             | Linux cgroup subsystems to use                   |
| `cgroup_base`        | `String.t()`               | Cgroup hierarchy name                            |
| `cgroup_sets`        | `[{subsys, param, value}]` | Cgroup parameter assignments                     |
| `stdio_window`       | `integer()`                | Max unacknowledged stdout bytes (default: 10 KB) |
| `stderr_to_stdout`   | `boolean()`                | Merge stderr into stdout                         |
| `into`               | `IO.binstream()`           | Stream output destination                        |
| `wait_for`           | `(() -> :ok)`              | Delayed startup until dependency ready           |

### Output Monitoring

Watch stdout in real-time:

```elixir
MuonTrap.cmd("my_program", [],
  stderr_to_stdout: true,
  into: IO.binstream(:stdio, :line))
```

For daemons, output channels through the logger system.

### Delayed Startup

Block daemon startup until dependencies available:

```elixir
{MuonTrap.Daemon,
 ["my_server", [],
  [wait_for: fn -> wait_for_tcp_port("localhost", 5432) end]]}
```

## Best Practices

### Supervision Tree Setup

Assign unique IDs for multiple daemons:

```elixir
Supervisor.child_spec(
  {MuonTrap.Daemon, ["cmd", ["arg1"], []]},
  id: :my_daemon,
  restart: :transient
)
```

### Handling Process Termination

Stop processes using standard Erlang mechanisms:

```elixir
# Supervisor-based termination
Supervisor.terminate_child(MySupervisor, :my_daemon)

# Direct PID kill
Process.exit(pid, :kill)
```

### Resource Control Pattern

Always define cgroup constraints for untrusted or resource-intensive processes:

```elixir
# For background jobs
MuonTrap.cmd("job_runner", [job_id],
  cgroup_controllers: ["memory", "cpu"],
  cgroup_base: "background_jobs",
  cgroup_sets: [
    {"memory", "memory.limit_in_bytes", "512000000"},
    {"cpu", "cpu.cfs_quota_us", "50000"}
  ])
```

### Backpressure Management

Set `stdio_window` for high-output programs to prevent mailbox overflow:

```elixir
MuonTrap.cmd("streaming_app", [], stdio_window: 20_000)
```

### Not Recommended For

- Interactive programs requiring port communication
- Single-shot commands with simple output (use `System.cmd/3`)
- Programs expecting TTY control signals

### When to Use MuonTrap

- Long-running background services or daemons
- Untrusted or resource-intensive processes
- Applications requiring automatic process cleanup
- Scenarios where child process proliferation must be prevented

---

**Version:** 1.7.0
**Source:** [hexdocs.pm/muontrap](https://hexdocs.pm/muontrap/)
**Repository:** [github.com/fhunleth/muontrap](https://github.com/fhunleth/muontrap)
**Generated:** 2026-05-09
