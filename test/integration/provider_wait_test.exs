Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ProviderWaitTest do
  use ExUnit.Case, async: false
  alias Kogen.{ChatGPT, Error, Integration.FakeProvider}
  @moduletag :integration
  @model %{model: "fixture", effort: "medium"}

  setup do
    home = Kogen.tmp_path("provider-wait")
    File.mkdir_p!(Path.join(home, ".kogen/credentials"))

    File.write!(
      Path.join(home, ".kogen/credentials/chatgpt.json"),
      JSON.encode!(%{
        client_id: "oaiapp_fixture",
        access_token: "fake-access",
        refresh_token: "fake-refresh",
        expires_at: System.system_time(:second) + 3600
      })
    )

    previous = :persistent_term.get(:kogen_caller, nil)

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(:kogen_caller, previous),
        else: :persistent_term.erase(:kogen_caller)

      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  defp connect(home, script) do
    server = FakeProvider.start(script)

    :persistent_term.put(:kogen_caller, %{
      env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{server.port}"}
    })

    on_exit(fn -> FakeProvider.stop(server) end)
    server
  end

  defp respond(opts), do: ChatGPT.respond(@model, "fixture", [], [], opts)
  defp done(response), do: %{"type" => "response.completed", "response" => response}

  defp tool,
    do: %{
      "type" => "function_call",
      "call_id" => "call",
      "name" => "write_file",
      "arguments" => "{}"
    }

  test "an expired invocation does not consume the next invocation's budget", %{home: home} do
    server = connect(home, [{:http, 500, %{}}, {:text, "fresh"}])
    started = System.monotonic_time(:millisecond)
    error = assert_raise Error, fn -> respond(response_budget_ms: 80) end
    assert error.reason == "unavailable"
    assert error.detail == "ChatGPT response wait exceeded 30 minutes"
    assert System.monotonic_time(:millisecond) - started < 600
    assert length(FakeProvider.provider_requests(server)) == 1
    assert %{items: [%{"content" => [%{"text" => "fresh"}]}]} = respond(response_budget_ms: 1000)
    assert length(FakeProvider.provider_requests(server)) == 2
  end

  test "the second backoff also spends the original budget", %{home: home} do
    server = connect(home, List.duplicate({:http, 500, %{}}, 3))
    started = System.monotonic_time(:millisecond)
    error = assert_raise Error, fn -> respond(response_budget_ms: 2300) end
    assert error.detail == "ChatGPT response wait exceeded 30 minutes"
    assert (System.monotonic_time(:millisecond) - started) in 2300..2900
    assert length(FakeProvider.provider_requests(server)) == 2
  end

  test "single attempt does not retry unreadable output or transient failures", %{home: home} do
    server = connect(home, [{:events, [done(%{})]}, {:http, 500, %{}}])

    assert %{reason: "invalid_response"} =
             assert_raise(Error, fn -> respond(single_attempt: true, response_budget_ms: 1000) end)

    assert length(FakeProvider.provider_requests(server)) == 1

    assert %{reason: "unavailable"} =
             assert_raise(Error, fn -> respond(single_attempt: true, response_budget_ms: 1000) end)

    assert length(FakeProvider.provider_requests(server)) == 2
  end

  test "completed output is validated, ordered and failures win", %{home: home} do
    item = tool()

    done_item = fn index, value ->
      %{"type" => "response.output_item.done", "output_index" => index, "item" => value}
    end

    cases = [
      [done_item.(1, item), done(%{})],
      [done_item.(-1, item), done(%{})],
      [done_item.(0, %{item | "arguments" => "[]"}), done(%{})],
      [done_item.(0, %{item | "call_id" => ""}), done(%{})],
      [
        done_item.(0, %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => 42}]
        }),
        done(%{})
      ],
      [%{"type" => "response.completed", "response" => "bad"}],
      [done(%{"output" => [Map.put(item, "status", "in_progress")]})],
      [done(%{"output" => [item], "status" => "incomplete"})],
      [done(%{"output" => [item], "error" => %{"code" => "server_error"}})],
      [
        %{"type" => "response.output_item.added", "output_index" => 1, "item" => item},
        done(%{"output" => [item]})
      ],
      [done(%{"output" => [item], "usage" => "bad"})],
      [done(%{"output" => [item], "usage" => %{"input_tokens_details" => 42}})],
      [%{"type" => "response.output_item.added", "output_index" => 0, "item" => item}, done(%{})]
    ]

    connect(
      home,
      Enum.map(cases, &{:events, &1}) ++
        [
          {:events,
           [
             %{"type" => "response.failed", "response" => %{"error" => %{}}},
             done(%{"output" => [item]})
           ]},
          {:events,
           [
             %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
             done(%{"output" => [item]})
           ]},
          {:events,
           [done(%{"status" => "completed", "output" => [Map.put(item, "status", "completed")]})]}
        ]
    )

    for _ <- cases do
      assert %{reason: "invalid_response"} =
               assert_raise(Error, fn ->
                 respond(single_attempt: true, response_budget_ms: 1000)
               end)
    end

    assert %{reason: "refused"} =
             assert_raise(Error, fn -> respond(single_attempt: true, response_budget_ms: 1000) end)

    assert %{items: [^item]} = respond(response_budget_ms: 1000)
    completed = Map.put(item, "status", "completed")
    assert %{items: [^completed]} = respond(response_budget_ms: 1000)
  end

  test "a validated open stream is cancelled before the caller exits", %{home: home} do
    item = tool()
    connect(home, [{:open_events, self(), [done(%{"output" => [item]})]}])
    assert %{items: [^item]} = respond(response_budget_ms: 1000)
    assert_receive {:provider_open, _}
    assert_receive {:provider_closed, {:error, :closed}}, 1000
  end

  test "expiry is checked with a continuously nonempty mailbox and closes the request", %{
    home: home
  } do
    connect(home, [{:open_events, self(), []}])
    caller = self()

    flood = spawn(fn -> flood(caller) end)
    started = System.monotonic_time(:millisecond)

    try do
      error = assert_raise Error, fn -> respond(response_budget_ms: 150) end
      assert error.detail == "ChatGPT response wait exceeded 30 minutes"
      assert (System.monotonic_time(:millisecond) - started) in 150..1000
      assert_receive {:provider_open, _}
      assert_receive {:provider_closed, {:error, :closed}}, 1000
    after
      Process.exit(flood, :kill)
      flush_noise()
    end
  end

  defp flood(caller) do
    for _ <- 1..100, do: send(caller, :mailbox_noise)
    Process.sleep(1)
    flood(caller)
  end

  defp flush_noise do
    receive do
      :mailbox_noise -> flush_noise()
    after
      0 -> :ok
    end
  end

  test "unreadable output retries once within the same invocation", %{home: home} do
    server =
      connect(home, [
        {:events, [done(%{"output" => [tool()], "usage" => "bad"})]},
        {:text, "retry"}
      ])

    assert %{items: [%{"content" => [%{"text" => "retry"}]}]} = respond(response_budget_ms: 1000)
    assert length(FakeProvider.provider_requests(server)) == 2
  end
end
