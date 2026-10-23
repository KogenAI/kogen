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

  for single <- [false, true], param <- [:absent, nil, "prompt_cache_options"] do
    @single single
    @param param
    test "observed cache refusal preserves requests and evidence (single=#{single}, param=#{inspect(param)})",
         %{home: home} do
      refusal =
        {:http, 400,
         %{
           "error" => %{
             "type" => "invalid_request_error",
             "code" => "invalid_parameter",
             "message" => "prompt_cache_options is not supported on this model"
           }
         }}

      {:http, 400, payload} = refusal

      error =
        if @param == :absent,
          do: payload["error"],
          else: Map.put(payload["error"], "param", @param)

      refusal = {:http, 400, %{"error" => error}}

      completed =
        {:events, [done(%{"id" => "resp_cache", "model" => "gpt-6.1-sol", "output" => [tool()]})]}

      server = connect(home, [refusal, completed, completed])
      Kogen.ShapeEvidence.start(Path.join(home, "evidence"))

      call = fn ->
        Kogen.ShapeEvidence.provider(
          "shape",
          nil,
          "revision",
          [],
          %{model: "gpt-6.1-sol", effort: "high"},
          fn ->
            ChatGPT.respond(
              %{model: "gpt-6.1-sol", effort: "high"},
              "policy",
              [%{"role" => "user", "content" => "contract"}],
              [],
              single_attempt: @single
            )
          end
        )
      end

      assert call.().items == [tool()]
      assert call.().items == [tool()]
      [first, retry, next] = FakeProvider.provider_requests(server)
      assert first.json["prompt_cache_options"]
      assert first.json["include"] == ["reasoning.encrypted_content"]
      assert first.json["model"] == "gpt-6.1-sol"
      assert first.json["reasoning"] == %{"effort" => "high"}

      stripped =
        first.json
        |> Map.delete("prompt_cache_options")
        |> Map.update!("input", fn items ->
          Enum.map(items, fn item ->
            if is_list(item["content"]),
              do:
                Map.update!(
                  item,
                  "content",
                  &Enum.map(&1, fn block -> Map.delete(block, "prompt_cache_breakpoint") end)
                ),
              else: item
          end)
        end)

      assert retry.json == stripped
      refute retry.json["prompt_cache_options"]
      refute next.json["prompt_cache_options"]
      assert retry.json["input"] == next.json["input"]

      rows =
        File.read!(Path.join(home, "evidence/events.ndjson"))
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      assert length(rows) == 3

      assert Enum.at(rows, 0)["provider"]["timestamp"] !=
               Enum.at(rows, 1)["provider"]["timestamp"]

      refused = hd(rows)["provider"]
      assert refused["usage_state"] == "unknown"
      assert Enum.all?(refused["usage"], fn {_, count} -> is_nil(count) end)

      for field <-
            ~w(provider_response_id effective_model effective_effort effective_service_tier) do
        assert refused[field] == nil
      end

      assert refused["provider_request_id"] == "req-fixture"
      assert refused["cache"]["applied_ttl"] == nil
      assert refused["cache"]["applied_mode"] == nil
      assert hd(rows)["provider"]["cache"]["status"] == "unsupported"
      assert hd(rows)["provider"]["cache"]["boundaries"] != []
      assert Enum.at(rows, 1)["provider"]["cache"]["boundaries"] == []
      assert List.last(rows)["provider"]["provider_response_id"] == "resp_cache"
      assert List.last(rows)["provider"]["provider_request_id"] == "req-fixture"
    end
  end

  test "cache refusal retries once, persists unsupported, and retains real request identifiers",
       %{home: home} do
    refusal =
      {:http, 400,
       %{
         "error" => %{
           "code" => "unknown_parameter",
           "param" => "input[0].content[0].prompt_cache_breakpoint",
           "message" => "unsupported"
         }
       }}

    completed =
      {:events, [done(%{"id" => "resp_cache", "model" => "gpt-6.1-sol", "output" => [tool()]})]}

    server = connect(home, [refusal, completed, completed])
    Kogen.ShapeEvidence.start(Path.join(home, "evidence"))

    call = fn ->
      Kogen.ShapeEvidence.provider(
        "shape",
        nil,
        "revision",
        [],
        %{model: "gpt-6.1-sol", effort: "medium"},
        fn ->
          ChatGPT.respond(
            %{model: "gpt-6.1-sol", effort: "medium"},
            "policy",
            [%{"role" => "user", "content" => "contract"}],
            [],
            single_attempt: true
          )
        end
      )
    end

    assert call.().items == [tool()]
    assert call.().items == [tool()]
    [first, retry, next] = FakeProvider.provider_requests(server)
    assert first.json["prompt_cache_options"]
    assert first.json["include"] == ["reasoning.encrypted_content"]
    assert retry.json["include"] == first.json["include"]
    refute retry.json["prompt_cache_options"]
    refute next.json["prompt_cache_options"]
    assert retry.json["input"] == next.json["input"]

    rows =
      File.read!(Path.join(home, "evidence/events.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert length(rows) == 3
    assert Enum.at(rows, 0)["provider"]["timestamp"] != Enum.at(rows, 1)["provider"]["timestamp"]
    assert hd(rows)["provider"]["usage"]["input"] == nil
    assert hd(rows)["provider"]["cache"]["status"] == "unsupported"
    assert hd(rows)["provider"]["cache"]["boundaries"] != []
    assert Enum.at(rows, 1)["provider"]["cache"]["boundaries"] == []
    assert List.last(rows)["provider"]["provider_response_id"] == "resp_cache"
    assert List.last(rows)["provider"]["provider_request_id"] == "req-fixture"
  end

  test "unrelated refusal never strips cache fields or reexecutes", %{home: home} do
    server =
      connect(home, [
        {:http, 400,
         %{
           "error" => %{
             "code" => "context_length_exceeded",
             "param" => "input",
             "message" => "full"
           }
         }}
      ])

    error =
      assert_raise Error, fn ->
        ChatGPT.respond(%{model: "gpt-6.1-sol", effort: "medium"}, "policy", [], [])
      end

    assert error.reason == "context_too_long"
    assert length(FakeProvider.provider_requests(server)) == 1
  end

  test "a cache field alone does not authorize compatibility replay", %{home: home} do
    for code <- ["policy_violation", "invalid_request_error", "unknown_policy_refusal"] do
      server =
        connect(home, [
          {:http, 400,
           %{
             "error" => %{
               "code" => code,
               "param" => "prompt_cache_options",
               "message" => "refused"
             }
           }}
        ])

      assert_raise Error, fn ->
        ChatGPT.respond(%{model: "gpt-6.1-sol", effort: "medium"}, "policy", [], [])
      end

      assert length(FakeProvider.provider_requests(server)) == 1
    end
  end

  test "inconsistent completed usage is retained but not added to compatible totals", %{
    home: home
  } do
    connect(home, [
      {:events,
       [
         done(%{
           "output" => [tool()],
           "usage" => %{
             "input_tokens" => 10,
             "input_tokens_details" => %{"cached_tokens" => 11},
             "output_tokens" => 2
           }
         })
       ]}
    ])

    response = respond(single_attempt: true)
    assert response.known_usage.cached == 11
    assert Kogen.Usage.state(response.known_usage) == "inconsistent"
    assert response.usage == Kogen.Usage.zero()
  end

  test "malformed optional write counts never leak into analytical usage", %{home: home} do
    connect(home, [
      {:events,
       [
         done(%{
           "output" => [tool()],
           "usage" => %{
             "input_tokens" => 10,
             "input_tokens_details" => %{"cache_write_tokens" => %{"raw" => "PRIVATE-WRITE-BODY"}}
           }
         })
       ]}
    ])

    Kogen.ShapeEvidence.start(Path.join(home, "evidence"))

    r =
      Kogen.ShapeEvidence.provider("shape", nil, "revision", [], @model, fn ->
        respond(single_attempt: true)
      end)

    assert r.items == [tool()]
    assert r.known_usage.write == nil
    assert r.usage_state == "inconsistent"
    log = File.read!(Path.join(home, "evidence/events.ndjson"))
    refute log =~ "PRIVATE-WRITE-BODY"
    row = JSON.decode!(String.trim(log))
    assert row["provider"]["usage_state"] == "inconsistent"
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

  test "terminal evidence retains sticky guards but describes only effective replacement items",
       %{home: home} do
    bad = Map.put(tool(), "arguments", "PRIVATE-invalid-json")

    frames = [
      %{"type" => "response.output_item.done", "output_index" => -1, "item" => bad},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => bad},
      %{"type" => "response.output_item.added", "output_index" => 2},
      done(%{"output" => [tool()]})
    ]

    connect(home, [{:events, frames}])
    error = assert_raise Error, fn -> respond(single_attempt: true) end
    evidence = terminal_evidence(error)
    assert evidence["reasons"] == ["item_event_shape", "terminal_index_coverage"]
    facts = evidence["facts"]
    assert facts["observed_index_count"] == 2
    assert facts["item_count"] == 1
    assert facts["pending_count"] == 0
    assert facts["terminal_output_replaced"]
    assert facts["arguments_object"] == ["yes"]
    refute error.detail =~ "PRIVATE"
  end

  test "terminal evidence distinguishes effective pending and gap predicates", %{home: home} do
    connect(home, [
      {:events,
       [
         %{"type" => "response.output_item.done", "output_index" => 1, "item" => tool()},
         done(%{})
       ]},
      {:events,
       [
         %{"type" => "response.output_item.done", "output_index" => 0, "item" => tool()},
         %{"type" => "response.output_item.added", "output_index" => 1},
         done(%{})
       ]}
    ])

    gap = assert_raise Error, fn -> respond(single_attempt: true) end
    assert terminal_evidence(gap)["reasons"] == ["noncontiguous_indexes"]
    pending = assert_raise Error, fn -> respond(single_attempt: true) end
    evidence = terminal_evidence(pending)
    assert evidence["reasons"] == ["pending_items"]
    assert evidence["facts"]["pending_count"] == 1
    assert evidence["facts"]["observed_index_count"] == 2
    refute evidence["facts"]["terminal_output_replaced"]
  end

  defp terminal_evidence(error) do
    [_, json] = String.split(error.detail, "; validation=", parts: 2)
    assert byte_size(json) <= 2048
    JSON.decode!(json)
  end

  defp item_done(index, item),
    do: %{"type" => "response.output_item.done", "output_index" => index, "item" => item}

  test "empty terminal metadata retains ordered multiitem output and usage on an open socket", %{
    home: home
  } do
    items = [
      %{"type" => "reasoning", "summary" => []},
      %{
        "type" => "message",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => "ready", "annotations" => []}]
      },
      Map.put(tool(), "arguments", "{\"path\":\"app.txt\"}"),
      Map.put(tool(), "call_id", "second")
    ]

    frames =
      Enum.flat_map(Enum.with_index(items), fn {item, i} ->
        [
          %{"type" => "response.output_item.added", "output_index" => i, "item" => item},
          %{
            "type" => "response.function_call_arguments.delta",
            "output_index" => i,
            "delta" => "PRIVATE-partial"
          }
        ]
      end)

    # Done events need not arrive in index order.
    frames =
      frames ++
        Enum.map(Enum.reverse(Enum.with_index(items)), fn {item, i} -> item_done(i, item) end)

    usage = %{
      "input_tokens" => 100,
      "input_tokens_details" => %{"cached_tokens" => 5},
      "output_tokens" => 20,
      "output_tokens_details" => %{"reasoning_tokens" => 10}
    }

    server =
      connect(home, [
        {:open_events, self(), frames ++ [done(%{"output" => [], "usage" => usage})]}
      ])

    expected_usage = %{input: 100, cached: 5, output: 20, reasoning: 10}

    assert %{
             items: ^items,
             usage: ^expected_usage,
             known_usage: %{
               input: 100,
               cached: 5,
               output: 20,
               reasoning: 10,
               write: nil,
               write_30m: nil,
               write_12h: nil
             }
           } =
             respond(single_attempt: true, response_budget_ms: 1000)

    assert_receive {:provider_open, _}
    assert_receive {:provider_closed, {:error, :closed}}, 1000
    assert length(FakeProvider.provider_requests(server)) == 1
  end

  test "empty final output retains refusal predicates and effective diagnostic facts", %{
    home: home
  } do
    item = tool()
    added = %{"type" => "response.output_item.added", "output_index" => 1}

    cases = [
      {[item_done(0, item), added], %{}, ["pending_items"], 1, 1, 2},
      {[
         %{
           "type" => "response.function_call_arguments.delta",
           "output_index" => 0,
           "delta" => "{}"
         }
       ], %{}, ["empty_output"], 0, 0, 0},
      {[item_done(0, %{item | "arguments" => "PRIVATE-invalid"})], %{}, ["item_shape"], 1, 0, 1},
      {[item_done(0, %{item | "arguments" => "[]"})], %{}, ["item_shape"], 1, 0, 1},
      {[item_done(0, %{item | "call_id" => ""})], %{}, ["item_shape"], 1, 0, 1},
      {[
         item_done(0, %{
           "type" => "message",
           "content" => [%{"type" => "output_text", "text" => 42}]
         })
       ], %{}, ["item_shape"], 1, 0, 1},
      {[item_done(0, Map.put(item, "status", "in_progress"))], %{}, ["item_status"], 1, 0, 1},
      {[item_done(1, item)], %{}, ["noncontiguous_indexes"], 1, 0, 1},
      {[item_done(-1, item), item_done(0, item)], %{}, ["item_event_shape"], 1, 0, 1},
      {[item_done(0, item)], %{"usage" => "bad"}, ["usage_shape"], 1, 0, 1},
      {[item_done(0, item)], %{"usage" => %{"input_tokens_details" => 42}}, ["usage_shape"], 1, 0,
       1},
      {[item_done(0, item)], %{"status" => "incomplete"}, ["response_status"], 1, 0, 1},
      {[item_done(0, item)], %{"error" => %{}}, ["response_error"], 1, 0, 1}
    ]

    connect(
      home,
      Enum.map(cases, fn {frames, meta, _, _, _, _} ->
        {:events, frames ++ [done(Map.put(meta, "output", []))]}
      end)
    )

    for {_, _, reasons, items, pending, observed} <- cases do
      error = assert_raise Error, fn -> respond(single_attempt: true) end
      assert error.reason == "invalid_response"
      evidence = terminal_evidence(error)
      assert evidence["reasons"] == reasons
      facts = evidence["facts"]
      assert facts["terminal_response_present"]
      assert facts["terminal_output_present"]
      refute facts["terminal_output_replaced"]
      assert facts["item_count"] == items
      assert facts["pending_count"] == pending
      assert facts["observed_index_count"] == observed
      refute error.detail =~ "PRIVATE"
    end
  end

  test "failure events win over retained done items and empty completion", %{home: home} do
    kinds = ["response.failed", "response.incomplete", "error"]

    connect(
      home,
      Enum.map(kinds, fn kind ->
        {:events,
         [
           item_done(0, tool()),
           %{"type" => kind, "response" => %{"error" => %{}}},
           done(%{"output" => []})
         ]}
      end) ++ [{:events, [item_done(0, tool())]}, {:events, [item_done(0, tool()), done("bad")]}]
    )

    for _ <- kinds do
      assert %{reason: "refused"} = assert_raise(Error, fn -> respond(single_attempt: true) end)
    end

    assert %{reason: "unavailable"} = assert_raise(Error, fn -> respond(single_attempt: true) end)

    assert %{reason: "invalid_response"} =
             assert_raise(Error, fn -> respond(single_attempt: true) end)
  end

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

  test "overload retries the complete request and discards failed output", %{home: home} do
    failure = %{
      "type" => "error",
      "error" => %{
        "code" => "server_is_overloaded",
        "type" => "service_unavailable_error",
        "message" => "Our servers are currently overloaded"
      }
    }

    partial = Map.put(tool(), "call_id", "failed-tool")

    server =
      connect(home, [
        {:events,
         [
           %{"type" => "response.output_item.done", "output_index" => 0, "item" => partial},
           failure
         ]},
        {:events, [done(%{"output" => [tool()]})]}
      ])

    assert respond([]).items == [tool()]
    [first, retry] = FakeProvider.provider_requests(server)
    assert first.json == retry.json
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
