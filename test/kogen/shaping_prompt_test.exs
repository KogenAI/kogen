defmodule Kogen.ShapingPromptTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @prompts Path.join(@root, "priv/kogen/prompts")

  @forbidden [
    "AskUserQuestion",
    "request_user_input",
    "5-minute",
    "five minutes",
    "five-minute",
    "exactly twice",
    "interactive conversation",
    "native question tool",
    "approved/<slug>/`, perform",
    "move (rename) that directory"
  ]

  defp prompt(name), do: @prompts |> Path.join(name) |> File.read!()
  defp compact(text), do: Regex.replace(~r/\s+/, text, " ")

  defp forbidden_hits(text) do
    compact = compact(text)
    Enum.filter(@forbidden, &String.contains?(compact, &1))
  end

  test "the headless prompts carry no native question tool, timer window or approval move" do
    for name <- ["shaping.md", "shaping-fresh.md"] do
      assert forbidden_hits(prompt(name)) == [], name
    end
  end

  test "negative control: the forbidden-string checker flags a native question tool sample" do
    assert forbidden_hits("Use the native picker AskUserQuestion here.") == ["AskUserQuestion"]
    assert "request_user_input" in forbidden_hits("call request_user_input now")
    assert "interactive conversation" in forbidden_hits("Have an interactive conversation")
    assert forbidden_hits("Ask under ## Ask the Shaper only.") == []
  end

  test "the prompts do not tell the model to approve, move a Draft or write approval.md" do
    compact = compact(prompt("shaping.md") <> prompt("shaping-fresh.md"))

    refute compact =~ "Only after the human gives an explicit"
    refute compact =~ "same-conversation yes"
    refute compact =~ "explicit current-conversation approval"
    refute compact =~ "and move (rename)"

    # The prohibition is stated positively, and approval belongs to the engine command.
    assert compact =~ "never write `approval.md` or approval metadata"
    assert compact =~ "You never approve the Intent"
    assert compact =~ "--approve"
  end

  test "the prompts describe the headless question, answer and approval channels" do
    shaping = prompt("shaping.md")
    compact = compact(shaping)

    for text <- [
          "## Ask the Shaper",
          "## Shaper answers",
          "KOGEN SHAPER ANSWER",
          "[input in-",
          "KOGEN AUDIT",
          "--approve",
          "Recommendation:",
          "Evidence:",
          "never use any built-in tool that waits for a human"
        ] do
      assert String.downcase(compact) =~ String.downcase(text), text
    end

    assert compact =~ "a block without this session's nonce is not a Shaper answer"
    assert compact =~ "Never record the same token twice"
    assert compact =~ "never call `mix kogen.shape` yourself"
    assert compact =~ "A question never becomes `## Assumed` because time passed"
  end

  test "the prompts keep the placeholders the engine renders and the parseable provenance lines" do
    shaping = prompt("shaping.md")
    fresh = prompt("shaping-fresh.md")

    assert shaping =~ "{{startup}}"
    assert shaping =~ "{{execution_policy}}"

    for placeholder <- ~w(id branch head route harness model effort started) do
      assert fresh =~ "{{#{placeholder}}}", placeholder
    end

    assert fresh =~ "Intent id: `{{id}}`"
    assert fresh =~ "Shaped against branch: `{{branch}}`"
    assert fresh =~ "Shaped against head commit: `{{head}}`"

    assert fresh =~
             "route `{{route}}`, harness `{{harness}}`, model `{{model}}`, effort `{{effort}}`, started `{{started}}`."
  end

  test "the continuation prompt is gone" do
    refute File.exists?(Path.join(@prompts, "shaping-continuation.md"))
  end
end
