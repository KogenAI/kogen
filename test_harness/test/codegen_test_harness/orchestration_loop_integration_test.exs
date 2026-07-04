defmodule CodegenTestHarness.OrchestrationLoopIntegrationTest do
  @moduledoc """
  Non-mocked end-to-end proof that `OrchestrationLoop.run/1` drives a real
  static-stack cycle (real `codegen-call` invocations, real `claude` CLI,
  real gate) to COMMITTED with a clean, advanced git history — as opposed
  to the mocked unit tests in `orchestration_loop_test.exs`, which stub
  every role's `invoke_fn`/`gate_fn` and never touch a real git repo or a
  real LLM call.
  """

  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag timeout: 1_800_000

  alias CodegenTestHarness.OrchestrationLoop

  @codegen_scaffold Path.expand("../../../codegen-scaffold", __DIR__)

  setup do
    unless System.find_executable("claude") do
      raise "orchestration_loop_integration_test: `claude` CLI not found on PATH — " <>
              "cannot drive a real loop cycle"
    end

    unless System.find_executable("node") do
      raise "orchestration_loop_integration_test: `node` not found on PATH — " <>
              "required for the static-stack render-check gate step"
    end

    parent =
      Path.join(
        System.tmp_dir!(),
        "loop_integration_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(parent)
    on_exit(fn -> File.rm_rf!(parent) end)

    slug = "loop-int-#{:erlang.unique_integer([:positive])}"

    unless File.exists?(@codegen_scaffold) do
      raise "orchestration_loop_integration_test: codegen-scaffold not found at #{@codegen_scaffold}"
    end

    {output, exit_code} =
      System.cmd(
        @codegen_scaffold,
        ["create", "--stack=static", "--cwd=#{parent}", "--slug=#{slug}"],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      raise "orchestration_loop_integration_test: codegen-scaffold create failed " <>
              "(exit=#{exit_code}):\n#{output}"
    end

    tmp = Path.join(parent, slug)

    unless File.dir?(Path.join(tmp, ".git")) do
      raise "orchestration_loop_integration_test: scaffolded app at #{tmp} is not a git repo " <>
              "(codegen-scaffold create must commit the initial scaffold)"
    end

    {porcelain, 0} = System.cmd("git", ["-C", tmp, "status", "--porcelain"])

    if String.trim(porcelain) != "" do
      raise "orchestration_loop_integration_test: scaffolded app at #{tmp} has an unclean " <>
              "working tree before the loop even starts:\n#{porcelain}"
    end

    {:ok, tmp: tmp}
  end

  test "loop reaches COMMITTED with a real new commit and clean tree", %{tmp: tmp} do
    {head_before, 0} = System.cmd("git", ["-C", tmp, "rev-parse", "HEAD"])
    head_before = String.trim(head_before)

    assert :ok ==
             OrchestrationLoop.run(
               harness: "claude_code",
               stack: "static",
               cwd: tmp,
               pitch: "Add a single tagline element to the homepage."
             )

    {head_after, 0} = System.cmd("git", ["-C", tmp, "rev-parse", "HEAD"])
    assert String.trim(head_after) != head_before, "expected a NEW commit; HEAD did not advance"

    {porcelain, 0} = System.cmd("git", ["-C", tmp, "status", "--porcelain"])
    assert String.trim(porcelain) == "", "working tree must be clean after committer"

    gate_json = Path.join([tmp, "codegen", "gate-pending", "gate-result.json"])
    assert File.exists?(gate_json)
    # gate-result.sh's verdict vocabulary is clear|failed|inconclusive, never
    # "passed" — LoopGate.run_gate/2 returns {:clear, _} on success.
    assert Jason.decode!(File.read!(gate_json))["verdict"] == "clear"
  end
end
