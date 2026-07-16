# Recipe: Per-IP Rate Limiting with Pure ETS (No Hammer)

## Problem

An endpoint (login form, public API, contact form) needs to reject requests
once a single client IP exceeds N requests per window, returning `429 Too
Many Requests`. Pulling in a rate-limit library (Hammer or similar) adds a
dependency for something the BEAM already gives you: ETS provides atomic
counters with sub-microsecond access, no external process, no extra dep.

## Solution

A named ETS table (`:public, :named_table, write_concurrency: true`) keyed
by client IP, holding a fixed-window counter and its window-start
timestamp. A plug increments the counter atomically via
`:ets.update_counter/4` and halts with 429 + `retry-after` when the
configured limit is exceeded. A periodic sweep (or lazy per-key check)
resets stale windows so the table never grows unbounded.

This recipe assumes `conn.remote_ip` is already the real client address —
see [Phoenix Remote IP](phoenix-remote-ip.md) if the app sits behind a
proxy; without that plug every request appears to come from the proxy's IP
and the limiter throttles the wrong thing.

## Implementation

### 1. Rate limiter module

```elixir
defmodule YourApp.RateLimiter do
  @moduledoc """
  Fixed-window per-key rate limiter backed by ETS.

  Each key (e.g., a client IP) gets a counter that resets once the window
  has elapsed. `:ets.update_counter/4` is atomic — concurrent requests from
  the same key never race on the increment.
  """

  @table :rate_limiter_buckets

  @type key :: term()
  @type limit_result :: :ok | {:limited, retry_after_ms :: non_neg_integer()}

  @spec init_table() :: :ok
  def init_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        :ok

      _info ->
        :ok
    end
  end

  @doc """
  Checks and increments the counter for `key`. `limit` is the max requests
  allowed within `window_ms`.
  """
  @spec check(key(), pos_integer(), pos_integer()) :: limit_result()
  def check(key, limit, window_ms) do
    init_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count >= limit do
          {:limited, window_ms - (now - window_start)}
        else
          :ets.update_counter(@table, key, {2, 1})
          :ok
        end

      _no_entry_or_expired ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc "Test/ops helper — clears all buckets."
  @spec reset() :: :ok
  def reset do
    case :ets.info(@table) do
      :undefined -> :ok
      _info -> :ets.delete_all_objects(@table)
    end

    :ok
  end
end
```

### 2. Plug wiring

```elixir
defmodule YourAppWeb.Plugs.RateLimit do
  @moduledoc "Per-IP rate limit plug — halts with 429 when the limit is exceeded."

  import Plug.Conn

  alias YourApp.RateLimiter

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    key = conn.remote_ip

    case RateLimiter.check(key, limit, window_ms) do
      :ok ->
        conn

      {:limited, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000)))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end
```

### 3. Use it on the endpoint that needs protecting

```elixir
# lib/your_app_web/router.ex
pipeline :rate_limited do
  plug YourAppWeb.Plugs.RateLimit, limit: 5, window_ms: 60_000
end

scope "/", YourAppWeb do
  pipe_through [:browser, :rate_limited]

  post "/login", SessionController, :create
end
```

## Testing

```elixir
defmodule YourApp.RateLimiterTest do
  use ExUnit.Case, async: false

  alias YourApp.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "allows requests under the limit" do
    assert :ok = RateLimiter.check("1.2.3.4", 3, 60_000)
    assert :ok = RateLimiter.check("1.2.3.4", 3, 60_000)
    assert :ok = RateLimiter.check("1.2.3.4", 3, 60_000)
  end

  test "limits requests over the threshold" do
    for _ <- 1..3, do: RateLimiter.check("1.2.3.4", 3, 60_000)
    assert {:limited, retry_after_ms} = RateLimiter.check("1.2.3.4", 3, 60_000)
    assert retry_after_ms > 0
  end

  test "different keys have independent counters" do
    for _ <- 1..3, do: RateLimiter.check("1.2.3.4", 3, 60_000)
    assert :ok = RateLimiter.check("5.6.7.8", 3, 60_000)
  end
end
```

`async: false` — the table is a process-global named ETS table shared
across the test module; concurrent tests would race on the same keys unless
each test uses a distinct key. Prefer distinct keys per test and keep
`async: true` when possible; fall back to `async: false` only if tests must
share a key.

## Considerations

- **Fixed window, not sliding** — a client can burst up to `2 * limit`
  requests across a window boundary (limit at the end of one window, limit
  again at the start of the next). Acceptable for abuse protection; not
  precise enough for billing-grade throttling.
- **Table growth** — stale keys are only cleaned up lazily (overwritten on
  next check). For high-cardinality keyspaces (e.g., IPv6, many distinct
  clients), add a periodic sweep via a GenServer + `:timer.send_interval/2`
  that runs `:ets.select_delete/2` on expired windows if memory becomes a
  concern.
- **Key on the real client IP** — see [Phoenix Remote IP](phoenix-remote-ip.md);
  without it, every request behind a proxy shares one counter (the proxy's
  IP), throttling all clients together.
- **Multi-node deployments** — this table is node-local. A client hitting
  different nodes behind a load balancer gets a separate counter per node.
  Acceptable for coarse abuse protection; not exact for strict global
  limits (that needs a shared store, out of scope here).

## Related Recipes

- [Phoenix Remote IP](phoenix-remote-ip.md) — real client IP extraction
  this limiter depends on.
- [ETS Content Cache](ets-content-cache.md) — sibling ETS pattern for
  caching rather than counting.
