# oban - Distributed Operations

## Multi-Node Architecture

Oban coordinates job processing across multiple nodes using a notifier (for pub/sub) and a peer (for leadership). This enables:

- Cluster-wide job coordination
- Distributed queue control
- Shared job database (PostgreSQL)
- Leadership-based stager mode

## Notifier Implementations

The notifier broadcasts events across the cluster:

### Postgres Notifier (Recommended)

Uses PostgreSQL's LISTEN/NOTIFY:

```elixir
config :my_app, Oban,
  notifier: Oban.Notifiers.Postgres
```

**Advantages:**

- Works with PostgreSQL 12+
- No additional dependencies
- Automatic failover
- Highly reliable

**Limitations:**

- Requires PostgreSQL
- Cannot cross firewall boundaries

### PG Notifier (Distributed Erlang)

Uses Distributed Erlang (Erlang node clustering):

```elixir
config :my_app, Oban,
  notifier: Oban.Notifiers.PG
```

**Advantages:**

- Works across networks
- No external dependencies

**Limitations:**

- Requires Erlang distribution setup
- Complex networking requirements

### Phoenix PubSub

Uses Phoenix.PubSub for cluster coordination:

```elixir
config :my_app, Oban,
  notifier: {Oban.Notifiers.Phoenix, pubsub: MyAppWeb.PubSub}
```

**Advantages:**

- Works with existing Phoenix infrastructure
- Supports multiple adapter backends

**Limitations:**

- Requires Phoenix in application
- Additional dependency

## Peer Implementations

The peer module manages leadership elections and global stager mode:

### Postgres Peer (Recommended)

Uses PostgreSQL for election coordination:

```elixir
config :my_app, Oban,
  peer: Oban.Peers.Postgres
```

**Features:**

- Leader election via database locks
- Works across any network
- Simple debugging

### PG Peer (Distributed Erlang)

Uses Distributed Erlang for elections:

```elixir
config :my_app, Oban,
  peer: Oban.Peers.PG
```

**Features:**

- Works without external services
- Requires Erlang distribution

### Isolated Peer

Single-node mode (no clustering):

```elixir
config :my_app, Oban,
  peer: Oban.Peers.Isolated
```

## Notifier Status

Monitor notifier connectivity:

```elixir
status = Oban.Notifier.status(Oban)

case status do
  :clustered ->
    # Connected to other nodes
    Logger.info("Multi-node cluster active")

  :solitary ->
    # Only receiving own messages
    Logger.warning("No other nodes detected")

  :isolated ->
    # Disconnected from cluster
    Logger.error("Unable to receive external messages")

  :unknown ->
    # Status not yet determined
    Logger.debug("Notifier status unknown")
end
```

## Distributed Queue Operations

Queue operations require a **connected notifier** to function across nodes:

### Pause Queue Across All Nodes

```elixir
# Affects all nodes simultaneously
Oban.pause_queue(Oban, :mailers)

# Resume all nodes
Oban.resume_queue(Oban, :mailers)
```

### Scale Queue Concurrency

```elixir
# Increase concurrency cluster-wide
Oban.scale_queue(Oban, :mailers, concurrency: 30)

# Decrease for maintenance
Oban.scale_queue(Oban, :mailers, concurrency: 2)
```

### Cancel Jobs Remotely

```elixir
# Cancel specific job from any node
Oban.cancel_job(Oban, job_id)

# Job stops even if currently executing on another node
```

## Multi-Node Configuration

### Example Production Setup

```elixir
# config/prod.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,
    mailers: 5,
    critical: 20
  ],

  # Distributed coordination
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Postgres,

  # Node identity
  node: :my_app@node1,

  # Performance tuning
  stage_interval: 5000,      # Poll every 5 seconds
  dispatch_cooldown: 50,     # 50ms between dispatches
  shutdown_grace_period: 15  # 15 second graceful shutdown
```

## Leadership & Stager Mode

The leader node is responsible for **staging** (moving scheduled jobs to available state). This prevents duplicate staging across nodes:

```elixir
# Check if this node is the leader
leader? = Oban.Peers.leader?(Oban)

if leader? do
  Logger.info("This node is the leader")
end
```

**Global Stager Mode**: When configured with Postgres peer, one node manages stager duties automatically.

**Local Stager Mode**: Each node manages its own staged jobs (less efficient).

## Distributed Job Processing

Jobs enqueued from any node execute on any available node:

```
Node 1: Enqueue job → Database
                    ↓
        Postgres NOTIFY
        ↙         ↓         ↘
    Node 1     Node 2     Node 3
    (executes) (receives) (receives)
```

**Guarantee**: Each job executes on exactly one node per attempt.

## Handling Network Partitions

When nodes can't communicate:

1. **Temporary partitions** - Nodes operate independently until reconnection
2. **Stager isolation** - No node can stage globally; jobs may delay
3. **Queue operations fail** - `pause_queue`, `scale_queue`, `cancel_job` return errors

**Recovery**: Once notifier reconnects, operations resume normally.

## Monitoring Cluster Health

```elixir
defmodule MyApp.ClusterMonitor do
  require Logger

  def check_connectivity() do
    case Oban.Notifier.status(Oban) do
      :clustered ->
        Logger.info("Cluster healthy - multi-node coordination active")
        :healthy

      :solitary ->
        Logger.warning("Cluster degraded - single node detected")
        :degraded

      :isolated ->
        Logger.error("Cluster critical - node isolated from cluster")
        :critical

      :unknown ->
        Logger.debug("Cluster status unknown")
        :unknown
    end
  end

  def check_leader() do
    if Oban.Peers.leader?(Oban) do
      Logger.info("This node is the leader")
    else
      Logger.debug("This node is not the leader")
    end
  end
end
```

## Common Distributed Patterns

### High Availability Setup

```elixir
# Multiple nodes with shared database
config :my_app, Oban,
  repo: MyApp.Repo,
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Postgres,

  # Each node subscribes to shared database
  queues: [
    default: 5,
    critical: 10,
    background: 3
  ]

# If any node fails, others continue processing jobs
```

### Geographic Distribution

```elixir
# Different queues on different nodes
config :my_app, Oban,
  queues: [
    # US node handles US queues
    us_processing: 20,
    us_notifications: 10
  ]

# EU node configuration
config :my_app, Oban,
  queues: [
    eu_processing: 20,
    eu_notifications: 10
  ]
```

### Queue Prioritization

```elixir
# Leader node - handles all queues
config :my_app, Oban,
  queues: [
    critical: 20,
    default: 10,
    background: 5
  ]

# Worker nodes - only background queues
config :my_app, Oban,
  queues: [
    background: 50  # Can handle more low-priority work
  ]
```

## Debugging Distributed Issues

Check registry for all Oban processes:

```elixir
# Get all registered Oban processes
Oban.Registry.select([{:_, :"$1", :"$2"}])

# Check specific process
Oban.Registry.whereis(Oban, :supervisor)
Oban.Registry.whereis(Oban, {:producer, :default})
```

Enable distributed tracing:

```elixir
# Add to config
config :logger, :console,
  format: {Logger, :plain_format},
  level: :debug

# Watch for notifier and peer events in logs
```

---

[← Back to main](oban-2.20.1.md)
**Version:** 2.20.1
