defmodule CodegenTestHarness.Stacks.Static.GateTest do
  @moduledoc """
  Gate contract for the static stack.

  Asserts that `codegen-build --stack=static` exit 0 implies a committed,
  buildable, and renderable static site. Uses vite_react as the representative
  sub-stack (rich SPA; exercises npm build + headless render checks).
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Create a React app with Vite that shows a counter ) <>
            ~s(with data-testid="increment" and data-testid="count" elements.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build exit 0 implies committed buildable static site", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(cwd, @prompt,
        stack: "static",
        test_name: "gate_static_exit0"
      )

    assert File.exists?(Path.join(cwd, "package.json")),
           "expected package.json in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_built_html_non_blank!(cwd, "public/index.html")
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_renders!(cwd, :static)

    # Structured gate-result.json must be produced by the static build-check hook
    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} — static build-check hook must write structured result"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] == "clear",
           "expected gate-result.json verdict=clear, got: #{inspect(gate_result["verdict"])}"

    assert is_binary(gate_result["gate"]) and gate_result["gate"] != "",
           "expected gate-result.json gate field to be non-empty string"

    Fixtures.bench_assertions_passed!("static", "gate_static_exit0")
  end

  test "static gate failure writes non-clear verdict", %{cwd: cwd} do
    hook = Path.join(File.cwd!(), "../harnesses/claude/hooks/phoenix-dev-gate.sh")
    hook = Path.expand(hook)

    # Scaffold a minimal committed static app so the hook has a real project_dir
    File.write!(Path.join(cwd, "package.json"), Jason.encode!(%{"name" => "test-app"}))
    File.mkdir_p!(Path.join(cwd, "codegen/logging"))

    {_output, 0} =
      System.cmd("git", ["add", "."], cd: cwd, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "init app"],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t"}, {"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t"}]
      )

    # Write a step log whose Gate is `false` — deterministic failure
    log_path =
      Path.join(cwd, "codegen/logging/#{DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")}_step1_fail.md")

    File.write!(log_path, """
    # Step

    ## Plan

    **Gate**: `false`
    """)

    transcript_path = Path.join(cwd, "transcript.jsonl")

    File.write!(
      transcript_path,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "name" => "Write", "input" => %{"file_path" => log_path}}]
        }
      }) <> "\n"
    )

    input =
      Jason.encode!(%{
        "hook_event_name" => "SubagentStop",
        "agent_type" => "developer-phoenix-backend",
        "agent_id" => "abc",
        "session_id" => "test-failure-static",
        "cwd" => cwd,
        "stop_hook_active" => false,
        "transcript_path" => transcript_path
      })

    {_out, _rc} =
      System.cmd("bash", ["-c", "printf '%s' \"$INPUT\" | bash \"$HOOK\""],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"INPUT", input}, {"HOOK", hook}]
      )

    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} after forced gate failure"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] != "clear",
           "expected gate-result.json verdict != clear after forced failure, got: #{inspect(gate_result["verdict"])}"
  end
end
