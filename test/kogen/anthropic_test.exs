defmodule Kogen.AnthropicTest do
  use ExUnit.Case, async: true
  alias Kogen.{Anthropic, ChatGPT, Error, Shape, WorkingContext}
  @role %{provider: "anthropic", model: "claude-opus-5-5", effort: "high"}
  defp wire(events),
    do: Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{JSON.encode!(&1)}\n\n")

  defp start(usage \\ %{}),
    do: %{
      "type" => "message_start",
      "message" => %{"id" => "msg_fixture", "model" => @role.model, "usage" => usage}
    }

  defp block(i, b),
    do: [
      %{"type" => "content_block_start", "index" => i, "content_block" => b},
      %{"type" => "content_block_stop", "index" => i}
    ]

  defp finish(reason),
    do: [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => reason},
        "usage" => %{"output_tokens" => 12}
      },
      %{"type" => "message_stop"}
    ]

  defp call(id),
    do: %{"type" => "tool_use", "id" => id, "name" => "read_file", "input" => %{"path" => "Δ"}}

  test "ordered native replay retains opaque blocks once and groups parallel results" do
    blocks = [
      %{"type" => "thinking", "thinking" => "opaque", "signature" => "signature"},
      %{"type" => "redacted_thinking", "data" => "redacted"},
      %{"type" => "text", "text" => "checking"},
      call("b"),
      call("a")
    ]

    events =
      [
        start(%{
          "input_tokens" => 100,
          "cache_read_input_tokens" => 20,
          "cache_creation_input_tokens" => 10
        })
      ] ++
        Enum.flat_map(Enum.with_index(blocks), fn {b, i} -> block(i, b) end) ++ finish("tool_use")

    assert {:ok, r} = Anthropic.parse(wire(events))
    assert r.usage == %{input: 130, cached: 20, output: 12, reasoning: nil}
    assert r.response_metadata == %{"id" => "msg_fixture", "model" => @role.model}
    assert r.known_usage.write == 10
    assert r.known_usage.write_30m == nil
    assert r.known_usage.write_12h == nil

    input =
      [%{"role" => "user", "content" => "original"}] ++
        Enum.map(r.items, &Shape.replay_item/1) ++
        Enum.map(["b", "a"], &Shape.output(%{"call_id" => &1}, "result " <> &1)) ++
        [%{"role" => "user", "content" => "next"}]

    tool = %{
      "name" => "read_file",
      "description" => "Read",
      "parameters" => %{"type" => "object", "additionalProperties" => false}
    }

    body = ChatGPT.request_body(@role, "policy", input, [tool])

    assert body["system"] == [
             %{"type" => "text", "text" => "policy", "cache_control" => %{"type" => "ephemeral"}}
           ]

    assert body["cache_control"] == %{"type" => "ephemeral"}
    assert body["tool_choice"] == %{"type" => "auto"}
    assert hd(body["tools"])["input_schema"] == tool["parameters"]

    assert body["messages"] == [
             %{"role" => "user", "content" => "original"},
             %{"role" => "assistant", "content" => blocks},
             %{
               "role" => "user",
               "content" =>
                 Enum.map(
                   ["b", "a"],
                   &%{"type" => "tool_result", "tool_use_id" => &1, "content" => "result " <> &1}
                 )
             },
             %{"role" => "user", "content" => "next"}
           ]

    refute Map.has_key?(body, "input")
    assert body["max_tokens"] == 128_000
    assert body["thinking"] == %{"type" => "adaptive"}
    assert body["output_config"] == %{"effort" => "high"}
  end

  test "fragments and cumulative usage merge without adding snapshots" do
    events =
      [
        start(%{
          "input_tokens" => 7,
          "cache_read_input_tokens" => 2,
          "cache_creation_input_tokens" => 3
        }),
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "opaque"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "sig"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{call("a") | "input" => %{}}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"Δ\"}"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "message_delta",
          "delta" => %{},
          "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
        },
        %{"type" => "ping"},
        %{"type" => "future_information"}
      ] ++ finish("tool_use")

    assert {:ok, r} = Anthropic.parse(wire(events))
    assert r.usage == %{input: 14, cached: 2, output: 12, reasoning: nil}
    assert List.last(r.items)["arguments"] == JSON.encode!(%{"path" => "Δ"})
    assert hd(hd(r.items)["anthropic_message"]["content"])["signature"] == "sig"
  end

  test "complete validation precedes exposing any call" do
    prefix = [start()] ++ block(0, call("a"))

    for later <- [
          block(1, call("a")),
          block(2, call("b")),
          block(1, %{call("b") | "input" => []}),
          block(1, %{call("b") | "name" => ""}),
          block(1, %{"type" => "server_tool_use"})
        ] do
      assert {:invalid, _} = Anthropic.parse(wire(prefix ++ later ++ finish("tool_use")))
    end

    for reason <- ~w(max_tokens refusal pause_turn stop_sequence) do
      assert {:invalid, _} = Anthropic.parse(wire(prefix ++ finish(reason)))

      refute match?(
               {:ok, _},
               Anthropic.parse(
                 wire(prefix ++ Enum.drop(finish(reason), -1) ++ finish("tool_use"))
               )
             )
    end

    assert {:go_error, "context_too_long", _} =
             Anthropic.parse(wire(prefix ++ finish("model_context_window_exceeded")))

    assert {:transient, _} = Anthropic.parse(wire(prefix))

    assert {:invalid, _} =
             Anthropic.parse(wire(prefix) <> "data: {broken\n\n" <> wire(finish("tool_use")))

    assert {:transient, _} = Anthropic.parse(wire(prefix) <> "data: {broken")
    assert {:invalid, _} = Anthropic.parse(wire([start()] ++ finish("end_turn")))

    assert {:ok, _} =
             Anthropic.parse(
               wire(
                 [start()] ++
                   block(0, %{"type" => "text", "text" => "Answer"}) ++ finish("end_turn")
               )
             )

    for type <- ~w(content_block_start content_block_stop) do
      malformed =
        Enum.map(prefix ++ finish("tool_use"), fn e ->
          if e["type"] == type, do: Map.put(e, "index", 0.0), else: e
        end)

      assert {:invalid, _} = Anthropic.parse(wire(malformed))
    end
  end

  test "partial and malformed counts remain unknown, never fabricated zeros" do
    assert Enum.all?(Map.values(Anthropic.usage(%{})), &is_nil/1)

    for field <-
          ~w(input_tokens cache_read_input_tokens cache_creation_input_tokens output_tokens),
        bad <- [nil, -1, "2", 1.5] do
      counts =
        Map.put(
          %{
            "input_tokens" => 7,
            "cache_read_input_tokens" => 2,
            "cache_creation_input_tokens" => 3,
            "output_tokens" => 4
          },
          field,
          bad
        )

      u = Anthropic.usage(counts)
      if field != "output_tokens", do: assert(u.input == nil), else: assert(u.output == nil)
      assert u.reasoning == nil

      events =
        [start(counts)] ++
          block(0, %{"type" => "text", "text" => "Answer"}) ++
          [
            %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
            %{"type" => "message_stop"}
          ]

      assert {:ok, r} = Anthropic.parse(wire(events))
      if bad != nil, do: assert(r.usage_state == "inconsistent")
    end
  end

  test "complete rendered bytes keep exact inclusive boundary and typed images refuse" do
    render = fn s ->
      ChatGPT.request_body(@role, "policy Δ", [%{"role" => "user", "content" => s}], [])
    end

    overhead = byte_size(JSON.encode!(render.("")))

    for {bytes, fits} <- [{524_287, true}, {524_288, true}, {524_289, false}] do
      assert %{rendered_bytes: ^bytes, fits: ^fits, output_reserve_tokens: 131_072} =
               WorkingContext.measure(render.(String.duplicate("x", bytes - overhead)))
    end

    assert_raise Error, ~r/provider\/unsupported_capability.*external/, fn ->
      ChatGPT.request_body(
        @role,
        "policy",
        [
          %{
            "type" => "function_call_output",
            "output" => [%{"type" => "input_image", "image_url" => "pixels"}]
          }
        ],
        []
      )
    end
  end
end
