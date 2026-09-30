defmodule Kogen.HarnessArgsTest do
  use ExUnit.Case, async: true

  # Resolved from this file, never the shared VM's mutable working directory.
  @root Path.expand("../..", __DIR__)
  @config_path Path.join(@root, ".kogen/config.yaml")
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
    assert {:ok, config} = Kogen.Intent.read_config(@config_path, "codex")
    assert config.harness == "codex"
    developer = Harness.developer_args(config.developer.model, config.developer.effort)
    resumed = Harness.developer_args(config.developer.model, config.developer.effort, "abc-123")
    reviewer = Harness.reviewer_args(config.reviewer.model, config.reviewer.effort)
    sol_medium = ["--model", "gpt-6.1-sol", "-c", "model_reasoning_effort=\"medium\""]
    sol_high = ["--model", "gpt-6.1-sol", "-c", "model_reasoning_effort=\"high\""]

    assert Enum.slice(developer, 1, 4) == sol_high
    assert Enum.slice(resumed, 2, 4) == sol_high
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

  test "the frozen default optimum route launches every role and native helper with its exact profile" do
    assert {:ok, config} = Kogen.Intent.read_config(@config_path)
    assert config.route == "optimum"

    developer = Kogen.Intent.role_config(config, :developer)
    assert developer.harness == "claude"
    context = %{config: developer}
    args = Harness.Claude.developer_args("claude-opus-5-5", "medium", context, {:fresh, "s-1"})
    pairs = Enum.chunk_every(args, 2, 1, :discard)

    assert ["--model", config.developer.model] in pairs
    assert ["--effort", config.developer.effort] in pairs
    assert {config.developer.model, config.developer.effort} == {"claude-opus-5-5", "medium"}

    agents = args |> Enum.at(Enum.find_index(args, &(&1 == "--agents")) + 1) |> Jason.decode!()
    assert agents["kogen-worker"]["model"] == "claude-sonnet-5-5"
    assert agents["kogen-worker"]["effort"] == "medium"
    assert agents["kogen-scout"]["model"] == "claude-sonnet-5-5"
    assert agents["kogen-scout"]["effort"] == "low"
    # The Expert runs on Codex: no native Claude stand-in is launched.
    refute Map.has_key?(agents, "kogen-expert")

    for builtin <- ~w(general-purpose Explore Plan),
        do: assert("Agent(#{builtin})" in Harness.Claude.disallowed_tools("developer"))

    # The Codex Reviewer and Expert launch Sol High; the Codex Shaper Astra Low.
    assert Kogen.Intent.role_harness(config, :reviewer) == "codex"
    reviewer = Harness.reviewer_args(config.reviewer.model, config.reviewer.effort)

    assert Enum.slice(reviewer, 1, 4) == [
             "--model",
             "gpt-6.1-sol",
             "-c",
             ~s(model_reasoning_effort="high")
           ]

    expert = Harness.Codex.expert_args(config.expert.model, config.expert.effort)

    assert Enum.slice(expert, 1, 4) == [
             "--model",
             "gpt-6.1-sol",
             "-c",
             ~s(model_reasoning_effort="high")
           ]

    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-optimum-shaper-#{System.pid()}-#{System.unique_integer([:positive])}.md"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, "Shape one Intent.")
    assert Kogen.Intent.role_harness(config, :shaping) == "codex"

    assert Enum.take(Harness.shaper_args(config.shaping.model, config.shaping.effort, path), 4) ==
             ["--model", "gpt-6-astra", "-c", ~s(model_reasoning_effort="low")]

    # The Codex roles' native worker is Luna Max on optimum only.
    assert Kogen.Intent.role_config(config, :reviewer).helpers.worker ==
             %{model: "gpt-6-luna", effort: "max"}

    policy = Kogen.ExecutionPolicy.render(config, "reviewer", @root)
    assert policy =~ "`gpt-6-luna` at `max`; native kind `worker`"
  end

  test "Sonnet 5.5 is accepted only with its verified efforts; unknown models and efforts reject" do
    dir = Path.join(System.tmp_dir!(), "kogen-sonnet-55-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    tracked = File.read!(@config_path)

    for {label, replacement, expected} <- [
          {"verified-low", "{model: claude-sonnet-5-5, effort: low}", :ok},
          {"unverified-high", "{model: claude-sonnet-5-5, effort: high}", :error},
          {"unknown-model", "{model: claude-sonnet-9, effort: medium}", :error}
        ] do
      path = Path.join(dir, label <> ".yaml")

      File.write!(
        path,
        String.replace(
          tracked,
          "worker: {model: claude-sonnet-5-5, effort: medium}",
          "worker: " <> replacement
        )
      )

      result = Kogen.Intent.read_config(path, "optimum")

      case expected do
        :ok -> assert {:ok, %{route: "optimum"}} = result
        :error -> assert {:error, _reason} = result
      end
    end
  end

  # The hybrid route's adversarial Expert launches with its own exact profile
  # and its harness's existing unattended flags; it is read-only on Claude
  # Code like the Reviewer.
  test "hybrid Expert args carry their exact profile and harness flags" do
    assert {:ok, config} =
             Kogen.Intent.read_config(@config_path, "claude-dominant-adversarial-codex")

    assert Kogen.Intent.role_harness(config, :expert) == "codex"
    profile = Map.fetch!(config, :expert)
    args = Harness.Codex.expert_args(profile.model, profile.effort)

    assert Enum.take(args, 5) == [
             "exec",
             "--model",
             "gpt-6.1-sol",
             "-c",
             ~s(model_reasoning_effort="high")
           ]

    assert "--dangerously-bypass-approvals-and-sandbox" in args
    assert "--dangerously-bypass-hook-trust" in args
    assert List.last(args) == "-"
    refute "resume" in args

    assert {:ok, mirror} =
             Kogen.Intent.read_config(@config_path, "codex-dominant-adversarial-claude")

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
             Harness.launch_build_developer("p", "gpt-6.1-sol", "medium", [], context)

    assert failure["output_tail"] =~ "server_overloaded"
    assert byte_size(evidence.diagnostics) > 16_384
    assert byte_size(evidence.output_tail) <= 16_384
    assert evidence.output_tail =~ "server_overloaded"

    assert %{"kind" => "overload", "retry" => true} =
             ProviderMarker.classify(evidence.output_tail)
  end
end
