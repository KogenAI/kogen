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

defmodule Kogen.Harness.OutputTailTest do
  @moduledoc """
  Provider stop/exit evidence keeps the TAIL of a long stream, not its first
  4,000 characters, and Developer transport-failure evidence carries an
  `:output_tail` (last ~16 KB) `Kogen.Harness.ProviderMarker` can classify
  (environment-and-provider-classes). Driven with scripted fake executables
  that print > 16 KB of padding before the classifying line, exactly like a
  paid target's make log embeds a nested harness stream.
  """
  use ExUnit.Case, async: true

  alias Kogen.Harness
  alias Kogen.Harness.ProviderMarker

  defp fake_executable(dir, name, script) do
    path = Path.join(dir, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen-output-tail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "Claude: a provider_exit marker past the first 4,000 characters survives", %{dir: dir} do
    executable =
      fake_executable(dir, "claude", """
      #!/bin/sh
      cat > /dev/null
      head -c 20000 /dev/zero | tr '\\0' 'p'
      printf '\\n'
      printf '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"session_id":"s"}\\n'
      exit 1
      """)

    context = %{
      harness: "claude",
      executable: executable,
      args: [],
      env: [],
      config: %{helpers: %{}}
    }

    assert {:error, {:developer_transport_failure, {:provider_exit, 1, evidence_tail}, evidence}} =
             Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], context)

    # A head-truncated (first 4,000 characters) evidence would never carry
    # the classifying line, since it sits after 20,000 bytes of padding.
    assert evidence_tail =~ "api_error_status"
    assert byte_size(evidence_tail) <= 16_384
    assert ProviderMarker.classify(evidence_tail)["kind"] == "usage_limit"
    assert byte_size(evidence.diagnostics) > 16_384
    assert byte_size(evidence.output_tail) <= 16_384
    assert evidence.output_tail =~ "api_error_status"

    assert %{"kind" => "usage_limit", "retry" => false} =
             ProviderMarker.classify(evidence.output_tail)
  end

  test "Codex: a turn.failed provider marker past 16 KB of padding survives on transport-failure evidence",
       %{dir: dir} do
    executable =
      fake_executable(dir, "codex", """
      #!/bin/sh
      cat > /dev/null
      head -c 20000 /dev/zero | tr '\\0' 'p'
      printf '\\n'
      printf '{"type":"thread.started","thread_id":"t1"}\\n'
      printf '{"type":"turn.failed","error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"server_overloaded"}}\\n'
      exit 0
      """)

    context = %{harness: "codex", executable: executable, args: [], env: []}

    assert {:error, {:developer_transport_failure, {:provider_error, failure}, evidence}} =
             Harness.launch_build_developer("p", "gpt-6-sol", "medium", [], context)

    assert failure["output_tail"] =~ "server_overloaded"
    assert byte_size(evidence.diagnostics) > 16_384
    assert byte_size(evidence.output_tail) <= 16_384
    assert evidence.output_tail =~ "server_overloaded"

    assert %{"kind" => "overload", "retry" => true} =
             ProviderMarker.classify(evidence.output_tail)
  end
end
