# Recipe: Real Client IP Behind a Proxy (remote_ip)

## Problem

An app fronted by a reverse proxy (Caddy, nginx, a load balancer) sees every
request's `conn.remote_ip` as the proxy's own IP, not the real client's.
Anything keyed on client IP — per-IP rate limiting, audit logging, geo
lookups, abuse blocking — silently keys on the wrong address until this is
wired in.

## Solution

Add the `remote_ip` plug ahead of the router. It rewrites
`conn.remote_ip` in place based on a trusted forwarding header
(`X-Forwarded-For`, `Forwarded`, etc.), so every downstream plug and context
function that reads `conn.remote_ip` gets the real client address for free —
no call-site changes needed.

**This is a recipe, not a scaffold default.** The header scheme
(`X-Forwarded-For` vs RFC 7239 `Forwarded`) is per-proxy; there is no safe
default that works for every deployment, and only proxy-fronted apps need
it. Add it deliberately, once you know what your proxy emits.

## Implementation

### 1. Add the dependency

```elixir
# mix.exs
def deps do
  [
    {:remote_ip, "~> 1.2"}
    # ...
  ]
end
```

```bash
mix deps.get
```

### 2. Plug it in ahead of the router

`remote_ip` must run **before** `:match`/`:dispatch` — in the endpoint, not
the router, so it applies to every request regardless of pipeline.

```elixir
# lib/your_app_web/endpoint.ex
defmodule YourAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :your_app

  # ... existing plugs (Plug.Static, Plug.RequestId, etc.) ...

  plug RemoteIp,
    headers: ~w[x-forwarded-for]

  plug YourAppWeb.Router
end
```

### 3. Pick ONE header, explicitly

Production deployments should configure a **singleton header list** — do
not rely on the library's multi-header default (`forwarded`,
`x-forwarded-for`, `x-client-ip`, `x-real-ip`), since header-ordering
ambiguity across infrastructure is an actual spoofing surface. Confirm what
your proxy emits before wiring this:

```bash
# Check what the proxy actually sends — do not guess
curl -sv https://your-app.example.com/ 2>&1 | grep -i forwarded
```

Caddy's default reverse_proxy already sets `X-Forwarded-For`; most
load balancers do the same. If the proxy speaks RFC 7239 `Forwarded`
instead, use `headers: ~w[forwarded]`.

### 4. Trust only the proxy hop, not the whole chain

```elixir
plug RemoteIp,
  headers: ~w[x-forwarded-for],
  proxies: {System, :get_env, ["TRUSTED_PROXY_CIDRS"]}
```

`proxies` names addresses to SKIP when walking the header (i.e., "these are
proxies, not clients"). Reserved/private ranges are skipped automatically
regardless of config. Leaving `proxies` unset trusts every hop in the
header, which is safe only when the immediate connection is from a proxy
you control (the common single-hop case) — for a multi-hop chain (CDN → LB
→ app), name the proxy CIDRs explicitly.

### 5. Use it downstream

No call-site changes are needed — every existing `conn.remote_ip` read
(logging, audit, rate limiting) now sees the corrected address:

```elixir
defp log_unauthorized_attempt(conn) do
  ip = conn.remote_ip |> :inet.ntoa() |> to_string()
  Logger.warning("Unauthorized attempt from #{ip}")
end
```

## Testing

```elixir
test "extracts real client IP from X-Forwarded-For" do
  conn =
    build_conn()
    |> put_req_header("x-forwarded-for", "203.0.113.5")
    |> RemoteIp.call(RemoteIp.init(headers: ~w[x-forwarded-for]))

  assert conn.remote_ip == {203, 0, 113, 5}
end
```

Validate parsing directly with `RemoteIp.from/2` before wiring into a live
pipeline:

```elixir
RemoteIp.from([{"x-forwarded-for", "203.0.113.5"}], headers: ~w[x-forwarded-for])
# => {203, 0, 113, 5}
```

## Considerations

- **Never use this plug in a non-proxied environment** — with no proxy in
  front, a client can set `X-Forwarded-For` itself and spoof any address.
- Header choice and `:proxies` trust boundary are per-deployment — verify
  against the real proxy before shipping, not from documentation alone.
- Full config surface (`:parsers`, `:clients`, MFA-tuple values for runtime
  env lookups) is documented in the usage_rules entry.

## Related Recipes

- [Phoenix ETS Rate Limit](phoenix-ets-rate-limit.md) — needs the real
  client IP from this recipe to key its per-IP counters correctly.
- Usage rules: `shared/usage_rules/remote_ip-1.2.0.md` for the full option
  reference.
