defmodule Kogen.PromptCacheTest do
  use ExUnit.Case, async: true
  alias Kogen.{PromptCache, Shape, Usage}

  test "stable boundaries retain authority and isolate dynamic bytes" do
    input = fn suffix ->
      [
        %{
          "role" => "user",
          "content" => PromptCache.contract_blocks("complete Δ contract\n", "# Files\n" <> suffix)
        }
      ]
    end

    tools = [%{"type" => "function", "parameters" => %{"type" => "object"}}]
    first = PromptCache.prepare("gpt-6.1-sol", "policy", input.("a"), tools)
    {_, _, a} = Process.get(:prompt_cache_current)
    second = PromptCache.prepare("gpt-6.1-sol", "policy", input.("b"), tools)
    {_, _, b} = Process.get(:prompt_cache_current)
    assert a.fingerprints == b.fingerprints
    assert first["prompt_cache_key"] == a.conversation_id
    refute first["prompt_cache_options"]
    assert hd(first["input"])["role"] == "developer"
    assert Enum.at(first["input"], 1)["role"] == "user"
    assert hd(Enum.at(first["input"], 1)["content"])["text"] == "complete Δ contract\n"
    refute first == second
    PromptCache.prepare("gpt-6.1-sol", "changed policy", input.("b"), tools)
    {_, _, c} = Process.get(:prompt_cache_current)
    refute c.fingerprints.policy == b.fingerprints.policy
    assert c.fingerprints.contract == b.fingerprints.contract
    assert c.fingerprints.schema == b.fingerprints.schema
    PromptCache.prepare("gpt-6.1-sol", "policy", input.("b"), [%{"parameters" => %{}}])
    {_, _, d} = Process.get(:prompt_cache_current)
    refute d.fingerprints.tools == b.fingerprints.tools
    refute d.fingerprints.schema == b.fingerprints.schema
  end

  test "public key suppression stays in the independent conversation" do
    input = [%{"role" => "user", "content" => "contract"}]
    first = PromptCache.prepare("gpt-6.1-sol", "policy", input, [])
    PromptCache.complete(%{"id" => "resp_1"})
    assert PromptCache.prepare("gpt-6.1-sol", "policy", input, []) == first
    PromptCache.unsupported()
    refute PromptCache.prepare("gpt-6.1-sol", "policy", input, [])["prompt_cache_key"]

    assert PromptCache.prepare("gpt-6.1-sol", "independent review", input, [])["prompt_cache_key"] !=
             first["prompt_cache_key"]

    for model <- ["gpt-5.4", "unknown"] do
      body = PromptCache.prepare(model, "policy", input, [])
      assert body["prompt_cache_key"]
      refute body["prompt_cache_options"]
      assert body["instructions"] == "policy"
      assert hd(body["input"])["role"] == "user"
    end
  end

  test "legacy options refusal does not suppress a new key but a key refusal survives restore" do
    input = [%{"role" => "user", "content" => "contract"}]
    first = PromptCache.prepare("gpt-6.1-sol", "policy", input, [])
    {key, state, _} = Process.get(:prompt_cache_current)
    legacy = state |> Map.delete(:control) |> Map.put(:unsupported, true)
    Process.put(:prompt_cache_states, %{key => legacy})
    assert PromptCache.prepare("gpt-6.1-sol", "policy", input, []) == first
    PromptCache.unsupported()
    restored = Process.get(:prompt_cache_states)
    Process.delete(:prompt_cache_states)
    Process.put(:prompt_cache_states, restored)
    refute PromptCache.prepare("gpt-6.1-sol", "policy", input, [])["prompt_cache_key"]
  end

  test "replay preserves valid supported fields without manufacturing absent legacy values" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "r",
      "encrypted_content" => "opaque",
      "summary" => [],
      "output_only" => true
    }

    assert Shape.replay_item(reasoning) == Map.delete(reasoning, "output_only")

    assert Shape.replay_item(%{"type" => "reasoning", "summary" => []}) == %{
             "type" => "reasoning",
             "summary" => []
           }

    message = %{
      "type" => "message",
      "id" => "m",
      "role" => "assistant",
      "phase" => "commentary",
      "content" => [%{"type" => "refusal", "refusal" => "no"}]
    }

    assert Shape.replay_item(message) == message
    assert Shape.replay_item(%{"type" => "unknown"}) == nil
    assert Shape.replay_item(%{"type" => "message", "content" => [%{"type" => "invalid"}]}) == nil

    assert Shape.replay_item(%{
             "type" => "function_call",
             "call_id" => "c",
             "name" => "tool",
             "arguments" => "{}"
           }) == %{
             "type" => "function_call",
             "call_id" => "c",
             "name" => "tool",
             "arguments" => "{}"
           }
  end

  test "optional diagnostics are bounded classified evidence, not text" do
    for type <- ~w(cache_hit cache_miss comparison_response_not_found unavailable) do
      assert PromptCache.diagnostics(%{"type" => type, "reason" => "secret", "raw" => "secret"}) ==
               %{type: type, reason: "other"}
    end

    assert PromptCache.diagnostics([]) == nil
    assert PromptCache.diagnostics(nil) == nil
  end

  test "usage validates disjoint writes and subset reasoning without clamping" do
    valid = %{
      input: 100,
      cached: 20,
      write: 80,
      write_30m: 40,
      write_12h: 40,
      output: 10,
      reasoning: 10
    }

    assert Usage.state(valid) == "known"

    for changed <- [
          %{cached: 21},
          %{write_12h: 41},
          %{reasoning: 11},
          %{input: -1},
          %{write: "invalid"}
        ] do
      assert Usage.state(Map.merge(valid, changed)) == "inconsistent"
    end

    assert Usage.state(%{valid | write: nil, write_30m: nil, write_12h: nil}) == "partial"
  end
end
