# systemd

## Overview

The **systemd v0.6.2** is an Erlang/Elixir library that facilitates communication between applications and systemd, the Linux system and service manager. It enables process state notifications, automatic watchdog management, file descriptor handling, and journal logging.

**Cross-platform advantage**: All functions are safe to call even in non-systemd and non-Linux environments. Functions gracefully become no-ops when systemd is unavailable, making the library suitable for portable applications.

## Quick Start

### Installation

**Mix projects:**

```elixir
{:systemd, "~> 0.6"}
```

**Rebar projects:**

```erlang
{deps, [systemd]}
```

### Basic Integration

Signal readiness to systemd:

```elixir
# Simple notification
systemd.notify(:ready)

# As a supervisor child (cleaner approach)
children = [
  {systemd, systemd.ready()}
]
```

### Key Modules

- **systemd** — Core functions for systemd interaction
- **systemd_journal_h** — Logger handler for structured logging
- **systemd_kmsg_formatter** — Formatter for kmsg-style journal output

## Core Concepts

### Process State Notifications

Applications inform systemd of their operational status via `NOTIFY_SOCKET` mechanism:

| State                                         | Purpose                                |
| --------------------------------------------- | -------------------------------------- |
| `:ready`                                      | Application is operational             |
| `:stopping`                                   | Application is shutting down           |
| `:reloading`                                  | Application is reloading configuration |
| `{:errno, integer()}`                         | Signal error state with errno          |
| `{:buserror, chardata()}`                     | Signal D-Bus error                     |
| `{:extend_timeout, {integer(), time_unit()}}` | Request timeout extension              |

Notify systemd:

```elixir
systemd.notify(:ready)
systemd.notify(:stopping)
systemd.notify([{:errno, 1}])
```

### Automatic Watchdog

A watchdog process automatically starts (unless disabled) to send keep-alive messages at regular intervals, preventing systemd from restarting the application during extended operations.

```elixir
# Check watchdog timeout
{:ok, timeout_us} = systemd.watchdog(:state)

# Send keepalive
systemd.watchdog(:ping)

# Control watchdog
systemd.watchdog(:enable)
systemd.watchdog(:disable)
```

### File Descriptor Handling

Retrieve socket file descriptors passed by systemd:

```elixir
fds = systemd.listen_fds()

# Persist across VM restarts
systemd.store_fds([fd1, fd2])
systemd.clear_fds(["named_socket"])
```

### System Detection

Verify systemd availability:

```elixir
{:ok, true} = systemd.booted()  # Systemd is available
{:ok, false} = systemd.booted() # Systemd not available (graceful handling)
```

## Configuration

### Journal Logging

Initialize the journal handler after starting the systemd application:

```elixir
:logger.add_handler(:journal, :systemd_journal_h, %{})
```

### Journal Handler Fields

Configure metadata sent to journald via the `fields` option:

```elixir
:logger.add_handler(:journal, :systemd_journal_h, %{
  fields: [
    :syslog_identifier,  # Application name
    :syslog_timestamp,   # RFC3339 UTC timestamp
    :syslog_pid,         # OS process ID
    :level,              # Log level
  ]
})
```

**Field Naming Rules:**

- Use uppercase ASCII letters, digits, underscores only
- Never start with underscore
- Invalid names are silently ignored by journald

**Convenience Aliases:**

- `syslog_pid` — maps to OS process ID
- `syslog_timestamp` — RFC3339 UTC format
- `syslog_identifier` — application name/version

### Logging Approaches

1. **kmsg-style (stdout/stderr):** Simple formatting with kmsg-style prefixes
2. **Datagram socket:** Multiline and structured logging support

Use the formatter wrapper for kmsg integration:

```elixir
{:systemd_kmsg_formatter, %{}}
```

## Best Practices

### Readiness Signaling

Use `systemd.ready()` as a supervisor child for automatic, clean readiness notification:

```elixir
children = [
  {systemd, systemd.ready()},
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

This approach ensures systemd is notified at the correct point in your application startup.

### Graceful Shutdown

Signal shutdown intent before termination:

```elixir
systemd.notify(:stopping)
```

### Status Tracking

Update systemd with detailed status:

```elixir
systemd.set_status(%{"status" => "Processing requests"})
```

### Watchdog Integration

Always check watchdog availability before relying on extended timeouts:

```elixir
case systemd.watchdog(:state) do
  {:ok, timeout_us} ->
    # Schedule pings at half the timeout interval
    ping_interval = div(timeout_us, 2)
    # ... setup periodic ping
  _ ->
    # Watchdog unavailable, handle gracefully
end
```

### Journal Logging Setup

Configure fields conservatively; empty entries are automatically omitted:

```elixir
:logger.add_handler(:journal, :systemd_journal_h, %{
  fields: [
    :syslog_identifier,
    :syslog_timestamp,
    :syslog_pid,
    :level,
    {:mfa, "MyApp.Module.function/arity"}  # Custom field
  ]
})
```

### Deployment Safety

The library's cross-platform design allows the same binary to run in systemd and non-systemd environments. No conditional logic needed—functions safely no-op when systemd is unavailable.

---

**Version:** 0.6.2  
**Source:** [hexdocs.pm/systemd](https://hexdocs.pm/systemd/)  
**Generated:** 2026-04-25
