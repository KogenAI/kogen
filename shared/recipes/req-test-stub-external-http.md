# Req.Test — Stub an External HTTP Client in Tests

**Problem**: Tests make real HTTP calls to external APIs because the Req client has no test seam.
**When**: Adding or testing any module that uses Req to call an external HTTP API.
**See also**: `task-supervisor-sandbox-allowance.md` — if the Req call happens inside a spawned Task

## Solution

Three changes wire up the test stub:

**1. `lib/` — add `req_options/0` to the client module:**

```elixir
defp req_options, do: Application.get_env(:my_app, :client_req_options, [])
```

Pass it when building the request: `Req.new(url: ...) |> Req.merge(req_options()) |> Req.post!(...)`.

**2. `config/test.exs` — point the plug at `Req.Test`:**

```elixir
config :my_app, :client_req_options, [plug: {Req.Test, MyApp.Client}, retry: false]
```

**3. Test — stub and assert on the captured request:**

```elixir
Req.Test.stub(MyApp.Client, fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  send(self(), {:request, Jason.decode!(body)})
  Req.Test.json(conn, %{})
end)

assert_receive {:request, %{"key" => value}}
```

## Gotchas

If the Req call is made inside a `Task.start` or `Task.Supervisor`, the stub is not automatically visible to the spawned process — see `task-supervisor-sandbox-allowance.md`.
