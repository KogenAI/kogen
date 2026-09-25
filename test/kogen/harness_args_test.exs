defmodule Kogen.HarnessArgsTest do
  use ExUnit.Case, async: true
  alias Kogen.Harness

  test "Developer starts Codex exec with JSON events, hooks, and reasoning effort" do
    args = Harness.developer_args("gpt-5.6", "high")
    assert Enum.take(args, 1) == ["exec"]
    assert "--json" in args
    assert "hooks" in args
    assert "--dangerously-bypass-hook-trust" in args
    assert "--dangerously-bypass-approvals-and-sandbox" in args
    assert "model_reasoning_effort=\"high\"" in args
    assert List.last(args) == "-"
  end

  test "the tracked codex route launches each root role with its exact GPT-6 profile" do
    assert {:ok, config} = Kogen.Intent.read_config(".kogen/config.yaml", "codex")
    assert config.harness == "codex"
    developer = Harness.developer_args(config.developer.model, config.developer.effort)
    resumed = Harness.developer_args(config.developer.model, config.developer.effort, "abc-123")
    reviewer = Harness.reviewer_args(config.reviewer.model, config.reviewer.effort)
    sol_medium = ["--model", "gpt-6-sol", "-c", "model_reasoning_effort=\"medium\""]
    sol_high = ["--model", "gpt-6-sol", "-c", "model_reasoning_effort=\"high\""]

    assert Enum.slice(developer, 1, 4) == sol_medium
    assert Enum.slice(resumed, 2, 4) == sol_medium
    assert Enum.take(resumed, -2) == ["abc-123", "-"]
    assert Enum.slice(reviewer, 1, 4) == sol_high

    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-shaper-route-#{System.pid()}-#{System.unique_integer([:positive])}.md"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, "Shape one Intent.")

    assert Enum.take(Harness.shaper_args(config.shaping.model, config.shaping.effort, path), 4) ==
             sol_medium

    for args <- [developer, resumed, reviewer] do
      refute Enum.any?(args, &(&1 =~ "gpt-5" or &1 =~ "terra"))
    end
  end

  # The hybrid route's adversarial Expert launches with its own exact profile
  # and its harness's existing unattended flags; it is read-only on Claude
  # Code like the Reviewer.
  test "hybrid Expert args carry their exact profile and harness flags" do
    assert {:ok, config} =
             Kogen.Intent.read_config(".kogen/config.yaml", "claude-dominant-adversarial-codex")

    assert Kogen.Intent.role_harness(config, :expert) == "codex"
    profile = Map.fetch!(config, :expert)
    args = Harness.Codex.expert_args(profile.model, profile.effort)

    assert Enum.take(args, 5) == [
             "exec",
             "--model",
             "gpt-6-sol",
             "-c",
             ~s(model_reasoning_effort="high")
           ]

    assert "--dangerously-bypass-approvals-and-sandbox" in args
    assert "--dangerously-bypass-hook-trust" in args
    assert List.last(args) == "-"
    refute "resume" in args

    assert {:ok, mirror} =
             Kogen.Intent.read_config(".kogen/config.yaml", "codex-dominant-adversarial-claude")

    context = %{config: Kogen.Intent.role_config(mirror, :expert)}

    args =
      Harness.Claude.expert_args(mirror.expert.model, mirror.expert.effort, context, "s-1")

    assert Enum.take(args, 4) == ["-p", "--output-format", "stream-json", "--verbose"]
    assert "--dangerously-skip-permissions" in args
    assert ["--model", "claude-opus-5-5"] in Enum.chunk_every(args, 2, 1, :discard)
    assert ["--effort", "high"] in Enum.chunk_every(args, 2, 1, :discard)
    assert ["--session-id", "s-1"] in Enum.chunk_every(args, 2, 1, :discard)

    for tool <- ~w(Edit Write NotebookEdit),
        do: assert(tool in Harness.Claude.disallowed_tools("expert"))
  end

  test "Developer resumes the exact Codex thread" do
    args = Harness.developer_args("gpt-5.6", "high", "abc-123")
    assert Enum.take(args, 2) == ["exec", "resume"]
    assert Enum.take(args, -2) == ["abc-123", "-"]
    assert "--json" in args
  end

  test "Reviewer uses noninteractive JSON Codex transport; schema files are added at launch" do
    args = Harness.reviewer_args("gpt-5.6", "medium")
    assert Enum.take(args, 1) == ["exec"]
    assert "--json" in args
    refute "--ignore-user-config" in args
    refute "--output-schema" in args
  end

  test "Shaping Controller passes the rendered prompt as Codex's interactive initial prompt" do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-shaper-#{System.pid()}-#{System.unique_integer([:positive])}.md"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, "Shape one Intent.")
    args = Harness.shaper_args("gpt-5.6", "medium", path)
    assert "hooks" in args
    assert Enum.take(args, -2) == ["--", "Shape one Intent."]
    refute "exec" in args
    refute "--json" in args
  end
end
