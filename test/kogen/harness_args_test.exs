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
