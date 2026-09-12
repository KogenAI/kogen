defmodule Kogen.ExecutionPolicyTest do
  use ExUnit.Case, async: true

  test "all roles receive the complete shared policy without expanding role authority" do
    {:ok, config} = Kogen.Intent.read_config()

    for role <- ["shaping", "developer", "reviewer"] do
      policy = Kogen.ExecutionPolicy.render(config, role)
      assert length(Regex.scan(~r/## Shared execution and delegation policy/, policy)) == 1
      refute policy =~ "{{"

      for obligation <- [
            "preparation, startup, cache/context transfer, coordination",
            "verification and repair all count",
            "Batch independent tools",
            "Reuse relevant helpers",
            "stopping\nconditions",
            "exclusive write ownership",
            "useful independent root work",
            "no mandatory fanout, spawn quota or automatic escalation",
            "concise advisory conclusions, source locators",
            "against actual source bytes",
            "Never reconstruct prose as an exact quote",
            "Reviewer and every child are read-only",
            "human product/UX decisions and explicit same-conversation",
            "Developer owns\nimplementation and handoff within approved paths",
            "missing usage is not\nzero",
            "Unit prices or raw tokens do not establish complete-task savings",
            "same-Developer rework, fresh independent Review"
          ] do
        assert policy =~ obligation
      end
    end
  end

  test "each role template has one insertion and retains its authoritative completion contract" do
    for role <- ["shaping", "developer", "reviewer"] do
      template = File.read!("priv/kogen/prompts/#{role}.md")
      assert length(Regex.scan(~r/\{\{execution_policy\}\}/, template)) == 1
      refute template =~ "{{scout_model}}"
      refute template =~ "## Proactive native delegation"
    end

    assert File.read!("priv/kogen/prompts/developer.md") =~ "{{verification_ownership}}"
    assert File.read!("priv/kogen/prompts/developer.md") =~ "Required final Developer handoff"
    assert File.read!("priv/kogen/prompts/reviewer.md") =~ "You must not modify the Candidate"
    assert File.read!("priv/kogen/prompts/reviewer.md") =~ "schema-valid final verdict yourself"
    assert File.read!("priv/kogen/prompts/shaping.md") =~ "in this same conversation"
  end
end
