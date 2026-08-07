# hpax

High-Performance HTTP/2 ALPN eXtension library for Elixir.

## Quick Start

Add hpax to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:hpax, "~> 1.0.4"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

## Core Concepts

hpax provides HTTP/2 ALPN (Application Layer Protocol Negotiation) protocol handling for Elixir applications. The library focuses on:

- **Protocol Negotiation**: Handles ALPN extensions for HTTP/2 protocol selection
- **Performance**: Optimized for high-throughput HTTP/2 communication
- **Integration**: Works with Elixir's HTTP/2 stack

## Configuration

hpax requires minimal configuration as it integrates directly with HTTP/2 protocol handling. Configuration is typically done through your HTTP client or server library that uses hpax as a dependency.

## Best Practices

- Use hpax with compatible HTTP/2 libraries in your Elixir stack
- Ensure your Erlang/OTP version supports HTTP/2 protocol features
- Monitor protocol negotiation during development to verify ALPN is functioning correctly
- Test with HTTP/2 clients to validate proper protocol selection

---

**Version:** 1.0.4
**Source:** [hexdocs.pm/hpax](https://hexdocs.pm/hpax)
**Generated:** 2026-08-07
