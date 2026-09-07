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
    path = Path.join(System.tmp_dir!(), "kogen-shaper-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "Shape one Intent.")
    args = Harness.shaper_args("gpt-5.6", "medium", path)
    assert "hooks" in args
    assert Enum.take(args, -2) == ["--", "Shape one Intent."]
    refute "exec" in args
    refute "--json" in args
  end
end
