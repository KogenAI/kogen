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
    assert File.read!("priv/kogen/prompts/developer.md") =~ "## Final Developer notes"
    assert File.read!("priv/kogen/prompts/reviewer.md") =~ "You must not modify the Candidate"
    assert File.read!("priv/kogen/prompts/reviewer.md") =~ "schema-valid final verdict yourself"
    assert File.read!("priv/kogen/prompts/shaping.md") =~ "in this same conversation"
  end

  test "Claude Code roles name the configured Claude Code agents instead of Codex native kinds" do
    config = %{
      harness: "claude",
      shaping: %{model: "claude-opus-5-5", effort: "medium"},
      developer: %{model: "claude-opus-5-5", effort: "medium"},
      reviewer: %{model: "claude-opus-5-5", effort: "medium"},
      helpers: %{
        scout: %{model: "claude-sonnet-5", effort: "low"},
        worker: %{model: "claude-sonnet-5", effort: "medium"},
        expert: %{model: "claude-opus-5-5", effort: "high"}
      }
    }

    for role <- ["shaping", "developer", "reviewer"] do
      policy = Kogen.ExecutionPolicy.render(config, role)
      assert policy =~ "- **scout:** `claude-sonnet-5` at `low`; Claude Code agent `kogen-scout`."

      assert policy =~
               "- **worker:** `claude-sonnet-5` at `medium`; Claude Code agent `kogen-worker`."

      assert policy =~
               "- **expert:** `claude-opus-5-5` at `high`; Claude Code agent `kogen-expert`."

      assert policy =~ "never to built-in agents"
      refute policy =~ "native kind"
      refute policy =~ "native agent-kind enums"
    end

    codex = Kogen.ExecutionPolicy.render(%{config | harness: "codex"}, "developer")
    assert codex =~ "native kind `explorer`"
    assert codex =~ "not native agent-kind enums: use the supported kinds above."
  end

  test "each tracked route renders its own helper profiles and harness-specific delegation" do
    {:ok, claude} = Kogen.Intent.read_config(".kogen/config.yaml", "claude")
    {:ok, codex} = Kogen.Intent.read_config(".kogen/config.yaml", "codex")

    for role <- ["shaping", "developer", "reviewer"] do
      claude_policy = Kogen.ExecutionPolicy.render(claude, role)
      codex_policy = Kogen.ExecutionPolicy.render(codex, role)

      assert claude_policy =~
               "- **scout:** `claude-sonnet-5` at `low`; Claude Code agent `kogen-scout`."

      assert codex_policy =~ "- **scout:** `gpt-5.6-luna` at `low`; native kind `explorer`."
      assert codex_policy =~ "- **worker:** `gpt-5.6-luna` at `medium`; native kind `worker`."
      assert codex_policy =~ "- **expert:** `gpt-5.6-sol` at `medium`; native kind `default`."
      refute codex_policy =~ "claude-"
      refute codex_policy =~ "Claude Code agent"
      refute claude_policy =~ "gpt-5.6"
    end

    assert Kogen.ExecutionPolicy.render(codex, "reviewer") =~
             "Configured root (reviewer): `gpt-5.6-terra` at `medium`."
  end

  test "rendering dispatches only on an explicit claude or codex harness" do
    {:ok, codex} = Kogen.Intent.read_config(".kogen/config.yaml", "codex")

    for invalid <- ["pi", "", nil] do
      assert_raise ArgumentError, ~r/unsupported harness/, fn ->
        Kogen.ExecutionPolicy.render(%{codex | harness: invalid}, "developer")
      end
    end

    assert_raise KeyError, fn ->
      Kogen.ExecutionPolicy.render(
        Map.delete(codex, String.to_existing_atom("harness")),
        "developer"
      )
    end
  end
end
