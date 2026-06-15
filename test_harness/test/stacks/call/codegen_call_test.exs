defmodule CodegenTestHarness.Stacks.Call.CodegenCallTest do
  @moduledoc "Schema-conformance contract for codegen-call structured output."

  use ExUnit.Case, async: false

  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 600_000

  @schema ~s({"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]})

  test "structured call returns schema-conformant JSON" do
    env =
      Fixtures.run_codegen_call(
        "Classify this message: Hello, how do I set up the platform?",
        @schema,
        role: "inspector",
        system_prompt: "You classify messages; reply only with the structured fields."
      )

    assert env["result"]["status"] == "success"
    assert is_map(env["result"]["value"])
    assert Map.has_key?(env["result"]["value"], "lang")
    assert Map.has_key?(env["result"]["value"], "intent")
  end

  test "schema-bound call never returns a clarifying_question" do
    env =
      Fixtures.run_codegen_call(
        "What do you need to know?",
        @schema,
        role: "inspector",
        system_prompt: "Reply only with the structured fields."
      )

    assert env["result"]["status"] in ["success", "failed"]
    refute env["result"]["status"] == "clarifying_question"
  end
end
