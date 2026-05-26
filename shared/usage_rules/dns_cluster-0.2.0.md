# dns_cluster

DNS-based cluster discovery for Elixir applications. Periodically queries DNS to discover and automatically connect new cluster nodes. Ideal for simple, stateless clustering scenarios without external dependencies.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:dns_cluster, "~> 0.2"}
  ]
end
```

### Basic Setup

Add to your supervision tree (typically in `application.ex`):

```elixir
children = [
  {DNSCluster, query: "myapp.internal"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

This automatically discovers and connects nodes in your cluster every 5 seconds.

## Core Concepts

### How Discovery Works

- **Periodic DNS queries**: DNSCluster queries a DNS domain at regular intervals (default: 5000ms)
- **Automatic node connection**: Discovered nodes matching your criteria are connected automatically
- **Basename matching**: By default, only connects to nodes whose basenames match the current node's basename
- **Shared cookie requirement**: All nodes must share the same Erlang distribution cookie for successful clustering

### Key Features

- **Zero external dependencies**: Uses built-in Erlang DNS resolution
- **Simple configuration**: Minimal setup required for basic clustering
- **Multiple domain support**: Can query multiple DNS domains simultaneously
- **Custom naming**: Supports different node naming schemes across clusters

## Configuration

### Start Link Options

```elixir
DNSCluster.start_link(
  name: :my_cluster,              # Cluster identifier (default: DNSCluster)
  query: "myapp.internal",        # Required: DNS domain to query
  interval: 5000,                 # Query interval in ms (default: 5000)
  connect_timeout: 10000          # Connection timeout in ms (default: 10000)
)
```

### Multiple Domains

Query multiple DNS domains:

```elixir
DNSCluster.start_link(
  query: ["app-one.internal", "app-two.internal"]
)
```

### Custom Node Basenames

Connect to nodes with different basenames using tuple syntax:

```elixir
DNSCluster.start_link(
  query: {"remote", "remote-app.internal"}
)
```

This connects current node to remote nodes with basename "remote" at domain "remote-app.internal".

Mixed domains with custom basenames:

```elixir
DNSCluster.start_link(
  query: [
    "myapp.internal",                    # Same basename required
    {"remote", "remote-app.internal"}    # Custom basename
  ]
)
```

## Best Practices

### Cluster Setup

- **Ensure DNS availability**: DNS must be resolvable and return IP addresses of running nodes
- **Same cookie everywhere**: Set `RELEASE_COOKIE` or configure in `rel/env.sh` - all nodes need identical cookies
- **Node naming consistency**: Use consistent naming schemes (e.g., `app@10.0.0.1`)

### Configuration

- **Adjust interval based on needs**: Lower intervals (e.g., 1000ms) for faster discovery, higher (e.g., 10000ms) to reduce DNS load
- **Extend timeout for slow networks**: Increase `connect_timeout` if experiencing connection failures
- **Use multiple domains cautiously**: Each domain adds overhead to the discovery cycle

### Monitoring

- Monitor DNS resolution health
- Log node connection attempts for debugging
- Watch for excessive DNS queries causing network load
- Verify cookie mismatches (most common connection issue)

### When to Use

- **Good for**: Simple deployments, homogeneous clusters, environments with stable DNS
- **Consider alternatives**: Use [libcluster](https://hexdocs.pm/libcluster) for complex clustering scenarios requiring advanced strategies (Kubernetes, cloud platforms, dynamic scaling)

---

**Version:** 0.2.0
**Source:** [hexdocs.pm/dns_cluster](https://hexdocs.pm/dns_cluster/)
**Generated:** 2025-10-28
