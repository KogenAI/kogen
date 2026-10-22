defmodule Kogen.OpenCodeGoTest do
  use ExUnit.Case, async: true
  alias Kogen.{ChatGPT, Error, OpenCodeGo, Shape, Usage, WorkingContext}
  @role %{provider: "opencode-go", model: "kimi-k3", effort: "high"}
  defp response(raw, extra \\ %{}),
    do: Map.merge(%{"choices" => [%{"message" => raw, "finish_reason" => "tool_calls"}]}, extra)

  defp call(id),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"Δ\"}"}
    }

  test "lossless ordered raw replay suppresses duplicate text and all normalized calls" do
    raw = %{
      "role" => "assistant",
      "content" => "unchanged Δ",
      "reasoning" => "private scalar",
      "reasoning_details" => [%{"type" => "reasoning.text", "index" => 0, "vendor" => [2, 1]}],
      "tool_calls" => [call("b"), call("a")]
    }

    {:ok, r} = OpenCodeGo.adapt(response(raw))
    assert r.usage == %{input: nil, cached: nil, output: nil, reasoning: nil}
    assert r.usage_state == "unknown"
    assert Usage.add(Usage.zero(), r.usage) == r.usage
    assert Usage.total(r.usage) == "unknown"

    input = [
      %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "original Δ\n"}]}
    ]

    replay = Enum.map(r.items, &Shape.replay_item/1)

    outputs =
      Enum.map(
        ["b", "a"],
        &%{"type" => "function_call_output", "call_id" => &1, "output" => "output " <> &1}
      )

    body = ChatGPT.request_body(@role, "policy", input ++ replay ++ outputs, [])

    assert body["messages"] == [
             %{"role" => "system", "content" => "policy"},
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "original Δ\n"}]},
             raw,
             %{"role" => "tool", "tool_call_id" => "b", "content" => "output b"},
             %{"role" => "tool", "tool_call_id" => "a", "content" => "output a"}
           ]
  end

  test "a malformed later call, refusal, truncation or explicit error returns no executable items" do
    raw = %{"role" => "assistant", "content" => nil, "tool_calls" => [call("a"), call("b")]}

    for invalid <- [
          response(
            Map.put(raw, "tool_calls", [
              call("a"),
              put_in(call("b"), ["function", "arguments"], "[]")
            ])
          ),
          response(Map.put(raw, "refusal", "refused")),
          response(%{"role" => "assistant", "content" => "text", "tool_calls" => false}),
          response(%{"role" => "assistant", "content" => "text", "tool_calls" => []}),
          response(Map.delete(raw, "content")),
          response(raw, %{"choices" => [%{"message" => raw, "finish_reason" => "length"}]}),
          response(raw, %{"error" => %{"code" => "failure"}}),
          %{"choices" => []},
          response(Map.put(raw, "tool_calls", [call("a"), call("a")]))
        ] do
      assert {:invalid, _} = OpenCodeGo.adapt(invalid)
    end
  end

  test "complete selected adapter bytes are inclusive, and images fail before transport" do
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
        "p",
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

  test "routing separates provider, model, contract, tools, owner and window while retaining append-only identity" do
    input = [%{"role" => "user", "content" => "contract"}]

    session = fn role, items, tools ->
      ChatGPT.request_body(role, "policy", items, tools)
      {_, _, m} = Process.get(:prompt_cache_current)
      m.conversation_id
    end

    id = session.(@role, input, [])
    assert id == session.(@role, input ++ [%{"role" => "user", "content" => "turn"}], [])
    refute id == session.(%{@role | provider: "supergrok"}, input, [])
    refute id == session.(%{@role | model: "other"}, input, [])
    refute id == session.(@role, [%{"role" => "user", "content" => "changed"}], [])
    refute id == session.(@role, input, [%{"type" => "function", "name" => "read"}])
    Process.put(:provider_conversation_scope, "fresh review")
    refute id == session.(@role, input, [])
    Process.delete(:provider_conversation_scope)
    Process.put(:provider_working_window, 1)
    refute id == session.(@role, input, [])
  end
end
